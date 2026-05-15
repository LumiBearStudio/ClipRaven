import AppKit
import SwiftUI
import Combine
import ClipRavenSync

/// PaywallView 를 메뉴바 panel 과 분리된 별도 NSWindow modal 로 표시.
///
/// 이전엔 PaywallView 가 `MainPanelView.overlay { ... }` 로 panel ZStack 위에
/// 덮였음. 문제: panel 이 작은 크기 + LSUIElement (메뉴바) 앱이라 StoreKit
/// 결제 시트가 panel 에 sheet 로 anchor 되면서 panel 크기 안에 끼어 결제 버튼이
/// 화면 밖으로 잘려나가는 회귀가 사용자 보고됨 (2026-05-15).
///
/// 해결: standalone `NSWindow` 띄움 → StoreKit 시트가 그 window 의 sheet 로
/// anchor → 정상 크기로 표시. 출시 후 사용자 첫 결제 경험 안정화.
///
/// 라이프사이클:
/// 1. `show()` — window 만들거나 재사용, key + frontmost, NSApp.activate
/// 2. PaywallView 내부에서 `purchase()` 호출 → 결제 시트가 이 window 의 sheet
/// 3. `lockState == .paid` 시 PaywallView 가 `.clipRavenPaywallShouldClose` 발행
/// 4. controller 가 receive → `close()` → window 해제
@MainActor
final class PaywallWindowController: NSObject, NSWindowDelegate {

    static let shared = PaywallWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var lockStateCancellable: AnyCancellable?

    private override init() {
        super.init()
        // PurchaseManager 의 lockState 를 관찰해 paid 전환 시 자동 close.
        // PaywallView 의 .onChange 와 이중 안전망 (어느 쪽이든 먼저 trigger).
        lockStateCancellable = PurchaseManager.shared.$lockState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .paid {
                    self.close()
                }
            }

        closeObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenPaywallShouldClose,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    deinit {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// PaywallWindow 표시. 이미 떠있으면 frontmost + activate 만.
    func show() {
        if window == nil { createWindow() }
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        // LSUIElement 앱은 기본 비활성화 — 결제 시트 위해 명시 활성화.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// PaywallWindow 닫기. 결제 완료 또는 사용자 명시 close.
    func close() {
        window?.close()
        window = nil
    }

    private func createWindow() {
        let hosting = NSHostingController(rootView: PaywallView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "ClipRaven"
        // .closable 만 두고 minimize/zoom 비활성 — modal 성격이라 사용자가 굳이
        // 최소화/확대해 다른 작업 안 함. 다만 사용자 cancel intent 위해 close 는 허용.
        win.styleMask = [.titled, .closable]
        win.contentMinSize = NSSize(width: 320, height: 480)
        win.setContentSize(NSSize(width: 360, height: 520))
        win.isReleasedWhenClosed = false
        win.delegate = self
        // 메뉴바 앱이 main window 가 없는 상태 → 이 window 가 frontmost 가 되도록
        // collectionBehavior 명시. 다른 Space 에서도 따라옴.
        win.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window = win
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}

extension Notification.Name {
    /// PaywallView 가 paid 전환 감지 시 발행. PaywallWindowController 가 close.
    static let clipRavenPaywallShouldClose = Notification.Name("clipRavenPaywallShouldClose")
}
