import SwiftUI
import ClipRavenSync

/// 소스 앱별 필터 + 날짜 범위 필터 행.
/// FilterChipRow(ContentType) 아래에 위치.
/// 앱 목록이 없거나 날짜 필터 없으면 숨김.
struct SecondaryFilterRow: View {

    let sourceApps: [String]
    @Binding var selectedSourceApp: String?
    @Binding var selectedDateRange: DateRangeFilter?

    @Environment(\.colorScheme) private var colorScheme

    private var hasContent: Bool {
        !sourceApps.isEmpty || selectedSourceApp != nil || selectedDateRange != nil
    }

    var body: some View {
        if hasContent || !sourceApps.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 날짜 범위 칩
                    ForEach(DateRangeFilter.allCases) { range in
                        SecondaryChip(
                            icon: range.icon,
                            label: range.displayName,
                            isSelected: selectedDateRange == range,
                            accentColor: .purple
                        ) {
                            AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                selectedDateRange = selectedDateRange == range ? nil : range
                            }
                        }
                    }

                    if !sourceApps.isEmpty {
                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 2)

                        // 소스 앱 칩
                        ForEach(sourceApps, id: \.self) { app in
                            SecondaryChip(
                                icon: appIcon(for: app),
                                label: app,
                                isSelected: selectedSourceApp == app,
                                accentColor: appColor(for: app)
                            ) {
                                AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    selectedSourceApp = selectedSourceApp == app ? nil : app
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
            }
        }
    }

    private func appIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("safari") || lower.contains("browser") { return "safari" }
        if lower.contains("xcode") || lower.contains("code") { return "hammer" }
        if lower.contains("note") { return "note.text" }
        if lower.contains("message") || lower.contains("slack") || lower.contains("telegram") { return "message" }
        if lower.contains("mail") { return "envelope" }
        if lower.contains("terminal") { return "terminal" }
        if lower.contains("photo") || lower.contains("camera") { return "photo" }
        if lower.contains("finder") { return "folder" }
        return "app"
    }

    private func appColor(for name: String) -> Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.75)
    }
}

private struct SecondaryChip: View {
    let icon: String
    let label: String  // already-localized String OR dynamic app name (verbatim ok)
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected
                          ? accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
                          : Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 8) {
        SecondaryFilterRow(
            sourceApps: ["Safari", "Xcode", "Notes", "Terminal"],
            selectedSourceApp: .constant("Xcode"),
            selectedDateRange: .constant(.today)
        )
        SecondaryFilterRow(
            sourceApps: [],
            selectedSourceApp: .constant(nil),
            selectedDateRange: .constant(nil)
        )
    }
    .background(Color(.systemGroupedBackground))
}
