import AppKit

/// 클립 내용을 그리는 창의 화면 공유·녹화 노출 정책.
///
/// **보장이 아니라 macOS 에 대한 요청이다.** Apple 문서는
/// `NSWindow.SharingType.none` 을 "macOS 가 더 이상 쓰지 않는 레거시 상수" 로
/// 적고 있고, macOS 15 이상에서는 ScreenCaptureKit 기반 앱(QuickTime, 일부
/// 화상회의 앱)이 이 창을 그대로 캡처할 수 있다. Apple DTS 도 화면 캡처를 막는
/// 공개 API 는 없다고 답했다. 그래서 설정 문구도 "숨기도록 요청" 으로 적는다
/// (v1 리뷰 G5).
///
/// 클립 내용을 보여주는 창은 모두 이 함수를 거쳐야 한다. 이전에는 메인 패널만
/// 적용하고 미리보기 창과 이미지 확인 창은 빠져 있어서, 설정을 켜도 그 두 창은
/// 어떤 macOS 에서든 화면 공유에 그대로 보였다.
enum ScreenSharingPolicy {

    /// 설정 › 개인정보 › "화면 공유 시 패널 숨기기". 기본 ON.
    static var hidesClipWindows: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.hideOnScreenSharing) as? Bool ?? true
    }

    /// 창을 만들 때와 설정이 바뀔 때 호출한다.
    static func apply(to window: NSWindow) {
        window.sharingType = hidesClipWindows ? .none : .readOnly
    }
}
