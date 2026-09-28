import AppIntents
import AppKit
import Foundation
import ClipRavenSync

/// 단축어 실행 기록. 시스템 로그(`ClipRavenLog.paste`)로 보내고, DEBUG 빌드만 파일로도
/// 남는다. 이전에는 모든 빌드에서 앱 번들 옆에 `clipraven_debug.log` 를 직접 써서,
/// App Store 판에서는 `/Applications` 쓰기가 샌드박스에 막혀 실행할 때마다 위반이
/// 기록됐다 (테스트 계획 A6).
private func intentLog(_ msg: String) {
    ClipRavenLog.write(.paste, msg)
}

/// Pastes a `ClipEntity` into the currently frontmost application.
///
/// Behavior notes (important for App Store review and users):
/// - Needs the paste (event-posting) permission, which macOS lists under
///   Privacy & Security › Accessibility. Without it the intent throws
///   `accessibilityRequired`.
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
        // Gate 0: 체험 만료 — 패널·단축키와 같은 검사 (v1 리뷰).
        if await MainActor.run(body: { MainPanelViewModel.blockPasteIfExpired() }) {
            intentLog("[PasteClipIntent] blocked: trial expired")
            throw ClipRavenIntentError.trialExpired
        }

        // Gate 1: accessibility — required for CGEvent paste synthesis
        guard PastePermission.isGranted else {
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
