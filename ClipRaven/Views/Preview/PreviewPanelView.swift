import SwiftUI
import ClipRavenSync

struct PreviewPanelView: View {
    let clip: Clip?
    @State private var isEditing = false
    @State private var nicknameText: String = ""
    @State private var isEditingNickname = false
    @State private var showTTLPicker = false
    @State private var aiSummary: String? = nil
    @State private var isSummarizing = false
    var onDismiss: () -> Void = {}
    var onUpdate: (Clip) -> Void = { _ in }
    var onNicknameChanged: (Clip, String?) -> Void = { _, _ in }

    var body: some View {
        if let clip {
            VStack(spacing: 0) {
                // Header
                previewHeader(clip)

                // Nickname field
                nicknameField(clip)

                Divider()

                // Content
                if isEditing {
                    EditorView(clip: clip) { updatedClip in
                        onUpdate(updatedClip)
                        isEditing = false
                    }
                } else {
                    PreviewContentView(clip: clip)
                }

                Divider()

                // Metadata section
                previewMetadata(clip)

                Divider()

                // Footer actions
                previewFooter(clip)
            }
            .frame(width: 280)
            .background(.ultraThickMaterial)
            .transition(.move(edge: .trailing))
            .onChange(of: clip.id) { _ in
                nicknameText = clip.nickname ?? ""
                isEditingNickname = false
            }
            .onAppear {
                nicknameText = clip.nickname ?? ""
            }
        }
    }

    private func nicknameField(_ clip: Clip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.line")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)

            if isEditingNickname {
                TextField("제목 없음", text: $nicknameText, onCommit: {
                    onNicknameChanged(clip, nicknameText)
                    isEditingNickname = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .onExitCommand {
                    nicknameText = clip.nickname ?? ""
                    isEditingNickname = false
                }
            } else {
                Text(clip.nickname?.isEmpty == false ? clip.nickname! : "제목 없음")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(clip.nickname?.isEmpty == false ? .primary : .secondary.opacity(0.6))
                    .onTapGesture {
                        nicknameText = clip.nickname ?? ""
                        isEditingNickname = true
                    }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05))
    }

    private func previewHeader(_ clip: Clip) -> some View {
        HStack(spacing: 8) {
            // Type icon with background
            Image(systemName: clip.contentType.systemImage)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(typeColor(clip.contentType)))

            VStack(alignment: .leading, spacing: 1) {
                Text(clip.contentType.displayName)
                    .font(.system(size: 12, weight: .semibold))

                Text(clip.lastCopiedAt.relativeString)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Edit button (text/code/url only)
            if clip.contentType != .image && clip.contentType != .color {
                Button(action: { isEditing.toggle() }) {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                        .font(.system(size: 16))
                        .foregroundColor(isEditing ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("e", modifiers: .command)
                .help("편집 (⌘E)")
            }

            // Close button
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("닫기")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func previewMetadata(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Source app
            if let appName = clip.sourceAppName, !appName.isEmpty {
                metadataRow(icon: "app.badge", label: "출처", value: appName)
            }

            // Copy count
            metadataRow(icon: "doc.on.doc", label: "복사 횟수", value: "\(clip.copyCount)회")

            // Created date
            metadataRow(icon: "calendar", label: "생성", value: formatDate(clip.createdAt))

            // Last copied
            if clip.createdAt != clip.lastCopiedAt {
                metadataRow(icon: "clock.arrow.circlepath", label: "최근 복사", value: formatDate(clip.lastCopiedAt))
            }

            // Character count (text/code)
            if let text = clip.contentText, clip.contentType == .text || clip.contentType == .code {
                let charCount = text.count
                let lineCount = text.components(separatedBy: .newlines).count
                metadataRow(icon: "textformat.abc", label: "크기", value: "\(charCount)자 / \(lineCount)줄")
            }

            // URL domain
            if clip.contentType == .url, let urlStr = clip.contentText,
               let url = URL(string: urlStr), let host = url.host {
                metadataRow(icon: "globe", label: "도메인", value: host)
            }

            // Image info
            if clip.contentType == .image {
                if let path = clip.imagePath {
                    let filename = (path as NSString).lastPathComponent
                    metadataRow(icon: "photo", label: "파일", value: filename)
                }
            }

            // Tags
            if !clip.tagsText.isEmpty {
                metadataRow(icon: "tag", label: "태그", value: clip.tagsText)
            }

            // Pin status
            if clip.isPinned {
                metadataRow(icon: "pin.fill", label: "상태", value: "고정됨")
            }

            // TTL / Expiration
            ttlRow(clip)

            // OCR text
            if let ocrText = clip.ocrText, !ocrText.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 9))
                        Text("OCR 텍스트")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.secondary)

                    Text(ocrText)
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.8))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            }

