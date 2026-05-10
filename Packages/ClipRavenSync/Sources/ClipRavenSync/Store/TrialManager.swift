import Foundation
import Security

/// 첫 실행일을 Keychain 에 저장하고 체험 잔여 일수를 계산한다.
///
/// Keychain 은 앱 삭제 후에도 데이터가 남아(iOS) 체험 기간 재사용을 막는다.
/// Mac 샌드박스 환경에서도 동일하게 동작한다.
public enum TrialManager {

    public static let trialDays = 15

    private static let service = "com.lumibear.clipraven.trial"
    private static let account = "firstLaunchDate"

    // MARK: - Public

    /// 체험 잔여 일수 (0 이면 만료).
    public static func daysRemaining() -> Int {
        let elapsed = Calendar.current.dateComponents(
            [.day], from: firstLaunchDate(), to: Date()
        ).day ?? 0
        return max(0, trialDays - elapsed)
    }

    /// 첫 실행일. 키체인에 없으면 지금 날짜를 기록하고 반환.
    public static func firstLaunchDate() -> Date {
        if let saved = load() { return saved }
        let now = Date()
        save(now)
        return now
    }

    // MARK: - Keychain

    private static func save(_ date: Date) {
        let data = withUnsafeBytes(of: date.timeIntervalSince1970) { Data($0) }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData:   data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func load() -> Date? {
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
