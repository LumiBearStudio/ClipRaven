import SwiftUI
import ClipRavenSync

struct SearchInputView: View {
    @Binding var query: String
    @Binding var selectedFilter: ContentType?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))

                TextField("검색어를 입력하세요 (초성 검색 지원)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)

                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Filter chips
            HStack(spacing: 6) {
                filterChip("전체", filter: nil)
                filterChip("텍스트", filter: .text)
                filterChip("코드", filter: .code)
                filterChip("URL", filter: .url)
                filterChip("이미지", filter: .image)
                filterChip("컬러", filter: .color)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear { isFocused = true }
    }

    private func filterChip(_ label: String, filter: ContentType?) -> some View {
        Button(action: { selectedFilter = filter }) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selectedFilter == filter ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundColor(selectedFilter == filter ? .accentColor : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
