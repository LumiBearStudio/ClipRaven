import SwiftUI
import ClipRavenSync

struct FilterBarView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Binding var selectedFilter: ContentTypeFilter
    @Binding var showPinned: Bool
    @Binding var selectedTagIds: Set<Int64>
    @Binding var selectedSourceApp: String?
    @Binding var dateRangeFilter: DateRangeFilter?
    @Binding var selectedAICategory: String?
    let counts: [ContentTypeFilter: Int]
    let tags: [Tag]
    let availableSourceApps: [(bundleId: String, name: String)]
    var clipCount: Int = 0
    @Binding var searchText: String
    var onCreateTag: (String, String) -> Void = { _, _ in }
    var onDeleteTag: (Int64) -> Void = { _ in }
    var onUpdateTag: (Int64, String, String) -> Void = { _, _, _ in }

    @State private var isSearching = false
    @State private var isPaused = false
    @State private var isCreatingTag = false
    @State private var newTagName = ""
    @State private var selectedColor: TagColor = .blue
    @State private var editingTagId: Int64? = nil
    @State private var editTagName = ""
    @State private var editTagColor: TagColor = .blue

    private let contentFilters: [ContentTypeFilter] = [.all, .text, .code, .url, .image, .file]

    var body: some View {
        HStack(spacing: 8) {

            // ── 좌측: 앱 아이콘 + 타이틀 ─────────────────────
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.colorPreset.accentColor))

                Text("ClipRaven")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.75))
            }
            .padding(.leading, 12)

            // ── 중앙: 각 기능 독립 그룹 (스크롤) ──────────────
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {

                        // ① 검색 그룹
                        if isSearching {
                            searchField
                        } else {
                            Button { openSearch() } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("/", modifiers: .command)
                            .help("검색 (⌘/)")
                            .toolbarPill()
                        }

                        // ② 콘텐츠 타입 필터 그룹 — 검색 중엔 아이콘만
                        filterSegmentGroup(compact: isSearching)

                        // ③ 핀 그룹
                        Button { showPinned.toggle() } label: {
                            Image(systemName: showPinned ? "pin.fill" : "pin")
                                .font(.system(size: 12, weight: showPinned ? .semibold : .regular))
                                .foregroundStyle(showPinned ? Color(NSColor.labelColor) : Color(NSColor.secondaryLabelColor))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help(showPinned ? "핀 고정 항목 표시 중" : "핀 고정 항목 숨김")
                        .toolbarPill(active: showPinned)

                        // ④ 소스앱 + 날짜 필터 그룹
                        HStack(spacing: 1) {
                            if !availableSourceApps.isEmpty {
                                sourceAppMenu
                                Color(NSColor.separatorColor).frame(width: 0.5, height: 14)
                            }
                            dateRangeMenu
                            if #available(macOS 26, *) {
                                Color(NSColor.separatorColor).frame(width: 0.5, height: 14)
                                aiCategoryMenu
                            }
                        }
                        .toolbarPill(active: selectedSourceApp != nil || dateRangeFilter != nil || selectedAICategory != nil)

                        // ⑤ 태그 그룹 — 검색 중엔 도트만, 평상시엔 전체 표시
                        if !tags.isEmpty || !isSearching {
                            HStack(spacing: isSearching ? 5 : 3) {
                                if isSearching {
                                    // 검색 중: 색상 도트만 표시
                                    ForEach(tags, id: \.id) { tag in
                                        let tagColor = Color(hex: tag.colorHex) ?? .gray
                                        let isSelected = selectedTagIds.contains(tag.id ?? -1)
                                        Circle()
                                            .fill(tagColor)
                                            .frame(width: isSelected ? 9 : 7, height: isSelected ? 9 : 7)
                                            .opacity(isSelected ? 1.0 : 0.5)
                                            .onTapGesture {
                                                if let id = tag.id {
                                                    AppAnimations.withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                                        if selectedTagIds.contains(id) { selectedTagIds.remove(id) }
                                                        else { selectedTagIds.insert(id) }
                                                    }
                                                }
                                            }
                                    }
                                } else {
                                    // 평상시: 칩 + 수정 폼
                                    ForEach(tags, id: \.id) { tag in
                                        if editingTagId == tag.id {
                                            inlineEditForm(tag: tag)
                                        } else {
                                            tagChip(tag)
                                        }
                                    }
                                    if isCreatingTag {
                                        inlineCreateForm
                                    } else {
                                        Button {
                                            AppAnimations.withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                isCreatingTag = true
                                            }
                                        } label: {
                                            Image(systemName: "plus")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                                                .frame(width: 18, height: 18)
                                        }
                                        .buttonStyle(.plain)
                                        .help("태그 추가")
                                    }
                                }
                            }
                            .padding(.horizontal, isSearching ? 8 : 6)
                            .padding(.vertical, isSearching ? 8 : 4)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                            )
                            .animation(AppAnimations.policy(.spring(response: 0.25, dampingFraction: 0.85)), value: isSearching)
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .center)
                }
            }

            // ── 우측: 더보기 메뉴 ────────────────────────────
            HStack(spacing: 4) {
                // 더보기 메뉴
                Menu {
                    Button {
                        NotificationCenter.default.post(name: .clipRavenOpenSettings, object: nil)
                    } label: {
                        Label("설정", systemImage: "gearshape")
                    }
                    Divider()
                    Button {
                        NotificationCenter.default.post(name: .clipRavenTogglePause, object: nil)
                    } label: {
                        Label(
                            isPaused ? "캡처 재개" : "캡처 일시정지",
                            systemImage: isPaused ? "play.circle" : "pause.circle"
                        )
                    }
                    Divider()
                    Button {
                        NotificationCenter.default.post(name: .clipRavenOpenAboutSection, object: nil)
                    } label: {
                        Label("ClipRaven 정보", systemImage: "info.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            )
            .padding(.trailing, 8)
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Color(NSColor.separatorColor).frame(height: 0.5)
        }
        .animation(AppAnimations.policy(.spring(response: 0.3, dampingFraction: 0.85)), value: isSearching)
        // 포커스 없이 Esc로 검색 닫힐 때 (ScrollConvertingPanel에서 발송)
        .onReceive(NotificationCenter.default.publisher(for: .clipRavenSearchClosed)) { _ in
            if isSearching { closeSearch() }
        }
        // Sync pause state from ClipboardMonitor (single source of truth)
        .onReceive(NotificationCenter.default.publisher(for: .clipRavenPauseStateChanged)) { notification in
            isPaused = notification.userInfo?["isPaused"] as? Bool ?? false
        }
    }

    // MARK: - Filter Segment Group (compact: 검색 중 아이콘만 표시)

    private func filterSegmentGroup(compact: Bool = false) -> some View {
        HStack(spacing: 1) {
            ForEach(contentFilters, id: \.self) { filter in
                let isSelected = selectedFilter == filter
                let count = counts[filter] ?? 0

                Button {
                    AppAnimations.withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        selectedFilter = filter
                    }
                } label: {
                    Group {
                        if compact {
                            // 검색 중: 아이콘만
                            Image(systemName: filter.systemImage)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                .frame(width: 26, height: 26)
                        } else {
                            // 평상시: 아이콘 + 텍스트 + 카운트
                            HStack(spacing: 4) {
                                Image(systemName: filter.systemImage)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                Text(filter.displayName)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(isSelected ? Color(NSColor.secondaryLabelColor) : Color(NSColor.tertiaryLabelColor))
                                        .monospacedDigit()
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? Color(NSColor.selectedControlColor).opacity(0.5) : Color.clear)
                    )
                    .foregroundStyle(isSelected ? Color(NSColor.labelColor) : Color(NSColor.secondaryLabelColor))
                }
                .buttonStyle(.plain)
                .help("\(filter.displayName) (\(count))")
            }
        }
        .animation(AppAnimations.policy(.spring(response: 0.25, dampingFraction: 0.85)), value: compact)
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            TextField("검색...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 140, maxWidth: 280)
                .onExitCommand { closeSearch() }

            if !searchText.isEmpty {
                Text("\(clipCount)건")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Button(action: closeSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))
        )
    }

    // MARK: - Toolbar Icon Button (배경 없는 아이콘 버튼)

    private func toolbarIconButton(
        systemImage: String,
        color: Color,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isActive ? color.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Source App Menu

    private var sourceAppMenu: some View {
        Menu {
            Button {
                selectedSourceApp = nil
            } label: {
                HStack {
                    Label("모든 앱", systemImage: "square.grid.2x2")
                    if selectedSourceApp == nil { Spacer(); Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach(availableSourceApps, id: \.bundleId) { app in
                Button { selectedSourceApp = app.bundleId } label: {
                    HStack {
                        Label(app.name, systemImage: "app")
                        if selectedSourceApp == app.bundleId { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedSourceApp != nil ? "app.badge.checkmark" : "app.badge")
                    .font(.system(size: 13))
                if let bundleId = selectedSourceApp,
                   let app = availableSourceApps.first(where: { $0.bundleId == bundleId }) {
                    Text(app.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            .foregroundColor(selectedSourceApp != nil ? .purple : .secondary)
            .frame(height: 26)
            .padding(.horizontal, selectedSourceApp != nil ? 6 : 4)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    // MARK: - Date Range Menu

    private var dateRangeMenu: some View {
        Menu {
            Button { dateRangeFilter = nil } label: {
                HStack {
                    Label("전체 기간", systemImage: "infinity")
                    if dateRangeFilter == nil { Spacer(); Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach([DateRangeFilter.today, .yesterday, .lastWeek, .lastMonth], id: \.systemImage) { filter in
                Button { dateRangeFilter = filter } label: {
                    HStack {
                        Label(filter.displayName, systemImage: filter.systemImage)
                        if dateRangeFilter == filter { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: dateRangeFilter != nil ? "calendar.badge.checkmark" : "calendar")
                    .font(.system(size: 13))
                if let filter = dateRangeFilter {
                    Text(filter.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            .foregroundColor(dateRangeFilter != nil ? .teal : .secondary)
            .frame(height: 26)
            .padding(.horizontal, dateRangeFilter != nil ? 6 : 4)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    // MARK: - AI Category Menu

    @available(macOS 26, *)
    private var aiCategoryMenu: some View {
        Menu {
            Button { selectedAICategory = nil } label: {
                HStack {
                    Label("전체", systemImage: "sparkles")
                    if selectedAICategory == nil { Spacer(); Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach(AICategory.allCases, id: \.rawValue) { category in
                Button { selectedAICategory = category.rawValue } label: {
                    HStack {
                        Label(category.displayName, systemImage: category.systemImage)
                        if selectedAICategory == category.rawValue { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedAICategory != nil ? "sparkles" : "sparkle")
                    .font(.system(size: 13))
                if let raw = selectedAICategory,
                   let cat = AICategory(rawValue: raw) {
                    Text(cat.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            .foregroundColor(selectedAICategory != nil ? .indigo : .secondary)
            .frame(height: 26)
            .padding(.horizontal, selectedAICategory != nil ? 6 : 4)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    // MARK: - Tag Chip (필터 세그먼트와 동일한 스타일)

    private func tagChip(_ tag: Tag) -> some View {
        let isSelected = selectedTagIds.contains(tag.id ?? -1)
        let tagColor = Color(hex: tag.colorHex) ?? .gray

        return Button {
            if let id = tag.id {
                AppAnimations.withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    if selectedTagIds.contains(id) { selectedTagIds.remove(id) }
                    else { selectedTagIds.insert(id) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(tagColor)
                    .frame(width: 7, height: 7)
                Text(tag.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color(NSColor.separatorColor) : Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(NSColor.tertiaryLabelColor), lineWidth: 0.5)
                            .opacity(isSelected ? 1 : 0)
                    )
            )
            .foregroundStyle(isSelected ? Color(NSColor.labelColor) : Color(NSColor.secondaryLabelColor))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let id = tag.id {
                    editTagName = tag.name
                    editTagColor = TagColor.allCases.first(where: { $0.hex == tag.colorHex }) ?? .blue
                    withAnimation { editingTagId = id }
                }
            } label: { Label("수정", systemImage: "pencil") }

            Button(role: .destructive) {
                if let id = tag.id { onDeleteTag(id) }
            } label: { Label("삭제", systemImage: "trash") }
        }
    }

    // MARK: - Inline Create Form

    private var inlineCreateForm: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(selectedColor.color)
                .frame(width: 12, height: 12)
                .onTapGesture {
                    let all = TagColor.allCases
                    if let idx = all.firstIndex(of: selectedColor) {
                        selectedColor = all[(idx + 1) % all.count]
                    }
                }
            TextField("이름", text: $newTagName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 72)
                .onSubmit { commitCreate() }
            Button(action: commitCreate) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(newTagName.isEmpty ? theme.colorPreset.accentColor.opacity(0.4) : theme.colorPreset.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(newTagName.isEmpty)
            Button(action: cancelCreate) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
    }

    // MARK: - Inline Edit Form

    private func inlineEditForm(tag: Tag) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(editTagColor.color)
                .frame(width: 12, height: 12)
                .onTapGesture {
                    let all = TagColor.allCases
                    if let idx = all.firstIndex(of: editTagColor) {
                        editTagColor = all[(idx + 1) % all.count]
                    }
                }
            TextField("이름", text: $editTagName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 72)
                .onSubmit { commitEdit() }
            Button(action: commitEdit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(editTagName.isEmpty ? theme.colorPreset.accentColor.opacity(0.4) : theme.colorPreset.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(editTagName.isEmpty)
            Button(action: cancelEdit) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
    }

    // MARK: - Actions

    private func openSearch() {
        AppAnimations.withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isSearching = true }
        searchText = ""
        NotificationCenter.default.post(name: .clipRavenSearchOpened, object: nil)
    }

    private func closeSearch() {
        AppAnimations.withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isSearching = false }
        searchText = ""
        NotificationCenter.default.post(name: .clipRavenSearchClosed, object: nil)
    }

    private func commitCreate() {
        guard !newTagName.isEmpty else { return }
        onCreateTag(newTagName, selectedColor.hex)
        newTagName = ""
        withAnimation { isCreatingTag = false }
    }

    private func cancelCreate() {
        newTagName = ""
        withAnimation { isCreatingTag = false }
    }

    private func commitEdit() {
        guard !editTagName.isEmpty, let id = editingTagId else { return }
        onUpdateTag(id, editTagName, editTagColor.hex)
        withAnimation { editingTagId = nil }
    }

    private func cancelEdit() {
        withAnimation { editingTagId = nil }
    }
}

// MARK: - Toolbar Pill Modifier

private struct ToolbarPillModifier: ViewModifier {
    var active: Bool = false
    var activeColor: Color = .accentColor

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? Color(NSColor.selectedControlColor).opacity(0.6) : Color(NSColor.controlBackgroundColor).opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
            )
    }
}

extension View {
    func toolbarPill(active: Bool = false, activeColor: Color = .accentColor) -> some View {
        modifier(ToolbarPillModifier(active: active, activeColor: activeColor))
    }
}

// MARK: - Filter Button (standalone, kept for reference)

struct FilterButton: View {
    let filter: ContentTypeFilter
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: filter.systemImage).font(.system(size: 13))
                Text(filter.displayName).font(.system(size: 13))
                if count > 0 {
                    Text("\(count)").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ContentTypeFilter Enum

enum ContentTypeFilter: CaseIterable {
    case all, text, code, url, image, color, file

    var displayName: LocalizedStringKey {
        switch self {
        case .all:   return "전체"
        case .text:  return "텍스트"
        case .code:  return "코드"
        case .url:   return "URL"
        case .image: return "이미지"
        case .color: return "컬러"
        case .file:  return "파일"
        }
    }

    var systemImage: String {
        switch self {
        case .all:   return "tray.full"
        case .text:  return "doc.text"
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .url:   return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file:  return "doc"
        }
    }

    var contentType: ContentType? {
        switch self {
        case .all:   return nil
        case .text:  return .text
        case .code:  return .code
        case .url:   return .url
        case .image: return .image
        case .color: return .color
        case .file:  return .file
        }
    }
}
