import XCTest
import Sentry
@testable import ClipRaven

/// 크래시 리포트 설정이 동의 범위 안에 있는지 (테스트 계획 B6).
///
/// 동의 문구·개인정보 처리방침·App Privacy 가 "비정상 종료 시에만, 클립 내용 없이" 라고
/// 약속한다. Sentry 는 기본값으로 세션·앱 멈춤·네트워크 기록·실패 요청·클라이언트
/// 리포트를 보내므로, SDK 를 올리거나 설정을 손볼 때 이 약속이 조용히 깨지지 않게 한다.
final class CRSentryConsentTests: XCTestCase {

    func test_onlyCrashReportsAreSent() {
        let options = Options()
        CRSentry.configure(options)

        XCTAssertNotNil(options.dsn)
        XCTAssertTrue(options.enableCrashHandler, "크래시 리포트 자체는 켜져 있어야 한다")

        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertFalse(options.enableAutoSessionTracking, "세션 데이터")
        XCTAssertFalse(options.enableAppHangTracking, "앱 멈춤 이벤트")
        XCTAssertFalse(options.enableNetworkBreadcrumbs, "요청 URL 기록 — 링크 미리보기는 복사한 URL 을 연다")
        XCTAssertFalse(options.enableCaptureFailedRequests, "실패한 HTTP 요청 이벤트")
        XCTAssertFalse(options.enableNetworkTracking)
        XCTAssertFalse(options.sendClientReports)
        XCTAssertNil(options.tracesSampleRate, "성능 추적")
        // 스크린샷·뷰 계층 첨부는 iOS 전용 옵션이라 macOS SDK 에는 없다.
    }

    /// 동의 전에는 켜지지 않는다: 값이 없으면 꺼짐이고, 첫 실행 기본값으로도 켜지 않는다.
    func test_dataSharingFeaturesAreOptIn() {
        let suite = "CRSentryConsentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: CRSentry.enabledKey))

        let registered = AppDelegate.registeredDefaults
        XCTAssertNil(registered[CRSentry.enabledKey], "크래시 리포트")
        XCTAssertNil(registered["linkPreviewEnabled"], "링크 미리보기")
        XCTAssertNil(registered["clipraven.sync.enabled"], "iCloud 동기화")
    }
}
