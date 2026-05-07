import SwiftUI
import ClipRavenSync

/// iPad NavigationSplitView 왼쪽 사이드바.
/// 아이폰의 FilterChipRow / SecondaryFilterRow / TagFilterRow(가로 스크롤)를
/// 세로 List(.sidebar)로 재배치. 동일한 ViewModel 바인딩을 공유한다.
struct IPadSidebarView: View {

    @ObservedObject var viewModel: ClipListViewModel
    @State private var showCreateTag = false

    var body: some View {
        List {
            // MARK: 콘텐츠 타입
            Section("타입") {
                typeRow(type: nil, icon: "square.grid.2x2", label: String(localized: "전체"))
                ForEach(ContentType.allCases.filter { $0 != .color }, id: \.self) { type in
                    typeRow(type: type, icon: type.systemImage, label: type.displayName)
                }
            }

            // MARK: 날짜
            Section("날짜") {
                ForEach(DateRangeFilter.allCases) { range in
                    dateRow(range: range)
                }
            }

            // MARK: 소스 앱
            if !viewModel.availableSourceApps.isEmpty {
                Section("소스 앱") {
                    ForEach(viewModel.availableSourceApps, id: \.self) { app in
                        appRow(app: app)
                    }
                }
            }

            // MARK: AI 카테고리 (Mac Foundation Models 가 분류한 카테고리)
            // iOS 단독 사용자는 sync 받은 클립만 카테고리 가짐.
            Section("AI 카테고리") {
                aiCategoryRow(category: nil, label: String(localized: "전체"), icon: "sparkles")
                ForEach(IPadSidebarView.aiCategoryOptions, id: \.0) { (key, label, icon) in
                    aiCategoryRow(category: key, label: String(localized: String.LocalizationValue(label)), icon: icon)
                }
            }

            // MARK: 태그
            Section {
                ForEach(viewModel.tags) { tag in
                    tagRow(tag: tag)
                }
                Button {
                    showCreateTag = true
                } label: {
                    Label("태그 추가", systemImage: "plus.circle")
                        .foregroundStyle(.tint)
                }
            } header: {
                Text("태그")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ClipRaven")
        .sheet(isPresented: $showCreateTag) {
            CreateTagSheet { name, hex in
                await viewModel.createTag(name: name, colorHex: hex)
            }
        }
    }

    // MARK: - Row builders

    private func typeRow(type: ContentType?, icon: String, label: String) -> some View {
        let count = viewModel.filterCounts[type] ?? 0
        let isSelected = viewModel.selectedFilter == type

        return Button {
            AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                viewModel.selectedFilter = type
            }
        } label: {
            HStack {
                Label(label, systemImage: icon)
                    .foregroundStyle(isSelected ? type?.themeColor ?? .primary : .primary)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(isSelected ? (type?.themeColor ?? Color.accentColor).opacity(0.1) : nil)
        .buttonStyle(.plain)
    }

    private func dateRow(range: DateRangeFilter) -> some View {
        let isSelected = viewModel.selectedDateRange == range
        return Button {
            AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                viewModel.selectedDateRange = viewModel.selectedDateRange == range ? nil : range
            }
        } label: {
            Label(range.displayName, systemImage: range.icon)
                .foregroundStyle(isSelected ? Color.purple : .primary)
        }
        .listRowBackground(isSelected ? Color.purple.opacity(0.1) : nil)
        .buttonStyle(.plain)
    }

    /// AI 카테고리 옵션 정의 — Mac Foundation Models 의 카테고리 raw value 와 매핑.
    static let aiCategoryOptions: [(String, String, String)] = [
        ("receipt", "영수증", "receipt"),
        ("meeting", "회의", "person.2"),
        ("code", "코드", "chevron.left.forwardslash.chevron.right"),
        ("phone", "전화", "phone"),
        ("email", "이메일", "envelope"),
        ("address", "주소", "mappin"),
        ("link", "링크", "link"),
        ("other", "기타", "questionmark.circle"),
    ]

    private func aiCategoryRow(category: String?, label: String, icon: String) -> some View {
        let isSelected = viewModel.selectedAICategory == category
        return Button {
            AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                // 같은 카테고리 다시 누르면 해제 (toggle)
                if viewModel.selectedAICategory == category {
                    viewModel.selectedAICategory = nil
                } else {
                    viewModel.selectedAICategory = category
                }
            }
        } label: {
            Label(label, systemImage: icon)
                .foregroundStyle(isSelected ? Color.indigo : .primary)
        }
        .listRowBackground(isSelected ? Color.indigo.opacity(0.1) : nil)
        .buttonStyle(.plain)
    }

    private func appRow(app: String) -> some View {
        let isSelected = viewModel.selectedSourceApp == app
        let hue = Double(abs(app.hashValue) % 360) / 360.0
        let color = Color(hue: hue, saturation: 0.6, brightness: 0.75)

        return Button {
            AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                viewModel.selectedSourceApp = viewModel.selectedSourceApp == app ? nil : app
            }
        } label: {
            Label(app, systemImage: "app")
                .foregroundStyle(isSelected ? color : .primary)
        }
        .listRowBackground(isSelected ? color.opacity(0.1) : nil)
        .buttonStyle(.plain)
    }

    private func tagRow(tag: Tag) -> some View {
        let id = tag.id ?? -1
        let isSelected = viewModel.selectedTagIds.contains(id)
        let color = Color(hex: tag.colorHex) ?? .accentColor

        return Button {
            AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                // 사이드바 단일 선택 — 한 번에 하나의 태그만 활성.
                // (칩 row 는 다중 선택 가능, 사이드바는 단일이라 일관성 유지)
                if isSelected {
                    viewModel.selectedTagIds.remove(id)
                } else {
                    viewModel.selectedTagIds = [id]
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(tag.name)
                    .foregroundStyle(isSelected ? color : .primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
        }
        .listRowBackground(isSelected ? color.opacity(0.1) : nil)
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await viewModel.deleteTag(id: id) }
            } label: {
                Label("태그 삭제", systemImage: "trash")
            }
        }
    }
}

// MARK: - Create Tag Sheet

private struct CreateTagSheet: View {
    let onCreate: (String, String) async -> Void
    @State private var name = ""
    @State private var colorHex = "4A90E2"
    @Environment(\.dismiss) private var dismiss

    private let presetColors = [
        "4A90E2", "E2574A", "50C878", "F5A623",
        "9B59B6", "1ABC9C", "E74C3C", "3498DB",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("태그 이름") {
                    TextField("예: 업무, 개인, 코드", text: $name)
                }
                Section("색상") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(presetColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().strokeBorder(
                                        colorHex == hex ? Color.primary : Color.clear,
                                        lineWidth: 2
                                    )
                                )
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("태그 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("추가") {
                        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        Task {
                            await onCreate(name, colorHex)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Color hex helper (sidebar-local)

private extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8)  & 0xFF) / 255,
            blue:  Double(v         & 0xFF) / 255
        )
    }
}
