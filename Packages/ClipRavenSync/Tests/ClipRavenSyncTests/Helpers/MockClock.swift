import Foundation
@testable import ClipRavenSync

/// 테스트용 Clock. 현재 시각을 임의로 설정/이동할 수 있다.
///
/// 사용 예:
/// ```
/// let clock = MockClock(now: Date(timeIntervalSinceReferenceDate: 0))
/// clock.advance(days: 7)
/// ```
final class MockClock: AppClock, @unchecked Sendable {
    private var current: Date

    init(now: Date = Date()) {
        self.current = now
    }

    func now() -> Date { current }

    /// 시간을 N 일 앞으로 이동.
    func advance(days: Int) {
        current = Calendar.current.date(byAdding: .day, value: days, to: current) ?? current
    }

    /// 시간을 N 초 앞으로 이동.
    func advance(seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }

    /// 특정 시각으로 설정.
    func set(_ date: Date) {
        current = date
    }
}
