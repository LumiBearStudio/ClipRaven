import SwiftUI
import ClipRavenSync

/// 클립 상세 뷰 — iPhone Sheet와 iPad Inspector 패널 모두에서 재사용.
///
/// iPhone: `.sheet(item: $selectedClip) { ClipDetailView(clip: $0) }` 로 호출.
///   dismiss는 @Environment(\.dismiss) 로 처리.
/// iPad:   `.inspector()` 패널 안에서 `onDismiss: { selectedClip = nil }` 로 호출.
///   NavigationStack 바깥이라 Environment dismiss가 없으므로 클로저로 처리.
struct ClipDetailView: View {
    let clip: Clip
    /// iPad inspector에서 닫을 때 호출. nil이면 @Environment dismiss 사용 (iPhone sheet).
    var onDismiss: (() -> Void)? = nil

    @State private var copiedHint = false
    @State private var isEditing = false
    @State private var editedText: String = ""
    @State private var editedNickname: String = ""
    @State private var isSaving = false
    @State private var excludeFromSync: Bool
    @Environment(\.dismiss) private var dismiss

    init(clip: Clip, onDismiss: (() -> Void)? = nil) {
        self.clip = clip
        self.onDismiss = onDismiss
        _excludeFromSync = State(initialValue: clip.excludeFromSync)
    }

    private var canEdit: Bool { clip.contentType != .image && clip.contentText != nil }

    private var shareText: String? {
        if let t = clip.contentText, !t.isEmpty { return t }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    contentBox
                    metaSection
                    if !isEditing { actionButtons }
                    else { saveButton }
                }
                .padding(20)
            }
            .navigationTitle(clip.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .background(Color(.systemGroupedBackground))
        }
        .onAppear {
            editedText = clip.contentText ?? ""
            editedNickname = clip.nickname ?? ""
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isEditing {
                Button("취소") {
                    isEditing = false
                    editedText = clip.contentText ?? ""
                    editedNickname = clip.nickname ?? ""
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                if !isEditing {
                    if let text = shareText {
                        ShareLink(item: text) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    if canEdit {
                        Button {
                            editedText = clip.contentText ?? ""
                            editedNickname = clip.nickname ?? ""
                            isEditing = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                }
                Button("완료") {
                    if let onDismiss { onDismiss() }
                    else { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let nickname = clip.nickname, !nickname.isEmpty {
                Text(nickname).font(.title2.bold())
            }
            HStack(spacing: 8) {
                Label(clip.contentType.displayName, systemImage: clip.contentType.systemImage)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                if clip.isPinned {
                    Label("핀 고정", systemImage: "pin.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
                Text(clip.lastCopiedAt, style: .relative)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Content Box

    @ViewBuilder
    private var contentBox: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("닉네임 (선택)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("짧은 이름으로 쉽게 찾기", text: $editedNickname)
                        .font(.body)
                        .padding(10)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("내용")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $editedText)
                        .font(.body)
                        .frame(minHeight: 140)
                        .padding(10)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5)
                        )
                }
            }
        } else if clip.contentType == .image,
                  let data = clip.thumbnail, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let text = clip.contentText, !text.isEmpty {
            Text(text)
                .font(.body).lineSpacing(3).tracking(-0.2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Meta Section

    @ViewBuilder
    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let app = clip.sourceAppName, !app.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "app.badge").font(.caption).foregroundStyle(.secondary)
                    Text(app).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let url = clip.sourceUrl {
                Link(destination: URL(string: url) ?? URL(string: "about:blank")!) {
                    Label(url, systemImage: "link").font(.caption).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                if excludeFromSync {
                    Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    Text("동기화 제외").foregroundStyle(.secondary)
                } else if let synced = clip.ckLastSyncedAt {
                    Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
                    Text("동기화 됨 · ").foregroundStyle(.secondary)
                    Text(synced, style: .relative).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
                    Text("동기화 대기 중").foregroundStyle(.secondary)
                }
                Spacer()
                // Toggle은 "동기화 ON" = excludeFromSync가 false 상태를 표현하므로 논리 반전.
                Toggle("", isOn: Binding(
                    get: { !excludeFromSync },
                    set: { newVal in
                        excludeFromSync = !newVal
                        guard let uuid = clip.uuid else { return }
                        Task { try? ClipRepository().toggleExcludeFromSync(uuid: uuid) }
                    }
                ))
                .labelsHidden()
                .controlSize(.mini)
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        if clip.contentType == .image, let data = clip.thumbnail, let img = UIImage(data: data) {
            ShareLink(
                item: Image(uiImage: img),
                preview: SharePreview(clip.displayTitle, image: Image(uiImage: img))
            ) {
                Label("이미지 공유", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }

        Button {
            ClipboardWriter.write(clip: clip)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            copiedHint = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copiedHint = false
            }
        } label: {
            Label(copiedHint ? "복사됨!" : "클립보드에 복사",
                  systemImage: copiedHint ? "checkmark.circle.fill" : "doc.on.doc")
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        // 이미지 클립은 contentText가 nil이어도 thumbnail로 paste 가능 → 활성화 유지.
        .disabled(clip.contentText == nil && clip.thumbnail == nil)
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            guard let uuid = clip.uuid,
                  !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            isSaving = true
            Task {
                try? ClipRepository().updateContentTextAndNickname(
                    uuid: uuid,
                    newText: editedText,
                    nickname: editedNickname
                )
                await MainActor.run {
                    isSaving = false
                    isEditing = false
                }
            }
        } label: {
            Group {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("저장")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
    }
}
