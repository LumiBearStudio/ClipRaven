// QA 빌드의 화면을 셸에서 바꾼다 — App Store 스크린샷용.
//
//   swift Scripts/qa/scene.swift 'stage:Everything you copy|One keystroke away'
//   swift Scripts/qa/scene.swift panel
//   swift Scripts/qa/scene.swift search:launch
//   swift Scripts/qa/scene.swift stack:3
//   swift Scripts/qa/scene.swift settings:privacy
//   swift Scripts/qa/scene.swift paywall
//   swift Scripts/qa/scene.swift snap      # 앱이 ⇧⌘3 을 누른다 (붙여넣기 권한 필요)
//   swift Scripts/qa/scene.swift clear
//
// QA 빌드(번들 .qa)만 이 알림을 듣는다. 장면 설명은 ClipRaven/App/QALaunchOptions.swift.
import Foundation

guard let scene = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write("usage: scene.swift <stage:제목|부제|panel|search:<검색어>|stack:<개수>|settings:<탭>|paywall|snap|clear>\n".data(using: .utf8)!)
    exit(64)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.lumibear.clipraven.qa.scene"),
    object: scene,
    userInfo: nil,
    deliverImmediately: true
)
print("scene → \(scene)")
