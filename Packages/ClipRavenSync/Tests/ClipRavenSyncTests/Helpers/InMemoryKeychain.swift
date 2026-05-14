import Foundation
@testable import ClipRavenSync

/// 메모리 기반 KeychainStorage. 테스트 격리용.
/// 실제 Keychain 을 건드리지 않으므로 테스트 실행 후 시스템에 잔존하는 데이터가 없다.
final class InMemoryKeychain: KeychainStorage, @unchecked Sendable {
    private var storedDate: Date?

    init(initial: Date? = nil) {
        self.storedDate = initial
    }

    func saveFirstLaunchDate(_ date: Date) throws {
        storedDate = date
    }

    func loadFirstLaunchDate() -> Date? {
        storedDate
    }

    /// 테스트 헬퍼: 강제로 비우기 (재실행 시뮬레이션).
    func clear() {
        storedDate = nil
    }
}
