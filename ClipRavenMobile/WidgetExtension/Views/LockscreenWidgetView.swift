import SwiftUI
import WidgetKit

/// 잠금 화면 위젯 (accessoryRectangular).
///
/// 표시: 타입 아이콘 / 본문 1줄 / 시간 / 카운트.
/// 잠금 화면은 인터랙티브 버튼 불가 — 탭 시 앱 오픈만.
///
/// **본문에는 `privacySensitive()` 가 붙어 있다.** 클립보드 매니저에서 "가장
/// 최근에 복사한 항목" 은 통계적으로 비밀번호·인증번호일 확률이 가장 높은
/// 슬롯이라, 잠긴 기기를 집어든 제3자에게 그대로 보이면 안 된다. 이 modifier
/// 를 붙이면 기기가 잠긴 동안 시스템이 해당 뷰를 가리고, Face ID 등으로
/// 인증한 뒤에만 실제 내용이 나타난다 (보안 감사 P5).
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
                        .privacySensitive()
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
