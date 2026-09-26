import Foundation
import Combine
import AppKit
import SwiftUI
import GRDB
import Carbon
import ApplicationServices
import ClipRavenSync

// MARK: - 붙여넣기 권한 (PostEvent)
//
// ClipRaven 은 ⌘V 를 합성해 앞 앱에 붙여넣는다. 여기에 필요한 것은 **이벤트
// 게시(PostEvent)** 권한이고, 전체 손쉬운 사용(Accessibility) 권한이 아니다.
// 두 권한 모두 시스템 설정의 "손쉬운 사용" 목록에 보이지만 서로 다른 권한이다.
//
// Apple DTS (developer.apple.com/forums/thread/789896):
//   "In general, App Sandbox blocks use of the Accessibility APIs."
//   "You can post events using CGEvent.post(…). That uses its own privilege,
//    one that's also compatible with App Sandbox."
//
// 이전에는 `AXIsProcessTrusted()` 로 확인하고 `AXIsProcessTrustedWithOptions`
// 로 요청했다. 샌드박스 빌드에서는 이 API 가 막혀, 사용자가 권한을 줘도 false
// 가 나와 붙여넣기가 영구히 막힐 수 있었다 (v1 리뷰 M1). 권한이 없어도 클립은
// 클립보드에 복사되므로 사용자는 ⌘V 로 직접 붙여넣을 수 있다.
enum PastePermission {
    /// ⌘V 합성 권한이 있는가. 권한 창을 띄우지 않는다.
    static var isGranted: Bool { CGPreflightPostEventAccess() }

    /// 시스템 권한 창을 띄운다. 이미 허용돼 있으면 아무 일도 일어나지 않는다.
    @discardableResult
    static func requestSystemPrompt() -> Bool { CGRequestPostEventAccess() }

    /// Tracks whether we've already prompted this session (avoid repeated alerts).
    private static var didPromptThisSession = false

