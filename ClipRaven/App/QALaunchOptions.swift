#if QA
import Foundation
import ClipRavenSync

/// QA 빌드 전용 실행 옵션 (테스트 계획 0단계 E3). 빌드 구성 `Debug-QA` 의 컴파일 플래그
/// `QA` 가 있을 때만 컴파일된다.
///
/// 실행 인자로 준다 (`UserDefaults` 인자 도메인이라 저장되지 않는다):
/// - `-qaReset YES` — 시작 전에 QA 컨테이너의 기록 DB·이미지·설정·체험 상태를
///   지워 첫 실행 상태로 만든다.
/// - `-qaStartTrial YES` — 체험을 지금 시작한 것으로 기록한다(온보딩을 거치지 않고).
///   시작일은 실제 현재 시각이라 `-qaTrialOffsetDays` 와 함께 주면 바로 만료된다.
/// - `-qaTrialOffsetDays 16` — 체험 경과일을 앞당긴다. 공용 패키지의 `QARuntime`
///   이 처리한다.
/// - 온보딩 건너뛰기는 기존 설정 키를 인자로 준다: `-hasCompletedOnboarding YES`.
///
/// 사용법은 `Scripts/qa/README.md`.
enum QALaunchOptions {

    /// 다른 코드가 DB·설정을 읽기 전에 불러야 한다 (`applicationWillFinishLaunching`).
    static func applyBeforeLaunch() {
        // 번들 ID 가 `.qa` 로 끝나지 않으면 아무것도 하지 않는다. QA 플래그가 실수로
        // 다른 구성에 붙더라도 실제 사용자 데이터를 지우지 않게 하는 이중 안전장치다.
        guard QARuntime.isQABuild else { return }
        if UserDefaults.standard.bool(forKey: "qaReset") {
            reset()
        }
        if UserDefaults.standard.bool(forKey: "qaStartTrial") {
            startTrialNow()
        }
    }

    /// `TrialManager.shared` 는 QA 시계(오프셋 적용)로 시작일을 기록하므로, 실제
    /// 현재 시각을 저장소에 직접 쓴다. 이미 시작했으면 그대로 둔다.
    private static func startTrialNow() {
        let storage = AppGroupStorage(groupIdentifier: TrialManager.trialAppGroup)
        guard storage.loadFirstLaunchDate() == nil else { return }
        try? storage.saveFirstLaunchDate(Date())
    }

    private static func reset() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: AppRuntime.dataDirectory)

        // 체험 시작일(`trial.dat`)과 공유 설정은 QA 전용 App Group 에 있다.
        let group = AppGroupDatabase.appGroupID
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) {
            try? fileManager.removeItem(at: container.appendingPathComponent("trial.dat"))
        }
        UserDefaults(suiteName: group)?.removePersistentDomain(forName: group)

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}
#endif
