import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipRavenSync

// MARK: - File Promise Providers for Drag-and-Drop

/// Provides a .txt file promise for dragging text clips to Finder.
private final class TextFilePromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let text: String
    private let filename: String

    init(text: String, filename: String) {
        self.text = text
        self.filename = filename
        super.init()
        self.fileType = UTType.utf8PlainText.identifier
        self.delegate = self
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String { filename }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
}

/// Provides an image file promise (png/jpeg/gif/…) for dragging image clips to Finder.
private final class ImageFilePromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let imagePath: String
    private let fileExt: String
    private let filename: String

    init(imagePath: String, uti: UTType, fileExt: String, filename: String) {
        self.imagePath = imagePath
        self.fileExt = fileExt
        self.filename = filename
        super.init()
        self.fileType = uti.identifier
        self.delegate = self
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String { filename }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let data = ImageStorageService.loadImage(relativePath: imagePath) else {
            completionHandler(CocoaError(.fileReadNoSuchFile))
            return
        }
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
}

// MARK: - Fast Click + Drag Handler (AppKit NSView, no SwiftUI tap delay)
//
// Root cause of prior drag-and-drop breakage:
//   DraggableClickView sits on top of all SwiftUI layers and captures every mouse
//   event via hitTest.  SwiftUI's .onDrag modifier never sees the events because
//   it relies on the same AppKit responder chain that DraggableClickView absorbed.
//
// Fix: implement the full drag session inside DraggableClickView (NSDraggingSource),
//   using NSFilePromiseProvider / NSURL / NSString as NSPasteboardWriting items so
//   Finder, text fields, and Electron apps all receive the correct data.

struct FastClickableView: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    var onCmdClick: (() -> Void)? = nil
    /// Returns NSDraggingItems when a drag gesture is detected.
    var makeDragItems: (() -> [NSDraggingItem])? = nil
    /// Called just before beginDraggingSession (panel auto-hide suppression, etc.)
    var onDragBegan: (() -> Void)? = nil

    func makeNSView(context: Context) -> DraggableClickView {
        let view = DraggableClickView()
        view.coordinator = context.coordinator
        view.makeDragItems = makeDragItems
        view.onDragBegan = onDragBegan
        return view
    }

    func updateNSView(_ nsView: DraggableClickView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onCmdClick = onCmdClick
        nsView.makeDragItems = makeDragItems
        nsView.onDragBegan = onDragBegan
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleClick: onSingleClick,
            onDoubleClick: onDoubleClick,
            onCmdClick: onCmdClick
        )
    }

    final class Coordinator: NSObject {
        var onSingleClick: () -> Void
        var onDoubleClick: () -> Void
        var onCmdClick: (() -> Void)?

        init(
            onSingleClick: @escaping () -> Void,
            onDoubleClick: @escaping () -> Void,
            onCmdClick: (() -> Void)?
        ) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
            self.onCmdClick = onCmdClick
        }
    }
}

/// NSView that handles click and drag for a ClipCard.
/// - acceptsFirstMouse: true so the panel doesn't need to be key first.
/// - Implements NSDraggingSource to start AppKit drag sessions directly,
///   bypassing SwiftUI's .onDrag (which never fires from behind this view).
final class DraggableClickView: NSView, NSDraggingSource {
    weak var coordinator: FastClickableView.Coordinator?
    var makeDragItems: (() -> [NSDraggingItem])? = nil
    var onDragBegan: (() -> Void)? = nil

    private var mouseDownEvent: NSEvent?
    private var isDragging = false
    private var dragSessionStarted = false

    // Minimum pixel distance before we treat a mouse move as a drag intent.
    // System default is ~3px which fires on trackpad tap micro-movements.
    private static let dragThreshold: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    // MARK: - Mouse Event Handling

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        isDragging = false
        dragSessionStarted = false
        // Do NOT call beginDraggingSession here. Starting the session in mouseDown
        // causes the system to capture all subsequent mouse events for the drag,
        // so trackpad tap micro-movements (3-5px) fire willBeginAt → isDragging = true
        // → mouseUp skips click handling. We start the session in mouseDragged instead.
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragSessionStarted, let downEvent = mouseDownEvent else { return }

        let dx = event.locationInWindow.x - downEvent.locationInWindow.x
        let dy = event.locationInWindow.y - downEvent.locationInWindow.y
        guard sqrt(dx * dx + dy * dy) >= Self.dragThreshold else { return }

