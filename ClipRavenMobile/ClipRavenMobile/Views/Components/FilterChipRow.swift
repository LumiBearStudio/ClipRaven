import SwiftUI
import ClipRavenSync

/// 콘텐츠 타입 필터 칩 행 — Mac FilterBarView 상단 필터 버튼 열의 iOS 이식.
/// "전체" + 각 ContentType 칩을 가로 스크롤로 표시.
/// 각 칩에 해당 타입의 클립 수를 배지로 표시 (0이면 숨김).
struct FilterChipRow: View {

    @Binding var selected: ContentType?
    let counts: [ContentType?: Int]

    private let allTypes: [ContentType?] = [nil] + ContentType.allCases.filter { $0 != .color }.map { Optional($0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allTypes, id: \.self) { type in
                    FilterChip(
                        type: type,
                        count: counts[type] ?? 0,
                        isSelected: selected == type
                    ) {
                        AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            selected = type
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

private struct FilterChip: View {

    let type: ContentType?
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var label: String {
        type?.displayName ?? String(localized: "전체")
    }

    private var icon: String {
        type?.systemImage ?? "square.grid.2x2"
    }

    private var accentColor: Color {
        type?.themeColor ?? .primary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))

                Text(label)
                    .font(.system(size: 13, weight: .medium))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? accentColor : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected
                                      ? accentColor.opacity(0.15)
                                      : Color.primary.opacity(0.06))
                        )
                }
            }
            .foregroundStyle(isSelected ? accentColor : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected
                          ? accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
                          : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? accentColor.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 16) {
        FilterChipRow(
            selected: .constant(nil),
            counts: [nil: 95, .text: 42, .code: 8, .url: 20, .image: 15, .color: 5, .file: 5]
        )
        FilterChipRow(
            selected: .constant(.text),
            counts: [nil: 95, .text: 42, .code: 8, .url: 20, .image: 15, .color: 5, .file: 5]
        )
    }
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}
