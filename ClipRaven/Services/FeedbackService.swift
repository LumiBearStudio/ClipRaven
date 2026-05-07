import AppKit

final class FeedbackService {

    private var captureObserver: Any?
    private var pasteObserver: Any?

    func setup() {
        captureObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenNewClipCaptured,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleCapture()
        }

        pasteObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenHidePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePaste()
        }
    }

    deinit {
        [captureObserver, pasteObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    // MARK: - Private

    private func handleCapture() {
        if UserDefaults.standard.bool(forKey: "hapticOnCapture") {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        }
        if UserDefaults.standard.bool(forKey: "soundOnCapture") {
            NSSound(named: .init("Tink"))?.play()
        }
    }

    private func handlePaste() {
        if UserDefaults.standard.bool(forKey: "hapticOnPaste") {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
        if UserDefaults.standard.bool(forKey: "soundOnPaste") {
            NSSound(named: .init("Pop"))?.play()
        }
    }
}
