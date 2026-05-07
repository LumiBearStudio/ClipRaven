import Foundation
import Combine
import AppKit
import SwiftUI
import GRDB
import Carbon
import ApplicationServices
import ClipRavenSync

// MARK: - Accessibility Permission
// ClipRaven needs Accessibility to synthesize ⌘V into the frontmost app.
// Since macOS 10.14, CGEvent.post() silently drops keyboard events from
// untrusted processes — without this permission, paste-to-app is dead.
enum AccessibilityPrompter {
    /// True if the app currently has Accessibility permission granted.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Tracks whether we've already prompted this session (avoid repeated alerts).
    private static var didPromptThisSession = false

    /// Show the one-shot system prompt + a guidance alert + deep-link to Settings.
    /// Safe to call repeatedly — only shows the alert once per session.
    @MainActor
    static func requestIfNeeded() {
        // Session guard FIRST — `AXIsProcessTrustedWithOptions(prompt: true)` shows
        // the native dialog every call in TCC-stale states, which is why the user
        // sees the popup on every click. Gate it behind the session flag.
        guard !didPromptThisSession else { return }
        didPromptThisSession = true

        // Fire the TCC prompt (native OS dialog).
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "ClipRaven에 접근성 권한이 필요합니다")
            alert.informativeText = String(localized: """
            선택한 클립을 다른 앱에 자동으로 붙여넣으려면 \
            시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 \
            ClipRaven을 켜주세요.

            권한을 부여하지 않아도 클립보드에는 복사되므로 \
            ⌘V로 직접 붙여넣을 수 있습니다.
            """)
            alert.addButton(withTitle: String(localized: "시스템 설정 열기"))
            alert.addButton(withTitle: String(localized: "나중에"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

private func debugLog(_ msg: String) {
    ClipRavenLog.paste.debug("\(msg, privacy: .public)")
    #if DEBUG
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
    #endif
}

// MARK: - 날짜 범위 필터
enum DateRangeFilter: Equatable {
    case today
    case yesterday
    case lastWeek
    case lastMonth
    case custom(from: Date, to: Date)

    var displayName: LocalizedStringKey {
        switch self {
        case .today: return "오늘"
        case .yesterday: return "어제"
        case .lastWeek: return "최근 7일"
        case .lastMonth: return "최근 30일"
        case .custom: return "사용자 지정"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "sun.max"
        case .yesterday: return "sun.haze"
        case .lastWeek: return "calendar"
        case .lastMonth: return "calendar.badge.clock"
        case .custom: return "calendar.badge.exclamationmark"
        }
    }

    /// 필터의 시작/종료 날짜를 계산
    var dateRange: (from: Date, to: Date) {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, now)
        case .yesterday:
            let todayStart = calendar.startOfDay(for: now)
            let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
            return (yesterdayStart, todayStart)
        case .lastWeek:
            let start = calendar.date(byAdding: .day, value: -7, to: now)!
            return (start, now)
        case .lastMonth:
            let start = calendar.date(byAdding: .day, value: -30, to: now)!
            return (start, now)
        case .custom(let from, let to):
            return (from, to)
        }
    }
}

private func vmDebugLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let logPath = "/tmp/clipraven_debug.log"
    let data = Data(line.utf8)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

@MainActor
final class MainPanelViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var selectedFilter: ContentTypeFilter = .all {
        didSet { restartObservation() }
    }
    @Published var selectedTagIds: Set<Int64> = [] {
        didSet { restartObservation() }
    }
    @Published var showPinned: Bool = true {
        didSet { restartObservation() }
    }
    @Published var selectedSourceApp: String? = nil {
        didSet { restartObservation() }
    }
    @Published var dateRangeFilter: DateRangeFilter? = nil {
        didSet { restartObservation() }
    }
    @Published var selectedAICategory: String? = nil {
        didSet { restartObservation() }
    }
    @Published var searchText: String = ""
    @Published var selectedIndex: Int? = 0
    @Published var selectedIndices: Set<Int> = [0]

    var isMultiSelectMode: Bool { selectedIndices.count > 1 }

    @Published var totalCount: Int = 0
    @Published var filterCounts: [ContentTypeFilter: Int] = [:]
    @Published var boards: [Tag] = []
    @Published var clipTags: [Int64: [Tag]] = [:]  // clipId -> assigned tags

