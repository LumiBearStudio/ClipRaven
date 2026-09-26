import Foundation
import Sentry

/// Sentry helper — breadcrumb 추가 및 에러 캡처.
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
        SentrySDK.start { options in
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
            // 진단 정보는 breadcrumb 으로만 보낸다 (보안 감사 P2).
        }
        breadcrumb("crash reporting enabled", category: "app")
    }

    /// 설정에서 끄면 즉시 전송을 멈춘다.
    static func stop() {
        SentrySDK.close()
    }

    // MARK: - Breadcrumb

    /// 앱 생명주기 이벤트 등을 Sentry breadcrumb 링버퍼에 쌓는다.
    /// 이후 발생하는 crash / captureError 이벤트에 자동 첨부됨.
    static func breadcrumb(_ message: String, category: String, level: SentryLevel = .info) {
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        crumb.type = "default"
        SentrySDK.addBreadcrumb(crumb)
    }

    // MARK: - Error capture

    /// 에러를 Sentry 로 전송한다. context 문자열은 호출자가 정하므로
    /// 사용자 콘텐츠를 넣지 말 것.
    ///
    /// macOS 와 동일하게 background queue 에서 실행 — 전송 준비가 호출
    /// 스레드에서 일어나 메인을 막는 것을 피한다.
    static func capture(_ error: Error, context: String? = nil) {
        Task.detached(priority: .utility) {
            SentrySDK.capture(error: error) { scope in
                if let context {
                    scope.setExtra(value: context, key: "context")
                }
            }
        }
    }

    /// 메시지를 에러로 전송한다.
    static func captureMessage(_ message: String, level: SentryLevel = .error, context: String? = nil) {
        Task.detached(priority: .utility) {
            SentrySDK.capture(message: message) { scope in
                scope.setLevel(level)
                if let context {
                    scope.setExtra(value: context, key: "context")
                }
            }
        }
    }
}
