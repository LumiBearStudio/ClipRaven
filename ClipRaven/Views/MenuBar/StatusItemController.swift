import AppKit
import Combine
import SwiftUI
import ClipRavenSync

final class StatusItemController {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var isPaused = false
    private var isSelectiveMode = false
    private var newClipObserver: Any?
    private var settingsObserver: Any?
    private var selectiveModeObserver: Any?
    private var pauseStateObserver: Any?
    private var themeObserver: Any?
    private var settingsWindow: NSWindow?

    // MARK: - Bird animation state
    /// 천천히 걸어가는 idle 애니메이션의 frame 진행을 구동하는 타이머.
    /// frame asset 이 2개 이상 있으면 frame swap, 없으면 transform-only
    /// fallback (subtle sway/tilt) 로 동작.
    private var walkTimer: Timer?
    private var walkFrameIndex: Int = 0
    /// 클립 capture 시 잠시 재생되는 flap 애니메이션의 타이머. 한 사이클 끝나면
    /// walking 으로 자동 복귀.
    private var flapTimer: Timer?

    weak var panelController: MainPanelController?

    deinit {
        if let o = newClipObserver { NotificationCenter.default.removeObserver(o) }
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = selectiveModeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = pauseStateObserver { NotificationCenter.default.removeObserver(o) }
        if let o = themeObserver { NotificationCenter.default.removeObserver(o) }
        walkTimer?.invalidate()
        flapTimer?.invalidate()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        // Brand menu-bar icon. Asset ships as a template (black silhouette
        // on transparent) — macOS handles the light/dark inversion for us.
        button.image = StatusItemController.brandedMenuBarImage()

        // 까마귀 애니메이션 layer 활성화. CAAnimation 기반 fallback (transform
        // walking sway / flap bounce) 가 작동하려면 wantsLayer = true 필요.
        button.wantsLayer = true

        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Listen for new clip capture → flap (1회 재생 후 walking 으로 복귀)
        newClipObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenNewClipCaptured,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.playFlapAnimation()
        }

