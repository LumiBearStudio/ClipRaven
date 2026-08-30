import Foundation
import Sentry

/// Sentry helper — breadcrumb 추가 및 에러 캡처.
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
    /// SDK 는 thread-safe 하지만 전송 준비 과정이 호출 스레드에서 일어나므로
    /// background queue 에서 실행해 메인을 차단하지 않는다.
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
    /// `capture(_:context:)` 와 동일한 사유로 background queue 에서 실행.
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
