import AppKit
import Combine
import SwiftUI

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

    weak var panelController: MainPanelController?

    deinit {
        if let o = newClipObserver { NotificationCenter.default.removeObserver(o) }
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = selectiveModeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = pauseStateObserver { NotificationCenter.default.removeObserver(o) }
        if let o = themeObserver { NotificationCenter.default.removeObserver(o) }
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        // Brand menu-bar icon. Asset ships as a template (black silhouette
        // on transparent) — macOS handles the light/dark inversion for us.
        button.image = StatusItemController.brandedMenuBarImage()

        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Listen for new clip capture → flash icon
        newClipObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenNewClipCaptured,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flashIcon()
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
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
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

    private func showContextMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "ClipRaven \(NSLocalizedString("정보", comment: "About"))",
            action: #selector(openAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())

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
            if let image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "ClipRaven paused") {
                image.isTemplate = true
                button.image = image
            }
        } else {
            button.image = StatusItemController.brandedMenuBarImage()
        }
        // Dim the button when paused so it's visually obvious in the menu bar
        button.appearsDisabled = isPaused
    }

    /// Flash the menu bar icon briefly (called when a new clip is captured).
    /// The brand asset does not ship a "filled" variant, so the flash is
    /// conveyed via a temporary accent tint instead of an icon swap.
    func flashIcon() {
        guard !isPaused else { return }
        guard let button = statusItem?.button else { return }

        let previousTint = button.contentTintColor
        button.contentTintColor = NSColor.controlAccentColor

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            button.contentTintColor = previousTint
            self?.updateIcon()  // belt + suspenders: restore the correct image too
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
