import AppKit
import SwiftUI

final class MainPanelController {
    private var panel: NSPanel?
    private(set) var isVisible = false
    private var panelHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "clipraven.panelHeight")
        return saved > 0 ? min(max(saved, 200), 600) : 320
    }()
    private let minPanelHeight: CGFloat = 200
    private let maxPanelHeight: CGFloat = 600
    private var appActivationObserver: Any?
    private var clickOutsideMonitor: Any?
    private var hidePanelObserver: Any?
    private var screenSharingObserver: Any?
    private var externalDragObserver: Any?
    private var externalDragMouseMonitor: Any?
    private var resizeMonitor: Any?
    private var themeObserver: Any?
    private var isResizing = false
    private var isExternalDrag = false
    private var resizeStartY: CGFloat = 0
    private var resizeStartHeight: CGFloat = 0
    private weak var glassView: NSVisualEffectView?

    func setup() {
        // Suppress auto-hide while user is dragging a clip to an external app
        externalDragObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenExternalDragStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isExternalDrag = true
            // Clear the flag when the user releases the mouse (drag ends)
            self.externalDragMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                self?.isExternalDrag = false
                if let monitor = self?.externalDragMouseMonitor {
                    NSEvent.removeMonitor(monitor)
                    self?.externalDragMouseMonitor = nil
                }
            }
        }

        // Listen for hide panel notifications (e.g., after paste)
        hidePanelObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenHidePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }

        // Get screen width for full-width panel
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let panel = ScrollConvertingPanel(
            contentRect: NSRect(x: 0, y: 0, width: screenFrame.width, height: panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )

        panel.isFloatingPanel = true
        // statusBar level (25) is above Dock (~20) and normal windows (0),
        // but below the system drag image level (~500) so drag previews appear in front.
        panel.level = .statusBar
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 개발 중 캡처 허용 — 배포 전 .none으로 복구
        panel.sharingType = .readOnly

        // Liquid Glass background (appearance-aware)
        let gv = NSVisualEffectView(frame: panel.contentView!.bounds)
        gv.autoresizingMask = [.width, .height]
        gv.material = ThemeManager.shared.currentTheme == .dark ? .sidebar : .underWindowBackground
        gv.state = .active
        gv.blendingMode = .behindWindow
        gv.wantsLayer = true
        gv.layer?.cornerRadius = 16
        gv.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        gv.layer?.masksToBounds = true
        panel.contentView?.addSubview(gv)
        glassView = gv

        themeObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenThemeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.glassView?.material = ThemeManager.shared.currentTheme == .dark ? .sidebar : .underWindowBackground
        }

        // SwiftUI content
        let hostingView = NSHostingView(rootView: MainPanelView())
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.layer?.backgroundColor = .clear
        panel.contentView?.addSubview(hostingView)

        // Resize handle at the top edge
        let resizeHandle = ResizeHandleView(frame: NSRect(x: 0, y: panelHeight - 6, width: screenFrame.width, height: 6))
        resizeHandle.autoresizingMask = [.width, .minYMargin]
        resizeHandle.onResizeStarted = { [weak self] event in
            self?.startResize(event: event)
        }
        panel.contentView?.addSubview(resizeHandle)

        // Register for drag types so NSDraggingSession drops are accepted
        panel.registerForDraggedTypes([.string])

        self.panel = panel

        // sharingType은 setup()에서 고정 — observer로 덮어쓰지 않음
    }

    func toggle() {
        ClipRavenLog.hotkey.info("toggle() invoked, isVisible=\(self.isVisible, privacy: .public)")
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let panel else {
            ClipRavenLog.hotkey.error("show() — panel is nil, cannot display")
            return
        }
        guard !isVisible else {
            ClipRavenLog.hotkey.info("show() — already visible, skipping")
            return
        }
        ClipRavenLog.hotkey.info("show() — proceeding")
        isVisible = true

        // Full-width, at absolute bottom of screen, in front of Dock
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let x = screenFrame.origin.x
            let y = screenFrame.origin.y  // Very bottom of screen
            let width = screenFrame.width

            panel.setFrame(
                NSRect(x: x, y: y, width: width, height: panelHeight),
                display: true
            )
        }

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        // Notify SwiftUI views that panel just appeared (for stagger animation)
        NotificationCenter.default.post(name: .clipRavenPanelShown, object: nil)

        // Watch for other app activation → auto hide (suppressed during external drag)
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isVisible, !self.isExternalDrag else { return }
            // If activated app is not ClipRaven, hide panel
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.hide()
            }
        }

        // Watch for clicks outside the panel → auto hide
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible, let panel = self.panel else { return }
            _ = event.locationInWindow
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.hide()
            }
        }

        // Slide up animation
        let finalFrame = panel.frame
        let startFrame = NSRect(
            x: finalFrame.origin.x,
            y: finalFrame.origin.y - panelHeight,
            width: finalFrame.width,
            height: finalFrame.height
        )
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 1

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    // MARK: - Resize

    private func startResize(event: NSEvent) {
        guard !isResizing else { return }
        isResizing = true
        resizeStartY = NSEvent.mouseLocation.y
        resizeStartHeight = panelHeight

        resizeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp {
                self.finishResize()
                return event
            }
            // Dragging — update height
            let currentY = NSEvent.mouseLocation.y
            let delta = currentY - self.resizeStartY
            let newHeight = min(self.maxPanelHeight, max(self.minPanelHeight, self.resizeStartHeight + delta))
            self.panelHeight = newHeight

            if let panel = self.panel, let screen = NSScreen.main {
                let screenFrame = screen.frame
                panel.setFrame(
                    NSRect(x: screenFrame.origin.x, y: screenFrame.origin.y, width: screenFrame.width, height: newHeight),
                    display: true
                )
            }
            return event
        }
    }

    private func finishResize() {
        isResizing = false
        if let monitor = resizeMonitor {
            NSEvent.removeMonitor(monitor)
            resizeMonitor = nil
        }
        // Persist preferred height
        UserDefaults.standard.set(panelHeight, forKey: "clipraven.panelHeight")
        // Notify SwiftUI of height change
        NotificationCenter.default.post(
            name: .clipRavenPanelHeightChanged,
            object: nil,
            userInfo: ["height": panelHeight]
        )
    }

    private func removeMonitors() {
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = resizeMonitor {
            NSEvent.removeMonitor(monitor)
            resizeMonitor = nil
        }
    }

    func hide() {
        guard let panel else {
            ClipRavenLog.hotkey.error("hide() — panel is nil")
            return
        }
        guard isVisible else {
            ClipRavenLog.hotkey.info("hide() — already hidden, skipping")
            return
        }
        ClipRavenLog.hotkey.info("hide() — proceeding")
        // Commit state immediately so a rapid re-press of the hotkey during the
        // 150ms hide animation is correctly interpreted as "show", not another "hide".
        isVisible = false
        removeMonitors()

        let finalFrame = NSRect(
            x: panel.frame.origin.x,
            y: panel.frame.origin.y - panelHeight,
            width: panel.frame.width,
            height: panel.frame.height
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(finalFrame, display: true)
        }, completionHandler: { [weak self] in
            // If show() was called during the animation, isVisible is true again —
            // don't orderOut or post the hidden notification.
            guard self?.isVisible == false else { return }
            panel.orderOut(nil)
            NotificationCenter.default.post(name: .clipRavenPanelHidden, object: nil)
        })
    }
}

// MARK: - Resize Handle View

private final class ResizeHandleView: NSView {
    var onResizeStarted: ((NSEvent) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        onResizeStarted?(event)
    }
}

