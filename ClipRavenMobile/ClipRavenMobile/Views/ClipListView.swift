import SwiftUI
import ClipRavenSync

struct ClipListView: View {

    @StateObject private var viewModel = ClipListViewModel()
    @State private var showAddSheet = false
    @State private var showSettings = false
    @State private var selectedClip: Clip?
    @State private var copyToast = false
    /// 키보드 익스텐션의 deep link `clipraven://search` 또는 위젯 등 다른
    /// 진입점에서 검색 모드를 강제 활성화할 때 사용. iOS 17+ `.searchable`
    /// 의 `isPresented` binding 으로 search bar 자동 표시 + focus.
    @State private var isSearchPresented = false

    @Environment(\.horizontalSizeClass) private var hSize

    // iPad inspector 표시 여부 — selectedClip과 연동.
    private var isInspectorPresented: Binding<Bool> {
        Binding(
            get: { selectedClip != nil },
            set: { if !$0 { selectedClip = nil } }
        )
    }

    // 그리드 컬럼 수. iPad Regular에서는 더 넓은 그리드 사용.
    private var columns: [GridItem] {
        let count: Int
        if hSize == .compact {
            count = 2
        } else if UIScreen.main.bounds.width > 1100 {
            count = 5
        } else {
            count = 4
        }
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    private var pinned: [Clip] { viewModel.clips.filter { $0.isPinned } }
    private var unpinned: [Clip] { viewModel.clips.filter { !$0.isPinned } }

    var body: some View {
        if hSize == .regular {
            iPadLayout
        } else {
            iPhoneLayout
        }
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        NavigationStack {
            gridContent
                .navigationTitle("ClipRaven")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .refreshable { await viewModel.refreshAwaiting() }
                .overlay(alignment: .bottom) { errorBanner }
                .background(Color(.systemGroupedBackground))
        }
        .overlay(alignment: .top) { copyToastBanner }
        .searchable(
            text: $viewModel.searchQuery,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "클립 검색"
        )
        .onSubmit(of: .search) { }
        .onReceive(NotificationCenter.default.publisher(for: .clipRavenOpenSearch)) { _ in
            // 키보드 익스텐션 검색 deep link → search bar 자동 활성화 + focus
            isSearchPresented = true
        }
        .sheet(isPresented: $showAddSheet) {
            AddClipView { text, nickname in
                Task { await viewModel.addTextClip(text: text, nickname: nickname) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $selectedClip) { clip in
            ClipDetailView(clip: clip)
        }
        .task { viewModel.refresh() }
        .onChange(of: viewModel.errorMessage) { _, _ in scheduleErrorDismiss() }
        .background(keyboardShortcutsLayer)
    }

    // MARK: - iPad Layout

    private var iPadLayout: some View {
        NavigationSplitView {
            IPadSidebarView(viewModel: viewModel)
        } detail: {
            NavigationStack {
                gridContent
                    .navigationTitle("ClipRaven")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbarContent }
                    .refreshable { await viewModel.refreshAwaiting() }
                    .overlay(alignment: .bottom) { errorBanner }
                    .background(Color(.systemGroupedBackground))
            }
            .inspector(isPresented: isInspectorPresented) {
                IPadInspectorView(clip: selectedClip, onDismiss: { selectedClip = nil })
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
            }
            .overlay(alignment: .top) { copyToastBanner }
        }
        .searchable(
            text: $viewModel.searchQuery,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "클립 검색"
        )
        .onSubmit(of: .search) { }
        .onReceive(NotificationCenter.default.publisher(for: .clipRavenOpenSearch)) { _ in
            isSearchPresented = true
        }
        .sheet(isPresented: $showAddSheet) {
            AddClipView { text, nickname in
                Task { await viewModel.addTextClip(text: text, nickname: nickname) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { viewModel.refresh() }
        .onChange(of: viewModel.errorMessage) { _, _ in scheduleErrorDismiss() }
        .background(keyboardShortcutsLayer)
    }

    private func scheduleErrorDismiss() {
        guard viewModel.errorMessage != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            viewModel.clearError()
        }
    }

    // MARK: - Copy with feedback

    private func copyWithFeedback(_ clip: Clip) {
        ClipboardWriter.write(clip: clip)
        viewModel.bumpCopyCount(clip)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard !copyToast else { return }
        AppAnimations.withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copyToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { copyToast = false }
        }
    }

    // MARK: - Grid content

    @ViewBuilder
    private var gridContent: some View {
        if viewModel.isLoading && viewModel.clips.isEmpty {
            loadingState
        } else if viewModel.clips.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {

                    // 핀 스트립 (검색/필터 없을 때만 표시)
                    if !pinned.isEmpty && viewModel.searchQuery.isEmpty && viewModel.selectedTagIds.isEmpty {
                        PinnedStrip(
                            clips: pinned,
                            onCopy: { copyWithFeedback($0) },
                            onPreview: { selectedClip = $0 },
                            onTogglePin: { clip in Task { await viewModel.togglePin(clip) } },
                            onDelete: { clip in Task { await viewModel.deleteClip(clip) } }
                        )
                        .background(Color(.systemGroupedBackground))
                    }

                    // 콘텐츠 타입 필터 칩 (검색 중 숨김)
                    if viewModel.searchQuery.isEmpty {
                        FilterChipRow(
                            selected: $viewModel.selectedFilter,
                            counts: viewModel.filterCounts
                        )
                        .padding(.top, pinned.isEmpty ? 8 : 0)
                    }

                    // 날짜 + 소스 앱 + AI 카테고리 → 상단 toolbar 메뉴 (ClipFilterMenu)
                    // chip row 에서 제거해 화면 공간 확보 + 자주 쓰는 필터만 남김.

                    // 태그 필터 행
                    if !viewModel.tags.isEmpty {
                        TagFilterRow(
                            tags: viewModel.tags,
                            selectedTagIds: $viewModel.selectedTagIds,
                            onCreateTag: { name, hex in await viewModel.createTag(name: name, colorHex: hex) },
                            onDeleteTag: { id in await viewModel.deleteTag(id: id) }
                        )
                    } else if viewModel.searchQuery.isEmpty {
                        TagFilterRow(
                            tags: [],
                            selectedTagIds: $viewModel.selectedTagIds,
                            onCreateTag: { name, hex in await viewModel.createTag(name: name, colorHex: hex) },
                            onDeleteTag: { _ in }
                        )
                    }

                    // 섹션 헤더
                    sectionHeader(
                        title: sectionTitle,
                        count: unpinned.count
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    // 카드 그리드
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(unpinned) { clip in
                            cardButton(clip: clip)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var sectionTitle: String {
        if !viewModel.searchQuery.isEmpty { return String(localized: "검색 결과") }
        if viewModel.selectedFilter != nil || !viewModel.selectedTagIds.isEmpty
            || viewModel.selectedSourceApp != nil || viewModel.selectedDateRange != nil {
            return String(localized: "필터 결과")
        }
        return String(localized: "전체 클립")
    }

    private var hasActiveFilter: Bool {
        viewModel.selectedFilter != nil
        || !viewModel.selectedTagIds.isEmpty
        || viewModel.selectedSourceApp != nil
        || viewModel.selectedDateRange != nil
    }

    // MARK: - Card button
    // 탭 = 클립보드 복사. 미리보기는 context menu에서만.

    private func cardButton(clip: Clip) -> some View {
        Button { copyWithFeedback(clip) } label: { ClipCard(clip: clip) }
            .buttonStyle(.plain)
            .onDrag {
                // 이미지는 UIImage provider, 나머지는 plain-text.
                // NSItemProvider를 통해 Safari, Notes, Mail 등 표준 앱의
                // 텍스트 필드에 드래그 & 드롭으로 직접 삽입 가능.
                if clip.contentType == .image,
                   let data = clip.thumbnail,
                   let image = UIImage(data: data) {
                    return NSItemProvider(object: image)
                }
                return NSItemProvider(object: (clip.contentText ?? "") as NSString)
            }
            .contextMenu {
                Button { selectedClip = clip } label: {
                    Label("미리보기", systemImage: "eye")
                }
                Button { copyWithFeedback(clip) } label: {
                    Label("클립보드에 복사", systemImage: "doc.on.doc")
                }
                .disabled(clip.contentText == nil && clip.thumbnail == nil)

                if let shareItem = shareItem(for: clip) {
                    ShareLink(item: shareItem) {
                        Label("공유", systemImage: "square.and.arrow.up")
                    }
                }

                Button {
                    Task { await viewModel.togglePin(clip) }
                } label: {
                    Label(clip.isPinned ? "핀 해제" : "핀 고정",
                          systemImage: clip.isPinned ? "pin.slash" : "pin")
                }

                Divider()

                Button {
                    Task { await viewModel.toggleExcludeFromSync(clip) }
                } label: {
                    Label(
                        clip.excludeFromSync ? "동기화 포함" : "동기화 제외",
                        systemImage: clip.excludeFromSync ? "icloud" : "icloud.slash"
                    )
                }

                Button(role: .destructive) {
                    Task { await viewModel.deleteClip(clip) }
                } label: {
                    Label("삭제", systemImage: "trash")
                }
            }
    }

    // MARK: - Share helpers

    private func shareItem(for clip: Clip) -> String? {
        if let text = clip.contentText, !text.isEmpty { return text }
        return nil
    }

    // MARK: - Section header

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()

            if hasActiveFilter {
                Button {
                    withAnimation {
                        viewModel.selectedFilter = nil
                        viewModel.selectedTagIds = []
                        viewModel.selectedSourceApp = nil
                        viewModel.selectedDateRange = nil
                    }
                } label: {
                    Text("필터 초기화")
                        .font(.system(size: 12))
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showSettings = true } label: {
                Image(systemName: "gear")
            }
            // ⌘, — iPadOS / Mac 표준 settings 단축키. 하드웨어 키보드
            // 사용자에게 자연스러움. iPhone 에선 키보드 없으면 no-op.
            .keyboardShortcut(",", modifiers: .command)
        }
        // 필터 메뉴 — 키보드 익스텐션과 동일 옵션 (콘텐츠/날짜/AI/소스앱/태그)
        ToolbarItem(placement: .topBarLeading) {
            ClipFilterMenu(viewModel: viewModel)
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text("ClipRaven")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(viewModel.clips.count)개")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showAddSheet = true } label: {
                Image(systemName: "plus")
            }
            // ⌘N — 신규 클립 추가
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    /// 보이지 않는 키보드 단축키 핸들러들. iPad/하드웨어 키보드 사용자
    /// 대상. iPhone 에선 자동 no-op (키보드 없으면 발화 X).
    ///
    /// - ⌘F: 검색 활성화
    /// - ⌘1...⌘9: 인덱스 위치 클립을 클립보드에 복사 (Mac 의 ⌥1-9 패턴 차용)
    @ViewBuilder
    private var keyboardShortcutsLayer: some View {
        // ⌘F — 검색 바 활성화
        Button("Search") { isSearchPresented = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)

        // ⌘1...⌘9 — 인덱스 위치 클립 복사
        // ForEach 직접 안 되니 명시적으로 9개 버튼 생성
        Group {
            quickCopyButton(index: 0, key: "1")
            quickCopyButton(index: 1, key: "2")
            quickCopyButton(index: 2, key: "3")
            quickCopyButton(index: 3, key: "4")
            quickCopyButton(index: 4, key: "5")
            quickCopyButton(index: 5, key: "6")
            quickCopyButton(index: 6, key: "7")
            quickCopyButton(index: 7, key: "8")
            quickCopyButton(index: 8, key: "9")
        }
    }

    private func quickCopyButton(index: Int, key: KeyEquivalent) -> some View {
        Button("Copy \(index + 1)") {
            guard index < viewModel.clips.count else { return }
            copyWithFeedback(viewModel.clips[index])
        }
        .keyboardShortcut(key, modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("클립 불러오는 중…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if hasActiveFilter || !viewModel.searchQuery.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 6) {
                    Text("결과 없음")
                        .font(.headline)
                    Text("다른 검색어나 필터를 시도해 보세요")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    viewModel.selectedFilter = nil
                    viewModel.selectedTagIds = []
                    viewModel.selectedSourceApp = nil
                    viewModel.selectedDateRange = nil
                    viewModel.searchQuery = ""
                } label: {
                    Text("필터 초기화")
                }
                .buttonStyle(.bordered)

            } else {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 6) {
                    Text("아직 클립이 없습니다")
                        .font(.headline)
                    Text("Mac ClipRaven에서 복사하면\n자동으로 동기화됩니다")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button { showSettings = true } label: {
                    Label("iCloud 동기화 설정", systemImage: "icloud")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Banners

    @ViewBuilder
    private var errorBanner: some View {
        if let message = viewModel.errorMessage {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var copyToastBanner: some View {
        if copyToast {
            Label("클립보드에 복사됨", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(red: 0.12, green: 0.58, blue: 0.22), in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}


// MARK: - Filter menu (toolbar 용)

/// iPhone navigation toolbar 의 고급 필터 메뉴.
///
/// 콘텐츠 타입 / 태그 는 chip row (FilterChipRow / TagFilterRow) 에서 처리.
/// 여기엔 자주 안 쓰지만 필요한 **날짜 / AI 카테고리 / 소스 앱** 3개만.
struct ClipFilterMenu: View {
    @ObservedObject var viewModel: ClipListViewModel

    var body: some View {
        Menu {
            // ① 날짜 (submenu)
            Menu {
                Button {
                    viewModel.selectedDateRange = nil
                } label: {
                    Label("전체 기간", systemImage: viewModel.selectedDateRange == nil ? "checkmark" : "calendar")
                }
                ForEach(DateRangeFilter.allCases) { range in
                    Button {
                        viewModel.selectedDateRange = range
                    } label: {
                        Label(range.displayName,
                              systemImage: viewModel.selectedDateRange == range ? "checkmark" : range.icon)
                    }
                }
            } label: {
                let title = viewModel.selectedDateRange.map { "📅 \($0.displayName)" } ?? String(localized: "날짜")
                Label(title, systemImage: "calendar")
            }

            // ④ AI 카테고리 (submenu)
            Menu {
                Button {
                    viewModel.selectedAICategory = nil
                } label: {
                    Label("전체", systemImage: viewModel.selectedAICategory == nil ? "checkmark" : "sparkles")
                }
                ForEach(IPadSidebarView.aiCategoryOptions, id: \.0) { (key, label, icon) in
                    Button {
                        viewModel.selectedAICategory = key
                    } label: {
                        Label(String(localized: String.LocalizationValue(label)),
                              systemImage: viewModel.selectedAICategory == key ? "checkmark" : icon)
                    }
                }
            } label: {
                let rawLabel: String? = IPadSidebarView.aiCategoryOptions
                    .first(where: { $0.0 == viewModel.selectedAICategory })?.1
                let activeLabel: String? = rawLabel.map { String(localized: String.LocalizationValue($0)) }
                let title = activeLabel.map { "🤖 \($0)" } ?? String(localized: "AI 카테고리")
                Label(title, systemImage: "sparkles")
            }

            // ⑤ 소스 앱 (submenu)
            if !viewModel.availableSourceApps.isEmpty {
                Menu {
                    Button {
                        viewModel.selectedSourceApp = nil
                    } label: {
                        Label("전체", systemImage: viewModel.selectedSourceApp == nil ? "checkmark" : "app")
                    }
                    ForEach(viewModel.availableSourceApps, id: \.self) { app in
                        Button {
                            viewModel.selectedSourceApp = app
                        } label: {
                            Label(app, systemImage: viewModel.selectedSourceApp == app ? "checkmark" : "app")
                        }
                    }
                } label: {
                    let title = viewModel.selectedSourceApp.map { "📱 \($0)" } ?? String(localized: "소스 앱")
                    Label(title, systemImage: "iphone.gen2")
                }
            }
        } label: {
            // 활성 필터 있으면 indigo, 없으면 회색
            Image(systemName: "line.3.horizontal.decrease.circle\(isAnyActive ? ".fill" : "")")
                .foregroundStyle(isAnyActive ? Color.indigo : Color.primary)
        }
    }

    private var isAnyActive: Bool {
        viewModel.selectedDateRange != nil
            || viewModel.selectedAICategory != nil
            || viewModel.selectedSourceApp != nil
    }
}


// MARK: - Clipboard write helper

enum ClipboardWriter {
    @MainActor
    static func write(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        NotificationCenter.default.post(name: .clipRavenIntentionalPasteboardWrite, object: nil)
    }

    /// 이미지를 클립보드에 — `UIPasteboard.image`가 표준 UTI(PNG/JPEG)를
    /// 자동 등록해 사진/메모/메일 등 어디든 이미지로 paste 된다.
    @MainActor
    static func write(image: UIImage) {
        UIPasteboard.general.image = image
        NotificationCenter.default.post(name: .clipRavenIntentionalPasteboardWrite, object: nil)
    }

    /// Clip 컨텐츠 타입에 맞는 형태로 클립보드에 쓴다.
    ///
    /// - `.image` 클립 우선순위:
    ///   1. `imagePath` (Phase C — 원본이 디스크에 저장된 경우) → 원본 해상도
    ///   2. `thumbnail` (~200×200 JPEG, fallback) → 썸네일 해상도
    /// - 그 외(.text/.url/.code/.color/.file): `contentText` 텍스트 paste.
    ///   `.file`은 macOS Finder에서 복사한 파일 경로가 그대로 들어 있어
    ///   path 텍스트가 paste된다. iOS에선 원본 파일을 가져올 수 없으므로
    ///   path만 전달하는 게 현재로선 최선이다.
    @MainActor
    static func write(clip: Clip) {
        if clip.contentType == .image {
            // 1순위: imagePath 의 원본 (Phase C 우선)
            if let relPath = clip.imagePath,
               let image = ImageStorageService.loadUIImage(relativePath: relPath)
            {
                write(image: image)
                return
            }
            // 2순위: thumbnail
            if let data = clip.thumbnail, let image = UIImage(data: data) {
                write(image: image)
                return
            }
            // 둘 다 없는 비정상 상태 — 텍스트 fallback
        }
        write(clip.contentText)
    }
}

extension Notification.Name {
    static let clipRavenIntentionalPasteboardWrite = Notification.Name("clipRavenIntentionalPasteboardWrite")
}

#Preview {
    ClipListView()
}
