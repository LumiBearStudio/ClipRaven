import SwiftUI
import ClipRavenSync

/// 상단 가로 스크롤 핀 스트립.
/// 그리드와 동일한 ClipCard 컴포넌트를 사용해 디자인 언어를 통일.
/// context menu로 핀 해제 / 미리보기 / 복사 / 삭제 제공.
struct PinnedStrip: View {

    let clips: [Clip]
    let onCopy: (Clip) -> Void
    let onPreview: (Clip) -> Void
    let onTogglePin: (Clip) -> Void
    let onDelete: (Clip) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(45))
                Text("핀 고정")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("\(clips.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(clips) { clip in
                        Button { onCopy(clip) } label: {
                            ClipCard(clip: clip)
                                .frame(width: 130)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { onPreview(clip) } label: {
                                Label("미리보기", systemImage: "eye")
                            }

                            Button { onCopy(clip) } label: {
                                Label("클립보드에 복사", systemImage: "doc.on.doc")
                            }
                            .disabled(clip.contentText == nil)

                            Button {
                                onTogglePin(clip)
                            } label: {
                                Label("핀 해제", systemImage: "pin.slash")
                            }

                            Divider()

                            Button(role: .destructive) {
                                onDelete(clip)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    PinnedStrip(
        clips: [
            Clip(contentType: .text, contentText: "회의 노트 — 4분기 OKR 정리", nickname: "OKR", isPinned: true, uuid: "1"),
            Clip(contentType: .url, contentText: "https://example.com/very-long-url", nickname: "Reference", isPinned: true, uuid: "2"),
            Clip(contentType: .code, contentText: "func calculate() -> Int { return 42 }", isPinned: true, uuid: "3"),
        ],
        onCopy: { _ in },
        onPreview: { _ in },
        onTogglePin: { _ in },
        onDelete: { _ in }
    )
    .background(Color(.systemGroupedBackground))
}
