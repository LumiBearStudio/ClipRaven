import Foundation
import Sentry

/// Sentry helper — 동의 시작·철회와 breadcrumb.
///
/// `crashReportsEnabled` 가 off 이면 SentrySDK 는 미초기화 상태이므로
/// 모든 호출은 no-op 이 된다 (Sentry-cocoa 내부 guard 처리).
///
/// **진단 정보는 breadcrumb 으로만 보낸다.** 이전에는 이벤트마다
/// `OSLogStore` 로 최근 120초 os.log 200줄을 긁어 `recent_oslog` extra 에
/// 첨부했는데, 두 가지가 문제였다 (보안 감사 P2):
///
/// 1. 개인정보처리방침은 크래시 리포트가 클립보드 내용을 포함하지 않는다고
///    약속하는데, 그 로그에는 클립 본문·파일 경로가 섞여 있었다.
/// 2. `OSLogStore.getEntries()` 는 logd 와 XPC 동기 통신이라 호출 스레드를
///    2초+ 막는다. 실제로 App Hang 이 보고된 이력이 있다.
///
/// breadcrumb 은 우리가 직접 문면을 정하는 채널이라 두 문제가 모두 없다.
enum CRSentry {

    /// 크래시 리포트 동의 여부. 온보딩 마지막 페이지와 설정 › 개인정보에서 바꾼다.
    static let enabledKey = "crashReportsEnabled"

    /// 사용자가 동의한 경우에만 SDK 를 초기화한다. 동의 전에는 네트워크도 없다.
    static func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        start()
    }

    /// 설정에서 켠 즉시 반영하기 위해 런타임에도 호출한다 (재시작 불필요).
    static func start() {
        SentrySDK.start { options in
            options.dsn = "https://c5f56450b1edd3c00bbe4efb757a3bc1@o4510949994266624.ingest.de.sentry.io/4511348541489232"
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
            // 진단 정보는 breadcrumb 으로만 보낸다 (보안 감사 P2).
        }
    }

    /// 설정에서 끄면 즉시 전송을 멈춘다. 이전에는 macOS 에 끄는 방법이 없었다 —
    /// 온보딩은 "설정에서 언제든 변경할 수 있다" 고 안내했지만 토글이 없었다
    /// (5.1.1(ii) 동의 철회, v1 리뷰 M9).
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
