import SwiftUI
import ClipRavenSync

struct TopBarView: View {
    let clipCount: Int
    var onSearchTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 16))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor)
                )

            // ClipRaven title
            Text("ClipRaven")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            // Clip count badge
            Text("\(clipCount)개")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())

            Spacer()

            // Search button
            Button(action: onSearchTap) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                    Text("검색")
                        .font(.system(size: 14))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("/", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
