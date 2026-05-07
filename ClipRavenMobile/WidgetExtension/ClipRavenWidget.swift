import WidgetKit
import SwiftUI

// MARK: - Widget Definition

/// ClipRaven 위젯 번들. Small / Medium / Lockscreen 세 가지 크기를 제공한다.
@main
struct ClipRavenWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClipRavenWidget()
        ClipRavenLockscreenWidget()
    }
}

// MARK: - Home Screen Widget (Small + Medium)

struct ClipRavenWidget: Widget {
    let kind = "ClipRavenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClipWidgetProvider()) { entry in
            ClipRavenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("ClipRaven")
        .description("최근 복사한 클립을 홈 화면에서 바로 확인하고 복사합니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Lockscreen Widget

struct ClipRavenLockscreenWidget: Widget {
    let kind = "ClipRavenLockscreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClipWidgetProvider()) { entry in
            LockscreenWidgetView(entry: entry)
        }
        .configurationDisplayName("ClipRaven 잠금 화면")
        .description("잠금 화면에서 최근 클립을 확인합니다.")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}

// MARK: - Entry View Router

struct ClipRavenWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ClipWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}
