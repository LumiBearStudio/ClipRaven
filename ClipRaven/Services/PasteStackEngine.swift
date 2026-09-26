import AppKit
import Combine

/// "Paste Stack" 기능 — 여러 클립을 큐에 쌓고 단축키로 순차 paste.
/// 큐는 `PasteStackRepository` 로 SQLite 영속화되어 앱 재시작 후에도 복원.
@MainActor
final class PasteStackEngine: ObservableObject {
    @Published var items: [PasteStackItem] = []
    @Published var isActive = false
    @Published var currentIndex = 0

    private let repository = PasteStackRepository()
    private let clipRepository = ClipRepository()

    static let maxItems = 25

    func addToStack(clipId: Int64) {
        guard items.count < Self.maxItems else {
            // Show warning
            return
        }
        if let item = try? repository.add(clipId: clipId) {
            items.append(item)
        }
    }

    func removeFromStack(clipId: Int64) {
        try? repository.remove(clipId: clipId)
        items.removeAll { $0.clipId == clipId }
    }

    func start() {
        guard !items.isEmpty else { return }
        // 체험 만료 시 Paste Stack 도 막는다 (패널 경로와 동일한 검사).
        guard !MainPanelViewModel.blockPasteIfExpired() else { return }
        isActive = true
        currentIndex = 0
        pasteNext()
    }

    func pasteNext() {
        guard isActive else { return }
        guard let next = try? repository.fetchNext() else {
            finish()
            return
        }

        // Load clip content and put on pasteboard
        if let clip = try? clipRepository.fetchOne(id: next.clipId),
           let content = clip.contentText {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(content, forType: .string)
            pasteboard.setData(Data(), forType: ClipboardMarker.selfType)
        }

        if let nextId = next.id {
            try? repository.markPasted(id: nextId)
        }
        currentIndex += 1
    }

    func finish() {
        isActive = false
        currentIndex = 0
    }

    func clear() {
        try? repository.clear()
        items = []
        isActive = false
        currentIndex = 0
    }

    func reload() {
        items = (try? repository.fetchAll()) ?? []
    }

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(currentIndex) / Double(items.count)
    }

    var remainingCount: Int {
        items.count - currentIndex
    }
}
