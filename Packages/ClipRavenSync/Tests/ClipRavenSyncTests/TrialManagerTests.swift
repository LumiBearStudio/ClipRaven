import XCTest
@testable import ClipRavenSync

/// `TrialManager` 의 시간 흐름 + Keychain 영구 저장을 격리 환경에서 검증.
/// `MockClock` 으로 시간 임의 제어, `InMemoryKeychain` 으로 저장 격리.
final class TrialManagerTests: XCTestCase {

    private var clock: MockClock!
    private var keychain: InMemoryKeychain!
    private var sut: TrialManager!

    /// 트라이얼 시작 기준 날짜. 일관된 계산을 위해 자정으로 맞춤.
    private let installDate = Calendar.current.startOfDay(
        for: Date(timeIntervalSinceReferenceDate: 0)
    )

    override func setUp() {
        super.setUp()
        clock = MockClock(now: installDate)
        keychain = InMemoryKeychain()
        sut = TrialManager(
            clock: clock,
            storage: keychain,
            trialDays: 15
        )
    }

    override func tearDown() {
        clock = nil
        keychain = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - 첫 실행

    func test_firstLaunchDate_recordsCurrentClock_whenStorageEmpty() {
        XCTAssertNil(keychain.loadFirstLaunchDate())

        let recorded = sut.firstLaunchDate()

        XCTAssertEqual(recorded, installDate)
        XCTAssertEqual(keychain.loadFirstLaunchDate(), installDate)
    }

    func test_firstLaunchDate_returnsStored_whenAlreadySaved() throws {
        let earlier = installDate.addingTimeInterval(-86400 * 3)
        try keychain.saveFirstLaunchDate(earlier)

        let result = sut.firstLaunchDate()

        XCTAssertEqual(result, earlier)
    }

    // MARK: - 시간 흐름별 잔여 일수

    func test_daysRemaining_day0_returns15() {
        XCTAssertEqual(sut.daysRemaining(), 15)
    }

    func test_daysRemaining_day1_returns14() {
        _ = sut.firstLaunchDate()  // record install
        clock.advance(days: 1)
        XCTAssertEqual(sut.daysRemaining(), 14)
    }

    func test_daysRemaining_day14_returns1() {
        _ = sut.firstLaunchDate()
        clock.advance(days: 14)
        XCTAssertEqual(sut.daysRemaining(), 1)
    }

    func test_daysRemaining_day15_returns0() {
        _ = sut.firstLaunchDate()
        clock.advance(days: 15)
        XCTAssertEqual(sut.daysRemaining(), 0)
    }

    func test_daysRemaining_day30_returns0_noNegativeOverflow() {
        _ = sut.firstLaunchDate()
        clock.advance(days: 30)
        XCTAssertEqual(sut.daysRemaining(), 0)
    }

    // MARK: - 시작 시점 (v1 리뷰 M3 — 3.1.1 고지 후 시작)

    /// 잔여 일수를 읽는 것만으로는 체험이 시작되면 안 된다. 이전에는 앱 초기화가
    /// `daysRemaining()` 을 읽는 순간 안내 없이 시작됐다.
    func test_daysRemaining_doesNotStartTrial() {
        XCTAssertEqual(sut.daysRemaining(), 15)
        XCTAssertFalse(sut.hasStarted)
        XCTAssertNil(keychain.loadFirstLaunchDate())
        clock.advance(days: 20)
        XCTAssertEqual(sut.daysRemaining(), 15, "시작 전에는 시간이 흘러도 전체 기간이어야 한다")
    }

    func test_startIfNeeded_startsOnce() {
        let first = sut.startIfNeeded()
        clock.advance(days: 3)
        let second = sut.startIfNeeded()
        XCTAssertEqual(first, second, "두 번째 호출이 시작일을 늦추면 안 된다")
        XCTAssertTrue(sut.hasStarted)
        XCTAssertEqual(sut.daysRemaining(), 12)
    }

    /// 기기 시계를 과거로 돌려도 체험 기간보다 늘어나지 않는다.
    func test_daysRemaining_clockSetBack_neverExceedsTrialDays() {
        sut.startIfNeeded()
        clock.advance(days: -100)
        XCTAssertEqual(sut.daysRemaining(), 15)
    }

    // MARK: - 트라이얼 일수 커스텀

    func test_daysRemaining_customTrialDays() {
        let custom = TrialManager(
            clock: clock,
            storage: keychain,
            trialDays: 7
        )
        custom.startIfNeeded()
        XCTAssertEqual(custom.daysRemaining(), 7)
        clock.advance(days: 3)
        XCTAssertEqual(custom.daysRemaining(), 4)
        clock.advance(days: 10)
        XCTAssertEqual(custom.daysRemaining(), 0)
    }

    // MARK: - 영구 저장 검증

    func test_daysRemaining_persistsAcrossInstances() {
        // 첫 인스턴스가 첫 실행 날짜를 저장
        _ = sut.firstLaunchDate()
        clock.advance(days: 5)

        // 같은 storage 로 새 인스턴스를 만들어도 동일 잔여 일수
        let restarted = TrialManager(
            clock: clock,
            storage: keychain,
            trialDays: 15
        )
        XCTAssertEqual(restarted.daysRemaining(), 10)
    }
}
