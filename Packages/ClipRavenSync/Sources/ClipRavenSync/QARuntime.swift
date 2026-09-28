import Foundation

/// QA 빌드 전용 동작의 스위치 (테스트 계획 0단계).
///
/// QA 빌드는 번들 ID 가 `.qa` 로 끝난다(`com.lumibear.ClipRaven.qa`). App Store·
/// TestFlight 빌드의 번들 ID 는 `.qa` 로 끝나지 않으므로 배포판에서는 여기 있는
/// 분기가 모두 꺼져 있다. QA 빌드가 개발용 앱과 같은 체험 상태·공유 설정을 쓰지
/// 않게 하고, 시스템 날짜를 바꾸지 않고도 체험 만료를 재현하게 한다.
public enum QARuntime {

    public static let isQABuild: Bool =
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".qa")

    /// 체험 경과일을 앞당기는 초 단위 오프셋. 실행 인자 `-qaTrialOffsetDays N`.
    ///
    /// 음수는 0 으로 본다 — 만료를 앞당길 수만 있고 체험을 늘릴 수는 없다.
    public static var trialClockOffset: TimeInterval {
        guard isQABuild else { return 0 }
        let days = UserDefaults.standard.double(forKey: "qaTrialOffsetDays")
        return max(0, days) * 86_400
    }
}

/// `QARuntime.trialClockOffset` 만큼 앞선 시각을 돌려주는 시계.
struct QAOffsetClock: AppClock {
    func now() -> Date { Date().addingTimeInterval(QARuntime.trialClockOffset) }
}
