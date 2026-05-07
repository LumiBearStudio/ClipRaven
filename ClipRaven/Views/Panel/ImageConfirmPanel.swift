import AppKit
import SwiftUI
import Combine

// MARK: - Panel Controller

final class ImageConfirmPanel {
    static let shared = ImageConfirmPanel()
    private init() {}

    private var panel: NSPanel?
    private var hostingView: NSHostingView<ImageConfirmView>?

    func show(_ confirmation: PendingImageConfirmation) {
        DispatchQueue.main.async { [weak self] in
            self?.present(confirmation)
        }
    }

    private func present(_ confirmation: PendingImageConfirmation) {
        // Dismiss any currently showing panel (no discard callback — replaced)
        hidePanel(animated: false, callDiscard: false)

        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame

        let panelWidth: CGFloat = 280
        let panelHeight: CGFloat = 168
        let margin: CGFloat = 16

        // macOS notification position: top-right, below menu bar
        let x = visibleFrame.maxX - panelWidth - margin
        let y = visibleFrame.maxY - panelHeight - margin

        let newPanel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        newPanel.level = .statusBar
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.appearance = NSAppearance(named: .darkAqua)

        newPanel.contentView?.wantsLayer = true
        newPanel.contentView?.layer?.cornerRadius = 12
        newPanel.contentView?.layer?.masksToBounds = true
        // Semantic color adapts to light/dark. Old literal (0.11,0.11,0.12)
        // rendered as a near-black panel in light mode — jarring against
        // the otherwise-bright UI and hurts legibility of the bundled
        // thumbnail and text.
        newPanel.contentView?.layer?.backgroundColor =
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor

        let view = ImageConfirmView(
            thumbnail: confirmation.thumbnail,
            sourceAppName: confirmation.sourceAppName,
            onConfirm: { [weak self] in
                confirmation.onConfirm()
                self?.hidePanel(animated: true, callDiscard: false)
            },
            onDiscard: { [weak self] in
                confirmation.onDiscard()
                self?.hidePanel(animated: true, callDiscard: false)
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = newPanel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        newPanel.contentView?.addSubview(hosting)

        self.panel = newPanel
        self.hostingView = hosting

        // Slide-down entrance from top (macOS notification style)
        let startFrame = NSRect(x: x, y: y + panelHeight + 10, width: panelWidth, height: panelHeight)
        newPanel.setFrame(startFrame, display: false)
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().setFrame(
                NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
                display: true
            )
            newPanel.animator().alphaValue = 1
        }
    }

    private func hidePanel(animated: Bool, callDiscard: Bool) {
        guard let panel else { return }
        self.panel = nil
        self.hostingView = nil

        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        } else {
            panel.orderOut(nil)
        }
    }
}

// MARK: - SwiftUI View

struct ImageConfirmView: View {
    let thumbnail: Data?
    let sourceAppName: String?
    let onConfirm: () -> Void
    let onDiscard: () -> Void

    private let totalDuration: Double = 5.0
    @State private var elapsed: Double = 0
    @State private var cancellable: AnyCancellable?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main area — click anywhere to confirm
            Button(action: {
                cancellable?.cancel()
                onConfirm()
            }) {
                VStack(spacing: 0) {
                    // Header row
                    HStack(spacing: 5) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(sourceAppName ?? "클립보드")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    // Thumbnail
                    thumbnailView
                        .frame(maxWidth: .infinity)
                        .frame(height: 96)
                        .clipped()

                    // Footer: hint + countdown bar
                    HStack(spacing: 8) {
                        Text("클릭하면 등록")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        countdownBar
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
            .buttonStyle(.plain)

            // Dismiss (×) button — top-right
            Button(action: {
                cancellable?.cancel()
                onDiscard()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.trailing, 4)
        }
        .onAppear { startCountdown() }
        .onDisappear { cancellable?.cancel() }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail, let image = NSImage(data: thumbnail) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(NSColor.controlBackgroundColor)
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var countdownBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 2)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary)
                    .frame(width: geo.size.width * max(0, 1 - elapsed / totalDuration), height: 2)
                    .animation(.linear(duration: 0.1), value: elapsed)
            }
        }
        .frame(width: 50, height: 2)
    }

    private func startCountdown() {
        cancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                elapsed += 0.1
                if elapsed >= totalDuration {
                    cancellable?.cancel()
                    onDiscard()
                }
            }
    }
}