        // Listen for settings open request
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openSettingsWindow()
        }

        // Listen for "open About section" request from any source (e.g. FilterBarView hamburger menu)
        NotificationCenter.default.addObserver(
            forName: .clipRavenOpenAboutSection,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openSettingsWindow(navigateTo: .about)
        }

        // Observe selective mode changes → update icon
        isSelectiveMode = UserDefaults.standard.bool(forKey: "selectiveMode")
        updateIcon()
        selectiveModeObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenSelectiveModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSelectiveMode = UserDefaults.standard.bool(forKey: "selectiveMode")
            self?.updateIcon()
        }

        // Observe pause state changes from any source (ClipboardMonitor is single source of truth)
        pauseStateObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenPauseStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let paused = notification.userInfo?["isPaused"] as? Bool ?? false
            self?.isPaused = paused
            self?.updateIcon()
        }

        themeObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenThemeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow?.appearance = NSApp.appearance
        }

        // Idle walking animation 시작. paused 면 updateIcon() 가 정지시킴.
        if !isPaused {
            startWalkingAnimation()
        }
    }

    @objc @MainActor private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        panelController?.toggle()
    }

    @MainActor private func showContextMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "ClipRaven \(NSLocalizedString("정보", comment: "About"))",
            action: #selector(openAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())

        // 체험 / 만료 상태 표시
        let lockState = PurchaseManager.shared.lockState
        if case .trial(let days) = lockState {
            let trialItem = NSMenuItem()
            // 회귀 방어: 직접 한국어 보간은 영문 locale 에서 한국어 그대로 노출됨.
            // NSLocalizedString + String(format:) 으로 xcstrings 번역 룩업 보장.
            let template = NSLocalizedString("⏱  무료 체험 %lld일 남음",
                                             comment: "Trial days left menu bar item")
            trialItem.attributedTitle = NSAttributedString(
                string: String(format: template, days),
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 12)
                ]
            )
            trialItem.isEnabled = false
            menu.addItem(trialItem)

            let upgradeItem = NSMenuItem(
                title: NSLocalizedString("지금 구매하기...", comment: "Upgrade menu item"),
                action: #selector(openPaywall(_:)),
                keyEquivalent: ""
            )
            upgradeItem.target = self
            menu.addItem(upgradeItem)
            menu.addItem(NSMenuItem.separator())
        } else if lockState == .expired {
            let expiredItem = NSMenuItem()
            expiredItem.attributedTitle = NSAttributedString(
                string: NSLocalizedString("🔒  무료 체험 만료",
                                          comment: "Trial expired menu bar item"),
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 12)
                ]
            )
            expiredItem.isEnabled = false
            menu.addItem(expiredItem)

            let upgradeItem = NSMenuItem(
                title: NSLocalizedString("지금 구매하기...", comment: "Upgrade menu item"),
                action: #selector(openPaywall(_:)),
                keyEquivalent: ""
            )
            upgradeItem.target = self
            menu.addItem(upgradeItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Current capture state indicator (non-clickable, colored)
        let stateItem = NSMenuItem()
        let stateText: String
        let stateColor: NSColor
        if isPaused {
            stateText = NSLocalizedString("⏸  일시정지 중", comment: "Status: capturing paused")
            stateColor = .systemOrange
        } else {
            stateText = NSLocalizedString("●  캡처 중", comment: "Status: capturing active")
            stateColor = .systemGreen
        }
        stateItem.attributedTitle = NSAttributedString(
            string: stateText,
            attributes: [
                .foregroundColor: stateColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        let pauseItem = NSMenuItem(
            title: isPaused
                ? NSLocalizedString("캡처 재개", comment: "Resume capturing")
                : NSLocalizedString("캡처 일시정지", comment: "Pause capturing"),
            action: #selector(togglePause(_:)),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("설정...", comment: "Settings menu item"),
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("종료", comment: "Quit app"),
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // Reset to allow left-click again
    }

    @objc @MainActor private func openPaywall(_ sender: NSMenuItem) {
        // 트라이얼 중 (사용자가 "지금 구매하기..." 메뉴 클릭) / 만료 후 (자동 표시)
        // 둘 다 별도 standalone NSWindow 로 표시. 이전엔 main panel 의 overlay
        // 였는데 panel 크기 안에 결제 시트가 sheet anchor 되면서 잘리는 회귀가
        // 있었음 (사용자 보고 2026-05-15).
        PaywallWindowController.shared.show()
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        // ClipboardMonitor handles the toggle and posts clipRavenPauseStateChanged.
        // isPaused and updateIcon() are updated in response to that notification.
        NotificationCenter.default.post(name: .clipRavenTogglePause, object: nil)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        openSettingsWindow()
    }

    @objc private func openAbout(_ sender: NSMenuItem) {
        openSettingsWindow(navigateTo: .about)
    }

    private func openSettingsWindow(navigateTo section: SettingsSection? = nil) {
        if let section {
            // 특정 탭으로 이동할 때는 창을 항상 새로 만들어야
            // SwiftUI의 List 내부 상태 복원에 영향을 받지 않음
            SettingsRouter.shared.section = section
            settingsWindow?.close()
            settingsWindow = nil
        } else {
            // 단순 설정 열기: 이미 열려있으면 앞으로
            if let win = settingsWindow, win.isVisible {
                win.makeKeyAndOrderFront(nil)
                if #available(macOS 14.0, *) { NSApp.activate() }
                else { NSApp.activate(ignoringOtherApps: true) }
                return
            }
        }

        let hostingView = NSHostingView(rootView: SettingsView())

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = NSLocalizedString("ClipRaven 환경설정", comment: "Settings window title")
        win.appearance = NSApp.appearance  // follows system / user theme selection
        win.backgroundColor = NSColor.windowBackgroundColor
        win.contentView = hostingView
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()  // LSUIElement apps need this to appear above other apps

        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }

        settingsWindow = win
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    /// Update menu bar icon based on pause / selective mode state.
    /// Paused keeps its distinctive SF Symbol (pause.circle.fill) so the
    /// state is unmistakable at a glance; other states use the brand asset.
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        if isPaused {
            // paused 면 모든 까마귀 애니메이션 정지하고 pause symbol 로 교체.
            stopWalkingAnimation()
            stopFlapAnimation()
            if let image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "ClipRaven paused") {
                image.isTemplate = true
                button.image = image
            }
        } else {
            button.image = StatusItemController.brandedMenuBarImage()
            // unpause 시 walking 재개 (이미 돌고 있으면 idempotent).
            startWalkingAnimation()
        }
        // Dim the button when paused so it's visually obvious in the menu bar
        button.appearsDisabled = isPaused
    }

    // MARK: - Bird animations
    //
    // 두 가지 모드:
    // 1) idle "walking" — 까마귀가 천천히 걸어가는 무한 loop. setup() 끝에서
    //    시작, paused 시 정지.
    // 2) "flapping" — 새 클립 capture 시 1회 재생 후 walking 으로 자동 복귀.
    //
    // 각 모드는 frame asset 이 있으면 frame swap 으로 작동, 없으면 transform
    // 기반 fallback (CAAnimation) 으로 흉내낸다. 향후 까마귀 frame asset 을
    // `MenuBarIcon_Walk{1..}` / `MenuBarIcon_Flap{1..}` imageset 으로 추가하면
    // 자동 frame animation 으로 승격된다.

    /// 천천히 걷는 walking 사이클 frame 간격 (초). 0.20~0.30 이 12 frame 기준
    /// 자연스럽다. 너무 길면 frame 간 자세 차이가 도드라져 딱딱하게 끊겨 보임.
    private static let walkFrameInterval: TimeInterval = 0.25
    /// 퍼득이는 flap 사이클 frame 간격 (초). 5 frame 기준 총 0.5초 — 클립
    /// capture 시 짧고 강한 시각 피드백.
    private static let flapFrameInterval: TimeInterval = 0.10

    /// idle 모드 frame asset. 없으면 빈 배열 → transform fallback.
    /// maxCount 를 16 으로 두면 향후 frame 더 추가해도 코드 수정 없이 인식.
    private static let walkFrames: [NSImage] = loadFrames(prefix: "MenuBarIcon_Walk", maxCount: 16)
    /// flap 모드 frame asset. 없으면 빈 배열 → transform fallback.
    private static let flapFrames: [NSImage] = loadFrames(prefix: "MenuBarIcon_Flap", maxCount: 16)

    /// 연속된 번호 (1..maxCount) 의 imageset 을 순서대로 로드한다. 누락된 번호가
    /// 나오면 거기서 종료 (gap 허용 안 함).
    ///
    /// **isTemplate 설정 안 함**: imageset 의 Contents.json 의
    /// `template-rendering-intent` (`template` 또는 `original`) 가 자동으로
    /// 적용된다. 코드에서 강제로 `isTemplate = true` 로 override 하면 RGBA
    /// 디테일이 단색 silhouette 으로 평탄화되어 손실됨. walking frame 들은
    /// `original` 로 설정되어 있어 흰색 까마귀 + 디테일이 그대로 표시된다.
    private static func loadFrames(prefix: String, maxCount: Int) -> [NSImage] {
        var frames: [NSImage] = []
        for i in 1...maxCount {
            guard let img = NSImage(named: "\(prefix)\(i)") else { break }
            frames.append(img)
        }
        return frames
    }

    /// idle walking animation 을 시작한다. 이미 돌고 있으면 no-op (idempotent).
    /// frame asset 이 2개 이상 있으면 frame swap, 없으면 transform sway/tilt.
    private func startWalkingAnimation() {
        guard !isPaused else { return }
        guard walkTimer == nil else { return }   // idempotent
        guard let button = statusItem?.button else { return }

        let frames = Self.walkFrames
        if frames.count >= 2 {
            // Ping-pong loop: 1→2→…→N→N-1→…→2→1 으로 reverse 구간 추가.
            // 이유: 영상에서 균등 추출한 N 개 frame 은 마지막 → 첫 frame 사이가
            // 자연 motion 으로 연결되지 않아 cycle loop 점에서 까마귀 자세가
            // 점프하는 듯한 회귀가 보였다. forward + reverse 합치면 마지막
            // frame 의 다음이 그 직전 frame 이 되어 seamless 로 흐른다.
            // 예: 12 frame → 22 frame sequence (1..12, 11..2)
            let pingPong: [NSImage] = frames + frames.dropFirst().dropLast().reversed()
            walkFrameIndex = 0
            walkTimer = Timer.scheduledTimer(
                withTimeInterval: Self.walkFrameInterval, repeats: true
            ) { [weak self] _ in
                guard let self = self,
                      let button = self.statusItem?.button else { return }
                button.image = pingPong[self.walkFrameIndex % pingPong.count]
                self.walkFrameIndex += 1
            }
        } else {
            // Transform fallback: subtle horizontal sway + tiny tilt.
            // 메뉴바 inside 에 머무는 작은 진폭만 사용 — 인접 menubar item 과
            // 시각적 충돌 방지.
            button.wantsLayer = true

            // Pivot 을 layer 중앙으로 (회전이 모서리에서 일어나지 않게).
            if let layer = button.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.position = CGPoint(
                    x: button.bounds.midX,
                    y: button.bounds.midY
                )
            }

            let sway = CABasicAnimation(keyPath: "transform.translation.x")
            sway.fromValue = -1.0
            sway.toValue = 1.0
            sway.duration = Self.walkFrameInterval
            sway.autoreverses = true
            sway.repeatCount = .infinity
            sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let tilt = CABasicAnimation(keyPath: "transform.rotation.z")
            tilt.fromValue = -0.04  // ~-2.3°
            tilt.toValue = 0.04
            tilt.duration = Self.walkFrameInterval
            tilt.autoreverses = true
            tilt.repeatCount = .infinity
            tilt.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            button.layer?.add(sway, forKey: "walk.sway")
            button.layer?.add(tilt, forKey: "walk.tilt")

            // Sentinel timer 로 walkTimer != nil 상태 유지 (idempotency 체크용).
            // 실제 frame 업데이트는 layer animation 이 담당.
            walkTimer = Timer.scheduledTimer(
                withTimeInterval: 60, repeats: true
            ) { _ in /* keepalive */ }
        }
    }

    private func stopWalkingAnimation() {
        walkTimer?.invalidate()
        walkTimer = nil
        walkFrameIndex = 0

        if let layer = statusItem?.button?.layer {
            layer.removeAnimation(forKey: "walk.sway")
            layer.removeAnimation(forKey: "walk.tilt")
        }
    }

    /// 새 클립 capture 시 호출되는 일회성 flap animation. frame asset 이 있으면
    /// frame swap 시퀀스, 없으면 transform bounce + scale pulse 로 흉내.
    /// 완료 후 walking 으로 복귀.
    func playFlapAnimation() {
        guard !isPaused else { return }
        guard let button = statusItem?.button else { return }

        // 진행 중이던 flap 이 있으면 cancel (overlap 방지).
        stopFlapAnimation()

        let frames = Self.flapFrames
        if frames.count >= 2 {
            // Real frame animation: walking 정지, flap 시퀀스 1회 재생, 끝나면
            // walking 자동 재개.
            stopWalkingAnimation()
            var idx = 0
            flapTimer = Timer.scheduledTimer(
                withTimeInterval: Self.flapFrameInterval, repeats: true
            ) { [weak self] timer in
                guard let self = self,
                      let button = self.statusItem?.button else {
                    timer.invalidate(); return
                }
                if idx < frames.count {
                    button.image = frames[idx]
                    idx += 1
                } else {
                    timer.invalidate()
                    self.flapTimer = nil
                    self.startWalkingAnimation()
                }
            }
        } else {
            // Transform fallback: bounce + scale pulse + 짧은 accent tint.
            // 기존 flashIcon() 의 tint 효과를 보존하면서 motion 추가.
            button.wantsLayer = true

            let previousTint = button.contentTintColor
            button.contentTintColor = NSColor.controlAccentColor

            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [0.0, 2.0, -2.0, 0.0]
            bounce.keyTimes = [0, 0.3, 0.7, 1.0]
            bounce.duration = 0.3
            bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [1.0, 1.12, 1.0]
            scale.keyTimes = [0, 0.5, 1.0]
            scale.duration = 0.3
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            button.layer?.add(bounce, forKey: "flap.bounce")
            button.layer?.add(scale, forKey: "flap.scale")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                button.contentTintColor = previousTint
                self?.updateIcon()
            }
        }
    }

    private func stopFlapAnimation() {
        flapTimer?.invalidate()
        flapTimer = nil

        if let layer = statusItem?.button?.layer {
            layer.removeAnimation(forKey: "flap.bounce")
            layer.removeAnimation(forKey: "flap.scale")
        }
    }

    /// Standard macOS menu-bar content height in points. Ventura+ menu bars
    /// are 22pt tall; a 18×18 icon leaves 2pt breathing room top/bottom
    /// (identical to what System Settings and Finder use for their
    /// menu-bar extras).
    private static let menuBarIconSize = NSSize(width: 18, height: 18)

    /// Loads the brand icon with light/dark appearance variants. Without
    /// the explicit `size` the NSStatusItem would render the raw 80×80
    /// bitmap at its native dimensions, producing a blurry oversized blob
    /// in the menu bar. Setting `size` tells AppKit the intended display
    /// size — Retina rendering still uses the full 80px bitmap, so the
    /// result stays crisp.
    ///
    /// `isTemplate = true` — the shipped asset is a black-on-transparent
    /// silhouette. macOS auto-inverts it per appearance (black on the
    /// bright menu bar in light mode, white on the dark menu bar in dark
    /// mode), so a single image covers both modes and the old dark/light
    /// variant pair is no longer needed. Contents.json also declares
    /// `template-rendering-intent` as belt-and-suspenders.
    ///
    /// Fallback path lets dev builds without a shipped icon set keep the
    /// previous SF Symbol experience rather than showing an empty button.
    private static func brandedMenuBarImage() -> NSImage {
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            // Intentionally NOT setting `image.size` — letting NSStatusItem
            // auto-fit preserves the source aspect ratio and uses the full
            // menu bar height (~18pt). Forcing 18×18 on a non-square asset
            // either crops or distorts; either way the icon renders smaller
            // than neighbouring system icons.
            image.accessibilityDescription = "ClipRaven"
            return image
        }
        let fallback = NSImage(systemSymbolName: "doc.on.clipboard",
                               accessibilityDescription: "ClipRaven")
            ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}