        guard let items = makeDragItems?(), !items.isEmpty else { return }

        let dragFrame = bounds.width > 0 ? bounds
                      : NSRect(origin: .zero, size: NSSize(width: 240, height: 240))
        let dragImage = snapshotImage() ?? makeFallbackImage(size: dragFrame.size)
        for item in items {
            item.setDraggingFrame(dragFrame, contents: dragImage)
        }
        dragSessionStarted = true
        // Pass the original mouseDown event — AppKit uses it for initial drag position.
        beginDraggingSession(with: items, event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            isDragging = false
            dragSessionStarted = false
        }
        guard !isDragging else { return }  // drag completed — no spurious click

        if event.clickCount >= 2 {
            coordinator?.onDoubleClick()
        } else if event.modifierFlags.contains(.command), let cmdClick = coordinator?.onCmdClick {
            cmdClick()
        } else {
            coordinator?.onSingleClick()
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                        sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isDragging = true
        onDragBegan?()
    }

    func draggingSession(_ session: NSDraggingSession,
                        endedAt screenPoint: NSPoint,
                        operation: NSDragOperation) {
        isDragging = false
        dragSessionStarted = false
    }

    // MARK: - Drag Image

    /// Snapshot the parent view (all SwiftUI card layers) for the drag image.
    private func snapshotImage() -> NSImage? {
        let target = superview ?? self
        guard target.bounds.width > 0, target.bounds.height > 0 else { return nil }
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        let img = NSImage(size: target.bounds.size)
        img.addRepresentation(rep)
        return img
    }

    /// Rounded-rect placeholder used when the real snapshot is unavailable.
    private func makeFallbackImage(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12).fill()
        img.unlockFocus()
        return img
    }
}

// MARK: - ClipCardView

