import Foundation

/// 앱이 어떤 환경에서 실행 중인지와, 그에 따른 데이터 위치.
///
/// 테스트와 QA 빌드가 실제 사용자 데이터에 닿지 않게 하는 분기를 여기 모은다
/// (테스트 계획 0단계).
enum AppRuntime {

    /// 단위 테스트 호스트로 떠 있는가 (`xcodebuild test`, Xcode ⌘U).
    ///
    /// 테스트 번들은 앱을 호스트로 띄운다. 이 판정이 없던 때에는 테스트를 돌릴
    /// 때마다 앱이 통째로 실행됐다 — 실제 기록 DB 를 열고, 클립보드 감시와 정리
    /// 작업을 시작하고, 실행 중인 다른 ClipRaven 에 종료 요청을 보냈다(샌드박스가
    /// 거부해 실패, 테스트 계획 T1).
    static let isRunningUnitTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    /// 기록 DB 와 이미지 원본을 두는 폴더.
    ///
    /// 평소에는 샌드박스 컨테이너의 `Application Support/ClipRaven`. 단위 테스트
    /// 중에는 프로세스마다 새 임시 폴더라서, 기본값으로 `AppDatabase.shared` 를
    /// 여는 테스트도 실제 기록이나 QA 빌드의 기록을 건드리지 않는다.
    static let dataDirectory: URL = {
        let fileManager = FileManager.default
        if isRunningUnitTests {
            return fileManager.temporaryDirectory.appendingPathComponent(
                "ClipRavenTests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClipRaven", isDirectory: true)
    }()
}
