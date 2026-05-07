import SwiftUI
import ClipRavenSync

struct PreviewContentView: View {
    let clip: Clip

    var body: some View {
        ScrollView {
            Group {
                switch clip.contentType {
                case .text:
                    Text(clip.contentText ?? "")
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .code:
                    CodePreviewView(code: clip.contentText ?? "")

                case .url:
                    VStack(alignment: .leading, spacing: 10) {
                        // OG 썸네일
                        if let data = clip.thumbnail,
                           let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        // OG 타이틀
                        if let title = clip.ogTitle {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(3)
                        }

                        // URL 링크
                        Link(destination: URL(string: clip.contentText ?? "") ?? URL(string: "about:blank")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.system(size: 10))
                                Text(clip.contentText ?? "")
                                    .lineLimit(2)
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                case .image:
                    if let thumbnailData = clip.thumbnail,
                       let nsImage = NSImage(data: thumbnailData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if let imagePath = clip.imagePath {
                        Text(imagePath)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                case .color:
                    VStack(spacing: 8) {
                        if let color = Color(hex: clip.contentText ?? "") {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(color)
                                .frame(height: 80)
                        }

                        Text(clip.contentText ?? "")
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)

                case .file:
                    VStack(alignment: .leading, spacing: 8) {
                        if let path = clip.contentText {
                            let url = URL(fileURLWithPath: path)
                            HStack(spacing: 10) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(2)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Code Preview (syntax highlighted, full content)

private struct CodePreviewView: View {
    let code: String
    @Environment(\.colorScheme) var colorScheme
    @State private var highlighted: AttributedString?

    var body: some View {
        Group {
            if let highlighted {
                Text(highlighted)
                    .textSelection(.enabled)
            } else {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: code) {
            let isDark = colorScheme == .dark
            highlighted = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlightFull(code, isDark: isDark)
            }.value
        }
        .onChange(of: colorScheme) { _ in
            highlighted = SyntaxHighlighter.highlightFull(code, isDark: colorScheme == .dark)
        }
    }
}
