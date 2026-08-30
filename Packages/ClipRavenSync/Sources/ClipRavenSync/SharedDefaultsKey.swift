import Foundation

/// 앱 본체와 확장(키보드·공유·위젯)이 **함께** 읽는 설정 키의 단일 진실.
///
/// ## 왜 App Group 이어야 하나
/// 확장은 앱 본체의 `UserDefaults.standard` 를 볼 수 없다 — 각자 다른 컨테이너다.
/// 공유 설정은 반드시 App Group suite 에 써야 양쪽이 같은 값을 본다.
///
/// ## 왜 상수로 모으나
/// iOS 설정 화면은 `clipraven.privacy.filterSensitive` 를 `standard` 에 쓰고,
/// 확장들은 App Group 의 `blockSensitive` 를 읽고 있었다. 즉 **토글을 아무리
/// 움직여도 아무 일도 일어나지 않았다** (감사 R2 — App Store 심사 2.1
/// "미구현 기능" 에 해당). 키를 문자열 리터럴로 흩어 두면 이런 어긋남이
/// 조용히 생기고 컴파일러가 잡아주지 못한다.
///
/// macOS 전용 키는 앱 타깃의 `DefaultsKey` 에 그대로 둔다 — 여기는 **공유가
/// 필요한 키만** 모은다.
///
/// ⚠️ 이미 출시된 키의 raw 값은 변경 금지 — 사용자 설정이 초기화된다.
public enum SharedDefaultsKey {

    // MARK: - 보호 / 보안 (앱 본체 + 키보드 + 공유 확장이 읽음)

    /// 민감 데이터(비밀번호·API 키·카드번호 등) 자동 차단. 기본 true.
    public static let blockSensitive = "blockSensitive"
    /// 2단계 인증 코드 자동 필터. 기본 true. `blockSensitive` 가 켜져 있을 때만 의미.
    public static let filter2FA = "filter2FA"

    // MARK: - 피드백 (앱 본체 + 키보드가 읽음)

    /// 복사 시 햅틱. 기본 true.
    public static let hapticOnCopy = "hapticOnCopy"
    /// 붙여넣기 시 햅틱. 기본 true.
    public static let hapticOnPaste = "hapticOnPaste"
}

public extension UserDefaults {

    /// 앱 본체와 확장이 공유하는 App Group suite.
    /// suite 생성이 실패하면(엔타이틀먼트 누락 등) `.standard` 로 떨어져
    /// 최소한 앱 본체 안에서는 설정이 일관되게 동작한다.
    static let appGroup: UserDefaults =
        UserDefaults(suiteName: AppGroupDatabase.appGroupID) ?? .standard

    /// 공유 Bool 설정 읽기. 미설정이면 `default` (보호 기능은 true 가 안전).
    func sharedBool(_ key: String, default defaultValue: Bool = true) -> Bool {
        object(forKey: key) as? Bool ?? defaultValue
    }
}
