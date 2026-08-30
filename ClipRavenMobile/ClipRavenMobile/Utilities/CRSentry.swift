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
