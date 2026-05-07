import SwiftUI
import WidgetKit
import AppIntents

/// Medium 위젯 — 최근 클립 최대 4개 목록.
///
/// 디자인 원칙:
/// - 미니멀 헤더 (아이콘만 좌상, 시간/카운트는 각 행에)
/// - 각 행: 타입 아이콘 (또는 썸네일) + 본문 + 시간 + 복사 버튼
/// - URL → 도메인 표시 / Code → monospace / Image → 16×16 썸네일
/// - 핀 클립은 별도 마크
///
/// 행 탭 → 앱의 해당 클립 상세로 이동.
struct MediumWidgetView: View {

    let entry: ClipWidgetEntry

    var body: some View {
        // Medium 은 4개까지 (행 높이 + spacing 고려)
        let clips = Array(entry.clips.prefix(4))

        VStack(alignment: .leading, spacing: 0) {
            // 미니멀 헤더: 앱 아이콘 + clip count
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("ClipRaven")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if !entry.clips.isEmpty {
                    Text("\(entry.clips.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            .padding(.bottom, 6)

            if clips.isEmpty {
                Spacer()
                emptyMessage
                Spacer()
            } else {
                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                    clipRow(clip: clip)
                    if index < clips.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func clipRow(clip: ClipSnapshot) -> some View {
        Link(destination: ClipWidgetURL.clipDetail(id: clip.id)) {
            HStack(spacing: 9) {
                // 타입 아이콘 또는 썸네일
                leadingVisual(clip)
                    .frame(width: 18, height: 18)

                // 본문 — 핀 아이콘 prefix + 메인 텍스트
                HStack(spacing: 4) {
                    if clip.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(clip.displayText)
                        .font(clip.isCode
                              ? .system(size: 12, design: .monospaced)
                              : .system(size: 13, weight: clip.hasNickname ? .medium : .regular))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 시간
                Text(clip.relativeTime)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                // 복사 버튼
                Button(intent: CopyClipIntent(clipId: clip.id)) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private func leadingVisual(_ clip: ClipSnapshot) -> some View {
        if clip.isImage, let thumbData = clip.thumbnailData,
           let uiImg = UIImage(data: thumbData) {
            Image(uiImage: uiImg)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: clip.typeIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(typeColor(clip))
                .frame(width: 18, height: 18)
                .background(
                    typeColor(clip).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
    }

    private func typeColor(_ clip: ClipSnapshot) -> Color {
        if clip.isURL   { return .blue }
        if clip.isCode  { return .orange }
        if clip.isImage { return .pink }
        if clip.isFile  { return .indigo }
        return .secondary
    }

    private var emptyMessage: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text("복사한 내용이 없습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