    /// 시스템 권한 창 + 안내 알림(시스템 설정 바로가기). 세션당 한 번만.
    @MainActor
    static func requestIfNeeded() {
        guard !didPromptThisSession else { return }
        didPromptThisSession = true

        requestSystemPrompt()

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

// 로컬 `debugLog` 함수는 `ClipRavenLog.write(.paste, …)` 으로 통합됨.

// MARK: - 날짜 범위 필터
//
// 핵심 enum 정의는 `ClipRavenSync.ClipDateRange` 로 이동 (양 플랫폼 단일 정의).
// macOS UI 컨벤션 (LocalizedStringKey displayName + SF Symbol systemImage) 은
// extension 으로 본 파일에서 부여.
typealias DateRangeFilter = ClipDateRange

extension ClipDateRange {
    /// macOS 칩 라벨용 LocalizedStringKey.
    var displayName: LocalizedStringKey {
        switch self {
        case .today: return "오늘"
        case .yesterday: return "어제"
        case .lastWeek: return "최근 7일"
        case .lastMonth: return "최근 30일"
        case .thisWeek: return "이번 주"
        case .thisMonth: return "이번 달"
        case .custom: return "사용자 지정"
        }
    }

    /// macOS 칩 아이콘 (SF Symbols).
    var systemImage: String {
        switch self {
        case .today: return "sun.max"
        case .yesterday: return "sun.haze"
        case .lastWeek: return "calendar"
        case .lastMonth: return "calendar.badge.clock"
        case .thisWeek: return "calendar.badge.clock"
        case .thisMonth: return "calendar"
        case .custom: return "calendar.badge.exclamationmark"
        }
    }

    /// 호환성: 기존 코드가 `.dateRange` 를 사용 — 패키지의 `range` 로 forward.
    var dateRange: (from: Date, to: Date) { self.range }
}

// 로컬 `vmDebugLog` 함수도 `ClipRavenLog.write(.ui, …)` 으로 통합됨.
// (이전엔 /tmp/clipraven_debug.log 에 별도 기록했지만 이제 동일 경로로 합쳐짐.)

/// 메인 패널의 ViewModel — macOS 앱의 핵심 상태 컨테이너.
///
/// 큰 단일 클래스(약 1100 줄)인 이유: SwiftUI 의 `@MainActor + ObservableObject + @Published`
/// 컨벤션상 모든 상태와 그 상태를 변경하는 모든 메서드가 한 곳에 있어야 SwiftUI 가
/// 변경 추적을 안정적으로 한다. 분할하려면 protocol + 다중 ObservableObject 가 필요한데
/// 그 비용이 가시화된 이득보다 크다 (Xcode Quick Open + MARK 컨벤션으로 충분히 탐색 가능).
///
/// ### 구역 가이드 (MARK 컨벤션으로 navigator 에서 jump)
/// - `@Published` 상태 변수 (이 파일 상단)
/// - **Observation**: `startObserving` / `stopObserving` / `restartObservation` — DB 옵저버 + Notification 구독 라이프사이클
/// - **Boards**: `loadBoards` / `toggleTagFilter` / `loadClipTags`
/// - **Paste**: `pasteClip(_:)` 및 변형 (`AsPlainText`, `AsMarkdown`, `AsRichText`, `WithTransform`)
/// - **CRUD**: `deleteClip` / `togglePin` / `updateClip` / `updateExpiration` / `updateNickname`
/// - **Tags**: `createTag` / `deleteTag` / `updateTag` / `assignClipToBoard` / `removeClipFromBoard`
/// - **Hotkeys**: `assignClipShortcut` / `removeClipShortcut`
/// - **Multi-select**: `toggleMultiSelect` / `selectSingle` / `clearMultiSelect` / `deleteSelectedClips` /
///   `addSelectedToStack` / `assignTagToSelected` / `mergeSelectedClips` / `mergeClips`
/// - **Keyboard nav**: `moveSelection` / `activateSelected` / `quickPaste`
/// - **Preview**: `togglePreview` / `updatePreviewSelection`
/// - **Paste Stack**: `addToStack` / `removeFromStack`
/// - **Drag&Drop**: `moveClip`
/// - **Similar Images**: `findSimilarImages` / `exitSimilarImagesMode`
/// - **Search**: `performSearch` (private, debounced 200ms 호출)
/// - **Counts**: `updateCounts` (filterCounts 계산)
///
/// 의존성: `ClipRepository`, `TagRepository`, `SearchRepository` 모두 기본값 주입.
/// `restartObservation()` 가 `repository.observeAll(...)` 를 통해 DB 변경을 구독한다.
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

    /// 현재 클립에서 사용 가능한 소스 앱 목록.
    ///
    /// 이전에는 computed property 로 매 접근마다 `fetchUniqueSourceApps()` 를
    /// **동기 호출**했다. SwiftUI body(MainPanelView, TitlebarFilterView)가 이걸
    /// 읽으므로, `clips`/`selectedIndex`/`searchText`/`optionKeyHeld` 중 무엇이
    /// 바뀌어도 body 재평가마다 인덱스 없는 clips 전체 스캔 + 정렬이 **메인
    /// 스레드**에서 돌았다. modifier 키를 누르기만 해도 트리거된다(FilterBar 의
    /// flagsChanged → optionKeyHeld). 5000 클립 기준 3~15ms × 초당 수 회 —
    /// 과거 App Hang 회귀와 같은 계열이다 (감사 F2).
    ///
    /// 이제 `updateCounts()` 와 같은 방식으로 백그라운드에서 계산해 publish 한다.
    @Published private(set) var availableSourceApps: [(bundleId: String, name: String)] = []

    /// 소스 앱 목록을 백그라운드에서 새로 읽어 publish.
    /// 클립 목록이 바뀌는 시점(=출처가 늘거나 줄 수 있는 시점)에만 호출한다.
    private func refreshAvailableSourceApps() {
        Task.detached(priority: .utility) { [clipRepository] in
            let apps = (try? clipRepository.fetchUniqueSourceApps()) ?? []
            await MainActor.run { [weak self] in
                self?.availableSourceApps = apps
            }
        }
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

    // 품질 감사 B-R1: prod 단일 인스턴스 강결합 회피 — 테스트가 격리된
    // dbPool 을 주입할 수 있도록 init 매개변수로 노출. 기본값은 종전과 같음.
    private let clipRepository: ClipRepository
    private let tagRepository: TagRepository
    private let searchRepository: SearchRepository
    private var cancellable: DatabaseCancellable?
    private var searchTask: Task<Void, Never>?
    private var searchCancellable: AnyCancellable?
    private var deleteObserver: Any?
    private var quickPasteObserver: Any?
    private var plainTextPasteObserver: Any?
    private var optionKeyObserver: Any?

    init(
        clipRepository: ClipRepository = ClipRepository(),
        tagRepository: TagRepository = TagRepository(),
        searchRepository: SearchRepository = SearchRepository()
    ) {
        self.clipRepository = clipRepository
        self.tagRepository = tagRepository
        self.searchRepository = searchRepository
    }

    func startObserving() {
        restartObservation()
        updateCounts()
        refreshAvailableSourceApps()
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
            ClipRavenLog.write(.paste, "[VM.quickPaste] received index=\(index) clipsCount=\(self.clips.count)")
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
        // background offload — main thread 차단 방지 (품질 감사 B-B2)
        Task.detached(priority: .userInitiated) { [tagRepository] in
            let result = (try? tagRepository.fetchAll()) ?? []
            await MainActor.run { [weak self] in
                self?.boards = result
            }
        }
    }

    func toggleTagFilter(_ tagId: Int64) {
        if selectedTagIds.contains(tagId) {
            selectedTagIds.remove(tagId)
        } else {
            selectedTagIds.insert(tagId)
        }
    }

    // MARK: - Paste (with Cmd+V simulation)

    /// 트라이얼 만료 상태면 paste 동작 차단 + PaywallWindow 표시.
    /// 모든 paste 진입점 (pasteClip, AsPlainText, AsMarkdown 등) 의 single source
    /// of truth. true 반환 시 호출자는 paste 진행 중단.
    private func guardExpiredLockAndShowPaywall() -> Bool {
        if PurchaseManager.shared.lockState == .expired {
            PaywallWindowController.shared.show()
            return true
        }
        return false
    }

    func pasteClip(_ clip: Clip) {
        if guardExpiredLockAndShowPaywall() { return }
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
        if guardExpiredLockAndShowPaywall() { return }
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
        if guardExpiredLockAndShowPaywall() { return }
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
        if guardExpiredLockAndShowPaywall() { return }
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
        if guardExpiredLockAndShowPaywall() { return }
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
            if !PastePermission.isGranted {
                // 클립은 이미 클립보드에 있다 — 사용자는 ⌘V 로 직접 붙여넣을 수 있다.
                ClipRavenLog.write(.paste, "[simulatePaste] BLOCKED: PostEvent not granted — clip is on the pasteboard, showing permission alert")
                PastePermission.requestIfNeeded()
                return
            }

            ClipRavenLog.write(.paste, "[simulatePaste] entering target=\(targetName) pid=\(targetPid) postEventGranted=true")

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
                ClipRavenLog.write(.paste, "[simulatePaste] posted ⌘V via postToPid=\(targetPid) (\(targetName))")
            } else {
                keyDown?.post(tap: .cgSessionEventTap)
                keyUp?.post(tap: .cgSessionEventTap)
                ClipRavenLog.write(.paste, "[simulatePaste] posted ⌘V via session tap (no target pid)")
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
        // 품질 감사 B-CS1: 사용자 액션의 silent failure 방지 — 실패 시 로그.
        do {
            try clipRepository.softDelete(id: clipId)
        } catch {
            ClipRavenLog.write(.database, "[VM.deleteClip] softDelete failed id=\(clipId): \(error)")
        }
    }

    // MARK: - Custom shortcut management

    /// Assign a global hotkey to a clip. AppDelegate picks up the change via notification.
    func assignClipShortcut(clip: Clip, keyCode: UInt32, modifiers: UInt32) {
        guard let clipId = clip.id else { return }
        do {
            try clipRepository.updateCustomShortcut(id: clipId, keyCode: keyCode, modifiers: modifiers)
        } catch {
            ClipRavenLog.write(.database, "[VM.assignShortcut] failed id=\(clipId): \(error)")
            return
        }
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
        do {
            try clipRepository.updateCustomShortcut(id: clipId, keyCode: nil, modifiers: nil)
        } catch {
            ClipRavenLog.write(.database, "[VM.removeShortcut] failed id=\(clipId): \(error)")
            return
        }
        NotificationCenter.default.post(
            name: .clipRavenClipShortcutChanged,
            object: nil,
            userInfo: ["clipId": clipId]
        )
        restartObservation()
    }

    func togglePin(_ clip: Clip) {
        guard let clipId = clip.id else { return }
        do {
            try clipRepository.togglePin(id: clipId)
        } catch {
            ClipRavenLog.write(.database, "[VM.togglePin] failed id=\(clipId): \(error)")
        }
    }

    func assignClipToBoard(_ clip: Clip, boardId: Int64) {
        guard let clipId = clip.id else { return }
        do {
            try tagRepository.assignTag(clipId: clipId, tagId: boardId)
        } catch {
            ClipRavenLog.write(.database, "[VM.assignBoard] failed clipId=\(clipId) board=\(boardId): \(error)")
            return
        }
        loadBoards()
        loadClipTags()
    }

    func removeClipFromBoard(_ clip: Clip, boardId: Int64) {
        guard let clipId = clip.id else { return }
        do {
            try tagRepository.removeTag(clipId: clipId, tagId: boardId)
        } catch {
            ClipRavenLog.write(.database, "[VM.removeBoard] failed clipId=\(clipId) board=\(boardId): \(error)")
            return
        }
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
        do {
            try clipRepository.softDeleteBatch(ids: ids)
        } catch {
            ClipRavenLog.write(.database, "[VM.deleteSelected] failed count=\(ids.count): \(error)")
        }
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
            do {
                try tagRepository.assignTag(clipId: clipId, tagId: tagId)
            } catch {
                ClipRavenLog.write(.database, "[VM.assignTagToSelected] failed clipId=\(clipId): \(error)")
            }
        }
        loadBoards()
        loadClipTags()
    }

    // MARK: - Nickname

    func updateNickname(_ clip: Clip, nickname: String?) {
        guard let clipId = clip.id else { return }
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNickname = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            try clipRepository.updateNickname(id: clipId, nickname: finalNickname)
        } catch {
            ClipRavenLog.write(.database, "[VM.updateNickname] failed clipId=\(clipId): \(error)")
        }
    }

