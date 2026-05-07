import SwiftUI

struct TextCardBody: View {
    let text: String
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(colorScheme == .dark ? .white.opacity(0.85) : Color(NSColor.labelColor))
            .lineLimit(10)
            .multilineTextAlignment(.leading)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
