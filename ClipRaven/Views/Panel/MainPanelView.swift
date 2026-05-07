import SwiftUI
import ClipRavenSync

struct MainPanelView: View {
    @StateObject private var viewModel = MainPanelViewModel()
    @ObservedObject private var theme = ThemeManager.shared
    @State private var panelHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "clipraven.panelHeight")
        return saved > 0 ? min(max(saved, 200), 600) : 320
    }()
    // A1: Stagger state for card entrance animation — managed here so filter changes can re-trigger
    @State private var cardStaggerAppeared = false

    private var filterResetIDString: String {
        "\(viewModel.selectedTagIds.sorted())-\(viewModel.selectedFilter)-\(viewModel.showPinned)-\(viewModel.selectedSourceApp ?? "")-\(viewModel.searchText.isEmpty)"
    }

    private var isCompactMode: Bool { panelHeight < 260 }
    private var cardSize: CGFloat { min(240, panelHeight - 80) }

    var body: some View {
        VStack(spacing: 0) {
            // Titlebar: filters centered (hidden during similar images mode)
            if !viewModel.similarImagesMode {
                FilterBarView(
                    selectedFilter: $viewModel.selectedFilter,
                    showPinned: $viewModel.showPinned,
                    selectedTagIds: $viewModel.selectedTagIds,
                    selectedSourceApp: $viewModel.selectedSourceApp,
                    dateRangeFilter: $viewModel.dateRangeFilter,
                    selectedAICategory: $viewModel.selectedAICategory,
                    counts: viewModel.filterCounts,
                    tags: viewModel.boards,
                    availableSourceApps: viewModel.availableSourceApps,
                    clipCount: viewModel.clips.count,
                    searchText: $viewModel.searchText,
                    onCreateTag: { name, colorHex in
                        viewModel.createTag(name: name, colorHex: colorHex)
                    },
                    onDeleteTag: { id in
                        viewModel.deleteTag(id: id)
                    },
                    onUpdateTag: { id, name, colorHex in
                        viewModel.updateTag(id: id, name: name, colorHex: colorHex)
                    }
                )
            } else {
                // Similar images mode banner — replaces filter bar
                similarImagesBanner
            }

            // Main content area: cards + optional preview
            HStack(spacing: 0) {
                // Card content
                if viewModel.clips.isEmpty {
                    emptyState
                } else {
                    CardScrollView(
                        clips: viewModel.clips,
                        boards: viewModel.boards,
                        clipTags: viewModel.clipTags,
                        selectedIndex: $viewModel.selectedIndex,
                        selectedIndices: viewModel.selectedIndices,
                        cardSize: cardSize,
                        canReorder: viewModel.canReorder,
                        showQuickPasteHints: viewModel.optionKeyHeld,
                        filterResetID: AnyHashable(filterResetIDString),
                        staggerAppeared: $cardStaggerAppeared,
                        onClipSelected: { _ in
                            viewModel.clearMultiSelect()
                            viewModel.updatePreviewSelection()
                        },
                        onCmdClipSelected: { index in
                            viewModel.toggleMultiSelect(index: index)
                        },
                        onClipActivated: { clip in
                            viewModel.pasteClip(clip)
                        },
                        onClipDelete: { clip in
                            viewModel.deleteClip(clip)
                        },
                        onClipTogglePin: { clip in
                            viewModel.togglePin(clip)
                        },
                        onClipAssignBoard: { clip, boardId in
                            viewModel.assignClipToBoard(clip, boardId: boardId)
                        },
                        onClipRemoveBoard: { clip, boardId in
                            viewModel.removeClipFromBoard(clip, boardId: boardId)
                        },
                        onClipAddToStack: { clip in
                            viewModel.addToStack(clip)
                        },
                        onClipPlainTextPaste: { clip in
                            viewModel.pasteClipAsPlainText(clip)
                        },
                        onClipPasteAsMarkdown: { clip in
                            viewModel.pasteClipAsMarkdown(clip)
                        },
                        onClipPasteAsRichText: { clip in
                            viewModel.pasteClipAsRichText(clip)
                        },
                        onClipPasteWithTransform: { clip, transform in
                            viewModel.pasteClipWithTransform(clip, transform: transform)
                        },
                        onClipAssignShortcut: { clip, keyCode, modifiers in
                            viewModel.assignClipShortcut(clip: clip, keyCode: keyCode, modifiers: modifiers)
                        },
                        onClipRemoveShortcut: { clip in
                            viewModel.removeClipShortcut(clip: clip)
                        },
                        onClipFindSimilarImages: { clip in
                            viewModel.findSimilarImages(clip)
                        },
                        onDragStarted: { clip in
                            viewModel.draggedClip = clip
                            viewModel.isDragging = true
                        },
                        onClipMoved: { clip, toIndex, isPinned in
                            viewModel.moveClip(clip, toIndex: toIndex, targetIsPinned: isPinned)
                        },
                        onDragEnded: {
                            viewModel.draggedClip = nil
                            viewModel.isDragging = false
                        }
                    )
                }

                // Preview panel (slide-in from right)
                if viewModel.showPreview {
                    Divider()
                    PreviewPanelView(
                        clip: viewModel.previewClip,
                        onDismiss: {
                            AppAnimations.withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.showPreview = false
                                viewModel.previewClip = nil
                            }
                        },
                        onUpdate: { updatedClip in
                            viewModel.updateClip(updatedClip)
                        },
                        onNicknameChanged: { clip, nickname in
                            viewModel.updateNickname(clip, nickname: nickname)
                        }
                    )
                    // A4: spring slide-in/out from trailing edge
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }

            // Multi-select floating action bar
            if viewModel.isMultiSelectMode {
                MultiSelectActionBar(
                    selectedCount: viewModel.selectedIndices.count,
                    boards: viewModel.boards,
                    canMerge: viewModel.canMergeSelectedClips,
                    onDelete: { viewModel.deleteSelectedClips() },
                    onAddToStack: { viewModel.addSelectedToStack() },
                    onMerge: { viewModel.mergeSelectedClips() },
                    onAssignTag: { tagId in viewModel.assignTagToSelected(tagId: tagId) },
                    onCancel: { viewModel.clearMultiSelect() }
                )
                // A5: spring action bar entrance
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Paste stack bar (only when stack has items)
            StackBarView(engine: viewModel.pasteStackEngine)

            // Bottom bar with keyboard hints
            BottomBarView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(theme.colorPreset.accentColor)
        .preferredColorScheme(theme.themePreference == "dark" ? .dark : theme.themePreference == "light" ? .light : nil)
        .overlay(alignment: .top) {
            // Stack feedback toast
            if let message = viewModel.stackFeedbackMessage {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(radius: 4)
                .padding(.top, 46)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(AppAnimations.policy(.easeInOut(duration: 0.2)), value: viewModel.stackFeedbackMessage)
        // A5: spring for multi-select action bar
        .animation(AppAnimations.policy(DesignTokens.Animation.multiBarSpring), value: viewModel.isMultiSelectMode)
        // A1: Panel hide → immediately reset stagger (no animation, prevent background spring)
        .onReceive(NotificationCenter.default.publisher(for: .clipRavenPanelHidden)) { _ in
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { cardStaggerAppeared = false }
        }
        // A1: Panel show → reset then re-trigger stagger after short delay
        .onReceive(NotificationCenter.default.publisher(for: .clipRavenPanelShown)) { _ in
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { cardStaggerAppeared = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                cardStaggerAppeared = true
            }
        }
        // A1: Filter change → reset & re-trigger stagger so newly-visible cards animate in
        .onChange(of: filterResetIDString) { _ in
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { cardStaggerAppeared = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                cardStaggerAppeared = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipRavenPanelHeightChanged)) { notification in
            if let height = notification.userInfo?["height"] as? CGFloat {
                panelHeight = height
            }
        }
        .onAppear { viewModel.startObserving() }
        .onDisappear { viewModel.stopObserving() }
        // A4: spring for preview panel slide
        .animation(AppAnimations.policy(DesignTokens.Animation.previewSpring), value: viewModel.showPreview)
        // MARK: - Keyboard Shortcuts
        .background(
            KeyboardShortcutView(viewModel: viewModel, isSearchActive: isSearchActive)
                .frame(width: 0, height: 0)
        )
    }

    private var isSearchActive: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Similar Images Banner

    private var similarImagesBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 11))
                .foregroundColor(.orange)

            Text("유사 이미지 검색")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)

            if let ref = viewModel.similarReferenceClip {
                Text("· \(viewModel.clips.count - 1)개 유사")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                let _ = ref  // suppress unused warning
            }

            Spacer()

            Button(action: { viewModel.exitSimilarImagesMode() }) {
                HStack(spacing: 3) {
                    Text("취소")
                        .font(.system(size: 11))
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // 0.08 opacity was invisible on white in light mode. 0.15 stays
        // subtle in dark and becomes a legible warning tint in light.
        .background(Color.orange.opacity(0.15))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            let isSearching = !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty

            Image(systemName: isSearching ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))

            if isSearching {
                Text("'\(viewModel.searchText)' 검색 결과 없음")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if !viewModel.selectedTagIds.isEmpty {
                Text("이 태그에 항목이 없습니다")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text("복사한 항목이 여기에 표시됩니다")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Keyboard Shortcut Handler (invisible view for key bindings)

private struct KeyboardShortcutView: View {
    @ObservedObject var viewModel: MainPanelViewModel
    var isSearchActive: Bool = false

    var body: some View {
        ZStack {
            // Arrow left/right navigation (disabled during search to allow cursor movement)
            if !isSearchActive {
                Button("") { viewModel.moveSelection(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .opacity(0)

                Button("") { viewModel.moveSelection(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .opacity(0)
            }

            // Enter = paste
            Button("") { viewModel.activateSelected() }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)

            // Delete/Backspace: handled by ScrollConvertingPanel → notification
            // Ctrl+1-9 quick paste: handled by ScrollConvertingPanel → notification

            // Space = open detail modal for selected clip
            Button("") {
                if let idx = viewModel.selectedIndex, idx < viewModel.clips.count {
                    DetailModalController.shared.show(clip: viewModel.clips[idx])
                }
            }
            .keyboardShortcut(KeyEquivalent(" "), modifiers: [])
            .opacity(0)

            // Option+Enter = paste as plain text
            Button("") { viewModel.activateSelectedAsPlainText() }
                .keyboardShortcut(.return, modifiers: .option)
                .opacity(0)

            // Shift+Enter = add to paste stack
            Button("") {
                if let idx = viewModel.selectedIndex, idx < viewModel.clips.count {
                    viewModel.addToStack(viewModel.clips[idx])
                }
            }
            .keyboardShortcut(.return, modifiers: .shift)
            .opacity(0)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Multi-Select Action Bar

private struct MultiSelectActionBar: View {
    let selectedCount: Int
    let boards: [Tag]
    var canMerge: Bool = false
    var onDelete: () -> Void = {}
    var onAddToStack: () -> Void = {}
    var onMerge: () -> Void = {}
    var onAssignTag: (Int64) -> Void = { _ in }
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount)개 선택됨")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)

            Divider()
                .frame(height: 14)

            Button(action: onDelete) {
                Label("삭제", systemImage: "trash")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.red.opacity(0.9))

            Button(action: onAddToStack) {
                Label("스택추가", systemImage: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Button(action: onMerge) {
                Label("병합", systemImage: "text.badge.plus")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canMerge ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .disabled(!canMerge)
            .help(canMerge ? "선택한 텍스트/코드 클립을 하나로 병합" : "텍스트 또는 코드 클립을 2개 이상 선택해주세요")

            if !boards.isEmpty {
                Menu {
                    ForEach(boards, id: \.id) { board in
                        Button {
                            if let boardId = board.id {
                                onAssignTag(boardId)
                            }
                        } label: {
                            Text(board.name)
                        }
                    }
                } label: {
                    Label("태그", systemImage: "tag")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.3))
        .background(.ultraThinMaterial)
    }
}