    /// 현재 클립에서 사용 가능한 소스 앱 목록
    var availableSourceApps: [(bundleId: String, name: String)] {
        (try? clipRepository.fetchUniqueSourceApps()) ?? []
    }

    // Preview state
    @Published var showPreview: Bool = false
    @Published var previewClip: Clip? = nil

    /// True while the user is holding the Option key (for ⌥1..⌥0 quick-paste hint overlays).
    @Published var optionKeyHeld: Bool = false

    // Paste Stack
    @Published var pasteStackEngine = PasteStackEngine()

    // Stack feedback
    @Published var stackFeedbackMessage: String? = nil

    // Drag & Drop state
    @Published var draggedClip: Clip? = nil
    @Published var dropTargetIndex: Int? = nil
    @Published var isDragging: Bool = false

    private let clipRepository = ClipRepository()
    private let tagRepository = TagRepository()
    private let searchRepository = SearchRepository()
    private var cancellable: DatabaseCancellable?
    private var searchTask: Task<Void, Never>?
    private var searchCancellable: AnyCancellable?
    private var deleteObserver: Any?
    private var quickPasteObserver: Any?
    private var plainTextPasteObserver: Any?
    private var optionKeyObserver: Any?

    func startObserving() {
        restartObservation()
        updateCounts()
        loadBoards()
        pasteStackEngine.reload()

        // Debounced search: 200ms
        searchCancellable = $searchText
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.performSearch(query)
            }

