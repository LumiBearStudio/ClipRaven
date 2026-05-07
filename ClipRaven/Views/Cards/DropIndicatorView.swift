import SwiftUI

/// Thin vertical indicator shown between cards during drag-and-drop reordering.
struct DropIndicatorView: View {
    var isPinZone: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            // Top circle
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            // Vertical line
            RoundedRectangle(cornerRadius: 2)
                .fill(indicatorColor)
                .frame(width: 3)

            // Bottom circle
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
        }
        .frame(width: 12, height: 220)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.15), value: isPinZone)
    }

    private var indicatorColor: Color {
        isPinZone ? .orange : .accentColor
    }
}
