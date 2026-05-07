import SwiftUI
import UniformTypeIdentifiers
import ClipRavenSync

struct CardScrollView: View {
    let clips: [Clip]
    let boards: [Tag]
    let clipTags: [Int64: [Tag]]
    @Binding var selectedIndex: Int?
    var selectedIndices: Set<Int> = []
    var cardSize: CGFloat = 240
    var canReorder: Bool = true
    /// When true, overlay ⌥1..⌥0 hint badges on the first 10 cards.
    var showQuickPasteHints: Bool = false
    /// 필터(태그/타입 등)가 바뀔 때마다 값이 달라지도록 부모에서 전달.
    /// 이 값이 변하면 ScrollViewReader를 재생성해 스크롤을 확실히 0으로 리셋.
    var filterResetID: AnyHashable = AnyHashable(0)
    /// A1: Stagger state — managed by parent (MainPanelView) so filter changes can re-trigger it
    @Binding var staggerAppeared: Bool
    var onClipSelected: (Clip) -> Void = { _ in }
    var onCmdClipSelected: (Int) -> Void = { _ in }
    var onClipActivated: (Clip) -> Void = { _ in }
    var onClipDelete: (Clip) -> Void = { _ in }
    var onClipTogglePin: (Clip) -> Void = { _ in }
    var onClipAssignBoard: (Clip, Int64) -> Void = { _, _ in }
    var onClipRemoveBoard: (Clip, Int64) -> Void = { _, _ in }
    var onClipAddToStack: (Clip) -> Void = { _ in }
    var onClipPlainTextPaste: (Clip) -> Void = { _ in }
    var onClipPasteAsMarkdown: (Clip) -> Void = { _ in }
    var onClipPasteAsRichText: (Clip) -> Void = { _ in }
    var onClipPasteWithTransform: (Clip, TextTransform) -> Void = { _, _ in }
    var onClipAssignShortcut: (Clip, UInt32, UInt32) -> Void = { _, _, _ in }
    var onClipRemoveShortcut: (Clip) -> Void = { _ in }
    var onClipFindSimilarImages: (Clip) -> Void = { _ in }
    var onDragStarted: (Clip) -> Void = { _ in }
    var onClipMoved: (Clip, Int, Bool) -> Void = { _, _, _ in }  // (clip, toIndex, targetIsPinned)
    var onDragEnded: () -> Void = {}

    @State private var cardFrames: [Int64: CGRect] = [:]
    @State private var viewportWidth: CGFloat = 0
    @State private var dropTargetIndex: Int? = nil
    @State private var dropTargetIsPinned: Bool = false
    @State private var draggedClipId: Int64? = nil
    /// Clip for which the shortcut recorder sheet is currently shown.
    @State private var shortcutSheetClip: Clip? = nil

