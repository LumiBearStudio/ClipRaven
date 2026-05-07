import SwiftUI
import WidgetKit

/// 잠금 화면 위젯 (accessoryRectangular).
///
/// 표시: 타입 아이콘 / 본문 1줄 / 시간 / 카운트.
/// 잠금 화면은 인터랙티브 버튼 불가 — 탭 시 앱 오픈만.
struct LockscreenWidgetView: View {

    let entry: ClipWidgetEntry

    var body: some View {
        if let clip = entry.clips.first {
            HStack(spacing: 6) {
                Image(systemName: clip.typeIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.displayText)
                        .font(.system(size: 13, weight: clip.hasNickname ? .semibold : .medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(clip.relativeTime)
                            .font(.system(size: 10))
                            .monospacedDigit()
                        if entry.clips.count > 1 {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text("외 \(entry.clips.count - 1)개")
                                .font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .widgetURL(ClipWidgetURL.openApp)
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            Label("복사한 내용이 없습니다", systemImage: "doc.on.clipboard")
                .font(.system(size: 12))
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}
