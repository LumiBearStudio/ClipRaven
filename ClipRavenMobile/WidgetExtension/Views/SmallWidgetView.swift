import SwiftUI
import WidgetKit
import AppIntents

/// Small 위젯 — 최근 클립 1개 + 복사 버튼.
///
/// 디자인 원칙 (Paste-style 차용):
/// - 미니멀 헤더 (아이콘만, "ClipRaven" 텍스트 없음 — 위젯 자체가 브랜드)
/// - 우측 상단 시간 표시 (방금 / 5분 / 1시간 / 어제)
/// - 핀 고정 클립은 핀 아이콘 prefix
/// - 이미지 클립은 썸네일 + 작은 텍스트
/// - 코드 클립은 monospace
/// - URL 클립은 도메인만
///
/// 탭 전체 → 앱 오픈. 복사 버튼(interactive) → AppIntent로 즉시 클립보드 복사.
struct SmallWidgetView: View {

    let entry: ClipWidgetEntry

    var body: some View {
        if let clip = entry.clips.first {
            clipView(clip)
        } else {
            emptyView
        }
    }

    private func clipView(_ clip: ClipSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 미니멀 헤더 — 핀 아이콘 + 시간
            HStack(spacing: 4) {
                if clip.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Image(systemName: clip.typeIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(typeColor(clip))
                Spacer()
                Text(clip.relativeTime)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.bottom, 8)

            // 본문 — 이미지 / 텍스트 분기
            if clip.isImage, let thumbData = clip.thumbnailData,
               let uiImg = UIImage(data: thumbData) {
                imageBody(uiImg, clip: clip)
            } else {
                textBody(clip)
            }

            Spacer(minLength: 6)

            // 복사 버튼 (iOS 17+ interactive)
            Button(intent: CopyClipIntent(clipId: clip.id)) {
                Label("복사", systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(ClipWidgetURL.openApp)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func textBody(_ clip: ClipSnapshot) -> some View {
        Text(clip.displayText)
            .font(clip.isCode
                  ? .system(size: 12, design: .monospaced)
                  : .system(size: 13))
            .lineLimit(clip.hasNickname ? 2 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.primary)
    }

    private func imageBody(_ img: UIImage, clip: ClipSnapshot) -> some View {
        Image(uiImage: img)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 콘텐츠 타입별 약한 색상 (Paste-style: subtle, not loud).
    private func typeColor(_ clip: ClipSnapshot) -> Color {
        if clip.isURL   { return .blue }
        if clip.isCode  { return .orange }
        if clip.isImage { return .pink }
        if clip.isFile  { return .indigo }
        return .secondary
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("복사한 내용이 없습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