    func createTag(name: String, colorHex: String) {
        var tag = Tag(name: name, colorHex: colorHex)
        do {
            _ = try tagRepository.save(&tag)
        } catch {
            ClipRavenLog.write(.database, "[VM.createTag] failed name=\(name): \(error)")
            return
        }
        loadBoards()
    }

    func deleteTag(id: Int64) {
        do {
            try tagRepository.delete(id: id)
        } catch {
            ClipRavenLog.write(.database, "[VM.deleteTag] failed id=\(id): \(error)")
            return
        }
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
        // 성능 감사 D-C2: N+1 쿼리를 단일 JOIN 으로 통합.
        // 클립 200개 × `fetchTags(forClipId:)` 200회 → 1회 SQL 로.
        let clipIds = clips.compactMap(\.id)
        Task.detached(priority: .userInitiated) { [tagRepository] in
            let map = (try? tagRepository.fetchTagsMap(forClipIds: clipIds)) ?? [:]
            await MainActor.run { [weak self] in
                self?.clipTags = map
            }
        }
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
        // Selective UPDATE 로 LWW timestamp 정확히 추적 (v14).
        // 이전엔 entire-row update 라 다른 user-intent field 도 같이 write 돼
        // sync 시 stale state 회귀 위험 있었음.
        guard let clipId = clip.id else { return }
        do {
            try clipRepository.updateExpiration(id: clipId, expiresAt: expiresAt)
        } catch {
            ClipRavenLog.write(.database, "[VM.updateExpiration] failed id=\(clipId): \(error)")
        }
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

    /// 드래그 카드 재정렬 활성 여부.
    ///
    /// 2026-04-17 부터 임시 비활성화. 재활성화 시 검색/필터 조합 별 정렬
    /// 부조화 (manualOrder 컬럼 vs 검색 결과 정렬) 를 어떻게 처리할지 결정
    /// 필요. 활성화 조건은 git history `dc6ab12c` 참고 (검색 + 필터 빈 상태에서만 허용).
    /// 품질 감사 B-CS4 권고로 주석 처리 코드 삭제.
    var canReorder: Bool { false }

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

        _ = try? clipRepository.save(&newClip)
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

        // 필터 상태는 MainActor 소유다 — detach 하기 **전에** 값으로 읽어
        // 넘긴다. (아래 detached 블록 안에서 self 프로퍼티를 건드리면 다시
        // 메인 액터 hop 이 생긴다.)
        let contentType = selectedFilter.contentType
        let tagIds = selectedTagIds
        let sourceApp = selectedSourceApp
        let dateFilter = dateRangeFilter
        let includePinned = showPinned

        // 검색은 반드시 백그라운드에서. 이전에는 `Task { }` 가 @MainActor
        // 격리를 상속해 동기 DB 호출이 메인 스레드에서 돌았다. FTS 결과가
        // 5건 미만이면 `substringSearch` 로 폴백하는데 그 SQL 은 `%q%` LIKE 라
        // 인덱스를 못 쓰고 전체 스캔한다. 한글 부분입력은 unicode61 토크나이저
        // 특성상 거의 항상 이 폴백으로 빠지므로, 타이핑 중 200ms 마다 수 MB
        // 문자열 스캔이 메인에서 일어났다 (감사 F2).
        searchTask = Task.detached(priority: .userInitiated) { [searchRepository, tagRepository] in
            do {
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
                if !tagIds.isEmpty {
                    let taggedClipIds = Set(
                        (try? tagRepository.fetchClipIds(forTagIds: tagIds)) ?? []
                    )
                    filtered = filtered.filter { clip in
                        guard let id = clip.id else { return false }
                        return taggedClipIds.contains(id)
                    }
                }

                // Apply source app filter
                if let sourceApp {
                    filtered = filtered.filter { $0.sourceAppBundleId == sourceApp }
                }

                // Apply date range filter
                if let dateFilter {
                    let range = dateFilter.dateRange
                    filtered = filtered.filter { $0.createdAt >= range.from && $0.createdAt <= range.to }
                }

                // Apply pin filter
                if !includePinned {
                    filtered = filtered.filter { !$0.isPinned }
                }

                guard !Task.isCancelled else { return }

                let results = filtered
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    AppAnimations.withAnimation(DesignTokens.Animation.quickFade) {
                        self.clips = results
                        self.selectedIndex = results.isEmpty ? nil : 0
                    }
                    self.loadClipTags()
                }
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
                self.refreshAvailableSourceApps()
                self.loadClipTags()
            }
        }
    }

    private func updateCounts() {
        // 품질 감사 B-B2: `Task { }` 는 호출자 (@MainActor ViewModel) 의 격리를
        // inherit 하므로 SQLite count() 7회가 main thread 위에서 직렬 실행됐다.
        // Task.detached 로 background 격리 보장 + struct repository 캡처.
        Task.detached(priority: .userInitiated) { [clipRepository] in
            let total = (try? clipRepository.count()) ?? 0
            let textCount = (try? clipRepository.count(contentType: .text)) ?? 0
            let codeCount = (try? clipRepository.count(contentType: .code)) ?? 0
            let urlCount = (try? clipRepository.count(contentType: .url)) ?? 0
            let imageCount = (try? clipRepository.count(contentType: .image)) ?? 0
            let colorCount = (try? clipRepository.count(contentType: .color)) ?? 0
            let fileCount = (try? clipRepository.count(contentType: .file)) ?? 0

            await MainActor.run { [weak self] in
                guard let self else { return }
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