            // AI category (macOS 26+)
            if #available(macOS 26, *) {
                aiCategorySection(clip)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: clip.id) { _ in
            aiSummary = nil
            isSummarizing = false
        }
    }

    @available(macOS 26, *)
    @ViewBuilder
    private func aiCategorySection(_ clip: Clip) -> some View {
        if let cat = clip.aiCategory, let category = AICategory(rawValue: cat) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundColor(.indigo)
                    .frame(width: 14, alignment: .center)

                Text("AI 분류")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 55, alignment: .leading)

                HStack(spacing: 4) {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 9))
                    Text(category.displayName)
                        .font(.system(size: 10))
                }
                .foregroundColor(.indigo)
            }
        }

        // AI summary for long text
        if let text = clip.contentText,
           text.count > 500,
           (clip.contentType == .text || clip.contentType == .code),
           (UserDefaults.standard.object(forKey: "aiSummaryEnabled") as? Bool ?? true) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundColor(.indigo)
                    Text("AI 요약")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    if isSummarizing {
                        ProgressView().scaleEffect(0.5)
                    } else if aiSummary == nil {
                        Button("요약") {
                            requestSummary(text: text)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.indigo)
                    }
                }

                if let summary = aiSummary {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.8))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
    }

    private func requestSummary(text: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            isSummarizing = true
            Task {
                let result = await AISummaryService.shared.summarize(text: text)
                await MainActor.run {
                    aiSummary = result
                    isSummarizing = false
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func ttlRow(_ clip: Clip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)

            Text("만료")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .leading)

            if showTTLPicker {
                Menu {
                    Button("만료 안 함") {
                        onUpdate(clipWithExpiry(clip, expiresAt: nil))
                        showTTLPicker = false
                    }
                    Divider()
                    Button("1일") {
                        onUpdate(clipWithExpiry(clip, expiresAt: Date().addingTimeInterval(86400)))
                        showTTLPicker = false
                    }
                    Button("7일") {
                        onUpdate(clipWithExpiry(clip, expiresAt: Date().addingTimeInterval(86400 * 7)))
                        showTTLPicker = false
                    }
                    Button("30일") {
                        onUpdate(clipWithExpiry(clip, expiresAt: Date().addingTimeInterval(86400 * 30)))
                        showTTLPicker = false
                    }
                    Button("90일") {
                        onUpdate(clipWithExpiry(clip, expiresAt: Date().addingTimeInterval(86400 * 90)))
                        showTTLPicker = false
                    }
                } label: {
                    Text(expiryLabel(clip))
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }
            } else {
                Button(action: { showTTLPicker = true }) {
                    Text(expiryLabel(clip))
                        .font(.system(size: 10))
                        .foregroundColor(clip.expiresAt != nil ? .orange : .primary.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    private func expiryLabel(_ clip: Clip) -> String {
        guard let date = clip.expiresAt else { return String(localized: "만료 안 함") }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: date)
    }

    private func clipWithExpiry(_ clip: Clip, expiresAt: Date?) -> Clip {
        var updated = clip
        updated.expiresAt = expiresAt
        return updated
    }

    private func previewFooter(_ clip: Clip) -> some View {
        HStack(spacing: 12) {
            // Copy to clipboard
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
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Spacer()

            // Pin toggle
            Button {
                var updated = clip
                updated.isPinned.toggle()
                onUpdate(updated)
            } label: {
                Label(
                    clip.isPinned ? "고정 해제" : "고정",
                    systemImage: clip.isPinned ? "pin.slash" : "pin"
                )
                .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(clip.isPinned ? .orange : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func metadataRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .leading)

            Text(value)
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
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
