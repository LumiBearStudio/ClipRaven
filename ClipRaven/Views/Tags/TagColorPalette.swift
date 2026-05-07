import SwiftUI

enum TagColor: String, CaseIterable {
    case red, orange, yellow, green, mint, blue, purple, pink, brown, gray, indigo, teal

    var hex: String {
        switch self {
        case .red: return "FF3B30"
        case .orange: return "FF9500"
        case .yellow: return "FFCC00"
        case .green: return "34C759"
        case .mint: return "00C7BE"
        case .blue: return "007AFF"
        case .purple: return "AF52DE"
        case .pink: return "FF2D55"
        case .brown: return "A2845E"
        case .gray: return "8E8E93"
        case .indigo: return "5856D6"
        case .teal: return "5AC8FA"
        }
    }

    var color: Color {
        Color(hex: hex) ?? .gray
    }
}

struct TagColorPalette: View {
    @Binding var selectedColor: TagColor

    private let columns = Array(repeating: GridItem(.fixed(20), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(TagColor.allCases, id: \.self) { tagColor in
                Circle()
                    .fill(tagColor.color)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle()
                            .stroke(Color.primary, lineWidth: selectedColor == tagColor ? 2 : 0)
                            .padding(1)
                    )
                    .onTapGesture {
                        selectedColor = tagColor
                    }
            }
        }
    }
}
