import Foundation

/// macOS 앱에서 사용하는 모든 `UserDefaults` 키의 단일 진실 (Single Source of Truth).
///
/// 이전엔 raw string literal (`"blockSensitive"`, `"maxClipCount"` 등) 이 코드 곳곳에
/// 흩어져 있었음 (감사 B-S1) — typo 시 silent 무동작이 발생했고, 새 설정 추가 시
/// 어떤 키가 이미 쓰이는지 알기 어려움. 본 enum 으로 단일화.
///
/// 사용 예:
/// ```swift
/// let on = UserDefaults.standard.object(forKey: DefaultsKey.blockSensitive) as? Bool ?? true
/// UserDefaults.standard.register(defaults: [
///     DefaultsKey.blockSensitive: true,
///     DefaultsKey.maxClipCount: AppConstants.maxClipCount,
/// ])
/// ```
///
/// 모든 key 가 `static let` 으로 노출되어 `UserDefaults` API 의 `forKey:`
/// String 매개변수에 그대로 전달 가능 (자동 String 추론).
///
/// ⚠️ 이미 사용 중인 key 의 raw 값은 절대 변경 금지 — 사용자 설정 손실.
enum DefaultsKey {

    // MARK: - 보호 / 보안
    static let blockSensitive       = "blockSensitive"
    static let filter2FA            = "filter2FA"
    static let stripInvisibleChars  = "stripInvisibleChars"
    static let stripURLTracking     = "stripURLTracking"
    static let excludedApps         = "excludedApps"
    /// 링크 미리보기(OG 메타데이터) 자동 fetch. **기본 false** — 켜면 복사한
    /// URL 로 앱이 직접 HTTP 요청을 보낸다 (보안 감사 P3-b).
    static let linkPreviewEnabled   = "linkPreviewEnabled"
    /// 화면 공유·녹화 시 패널을 숨긴다 (`NSWindow.sharingType`). 기본 true.
    /// 끄면 App Store 스크린샷 촬영 등에서 패널이 정상적으로 캡처된다.
    static let hideOnScreenSharing  = "hideOnScreenSharing"

    // MARK: - 캡처 / 저장
    static let selectiveMode        = "selectiveMode"
    static let doubleCopyWindowMs   = "doubleCopyWindowMs"
    static let maxClipCount         = "maxClipCount"
    static let maxDaysToKeep        = "maxDaysToKeep"

    // MARK: - 외관 / 시스템
    static let theme                = "theme"
    static let colorPreset          = "colorPreset"
    static let language             = "language"
    static let appleLanguages       = "AppleLanguages"
    static let drawsBackground      = "drawsBackground"
    static let launchAtLoginPending = "launchAtLoginPending"
    static let showInDock           = "showInDock"

    // MARK: - 사운드 / 햅틱
    static let soundOnCapture       = "soundOnCapture"
    static let soundOnPaste         = "soundOnPaste"
    static let hapticOnCapture      = "hapticOnCapture"
    static let hapticOnPaste        = "hapticOnPaste"

    // MARK: - AI / 자동화
    static let aiCategorizationEnabled = "aiCategorizationEnabled"
    static let aiSummaryEnabled        = "aiSummaryEnabled"

    // MARK: - 단축키
    static let hotkey               = "hotkey"

    // MARK: - 온보딩 / 메타
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let crashReportsEnabled    = "crashReportsEnabled"
}