        // Listen for Delete key from ScrollConvertingPanel
        deleteObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenDeleteSelected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  let idx = self.selectedIndex,
                  idx < self.clips.count else { return }
            self.deleteClip(self.clips[idx])
        }

        // Listen for Option+Enter plain text paste from ScrollConvertingPanel
        plainTextPasteObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenPlainTextPaste,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  let idx = self.selectedIndex,
                  idx < self.clips.count else { return }
            self.pasteClipAsPlainText(self.clips[idx])
        }

        // Listen for Cmd+1-9 quick paste from ScrollConvertingPanel
        quickPasteObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenQuickPaste,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let index = notification.userInfo?["index"] as? Int else { return }
            debugLog("[VM.quickPaste] received index=\(index) clipsCount=\(self.clips.count)")
            self.quickPaste(index: index)
        }

        // (Space key preview is handled by SwiftUI's .keyboardShortcut(" ") in MainPanelView,
        //  which opens DetailModalController — the centered large preview modal.)

        // Option key pressed/released (from ScrollConvertingPanel.flagsChanged).
        // Used to show ⌥1..⌥0 hint badges on cards.
        optionKeyObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenOptionKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pressed = notification.userInfo?["pressed"] as? Bool ?? false
            self?.optionKeyHeld = pressed
        }
    }

    func stopObserving() {
        cancellable?.cancel()
        cancellable = nil
        searchCancellable?.cancel()
        searchCancellable = nil
        searchTask?.cancel()

        if let observer = deleteObserver {
            NotificationCenter.default.removeObserver(observer)
            deleteObserver = nil
        }
        if let observer = quickPasteObserver {
            NotificationCenter.default.removeObserver(observer)
            quickPasteObserver = nil
        }
        if let observer = plainTextPasteObserver {
            NotificationCenter.default.removeObserver(observer)
            plainTextPasteObserver = nil
        }
        if let observer = optionKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            optionKeyObserver = nil
        }
        // Reset state so overlays don't persist across panel hide cycles
        optionKeyHeld = false
    }

    func loadBoards() {
        boards = (try? tagRepository.fetchAll()) ?? []
    }

    func toggleTagFilter(_ tagId: Int64) {
        if selectedTagIds.contains(tagId) {
            selectedTagIds.remove(tagId)
        } else {
            selectedTagIds.insert(tagId)
        }
    }

    // MARK: - Paste (with Cmd+V simulation)

    func pasteClip(_ clip: Clip) {
        Self.pasteClipStatic(clip, clipRepository: clipRepository)
    }

    /// Static paste entry point — callable without a live MainPanelViewModel instance.
    /// Used by global per-clip hotkeys registered from AppDelegate (where the panel may be hidden).
    ///
    /// Matches the instance `pasteClip(_:)` behavior exactly:
    /// - image clips → write PNG to pasteboard, then ⌘V
    /// - file clips → Finder reveal (no paste)
    /// - text / code / URL / color → write string (with URL tracking strip) + ⌘V
    static func pasteClipStatic(_ clip: Clip, clipRepository: ClipRepository) {
        if clip.contentType == .image {
            pasteImageClipStatic(clip, clipRepository: clipRepository)
            return
        }
        if clip.contentType == .file {
            revealFileClipStatic(clip, clipRepository: clipRepository)
            return
        }

        guard let rawContent = clip.contentText else { return }

        // URL tracking param stripping (default ON, setting: stripURLTracking)
        let content: String
        if clip.contentType == .url {
            let stripURL = UserDefaults.standard.object(forKey: "stripURLTracking") as? Bool ?? true
            content = stripURL ? URLNormalizer.stripTracking(rawContent) : rawContent
        } else {
            content = rawContent
        }

        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let targetName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(content, forType: .string)
            pasteboard.setData(Data(), forType: ClipboardMarker.selfType)
            if let clipId = clip.id {
                try? clipRepository.incrementCopyCount(id: clipId)
            }
            simulatePaste(targetPid: targetPid, targetName: targetName)
        }
    }

    /// Static variant of `pasteImageClip` for use outside the panel flow (e.g. per-clip hotkey).
    private static func pasteImageClipStatic(_ clip: Clip, clipRepository: ClipRepository) {
        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let targetName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let path = clip.imagePath,
               let data = ImageStorageService.loadImage(relativePath: path) {
                pasteboard.setData(data, forType: .png)
            } else if let thumbnail = clip.thumbnail {
                pasteboard.setData(thumbnail, forType: .png)
            }
            pasteboard.setData(Data(), forType: ClipboardMarker.selfType)
            if let clipId = clip.id {
                try? clipRepository.incrementCopyCount(id: clipId)
            }
            simulatePaste(targetPid: targetPid, targetName: targetName)
        }
    }

    /// Static variant of `revealFileClip`.
    private static func revealFileClipStatic(_ clip: Clip, clipRepository: ClipRepository) {
        guard let content = clip.contentText else { return }
        let paths = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let urls = paths.compactMap { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)
        if let clipId = clip.id {
            try? clipRepository.incrementCopyCount(id: clipId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(existing)
            } else if let first = urls.first {
                NSWorkspace.shared.open(first.deletingLastPathComponent())
            }
        }
    }

    /// 파일 클립 활성화: Finder에서 파일 위치를 열고 하이라이트.
    /// Finder의 "Paste Item"은 com.apple.finder.noderef private type 없이는 동작하지 않아
    /// 모든 서드파티 clipboard manager가 사용하는 표준 방식(reveal)으로 구현.
    private func revealFileClip(_ clip: Clip) {
        guard let content = clip.contentText else { return }
        let paths = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let urls = paths.compactMap { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)

        if let clipId = clip.id {
            try? clipRepository.incrementCopyCount(id: clipId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // 파일을 Finder에서 선택한 상태로 열기 (없어진 파일은 상위 폴더로 fallback)
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(existing)
            } else if let first = urls.first {
                NSWorkspace.shared.open(first.deletingLastPathComponent())
            }
        }
    }

    private func pasteImageClip(_ clip: Clip) {
        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let targetName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            // Try loading full image from path
            if let path = clip.imagePath,
               let imageData = ImageStorageService.loadImage(relativePath: path) {
                pasteboard.setData(imageData, forType: .png)
            } else if let thumbnail = clip.thumbnail {
                pasteboard.setData(thumbnail, forType: .png)
            }
            pasteboard.setData(Data(), forType: ClipboardMarker.selfType)

            if let clipId = clip.id {
                try? self?.clipRepository.incrementCopyCount(id: clipId)
            }

            Self.simulatePaste(targetPid: targetPid, targetName: targetName)
        }
    }

    func pasteClipAsPlainText(_ clip: Clip) {
        guard let rawContent = clip.contentText else { return }

        // Also strip URL tracking params for URL clips on plain-text paste
        let content: String
        if clip.contentType == .url {
            let stripURL = UserDefaults.standard.object(forKey: "stripURLTracking") as? Bool ?? true
            content = stripURL ? URLNormalizer.stripTracking(rawContent) : rawContent
        } else {
            content = rawContent
        }

        // Capture target app BEFORE panel takes key status
        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let targetName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            // Only set .string type — strips all RTF/HTML formatting
            pasteboard.setString(content, forType: .string)
            pasteboard.setData(Data(), forType: ClipboardMarker.selfType)

            if let clipId = clip.id {
                try? self?.clipRepository.incrementCopyCount(id: clipId)
            }

            Self.simulatePaste(targetPid: targetPid, targetName: targetName)
        }
    }

    /// Paste the clip converted to Markdown syntax (plain text, no formatting).
    /// If the clip text is detected as HTML, run it through FormatConverter.htmlToMarkdown.
    /// Otherwise the text is already Markdown or plain — passed through as-is.
    func pasteClipAsMarkdown(_ clip: Clip) {
        guard let raw = clip.contentText else { return }

        let content: String
        if FormatConverter.looksLikeHTML(raw) {
            content = FormatConverter.htmlToMarkdown(raw)
        } else {
            content = raw
        }

        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let targetName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(content, forType: .string)
            pasteboard.setData(Data(), forType: ClipboardMarker.selfType)
            if let clipId = clip.id {
                try? self?.clipRepository.incrementCopyCount(id: clipId)
            }
            Self.simulatePaste(targetPid: targetPid, targetName: targetName)
        }
    }

    /// Paste the clip as Rich Text (RTF) so target apps like Mail/Pages/Word render
    /// bold, headings, links, etc. Heuristically interprets the source:
    /// - HTML → parsed by NSAttributedString(html:)
    /// - Markdown / plain → parsed by NSAttributedString(markdown:)
    /// Falls back to plain text if conversion fails.
    func pasteClipAsRichText(_ clip: Clip) {
        guard let raw = clip.contentText else { return }

        // Build the richest representation available
        let attributed: NSAttributedString? = {
            if FormatConverter.looksLikeHTML(raw) {
                return FormatConverter.htmlToAttributed(raw)
            }
            return FormatConverter.markdownToAttributed(raw)
        }()

        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let targetName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            // Primary payload: RTF when available (covers Mail/Pages/Notes/Word).
            var wroteRich = false
            if let attributed,
               let rtf = FormatConverter.rtfData(from: attributed) {
                pasteboard.setData(rtf, forType: .rtf)
                // Always include a plain-text fallback so receivers without RTF support still work.
                pasteboard.setString(attributed.string, forType: .string)
                wroteRich = true
            }
            if !wroteRich {
                // Failure path — fall back to plain text of the original
                pasteboard.setString(raw, forType: .string)
            }
            pasteboard.setData(Data(), forType: ClipboardMarker.selfType)

            if let clipId = clip.id {
                try? self?.clipRepository.incrementCopyCount(id: clipId)
            }
            Self.simulatePaste(targetPid: targetPid, targetName: targetName)
        }
    }

    /// 텍스트/코드 클립을 주어진 변환(대문자/소문자/공백제거/한줄합치기)을 적용한 뒤 붙여넣기
    func pasteClipWithTransform(_ clip: Clip, transform: TextTransform) {
        // 텍스트/코드 타입만 지원
        guard clip.contentType == .text || clip.contentType == .code else { return }
        guard let content = clip.contentText else { return }

        let transformed = transform.apply(to: content)

        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let targetName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(transformed, forType: .string)
            pasteboard.setData(Data(), forType: ClipboardMarker.selfType)

            if let clipId = clip.id {
                try? self?.clipRepository.incrementCopyCount(id: clipId)
            }

            Self.simulatePaste(targetPid: targetPid, targetName: targetName)
        }
    }

    /// Synthesize ⌘V into the previously-frontmost app.
    /// Requires Accessibility permission — if missing, prompts the user once and
    /// falls back to pasteboard-only (user must manually ⌘V).
    ///
    /// - Parameters:
    ///   - targetPid: PID captured BEFORE the panel became key window. Used as the
    ///     destination for PID-direct delivery (bypasses focus-routing race).
    ///   - targetName: Human-readable name for logging/alerts.
    static func simulatePaste(targetPid: pid_t, targetName: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Gate 1: Accessibility permission. Without it, CGEvent.post silently drops
            // since macOS 10.14 — this was the root cause of the long-standing paste bug.
            if !AXIsProcessTrusted() {
                debugLog("[simulatePaste] BLOCKED: AXIsProcessTrusted=false — showing permission alert")
                AccessibilityPrompter.requestIfNeeded()
                return
            }

            debugLog("[simulatePaste] entering target=\(targetName) pid=\(targetPid) AXTrusted=true")

            let source = CGEventSource(stateID: .combinedSessionState)

            // Maccy pattern: suppress physical key interleaving during paste synthesis
            // so holding ⌥ (from ⌥1-9) doesn't corrupt the ⌘V that follows.
            source?.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitSystemDefinedEvents],
                state: .eventSuppressionStateSuppressionInterval
            )

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand

            // Prefer PID-direct delivery when we have a valid target — removes the
            // focus-routing race entirely. Falls back to session tap otherwise.
            if targetPid > 0 {
                keyDown?.postToPid(targetPid)
                keyUp?.postToPid(targetPid)
                debugLog("[simulatePaste] posted ⌘V via postToPid=\(targetPid) (\(targetName))")
            } else {
                keyDown?.post(tap: .cgSessionEventTap)
                keyUp?.post(tap: .cgSessionEventTap)
                debugLog("[simulatePaste] posted ⌘V via session tap (no target pid)")
            }
        }
    }

    // MARK: - Card Actions

    func deleteClip(_ clip: Clip) {
        guard let clipId = clip.id else { return }
        // Revoke custom hotkey registration before soft-delete so the combo is freed.
        if clip.customShortcutKeyCode != nil {
            NotificationCenter.default.post(
                name: .clipRavenClipShortcutChanged,
                object: nil,
                userInfo: ["clipId": clipId, "deleted": true]
            )
        }
        try? clipRepository.softDelete(id: clipId)
    }

    // MARK: - Custom shortcut management

    /// Assign a global hotkey to a clip. AppDelegate picks up the change via notification.
    func assignClipShortcut(clip: Clip, keyCode: UInt32, modifiers: UInt32) {
        guard let clipId = clip.id else { return }
        try? clipRepository.updateCustomShortcut(id: clipId, keyCode: keyCode, modifiers: modifiers)
        NotificationCenter.default.post(
            name: .clipRavenClipShortcutChanged,
            object: nil,
            userInfo: ["clipId": clipId]
        )
        // Refresh clips list so the UI (e.g. preview) reflects the new value
        restartObservation()
    }

    /// Clear the hotkey on a clip.
    func removeClipShortcut(clip: Clip) {
        guard let clipId = clip.id else { return }
        try? clipRepository.updateCustomShortcut(id: clipId, keyCode: nil, modifiers: nil)
        NotificationCenter.default.post(
            name: .clipRavenClipShortcutChanged,
            object: nil,
            userInfo: ["clipId": clipId]
        )
        restartObservation()
    }

    func togglePin(_ clip: Clip) {
        guard let clipId = clip.id else { return }
        try? clipRepository.togglePin(id: clipId)
    }

    func assignClipToBoard(_ clip: Clip, boardId: Int64) {
        guard let clipId = clip.id else { return }
        try? tagRepository.assignTag(clipId: clipId, tagId: boardId)
        loadBoards()
        loadClipTags()
    }

    func removeClipFromBoard(_ clip: Clip, boardId: Int64) {
        guard let clipId = clip.id else { return }
        try? tagRepository.removeTag(clipId: clipId, tagId: boardId)
        loadClipTags()
    }

    // MARK: - Multi-Select

    func toggleMultiSelect(index: Int) {
        guard index < clips.count else { return }
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
            // Update selectedIndex to the last remaining selection
            selectedIndex = selectedIndices.sorted().last
        } else {
            selectedIndices.insert(index)
            selectedIndex = index
        }
    }

    func selectSingle(index: Int) {
        selectedIndex = index
        selectedIndices = [index]
    }

    func clearMultiSelect() {
        selectedIndices = selectedIndex.map { [$0] } ?? []
    }

    func deleteSelectedClips() {
        let ids = selectedIndices
            .filter { $0 < clips.count }
            .compactMap { clips[$0].id }
        guard !ids.isEmpty else { return }
        try? clipRepository.softDeleteBatch(ids: ids)
        selectedIndices.removeAll()
        selectedIndex = nil
    }

    func addSelectedToStack() {
        let validClips = selectedIndices
            .sorted()
            .filter { $0 < clips.count }
            .map { clips[$0] }
        for clip in validClips {
            addToStack(clip)
        }
    }

    func assignTagToSelected(tagId: Int64) {
        let validClips = selectedIndices
            .filter { $0 < clips.count }
            .map { clips[$0] }
        for clip in validClips {
            guard let clipId = clip.id else { continue }
            try? tagRepository.assignTag(clipId: clipId, tagId: tagId)
        }
        loadBoards()
        loadClipTags()
    }

    // MARK: - Nickname

    func updateNickname(_ clip: Clip, nickname: String?) {
        guard let clipId = clip.id else { return }
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNickname = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try? clipRepository.updateNickname(id: clipId, nickname: finalNickname)
    }

    func createTag(name: String, colorHex: String) {
        var tag = Tag(name: name, colorHex: colorHex)
        _ = try? tagRepository.save(&tag)
        loadBoards()
    }

    func deleteTag(id: Int64) {
        try? tagRepository.delete(id: id)
        selectedTagIds.remove(id)
        loadBoards()
    }

    func updateTag(id: Int64, name: String, colorHex: String) {
        guard var tag = boards.first(where: { $0.id == id }) else { return }
        tag.name = name
        tag.colorHex = colorHex
        _ = try? tagRepository.save(&tag)
        loadBoards()
        loadClipTags()
    }

    func loadClipTags() {
        var map: [Int64: [Tag]] = [:]
        for clip in clips {
            guard let clipId = clip.id else { continue }
            if let tags = try? tagRepository.fetchTags(forClipId: clipId), !tags.isEmpty {
                map[clipId] = tags
            }
        }
        clipTags = map
    }

    // MARK: - Keyboard Navigation

    func moveSelection(_ direction: Int) {
        guard !clips.isEmpty else { return }
        let current = selectedIndex ?? 0
        let newIndex = max(0, min(clips.count - 1, current + direction))
        selectedIndex = newIndex
        selectedIndices = [newIndex]
    }

    func activateSelected() {
        guard let index = selectedIndex, index < clips.count else { return }
        pasteClip(clips[index])
    }

    func activateSelectedAsPlainText() {
        guard let index = selectedIndex, index < clips.count else { return }
        pasteClipAsPlainText(clips[index])
    }

    /// Quick paste: Cmd+1 through Cmd+9
    func quickPaste(index: Int) {
        guard index < clips.count else { return }
        pasteClip(clips[index])
    }

    // MARK: - Preview

    func togglePreview() {
        if showPreview {
            showPreview = false
            previewClip = nil
        } else if let index = selectedIndex, index < clips.count {
            previewClip = clips[index]
            showPreview = true
        }
    }

    func updatePreviewSelection() {
        if showPreview, let index = selectedIndex, index < clips.count {
            previewClip = clips[index]
        }
    }

    func updateClip(_ clip: Clip) {
        var updated = clip
        // Recalculate hash and chosung when content changes
        if let text = updated.contentText {
            let normalized = TextNormalizer.normalize(text)
            updated.contentHash = XXHash64Wrapper.hash(normalized)
            updated.contentChosung = ChosungConverter.extractChosung(from: text)
        }
        try? clipRepository.update(updated)
    }

    func updateExpiration(_ clip: Clip, expiresAt: Date?) {
        var updated = clip
        updated.expiresAt = expiresAt
        try? clipRepository.update(updated)
    }

    // MARK: - Paste Stack

    func addToStack(_ clip: Clip) {
        guard let clipId = clip.id else { return }
        let countBefore = pasteStackEngine.items.count
        pasteStackEngine.addToStack(clipId: clipId)
        let countAfter = pasteStackEngine.items.count

        if countAfter > countBefore {
            stackFeedbackMessage = "스택에 추가됨 (\(countAfter)개)"
        } else if countAfter >= PasteStackEngine.maxItems {
            stackFeedbackMessage = "스택 최대 \(PasteStackEngine.maxItems)개"
        }

        // Auto-dismiss feedback
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            stackFeedbackMessage = nil
        }
    }

    func removeFromStack(_ clip: Clip) {
        guard let clipId = clip.id else { return }
        pasteStackEngine.removeFromStack(clipId: clipId)
    }

    // MARK: - Drag & Drop Reorder

    // TODO: DRAG_REORDER — 카드 드래그 재정렬 임시 비활성화 (2026-04-17)
    // 재활성화 시: return false 줄 삭제하고 아래 로직 주석 해제
    var canReorder: Bool {
        return false
        // let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // return trimmed.isEmpty && selectedFilter == .all && selectedTagIds.isEmpty
        //     && selectedSourceApp == nil && dateRangeFilter == nil
    }

    func moveClip(_ clip: Clip, toIndex: Int, targetIsPinned: Bool) {
        guard let clipId = clip.id else { return }

        let sourceIsPinned = clip.isPinned

        // Calculate the index within the pin/normal sub-array
        let pinnedCount = clips.filter(\.isPinned).count

        switch (sourceIsPinned, targetIsPinned) {
        case (true, true):
            // Reorder within pinned
            let pinIndex = min(toIndex, pinnedCount - 1)
            try? clipRepository.reorderPinnedClip(clipId: clipId, newIndex: pinIndex)

        case (false, false):
            // Reorder within normal — toIndex is relative to full array, convert to normal-only
            let normalIndex = max(0, toIndex - pinnedCount)
            try? clipRepository.reorderNormalClip(clipId: clipId, newIndex: normalIndex)

        case (false, true):
            // Normal → Pin zone: auto-pin and insert at position
            let pinIndex = min(toIndex, pinnedCount)
            try? clipRepository.pinClipAtPosition(clipId: clipId, position: pinIndex)

        case (true, false):
            // Pin → Normal zone: auto-unpin and insert at position
            let normalIndex = max(0, toIndex - pinnedCount)
            try? clipRepository.unpinClipAtPosition(clipId: clipId, position: normalIndex)
        }

        // Clear drag state
        draggedClip = nil
        dropTargetIndex = nil
        isDragging = false
    }

    // MARK: - Clip Merge

    /// 현재 다중 선택된 클립들이 병합 가능한지 여부
    /// 텍스트/코드 타입 클립이 2개 이상 있어야 병합 가능
    var canMergeSelectedClips: Bool {
        let mergable: [Clip] = selectedIndices
            .filter { $0 < clips.count }
            .map { clips[$0] }
            .filter { $0.contentType == .text || $0.contentType == .code }
        return mergable.count >= 2
    }

    /// 현재 다중 선택된 클립들을 하나로 병합
    func mergeSelectedClips(separator: String = "\n") {
        let sortedIndices = selectedIndices.sorted()
        mergeClips(indices: sortedIndices, separator: separator)
        clearMultiSelect()
    }

    func mergeClips(indices: [Int], separator: String = "\n") {
        let validClips: [Clip] = indices
            .filter { $0 < clips.count }
            .map { clips[$0] }
            .filter { $0.contentType == ContentType.text || $0.contentType == ContentType.code }

        guard validClips.count >= 2 else { return }

        let texts: [String] = validClips.compactMap { $0.contentText }
        let mergedText: String = texts.joined(separator: separator)

        let hasCode: Bool = validClips.contains(where: { $0.contentType == ContentType.code })
        let contentType: ContentType = hasCode ? .code : .text
        let normalized: String = TextNormalizer.normalize(mergedText)
        let hash: String = XXHash64Wrapper.hash(normalized)
        let chosung: String = ChosungConverter.extractChosung(from: mergedText)

        var newClip = Clip(
            contentType: contentType,
            contentText: mergedText,
            contentHash: hash,
            sourceAppName: "ClipRaven (merged)",
            contentChosung: chosung,
            createdAt: Date(),
            lastCopiedAt: Date()
        )

        try? clipRepository.save(&newClip)
    }

    // MARK: - Similar Images (dHash-based)

    /// 유사 이미지 모드 활성화 상태 — true일 때 clips는 유사 이미지만 표시
    @Published var similarImagesMode: Bool = false
    /// 유사 이미지 검색 기준 클립
    @Published var similarReferenceClip: Clip? = nil

    /// 주어진 클립과 유사한 이미지를 찾아 현재 clips 목록을 해당 결과로 교체
    func findSimilarImages(_ clip: Clip) {
        // 이미지 타입이고 dHash가 있는 경우에만 동작
        guard clip.contentType == .image else { return }
        guard let dHash = clip.imageDhash else { return }

        do {
            let similar = try searchRepository.findSimilarImages(
                dHash: dHash,
                threshold: 10,
                excludeId: clip.id
            )

            // 기준 이미지를 맨 앞에 고정 + 유사 이미지 리스트
            var results = [clip]
            results.append(contentsOf: similar)

            // 라이브 관찰 중단 및 결과 표시
            cancellable?.cancel()
            cancellable = nil
            searchTask?.cancel()

            self.clips = results
            self.similarImagesMode = true
            self.similarReferenceClip = clip
            self.selectedIndex = results.isEmpty ? nil : 0
            self.selectedIndices = results.isEmpty ? [] : [0]
            self.loadClipTags()
        } catch {
            ClipRavenLog.search.error("findSimilarImages: \(String(describing: error), privacy: .public)")
        }
    }

    /// 유사 이미지 모드 종료 — 일반 관찰로 복귀
    func exitSimilarImagesMode() {
        similarImagesMode = false
        similarReferenceClip = nil
        restartObservation()
    }

    // MARK: - Search

    private func performSearch(_ query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty query -> switch back to normal observation
        if trimmed.isEmpty {
            restartObservation()
            return
        }

        // Cancel live observation during search
        cancellable?.cancel()
        cancellable = nil

        searchTask = Task {
            do {
                let contentType = selectedFilter.contentType
                let searchResults: [Clip]

                if ChosungConverter.isChosungOnly(trimmed) {
                    // Korean chosung-only search
                    searchResults = try searchRepository.searchChosung(query: trimmed, limit: 100)
                } else {
                    // FTS5 full-text search
                    searchResults = try searchRepository.search(
                        query: trimmed,
                        contentType: contentType,
                        limit: 100
                    )
                }

                guard !Task.isCancelled else { return }

                // Apply tag filter if active
                var filtered = searchResults
                if !selectedTagIds.isEmpty {
                    let taggedClipIds = Set(
                        (try? tagRepository.fetchClipIds(forTagIds: selectedTagIds)) ?? []
                    )
                    filtered = filtered.filter { clip in
                        guard let id = clip.id else { return false }
                        return taggedClipIds.contains(id)
                    }
                }

                // Apply source app filter
                if let sourceApp = self.selectedSourceApp {
                    filtered = filtered.filter { $0.sourceAppBundleId == sourceApp }
                }

                // Apply date range filter
                if let dateFilter = self.dateRangeFilter {
                    let range = dateFilter.dateRange
                    filtered = filtered.filter { $0.createdAt >= range.from && $0.createdAt <= range.to }
                }

                // Apply pin filter
                if !showPinned {
                    filtered = filtered.filter { !$0.isPinned }
                }

                AppAnimations.withAnimation(DesignTokens.Animation.quickFade) {
                    self.clips = filtered
                    self.selectedIndex = filtered.isEmpty ? nil : 0
                }
                self.loadClipTags()
            } catch {
                guard !Task.isCancelled else { return }
                ClipRavenLog.search.error("Search failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Private

    private func restartObservation() {
        // Don't restart observation if we're actively searching
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return }

        cancellable?.cancel()

        let contentType = selectedFilter.contentType

        let dateFrom = dateRangeFilter?.dateRange.from
        let dateTo = dateRangeFilter?.dateRange.to

        cancellable = clipRepository.observeAll(
            contentType: contentType,
            tagIds: selectedTagIds,
            sourceAppBundleId: selectedSourceApp,
            dateFrom: dateFrom,
            dateTo: dateTo,
            aiCategory: selectedAICategory
        ) { [weak self] clips in
            Task { @MainActor in
                guard let self else { return }
                AppAnimations.withAnimation(DesignTokens.Animation.deletionSpring) {
                    if self.showPinned {
                        self.clips = clips
                    } else {
                        self.clips = clips.filter { !$0.isPinned }
                    }
                }
                self.updateCounts()
                self.loadClipTags()
            }
        }
    }

    private func updateCounts() {
        Task {
            let total = (try? clipRepository.count()) ?? 0
            let textCount = (try? clipRepository.count(contentType: .text)) ?? 0
            let codeCount = (try? clipRepository.count(contentType: .code)) ?? 0
            let urlCount = (try? clipRepository.count(contentType: .url)) ?? 0
            let imageCount = (try? clipRepository.count(contentType: .image)) ?? 0
            let colorCount = (try? clipRepository.count(contentType: .color)) ?? 0
            let fileCount = (try? clipRepository.count(contentType: .file)) ?? 0

            await MainActor.run {
                self.totalCount = total
                self.filterCounts = [
                    .all: total,
                    .text: textCount,
                    .code: codeCount,
                    .url: urlCount,
                    .image: imageCount,
                    .color: colorCount,
                    .file: fileCount,
                ]
            }
        }
    }
}
