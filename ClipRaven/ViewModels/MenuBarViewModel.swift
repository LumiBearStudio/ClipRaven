import Foundation
import Combine

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
