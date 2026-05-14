import Foundation
import Combine

/// 메뉴바 아이콘의 표시 상태 — 일시정지 토글 + 캡처된 클립 카운트.
///
/// `ClipboardMonitor` 를 의존성 주입으로 받아 일시정지/재개를 제어한다.
final class MenuBarViewModel: ObservableObject {
    @Published var isPaused = false
    @Published var clipCount = 0

    private let clipboardMonitor: ClipboardMonitor
    private var cancellables = Set<AnyCancellable>()

    init(clipboardMonitor: ClipboardMonitor = ClipboardMonitor()) {
        self.clipboardMonitor = clipboardMonitor
    }

    func togglePause() {
        if isPaused {
            clipboardMonitor.resume()
        } else {
            clipboardMonitor.pause()
        }
        isPaused = !isPaused
    }
}
