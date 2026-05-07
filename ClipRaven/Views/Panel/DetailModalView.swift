import SwiftUI
import ClipRavenSync

struct DetailModalView: View {
    let clip: Clip
    var onDismiss: () -> Void = {}
    @State private var editedText: String = ""
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: clip.contentType.systemImage)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(typeColor(clip.contentType)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.nickname?.isEmpty == false ? clip.nickname! : clip.contentType.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(clip.lastCopiedAt.relativeString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if clip.contentType == .text || clip.contentType == .code {
                    Button(action: { isEditing.toggle() }) {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                            .font(.system(size: 18))
                            .foregroundColor(isEditing ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Content area
            Group {
                switch clip.contentType {
                case .image:
                    imageContent
                case .color:
                    colorContent
                default:
                    textContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            HStack(spacing: 16) {
                Button {
                    if let text = clip.contentText {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        // 우리가 직접 쓴 거 — ClipboardMonitor가 echo-back
                        // 으로 잡지 않게 알림.
                        NotificationCenter.default.post(
                            name: .clipRavenIntentionalPasteboardWrite,
                            object: nil
                        )
                    }
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                if let appName = clip.sourceAppName, !appName.isEmpty {
                    Label(appName, systemImage: "app.badge")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(formatDate(clip.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.clear)
        .onAppear {
            editedText = clip.contentText ?? ""
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if isEditing {
            WritableTextView(
                text: $editedText,
                font: clip.contentType == .code
                    ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                    : NSFont.systemFont(ofSize: 13)
            )
            .padding(16)
        } else {
            ScrollView {
                Text(clip.contentText ?? "")
                    .font(clip.contentType == .code
                          ? .system(size: 13, design: .monospaced)
                          : .system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let path = clip.imagePath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(16)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.3))
        }
    }

    @ViewBuilder
    private var colorContent: some View {
        if let hex = clip.contentText {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: hex) ?? .gray)
                    .frame(width: 120, height: 120)
                    .shadow(radius: 8)
                Text(hex)
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func typeColor(_ type: ContentType) -> Color {
        switch type {
        case .text:  return .blue
        case .code:  return .green
        case .url:   return .purple
        case .image: return .orange
        case .color: return .pink
        case .file:  return .gray
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd HH:mm"
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }
}
