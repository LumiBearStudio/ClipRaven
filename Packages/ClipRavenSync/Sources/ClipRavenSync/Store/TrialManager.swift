import Foundation
import Security

// MARK: - Clock 프로토콜 (테스트용 시간 주입)

/// 현재 시각을 반환하는 추상화. 테스트에서 `MockClock` 으로 임의 시각 주입 가능.
///
/// Swift 5.9 표준 `Clock` 프로토콜은 macOS 13+/iOS 16+ 필요. ClipRaven 은
/// iOS 17 + macOS 13 deployment target 으로 표준 Clock 사용 가능하지만,
/// `Date()` 기반 단순 시간만 필요하므로 자체 정의가 표현이 더 명확하다.
public protocol AppClock: Sendable {
    func now() -> Date
}

/// 시스템 시각을 그대로 반환. 프로덕션 기본값.
public struct SystemClock: AppClock {
    public init() {}
    public func now() -> Date { Date() }
}

// MARK: - KeychainStorage 프로토콜

/// 첫 실행 날짜를 영구 저장. 프로덕션 = `SystemKeychain`,
/// 테스트 = `InMemoryKeychain` 으로 격리.
public protocol KeychainStorage: Sendable {
    /// 첫 실행 날짜 저장. 동일 키가 있으면 덮어쓴다.
    func saveFirstLaunchDate(_ date: Date) throws
    /// 저장된 첫 실행 날짜 로드. 없으면 nil.
    func loadFirstLaunchDate() -> Date?
}

/// 실제 Keychain 을 쓰는 구현. iOS / macOS 둘 다 동일 API.
public struct SystemKeychain: KeychainStorage {
    private let service: String
    private let account: String

    public init(
        service: String = "com.lumibear.clipraven.trial",
        account: String = "firstLaunchDate"
    ) {
        self.service = service
        self.account = account
    }

    public func saveFirstLaunchDate(_ date: Date) throws {
        let data = withUnsafeBytes(of: date.timeIntervalSince1970) { Data($0) }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData:   data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
    }

    public func loadFirstLaunchDate() -> Date? {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count >= 8 else { return nil }
        let interval = data.withUnsafeBytes { $0.load(as: Double.self) }
        return Date(timeIntervalSince1970: interval)
    }
}

// MARK: - TrialManager

/// 첫 실행일을 영구 저장 (기본: Keychain) 하고 체험 잔여 일수를 계산한다.
///
/// Keychain 은 앱 삭제 후에도 데이터가 남아(iOS) 체험 기간 재사용을 막는다.
/// Mac 샌드박스 환경에서도 동일하게 동작한다.
///
/// 테스트에서는 `init(clock:storage:trialDays:)` 로 `MockClock`/`InMemoryKeychain`
/// 을 주입해 시간 흐름과 영구 저장을 격리한다.
///
/// 프로덕션 호출 코드는 `TrialManager.daysRemaining()` 정적 호환 레이어를 그대로 쓴다.
public final class TrialManager {

    public static let trialDays = 15

    /// 프로덕션 기본 인스턴스. SystemClock + SystemKeychain.
    public static let shared = TrialManager()

    private let clock: any AppClock
    private let storage: any KeychainStorage
    private let trialDays: Int

    public init(
        clock: any AppClock = SystemClock(),
        storage: any KeychainStorage = SystemKeychain(),
        trialDays: Int = TrialManager.trialDays
    ) {
        self.clock = clock
        self.storage = storage
        self.trialDays = trialDays
    }

    // MARK: - Instance API

    /// 체험 잔여 일수 (0 이면 만료).
    public func daysRemaining() -> Int {
        let elapsed = Calendar.current.dateComponents(
            [.day], from: firstLaunchDate(), to: clock.now()
        ).day ?? 0
        return max(0, trialDays - elapsed)
    }

    /// 첫 실행일. 저장된 값이 없으면 지금 시각을 기록하고 반환.
    public func firstLaunchDate() -> Date {
        if let saved = storage.loadFirstLaunchDate() { return saved }
        let now = clock.now()
        try? storage.saveFirstLaunchDate(now)
        return now
    }

    // MARK: - Static Backward Compatibility

    /// 정적 호환 레이어 — 기존 호출처가 `TrialManager.daysRemaining()` 으로
    /// 직접 호출하던 코드를 그대로 둘 수 있게 함.
    public static func daysRemaining() -> Int {
        shared.daysRemaining()
    }

    public static func firstLaunchDate() -> Date {
        shared.firstLaunchDate()
    }
}
