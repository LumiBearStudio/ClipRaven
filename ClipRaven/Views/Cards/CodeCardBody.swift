import SwiftUI

struct CodeCardBody: View {
    let text: String
    @Environment(\.colorScheme) var colorScheme
    @State private var highlighted: AttributedString?

    var body: some View {
        Group {
            if let highlighted {
                Text(highlighted)
            } else {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : Color(NSColor.labelColor))
            }
        }
        .lineLimit(12)
        .multilineTextAlignment(.leading)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.8)
            : Color(NSColor.textBackgroundColor).opacity(0.9))
        .task(id: text) {
            highlighted = SyntaxHighlighter.highlight(text, isDark: colorScheme == .dark)
        }
        .onChange(of: colorScheme) { _ in
            highlighted = SyntaxHighlighter.highlight(text, isDark: colorScheme == .dark)
        }
    }
}