struct ClipCardView: View {
    let clip: Clip
    let isSelected: Bool
    var isMultiSelected: Bool = false
    var cardSize: CGFloat = 240
    var assignedTags: [Tag] = []
    /// If non-nil, an ⌥{hint} quick-paste badge is overlaid on this card.
    /// Pass 1..9 for slots 1-9, and 0 for slot 10 (the ⌥0 shortcut).
    var quickPasteHint: Int? = nil
    var onTap: () -> Void = {}
    var onCmdTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}
    var onDelete: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onAddToStack: (() -> Void)? = nil
    var onDragStarted: ((Clip) -> Void)? = nil

    @State private var isHovered = false
    @State private var cachedAppIcon: NSImage?
    @State private var iconLoaded = false
    @State private var imageResolution: String?
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var theme = ThemeManager.shared

    // A1: Stagger appearance state
    var appearanceIndex: Int = 0
    var isInitialLoad: Bool = false

    private var headerColor: Color { clip.contentType.themeColor }

    /// Display name: nickname if available, otherwise content type name
    private var displayName: String {
        if let nickname = clip.nickname, !nickname.isEmpty {
            return nickname
        }
        return clip.contentType.displayName
    }

    var body: some View {
        ZStack {
            // Layer 1: Visual content
            contentLayout
                .allowsHitTesting(false)

            // Layer 2: Gesture overlay — handles click AND drag (AppKit-native).
            // DraggableClickView intercepts all mouse events so SwiftUI's .onDrag
            // can never fire from this view; drag is implemented via NSDraggingSource.
            FastClickableView(
                onSingleClick: onTap,
                onDoubleClick: onDoubleTap,
                onCmdClick: onCmdTap,
                makeDragItems: {
                    ClipCardView.makeExternalDraggingItems(for: clip, clipId: clip.id)
                },
                onDragBegan: {
                    NotificationCenter.default.post(name: .clipRavenExternalDragStarted, object: nil)
                    onDragStarted?(clip)
                }
            )

            // Layer 3: Header (full width, top, clipped so icon doesn't overflow into body)
            VStack(spacing: 0) {
                cardHeader
                    .clipped()
                Spacer()
            }

            // Layer 4: Bottom overlay (image/URL only)
            if clip.contentType == .image || clip.contentType == .url {
                VStack {
                    Spacer()
                    bottomOverlay
                }
                .allowsHitTesting(false)
            }

            // Layer 5: Bottom-right badge (copy count + tags)
            if !assignedTags.isEmpty || clip.copyCount > 1 {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        bottomRightBadge
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
            }

            // Layer 6: Multi-select checkmark badge (top-left)
            if isMultiSelected {
                VStack {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .shadow(color: headerColor.opacity(0.8), radius: 4)
                            .padding(.leading, 8)
                            .padding(.top, 42)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

        }
        .frame(width: cardSize, height: cardSize)
        .background(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? theme.colorPreset.accentColor.opacity(0.85) : (colorScheme == .dark ? Color.white.opacity(0.08) : Color(NSColor.separatorColor).opacity(0.4)),
                    lineWidth: isSelected ? 2.0 : 0.5
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill((colorScheme == .dark ? Color.white : Color.black).opacity(isHovered && !isSelected ? 0.05 : 0))
                .allowsHitTesting(false)
        )
        // ⌥N quick-paste hint: shown while the user holds Option (driven by parent binding).
        .overlay(alignment: .topTrailing) {
            if let hint = quickPasteHint {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.colorPreset.accentColor)
                        .frame(width: 38, height: 28)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    HStack(spacing: 1) {
                        Text("⌥")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                        Text("\(hint)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(AppAnimations.policy(.spring(response: 0.25, dampingFraction: 0.75)), value: quickPasteHint)
        .shadow(
            color: isSelected ? theme.colorPreset.accentColor.opacity(0.35) : .black.opacity(0.2),
            radius: isSelected ? 8 : 4,
            y: isSelected ? 0 : 2
        )
        .animation(AppAnimations.policy(.easeOut(duration: 0.12)), value: isHovered)
        .animation(AppAnimations.policy(.spring(response: 0.25, dampingFraction: 0.7)), value: isSelected)
        .onHover { isHovered = $0 }
        .onAppear {
            if !iconLoaded {
                iconLoaded = true
                if let bundleId = clip.sourceAppBundleId {
                    cachedAppIcon = SourceAppTracker.icon(forBundleId: bundleId)
                }
            }
        }
    }

    // MARK: - Content Layout
    @ViewBuilder
    private var contentLayout: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 38) // Reserve header space

            cardBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // Standard footer for text/code/color/file
            if clip.contentType != .image && clip.contentType != .url {
                standardFooter
            }
        }
    }

    // MARK: - Header (full width with source app icon + hover buttons)
    private var cardHeader: some View {
        HStack(spacing: 6) {
            // Source app icon or type SF Symbol
            if let icon = cachedAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 55, height: 55)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .offset(x: -17)
            } else {
                Image(systemName: clip.contentType.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 28, height: 28)
            }

            Text(displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .offset(x: cachedAppIcon != nil ? -17 : 0)

            Text(clip.lastCopiedAt.relativeString)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .offset(x: cachedAppIcon != nil ? -17 : 0)

            Spacer()

            // Custom shortcut badge — persistent indicator when a global hotkey is bound to this clip.
            // Hidden while hovering so the pin/delete buttons (overlay at .trailing) can take over the space.
            if let kc = clip.customShortcutKeyCode,
               let mods = clip.customShortcutModifiers,
               !isHovered {
                let label = HotKeyFormatter.format(keyCode: kc, modifiers: mods)
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.45))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                    .help("전역 단축키: \(label)")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .animation(AppAnimations.policy(.easeInOut(duration: 0.12)), value: isHovered)
        .overlay(alignment: .trailing) {
            HStack(spacing: 2) {
                if isHovered || clip.isPinned {
                    Button(action: onTogglePin) {
                        Image(systemName: clip.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(clip.isPinned ? .yellow : .white.opacity(0.9))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(clip.isPinned ? "고정 해제" : "고정")
                    .transition(.opacity)
                }

                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("삭제")
                    .transition(.opacity)
                }
            }
            .padding(.trailing, 8)
            .animation(AppAnimations.policy(.easeInOut(duration: 0.15)), value: isHovered)
        }
        .background(
            LinearGradient(
                colors: [headerColor, headerColor.opacity(0.9)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    // MARK: - Body
    private var cardBody: some View {
        Group {
            switch clip.contentType {
            case .text:  TextCardBody(text: clip.contentText ?? "")
            case .code:  CodeCardBody(text: clip.contentText ?? "")
            case .url:   URLCardBody(clip: clip)
            case .image: ImageCardBody(thumbnail: clip.thumbnail)
            case .color: ColorCardBody(text: clip.contentText ?? "")
            case .file:  FileCardBody(clip: clip)
            }
        }
    }

    // MARK: - Bottom Overlay (image/URL)
    @ViewBuilder
    private var bottomOverlay: some View {
        if clip.contentType == .image {
            imageBottomOverlay
        } else if clip.contentType == .url {
            urlBottomOverlay
        }
    }

    /// Image: resolution centered on dark gradient, OCR badge on the right
    private var imageBottomOverlay: some View {
        let hasOCR = (clip.ocrText?.isEmpty == false)

        return ZStack {
            HStack {
                Spacer()
                if let resolution = imageResolution {
                    Text(resolution)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                }
                Spacer()
            }

            if hasOCR {
                HStack {
                    ocrBadge
                        .padding(.leading, 8)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.45), Color.black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            if imageResolution == nil, let path = clip.imagePath {
                DispatchQueue.global(qos: .utility).async {
                    if let img = ImageStorageService.loadNSImage(relativePath: path),
                       let rep = img.representations.first {
                        let res = "\(rep.pixelsWide) \u{00d7} \(rep.pixelsHigh)"
                        DispatchQueue.main.async { imageResolution = res }
                    }
                }
            }
        }
    }

    /// OCR badge - indicates "이미지 내 텍스트 검색 가능"
    private var ocrBadge: some View {
        Image(systemName: "text.magnifyingglass")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.95))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .help("OCR 텍스트 검색 가능")
    }

    /// URL: favicon + domain on dark gradient
    private var urlBottomOverlay: some View {
        let urlText = clip.contentText ?? ""
        let domain = Self.extractDomain(from: urlText)
        let faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=32")

        return HStack(spacing: 5) {
            AsyncImage(url: faviconURL) { image in
                image.resizable()
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } placeholder: {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(width: 14, height: 14)

            Text(domain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.45), Color.black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Standard Footer (text/code/color/file)
    private var standardFooter: some View {
        HStack(spacing: 6) {
            if clip.contentType == .file {
                // 파일: 확장자 표시
                if let path = clip.contentText {
                    let ext = (path as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    } else {
                        Text("파일")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
            } else if let text = clip.contentText {
                Text("\(text.count)자")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.85))
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            LinearGradient(
                stops: [
                    .init(color: headerColor.opacity(0.5), location: 0.0),
                    .init(color: headerColor.opacity(0.7), location: 0.5),
                    .init(color: headerColor.opacity(0.85), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Bottom-Right Badge (copy count + tags)
    private var bottomRightBadge: some View {
        HStack(spacing: 4) {
            // Copy count (left of tags)
            if clip.copyCount > 1 {
                HStack(spacing: 2) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 7))
                    Text("×\(clip.copyCount)")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.8))
            }

            // Tag dots
            ForEach(assignedTags.prefix(3), id: \.id) { tag in
                Circle()
                    .fill(Color(hex: tag.colorHex) ?? .gray)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.3), lineWidth: 0.5)
                    )
            }
            if assignedTags.count > 3 {
                Text("+\(assignedTags.count - 3)")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.45))
        )
    }

    // MARK: - Helpers
    private static func extractDomain(from urlText: String) -> String {
        if let url = URL(string: urlText) ?? URL(string: "https://\(urlText)") {
            return url.host ?? urlText
        }
        return urlText
    }

    // MARK: - Drag Items Factory

    /// Build NSDraggingItems for an AppKit drag session.
    ///
    /// Two groups of items are returned so a single drag works for both
    /// Finder (file promise / NSURL) and text inputs / Electron apps (NSString / NSImage):
    ///
    /// - .file  → [NSURL]              — Finder moves/copies the original file.
    /// - .image → [ImageFilePromise, NSImage]  — Finder gets the image file; Electron gets NSImage.
    /// - text/code/url/color → [NSString, TextFilePromise]  — text inputs get the string;
    ///                                   Finder creates a named .txt file via the promise.
    ///
    /// An optional internal-reorder item (NSPasteboardItem with ClipDragType UTI) is prepended
    /// so that CardScrollView's .onDrop can still identify the source clip for reordering.
    static func makeExternalDraggingItems(for clip: Clip, clipId: Int64?) -> [NSDraggingItem] {
        var items: [NSDraggingItem] = []

        // ── Internal reorder item (invisible to Finder / other apps) ──────────────
        if let id = clipId {
            let internalPB = NSPasteboardItem()
            internalPB.setString(
                ClipDragType.encode(clipId: id),
                forType: NSPasteboard.PasteboardType(ClipDragType.utType.identifier)
            )
            items.append(NSDraggingItem(pasteboardWriter: internalPB))
        }

        // ── Content item(s) ───────────────────────────────────────────────────────
        switch clip.contentType {

        case .file:
            guard let path = clip.contentText,
                  FileManager.default.fileExists(atPath: path) else { return items }
            let fileURL = URL(fileURLWithPath: path)
            // NSURL conforms to NSPasteboardWriting and provides public.file-url
            items.append(NSDraggingItem(pasteboardWriter: fileURL as NSURL))

        case .image:
            guard let imagePath = clip.imagePath else { return items }
            let rawExt = (imagePath as NSString).pathExtension.lowercased()
            let (uti, fileExt): (UTType, String) = {
                switch rawExt {
                case "jpg", "jpeg": return (.jpeg,  "jpg")
                case "gif":         return (.gif,   "gif")
                case "tiff", "tif": return (.tiff,  "tiff")
                case "heic":        return (UTType(filenameExtension: "heic") ?? .image, "heic")
                case "webp":        return (UTType(filenameExtension: "webp") ?? .image, "webp")
                default:            return (.png,   "png")
                }
            }()
            let baseName = URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent
            let filename  = "\(baseName).\(fileExt)"

            // File promise for Finder (lazy — writes only when Finder requests it)
            items.append(NSDraggingItem(pasteboardWriter:
                ImageFilePromiseProvider(imagePath: imagePath, uti: uti, fileExt: fileExt, filename: filename)
            ))
            // NSImage for Electron / browser image drop zones (Claude Desktop, etc.)
            if let data = ImageStorageService.loadImage(relativePath: imagePath),
               let nsImage = NSImage(data: data) {
                items.append(NSDraggingItem(pasteboardWriter: nsImage))
            }

        default:
            guard let text = clip.contentText, !text.isEmpty else { return items }
            let snippet = String(text.prefix(40))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .init(charactersIn: "/:\\?*\"<>|\n\r"))
                .joined(separator: "-")
            let filename = snippet.isEmpty ? "text.txt" : "\(snippet).txt"

            // NSString for native text fields, browsers, Electron apps
            items.append(NSDraggingItem(pasteboardWriter: text as NSString))
            // File promise for Finder (creates a named .txt file)
            items.append(NSDraggingItem(pasteboardWriter:
                TextFilePromiseProvider(text: text, filename: filename)
            ))
        }

        return items
    }
}

// MARK: - Content Type Theme Colors (vibrant, Paste-inspired)
extension ContentType {
    var themeColor: Color {
        switch self {
        case .text:  return DesignTokens.Colors.typeText
        case .code:  return DesignTokens.Colors.typeCode
        case .url:   return DesignTokens.Colors.typeURL
        case .image: return DesignTokens.Colors.typeImage
        case .color: return DesignTokens.Colors.typeColor
        case .file:  return DesignTokens.Colors.typeFile
        }
    }
}

// MARK: - Internal Drag Type

enum ClipDragType {
    /// Private UTI for internal clip ID. External apps never see this type —
    /// they fall through to the .utf8PlainText registration which holds actual content.
    static let utType = UTType("com.lumibear.clipraven.clip-id") ?? .data
    static let prefix = "clipraven:"

    static func encode(clipId: Int64) -> String { "\(prefix)\(clipId)" }

    static func decode(_ string: String) -> Int64? {
        guard string.hasPrefix(prefix) else { return nil }
        return Int64(string.dropFirst(prefix.count))
    }
}

// MARK: - Date Extension
extension Date {
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    var relativeString: String {
        let interval = -timeIntervalSinceNow
        if interval < 60 { return NSLocalizedString("방금", comment: "Just now") }
        if interval < 3600 { return String(format: NSLocalizedString("%d분", comment: "N minutes ago"), Int(interval / 60)) }
        if interval < 86400 { return String(format: NSLocalizedString("%d시간", comment: "N hours ago"), Int(interval / 3600)) }
        if interval < 604800 { return String(format: NSLocalizedString("%d일", comment: "N days ago"), Int(interval / 86400)) }
        return Self.shortDateFormatter.string(from: self)
    }
}
