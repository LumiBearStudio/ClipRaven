import Foundation
import OSLog
import Sentry

/// Sentry helper — breadcrumb 추가 및 에러 캡처 시 최근 os.log 자동 첨부.
///
/// `crashReportsEnabled` 가 off 이면 SentrySDK 는 미초기화 상태이므로
/// 모든 호출은 no-op 이 된다 (Sentry-cocoa 내부 guard 처리).
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

    /// 에러를 Sentry 로 전송한다. 최근 120초 os.log 를 extra 에 첨부.
    ///
    /// **App Hang 회귀 방어**: `recentLogLines()` 가 내부적으로
    /// `OSLogStore.getEntries()` 를 호출하는데, 이는 logd 와의 XPC 동기 통신을
    /// 일으켜 메인 스레드에서 호출 시 2초+ block 으로 Sentry App Hang 보고가
    /// 트리거된 사례가 있었다 (APNs 등록 실패 콜백 등). Sentry SDK 자체는
    /// thread-safe 하므로 capture 본체를 background queue 로 옮겨 메인을
    /// 차단하지 않는다.
    static func capture(_ error: Error, context: String? = nil) {
        Task.detached(priority: .utility) {
            SentrySDK.capture(error: error) { scope in
                if let context {
                    scope.setExtra(value: context, key: "context")
                }
                if #available(macOS 12.0, iOS 15.0, *) {
                    if let logs = recentLogLines() {
                        scope.setExtra(value: logs, key: "recent_oslog")
                    }
                }
            }
        }
    }

    /// 메시지를 에러로 전송한다. 로그 첨부 포함.
    /// `capture(_:context:)` 와 동일한 사유로 background queue 에서 실행.
    static func captureMessage(_ message: String, level: SentryLevel = .error, context: String? = nil) {
        Task.detached(priority: .utility) {
            SentrySDK.capture(message: message) { scope in
                scope.setLevel(level)
                if let context {
                    scope.setExtra(value: context, key: "context")
                }
                if #available(macOS 12.0, iOS 15.0, *) {
                    if let logs = recentLogLines() {
                        scope.setExtra(value: logs, key: "recent_oslog")
                    }
                }
            }
        }
    }

    // MARK: - OS log reader

    /// 현재 프로세스의 최근 `seconds` 초 os.log 항목을 최대 200행 반환.
    /// macOS 12+ / iOS 15+ 미만에서는 nil.
    @available(macOS 12.0, iOS 15.0, *)
    static func recentLogLines(seconds: Double = 120) -> String? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
        let since = store.position(date: Date().addingTimeInterval(-seconds))
        let subsystem = Bundle.main.bundleIdentifier ?? ""
        let lines = (try? store.getEntries(at: since)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == subsystem }
            .map { "[\($0.category)] \($0.composedMessage)" }) ?? []
        guard !lines.isEmpty else { return nil }
        return lines.suffix(200).joined(separator: "\n")
    }
}
