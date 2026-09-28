import Foundation
import Sentry

/// Sentry helper — 동의 시작·철회와 breadcrumb.
///
/// `crashReportsEnabled` 가 off 이면 SentrySDK 는 미초기화 상태이므로
/// 모든 호출은 no-op 이 된다 (Sentry-cocoa 내부 guard 처리).
///
/// **진단 정보는 breadcrumb 으로만 보낸다.** 이벤트마다 `OSLogStore` 로
/// os.log 를 긁어 첨부하던 경로는 제거했다 — 클립 본문이 섞여 개인정보
/// 처리방침을 위반했고, 동기 XPC 호출이라 호출 스레드를 막았다
/// (보안 감사 P2, macOS 쪽과 동일 조치).
enum CRSentry {

    /// 크래시 리포트 동의 여부를 저장하는 키. 앱 본체만 읽으므로
    /// `UserDefaults.standard` 에 둔다 (확장은 Sentry 를 쓰지 않는다).
    static let enabledKey = "crashReportsEnabled"

    /// 사용자가 동의한 경우에만 SDK 를 초기화한다. 동의 전에는 SDK 가 아예
    /// 시작되지 않으므로 네트워크도 발생하지 않는다.
    static func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        start()
    }

    /// 설정에서 켠 즉시 반영하기 위해 런타임에도 호출할 수 있다.
    /// (앱 재시작을 요구하지 않기 위한 것 — 재시작 안내는 나쁜 UX 다.)
    static func start() {
        SentrySDK.start(configureOptions: configure)
        breadcrumb("crash reporting enabled", category: "app")
    }

    /// SDK 옵션. 동의 범위("비정상 종료 시에만, 클립 내용 없이")를 지키는 설정이
    /// 모여 있어 테스트(`CRSentryConsentTests`)가 이 함수로 만든 값을 검사한다.
    static func configure(_ options: Options) {
        options.dsn = "https://2e87dafa4228a756923fbb0e0d914949@o4510949994266624.ingest.de.sentry.io/4511348636778576"
        // Sentry dashboard 의 environment 필터로 dev / prod 구분.
        #if DEBUG
        options.environment = "development"
        #else
        options.environment = "production"
        #endif
        options.sendDefaultPii = false
        options.maxBreadcrumbs = 200
        // 크래시가 없을 때는 아무것도 보내지 않는다. Sentry 9 는 기본값으로 세션
        // 추적과 앱 멈춤 추적이 켜져 있어, 크래시가 없어도 세션·멈춤 데이터를
        // 보냈다 — "비정상 종료 시에만" 이라는 동의 문구와 개인정보 라벨(충돌
        // 데이터만)이 사실이 되도록 끈다 (v1 리뷰).
        options.enableAutoSessionTracking = false
        options.enableAppHangTracking = false
        // 같은 이유로 크래시와 무관한 자동 전송도 끈다. 기본값은 앱 안의 HTTP 요청
        // URL 을 breadcrumb 으로 기록하고(링크 미리보기가 사용자가 복사한 URL 을
        // 여는 경로), 5xx 응답을 별도 이벤트로 보내고, 폐기 통계(client report)를
        // 보낸다 — 모두 "크래시 시에만, 클립 내용 없이" 약속 밖이다.
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableNetworkTracking = false
        options.sendClientReports = false
        // iOS 의 자동 breadcrumb 은 화면이 나타날 때 뷰 컨트롤러 제목과 버튼 제목을
        // 기록한다(SentryBreadcrumbTracker). 클립 상세 화면은 제목이 클립 내용
        // (`clip.displayTitle`)이라 클립 내용이 크래시 리포트에 실릴 수 있었다.
        // 앱이 직접 남기는 breadcrumb 은 이 옵션과 무관하게 계속 남는다.
        // (macOS 의 자동 breadcrumb 은 활성/비활성 상태만 기록해 켜 둔다.)
        options.enableAutoBreadcrumbTracking = false
        // 진단 정보는 breadcrumb 으로만 보낸다 (보안 감사 P2).
    }

    /// 설정에서 끄면 즉시 전송을 멈춘다.
    static func stop() {
        SentrySDK.close()
    }

    // MARK: - Breadcrumb

    /// 앱 생명주기 이벤트 등을 Sentry breadcrumb 링버퍼에 쌓는다.
    /// 이후 발생하는 크래시 리포트에 자동 첨부된다.
    static func breadcrumb(_ message: String, category: String, level: SentryLevel = .info) {
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        crumb.type = "default"
        SentrySDK.addBreadcrumb(crumb)
    }

    // 크래시가 아닌 오류를 이벤트로 보내는 `capture` API 는 두지 않는다. 동의 문구와
    // 개인정보 라벨이 "비정상 종료 시에만" 이므로, 비치명 오류는 `breadcrumb(level:
    // .error)` 로 남겨 다음 크래시 리포트에 함께 실리게 한다 (v1 리뷰).
}
