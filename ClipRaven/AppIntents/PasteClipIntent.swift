import AppIntents
import AppKit
import Foundation
import ClipRavenSync

private func intentLog(_ msg: String) {
    // Reuse the debug log convention from other parts of the app — write next to the .app bundle.
    let line = "\(Date()): \(msg)\n"
    let logPath = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("clipraven_debug.log").path
    let data = Data(line.utf8)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

/// Pastes a `ClipEntity` into the currently frontmost application.
///
/// Behavior notes (important for App Store review and users):
/// - Requires Accessibility permission (Apple's TCC).
/// - Designed to be triggered from **Spotlight**, **Siri**, or an **Automation** —
///   the launcher dismisses itself before the paste fires, so the "frontmost"
///   app is whatever the user was working in.
/// - If invoked from the **Shortcuts editor** directly, we refuse (we'd paste
///   into Shortcuts itself, which is never useful). Instead we return a
///   localized error asking the user to run it from Spotlight/Siri/Automation.
struct PasteClipIntent: AppIntent {
    static var title: LocalizedStringResource = "Paste Clip"
    static var description = IntentDescription(
        "Pastes a ClipRaven clip into the frontmost app. Intended for Spotlight, Siri, or Automation.",
        categoryName: "ClipRaven"
    )

    // This has side effects (simulates ⌘V) — surface it in the Shortcuts catalog.
    static var isDiscoverable: Bool = true
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Clip")
    var clip: ClipEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Paste \(\.$clip) into the frontmost app")
    }

    func perform() async throws -> some IntentResult {
        // Gate 1: accessibility — required for CGEvent paste synthesis
        guard AccessibilityPrompter.isTrusted else {
            intentLog("[PasteClipIntent] blocked: accessibility not trusted")
            throw ClipRavenIntentError.accessibilityRequired
        }

        // Gate 2: refuse when the editor itself is frontmost
        // (invoking the action from the Shortcuts app's test button puts Shortcuts
        //  in front, so the paste would land in its UI — never what the user wants).
        let frontApp = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        let frontBundle = frontApp?.bundleIdentifier ?? ""
        let frontName = frontApp?.localizedName ?? "?"
        intentLog("[PasteClipIntent] frontApp name=\(frontName) bundleId=\(frontBundle)")

        // Match any bundle ID that contains "shortcuts" (case-insensitive) so we catch
        // com.apple.shortcuts, com.apple.Shortcuts, com.apple.shortcuts.events,
        // com.apple.ShortcutsEditor, and any future variants.
        if frontBundle.lowercased().contains("shortcut") {
            intentLog("[PasteClipIntent] blocked: frontmost is Shortcuts-family (\(frontBundle))")
            throw ClipRavenIntentError.cannotPasteIntoShortcutsEditor
        }

        // Gate 3: fetch the live clip (it may have been deleted after the ID was captured)
        let repo = ClipRepository()
        guard let full = try? repo.fetchOne(id: clip.clipId), !full.isDeleted else {
            intentLog("[PasteClipIntent] blocked: clip not found id=\(clip.clipId)")
            throw ClipRavenIntentError.clipNotFound
        }

        // Execute paste on the main actor — pasteboard + simulatePaste both require it.
        intentLog("[PasteClipIntent] pasting clipId=\(clip.clipId) into \(frontName)")
        await MainActor.run {
            MainPanelViewModel.pasteClipStatic(full, clipRepository: repo)
        }

        return .result()
    }
}
