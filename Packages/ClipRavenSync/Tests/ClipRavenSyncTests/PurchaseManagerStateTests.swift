import XCTest
@testable import ClipRavenSync

/// `PurchaseManager.computeLockState` 는 외부 의존성 없는 순수 함수.
/// 트라이얼 잔여 일수 × paid 권한 보유 여부 → `LockState` 매핑을 검증한다.
///
/// StoreKit 실제 호출 흐름(`refresh`, `purchase`, `restore`)은 외부 시스템 의존성이
/// 커서 본 단위 테스트의 범위 밖. StoreKitTest 프레임워크 통합은 별도 사이클.
final class PurchaseManagerStateTests: XCTestCase {

    // MARK: - 트라이얼

    func test_trialWithPositiveDays_returnsTrial() {
        let state = PurchaseManager.computeLockState(
            daysLeft: 5,
            hasPaidEntitlement: false
        )
        XCTAssertEqual(state, .trial(daysLeft: 5))
    }

    func test_trialOneDayLeft_returnsTrial1() {
        let state = PurchaseManager.computeLockState(
            daysLeft: 1,
            hasPaidEntitlement: false
        )
        XCTAssertEqual(state, .trial(daysLeft: 1))
    }

    // MARK: - 만료

    func test_zeroDays_returnsExpired() {
        let state = PurchaseManager.computeLockState(
            daysLeft: 0,
            hasPaidEntitlement: false
        )
        XCTAssertEqual(state, .expired)
    }

    func test_negativeDays_returnsExpired() {
        // 방어 코드: 어떤 이유로든 음수가 흘러들어와도 expired
        let state = PurchaseManager.computeLockState(
            daysLeft: -3,
            hasPaidEntitlement: false
        )
        XCTAssertEqual(state, .expired)
    }

    // MARK: - 구매 우선

    func test_paidEntitlement_overridesTrial() {
        let state = PurchaseManager.computeLockState(
            daysLeft: 10,
            hasPaidEntitlement: true
        )
        XCTAssertEqual(state, .paid)
    }

    func test_paidEntitlement_overridesExpired() {
        // 트라이얼 끝나고도 paid 권한 있으면 paid (복원 케이스)
        let state = PurchaseManager.computeLockState(
            daysLeft: 0,
            hasPaidEntitlement: true
        )
        XCTAssertEqual(state, .paid)
    }

    func test_paidEntitlement_withZeroDays() {
        let state = PurchaseManager.computeLockState(
            daysLeft: 0,
            hasPaidEntitlement: true
        )
        XCTAssertEqual(state, .paid)
    }

    // MARK: - 경계값

    func test_15Days_returnsTrial15() {
        let state = PurchaseManager.computeLockState(
            daysLeft: 15,
            hasPaidEntitlement: false
        )
        XCTAssertEqual(state, .trial(daysLeft: 15))
    }
}
