import AppKit
import SwiftUI
import ClipRavenSync

/// Centered detail modal panel for full clip preview/edit.
final class DetailModalController {
    static let shared = DetailModalController()
    private var panel: NSPanel?

    private init() {}

    func show(clip: Clip) {
        if let existing = panel, existing.isVisible {
            // Update content by recreating hosting view
            existing.contentView?.subviews.forEach { $0.removeFromSuperview() }
            let hosting = NSHostingView(rootView: DetailModalView(clip: clip, onDismiss: { [weak self] in self?.hide() }))
            hosting.frame = existing.contentView!.bounds
            hosting.autoresizingMask = [.width, .height]
            existing.contentView?.addSubview(hosting)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Visual effect background
        let visualEffect = NSVisualEffectView(frame: panel.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .windowBackground
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.masksToBounds = true
        panel.contentView?.addSubview(visualEffect)

        let hosting = NSHostingView(rootView: DetailModalView(clip: clip, onDismiss: { [weak self] in self?.hide() }))
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)

        // Center on main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let x = screenFrame.midX - 350
            let y = screenFrame.midY - 260
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
