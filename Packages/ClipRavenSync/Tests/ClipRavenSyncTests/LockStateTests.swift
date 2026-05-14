import XCTest
@testable import ClipRavenSync

/// `LockState` 는 순수 enum. 의존성 없이 즉시 테스트 가능.
final class LockStateTests: XCTestCase {

    func test_trial_withPositiveDays_isAccessible() {
        XCTAssertTrue(LockState.trial(daysLeft: 1).isAccessible)
        XCTAssertTrue(LockState.trial(daysLeft: 7).isAccessible)
        XCTAssertTrue(LockState.trial(daysLeft: 15).isAccessible)
    }

    /// daysLeft 가 0 인 .trial 자체는 .isAccessible == true 로 정의됨.
    /// 0 이하 처리는 PurchaseManager.computeLockState 가 .expired 로 변환하는 책임.
    func test_trial_withZeroDays_isStillAccessibleByDefinition() {
        XCTAssertTrue(LockState.trial(daysLeft: 0).isAccessible)
    }

    func test_paid_isAccessible() {
        XCTAssertTrue(LockState.paid.isAccessible)
    }

    func test_expired_isNotAccessible() {
        XCTAssertFalse(LockState.expired.isAccessible)
    }

    // MARK: - Equatable

    func test_equality_trialDifferentDays_areNotEqual() {
        XCTAssertNotEqual(LockState.trial(daysLeft: 5), LockState.trial(daysLeft: 6))
    }

    func test_equality_paidVsExpired_areNotEqual() {
        XCTAssertNotEqual(LockState.paid, LockState.expired)
    }

    func test_equality_sameCase_areEqual() {
        XCTAssertEqual(LockState.trial(daysLeft: 7), LockState.trial(daysLeft: 7))
        XCTAssertEqual(LockState.paid, LockState.paid)
        XCTAssertEqual(LockState.expired, LockState.expired)
    }
}