    var body: some View {
        // filterResetID가 바뀌면 ScrollViewReader가 재생성되어
        // 스크롤 위치가 확실히 0으로 리셋됨. (staggerAppeared는 CardScrollView 레벨에서 유지)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        // TODO: DRAG_REORDER — 드롭 인디케이터 (임시 비활성화)
                        // if dropTargetIndex == index && draggedClipId != nil {
                        //     DropIndicatorView(isPinZone: dropTargetIsPinned).transition(.opacity)
                        // }

                        // Section divider
                        if shouldShowDivider(at: index) {
                            SectionDividerView(
                                title: clip.section.title,
                                icon: clip.section.icon
                            )
                        }

                        let assignedTags = clipTags[clip.id ?? -1] ?? []

                        let staggerDelay = index < 20 ? Double(index) * DesignTokens.Animation.cardStagger : 0.0

                        // Map index 0..9 → hint label. ⌥1..⌥9 for cards 0..8, ⌥0 for card 9.
                        let quickHint: Int? = {
                            guard showQuickPasteHints, index < 10 else { return nil }
                            return index == 9 ? 0 : (index + 1)
                        }()

                        ClipCardView(
                            clip: clip,
                            isSelected: selectedIndex == index || selectedIndices.contains(index),
                            isMultiSelected: selectedIndices.contains(index) && selectedIndices.count > 1,
                            cardSize: cardSize,
                            assignedTags: assignedTags,
                            quickPasteHint: quickHint,
                            onTap: {
                                selectedIndex = index
                                onClipSelected(clip)
                            },
                            onCmdTap: {
                                onCmdClipSelected(index)
                            },
                            onDoubleTap: {
                                onClipActivated(clip)
                            },
                            onDelete: {
                                onClipDelete(clip)
                            },
                            onTogglePin: {
                                onClipTogglePin(clip)
                            },
                            // TODO: DRAG_REORDER — 재정렬 드래그 시작 핸들러 (임시 비활성화)
                            // onDragStarted: canReorder ? { dragClip in
                            //     draggedClipId = dragClip.id
                            //     onDragStarted(dragClip)
                            // } : nil
                            onDragStarted: nil
                        )
                        // A2: deletion transition (scale + fade out, identity on insertion)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .scale(scale: 0.85).combined(with: .opacity)
                        ))
                        // A1: stagger appearance — true일 때만 애니메이션, false 리셋은 즉시(withTransaction으로 처리)
                        .opacity(staggerAppeared ? 1 : 0)
                        .offset(y: staggerAppeared ? 0 : 18)
                        .animation(AppAnimations.policy(staggerAppeared
                                ? .spring(response: 0.38, dampingFraction: 0.78).delay(staggerDelay)
                                : .none),
                            value: staggerAppeared
                        )
                        .id(clip.id)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CardFramePreferenceKey.self,
                                    value: [clip.id ?? -1: geo.frame(in: .named("cardScroll"))]
                                )
                            }
                        )
                        // TODO: DRAG_REORDER — 드롭 델리게이트 (임시 비활성화)
                        // .onDrop(
                        //     of: [ClipDragType.utType],
                        //     delegate: CardDropDelegate(
                        //         targetIndex: index, targetClip: clip, clips: clips,
                        //         canReorder: canReorder,
                        //         dropTargetIndex: $dropTargetIndex,
                        //         dropTargetIsPinned: $dropTargetIsPinned,
                        //         onDrop: handleDrop
                        //     )
                        // )
                        // Right-click context menu
                        .contextMenu {
                            Button {
                                DetailModalController.shared.show(clip: clip)
                            } label: {
                                Label("미리보기", systemImage: "eye")
                            }

                            Divider()

                            Button {
                                onClipActivated(clip)
                            } label: {
                                Label("붙여넣기", systemImage: "doc.on.clipboard")
                            }

                            // Paste As... (non-image only) — Plain / Markdown / Rich Text
                            if clip.contentType != .image {
                                Menu {
                                    Button {
                                        onClipPlainTextPaste(clip)
                                    } label: {
                                        Label("paste.as.plain", systemImage: "doc.plaintext")
                                    }
                                    Button {
                                        onClipPasteAsMarkdown(clip)
                                    } label: {
                                        Label("paste.as.markdown", systemImage: "chevron.left.forwardslash.chevron.right")
                                    }
                                    Button {
                                        onClipPasteAsRichText(clip)
                                    } label: {
                                        Label("paste.as.richtext", systemImage: "textformat")
                                    }
                                } label: {
                                    Label("paste.as.menu", systemImage: "square.and.pencil")
                                }
                            }

                            // 변환하여 붙여넣기 (텍스트/코드 전용)
                            if clip.contentType == .text || clip.contentType == .code {
                                Menu {
                                    ForEach(TransformCategory.allCases, id: \.rawValue) { category in
                                        let items = TextTransform.allCases.filter { $0.category == category }
                                        Section(category.rawValue) {
                                            ForEach(items) { transform in
                                                Button {
                                                    onClipPasteWithTransform(clip, transform)
                                                } label: {
                                                    Label(transform.displayName, systemImage: transform.systemImage)
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Label("변환하여 붙여넣기", systemImage: "wand.and.stars")
                                }
                            }

                            // 유사 이미지 찾기 (이미지 전용)
                            if clip.contentType == .image {
                                Button {
                                    onClipFindSimilarImages(clip)
                                } label: {
                                    Label("유사 이미지 찾기", systemImage: "rectangle.on.rectangle.angled")
                                }
                            }

                            // 클립별 커스텀 단축키 (파일 타입 제외 — Finder reveal이 paste 대신 실행됨)
                            if clip.contentType != .file {
                                shortcutMenu(for: clip)
                            }

                            Divider()

                            Button {
                                onClipTogglePin(clip)
                            } label: {
                                Label(
                                    clip.isPinned ? "고정 해제" : "고정",
                                    systemImage: clip.isPinned ? "pin.slash" : "pin"
                                )
                            }

                            if !boards.isEmpty {
                                Menu {
                                    ForEach(boards, id: \.id) { board in
                                        let isAssigned = assignedTags.contains(where: { $0.id == board.id })
                                        Button {
                                            if let boardId = board.id {
                                                if isAssigned {
                                                    onClipRemoveBoard(clip, boardId)
                                                } else {
                                                    onClipAssignBoard(clip, boardId)
                                                }
                                            }
                                        } label: {
                                            let prefix = isAssigned ? "✓ " : ""
                                            Label {
                                                Text(prefix + board.name)
                                            } icon: {
                                                Image(nsImage: colorDot(hex: board.colorHex))
                                            }
                                        }
                                    }
                                } label: {
                                    Label("태그 지정", systemImage: "tag")
                                }
                            }

                            Button {
                                onClipAddToStack(clip)
                            } label: {
                                Label("스택에 추가", systemImage: "square.stack.3d.up")
                            }

                            Divider()

                            Button(role: .destructive) {
                                onClipDelete(clip)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }

                    // TODO: DRAG_REORDER — 마지막 카드 뒤 드롭 인디케이터 (임시 비활성화)
                    // if dropTargetIndex == clips.count && draggedClipId != nil {
                    //     DropIndicatorView(isPinZone: dropTargetIsPinned).transition(.opacity)
                    // }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .animation(AppAnimations.policy(.easeInOut(duration: 0.15)), value: dropTargetIndex)
                // A3: smooth card list replacement when filter/search changes
                .animation(AppAnimations.policy(DesignTokens.Animation.cardSpring), value: clips.compactMap { $0.id })
                // TODO: DRAG_REORDER — 드래그 취소 정리 (임시 비활성화)
                // .onReceive(NotificationCenter.default.publisher(for: .clipRavenDragSessionEnded)) { _ in
                //     draggedClipId = nil; dropTargetIndex = nil; onDragEnded()
                // }
            }
            .coordinateSpace(name: "cardScroll")
            // Panel show/hide and filter change stagger is managed by MainPanelView via @Binding
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { viewportWidth = geo.size.width }
                        .onChange(of: geo.size.width) { viewportWidth = $0 }
                }
            )
            .onPreferenceChange(CardFramePreferenceKey.self) { frames in
                cardFrames.merge(frames) { _, new in new }
            }
            .onChange(of: selectedIndex) { newValue in
                guard let idx = newValue, idx < clips.count, let clipId = clips[idx].id else { return }
                guard let frame = cardFrames[clipId] else { return }

                let leftVisible = frame.minX >= 0
                let rightVisible = frame.maxX <= viewportWidth

                if leftVisible && rightVisible {
                    // Fully visible, no scroll
                } else if !leftVisible {
                    AppAnimations.withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(clipId, anchor: .leading)
                    }
                } else {
                    AppAnimations.withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(clipId, anchor: .trailing)
                    }
                }
            }
        }
        // filterResetID 변경 → ScrollViewReader 재생성 → 스크롤 위치 0 확실히 리셋
        .id(filterResetID)
        .sheet(item: Binding(
            get: { shortcutSheetClip },
            set: { shortcutSheetClip = $0 }
        )) { clip in
            ShortcutRecorderSheet(
                initialKeyCode: clip.customShortcutKeyCode,
                initialModifiers: clip.customShortcutModifiers,
                clipId: clip.id,
                onSave: { keyCode, modifiers in
                    onClipAssignShortcut(clip, keyCode, modifiers)
                    shortcutSheetClip = nil
                },
                onClear: {
                    onClipRemoveShortcut(clip)
                    shortcutSheetClip = nil
                },
                onCancel: {
                    shortcutSheetClip = nil
                }
            )
        }
    }

    // MARK: - Shortcut submenu

    /// Builds the "단축키" submenu for a clip's context menu.
    @ViewBuilder
    private func shortcutMenu(for clip: Clip) -> some View {
        let hasShortcut = clip.customShortcutKeyCode != nil && clip.customShortcutModifiers != nil
        Menu {
            if hasShortcut,
               let kc = clip.customShortcutKeyCode,
               let mods = clip.customShortcutModifiers {
                let display = HotKeyFormatter.format(keyCode: kc, modifiers: mods)
                Button {
                    shortcutSheetClip = clip
                } label: {
                    Label("\(display) 변경…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onClipRemoveShortcut(clip)
                } label: {
                    Label("단축키 제거", systemImage: "minus.circle")
                }
            } else {
                Button {
                    shortcutSheetClip = clip
                } label: {
                    Label("단축키 할당…", systemImage: "command")
                }
            }
        } label: {
            Label("단축키", systemImage: "keyboard")
        }
    }

    // MARK: - Drop Handler

    private func handleDrop(draggedId: Int64, targetIndex: Int, targetIsPinned: Bool) {
        guard let clip = clips.first(where: { $0.id == draggedId }) else { return }
        onClipMoved(clip, targetIndex, targetIsPinned)
        draggedClipId = nil
        dropTargetIndex = nil
        onDragEnded()
    }

    // MARK: - Helpers

    private static var colorDotCache: [String: NSImage] = [:]

    private func colorDot(hex: String) -> NSImage {
        if let cached = Self.colorDotCache[hex] { return cached }

        let size: CGFloat = 12
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let color = NSColor(Color(hex: hex) ?? .gray)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        Self.colorDotCache[hex] = image
        return image
    }

    private func shouldShowDivider(at index: Int) -> Bool {
        let currentSection = clips[index].section
        if index == 0 { return true }
        let previousSection = clips[index - 1].section
        return currentSection != previousSection
    }
}

// MARK: - Drop Delegate

private struct CardDropDelegate: DropDelegate {
    let targetIndex: Int
    let targetClip: Clip
    let clips: [Clip]
    let canReorder: Bool
    @Binding var dropTargetIndex: Int?
    @Binding var dropTargetIsPinned: Bool
    let onDrop: (Int64, Int, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        canReorder && info.hasItemsConforming(to: [ClipDragType.utType])
    }

    func dropEntered(info: DropInfo) {
        guard canReorder else { return }
        dropTargetIndex = targetIndex
        dropTargetIsPinned = targetClip.isPinned
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard canReorder else { return DropProposal(operation: .forbidden) }
        dropTargetIndex = targetIndex
        dropTargetIsPinned = targetClip.isPinned
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard canReorder else { return false }

        let providers = info.itemProviders(for: [ClipDragType.utType])
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: ClipDragType.utType.identifier) { data, _ in
            guard let data,
                  let encoded = String(data: data, encoding: .utf8),
                  let clipId = ClipDragType.decode(encoded) else { return }

            DispatchQueue.main.async {
                onDrop(clipId, targetIndex, targetClip.isPinned)
            }
        }

        return true
    }
}

// MARK: - Card Frame Tracking

private struct CardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
