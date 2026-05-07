import SwiftUI
import ClipRavenSync

struct SearchResultRow: View {
    let clip: Clip
    let snippet: String

    var body: some View {
        HStack(spacing: 10) {
            // Type icon
            Image(systemName: clip.contentType.systemImage)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                // Snippet or content preview
                if !snippet.isEmpty {
                    Text(attributedSnippet)
                        .font(.system(size: 12))
                        .lineLimit(2)
                } else {
                    Text(clip.contentText ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }

                // Source info
                HStack(spacing: 4) {
                    if let appName = clip.sourceAppName {
                        Text(appName)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Text("·")
                        .foregroundColor(.secondary)

                    Text(clip.lastCopiedAt.relativeString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var attributedSnippet: AttributedString {
        // Parse <mark> tags from FTS5 snippet
        let result = AttributedString(
            snippet.replacingOccurrences(of: "<mark>", with: "")
                   .replacingOccurrences(of: "</mark>", with: "")
        )
        // Simple approach - full highlight support can be added later
        return result
    }
}
