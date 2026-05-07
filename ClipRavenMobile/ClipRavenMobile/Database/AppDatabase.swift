import GRDB
import SQLite3        // SQLITE_FCNTL_PERSIST_WAL, sqlite3_file_control
import Foundation
import ClipRavenSync

/// iOS 로컬 SQLite 데이터베이스. Mac 앱과 같은 `Clip` 모델을 그대로 쓰지만
/// 마이그레이션은 iOS 전용으로 단일 통합 마이그레이션을 적용한다.
///
/// 왜 통합 마이그레이션 1개?
/// Mac은 v1→v14에 걸쳐 점진적으로 진화한 스키마를 따라간다 (v1 → v12에서 sync
/// 컬럼 추가, v13에서 sync_engine_state 추가, etc.). iOS는 legacy 데이터가
/// 없으므로 처음부터 최종 모양으로 만드는 게 단순하고 빠르다.
///
/// 컬럼 정의는 Mac과 동일해야 한다 — `Clip` 구조체가 같은 패키지에서 공유되고
/// GRDB Codable이 컬럼명/타입에 의존하기 때문.
final class AppDatabase {
    static let shared = makeShared()

    let dbPool: DatabasePool

    var databaseReader: some DatabaseReader { dbPool }
    var databaseWriter: some DatabaseWriter { dbPool }

    private init(_ dbPool: DatabasePool) throws {
        self.dbPool = dbPool
        try migrator.migrate(dbPool)
    }

    /// App Group ID — Share/Keyboard Extensions와 메인 앱이 같은 SQLite
    /// 파일을 공유. 모든 entitlements (.entitlements) 파일에 동일 ID가
    /// 등록되어 있어야 한다.
    static let appGroupID = "group.com.lumibear.ClipRavenMobile"

    private static func makeShared() -> AppDatabase {
        do {
            // App Group 컨테이너 경로. 메인 앱 + Share Extension + Keyboard
            // Extension이 모두 동일 SQLite 파일에 접근하려면 sandbox-local
            // Application Support가 아닌 App Group container를 써야 한다.
            //
            // 컨테이너가 nil이면 entitlement가 빠졌거나 provisioning profile
            // 이 App Group을 포함하지 않은 경우. Production에서는 발생하면
            // 안 되지만 dev 빌드 (App Group 미설정 상태)에서는 sandbox-local
            // 경로로 fallback 해서 메인 앱은 정상 동작하게 한다. Extension
            // 들은 DB 접근 불가이므로 "전체 접근 허용 안 됨" 같은 UX로 빠짐.
            let fileManager = FileManager.default
            let dbDir: URL
            if let groupURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            ) {
                dbDir = groupURL.appendingPathComponent("ClipRaven", isDirectory: true)
            } else {
                let appSupport = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                dbDir = appSupport.appendingPathComponent("ClipRaven", isDirectory: true)
                NSLog("⚠️ ClipRaven: App Group '\(appGroupID)' unavailable — falling back to sandbox-local DB. Extensions won't see this data.")
            }
            try fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)

            let dbURL = dbDir.appendingPathComponent("clipraven.sqlite")

            var config = Configuration()
            config.foreignKeysEnabled = true
            // 다른 프로세스가 lock 잡고 있을 때 즉시 BUSY 에러 내지 않고 최대
            // 5초까지 대기 — keyboard/widget extension 과 SQLite 공유 시 안전.
            config.busyMode = .timeout(5.0)

            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA synchronous = NORMAL")

                // ⚠️ Persistent WAL — `-wal` / `-shm` 파일이 connection close
                // 시 자동 삭제되지 않도록 함. 키보드/위젯 extension 같은
                // readonly reader 가 메인 앱 종료 후에도 정상 동작하기 위해
                // 필수. 이 설정 없으면 키보드가 stale snapshot 만 보거나
                // DB 를 못 여는 케이스 발생 (사용자 보고 2026-05-04).
                //
                // 참고: 이 옵션은 SQL PRAGMA 가 아닌 sqlite3_file_control 로
                // 만 설정 가능. read-write connection 에서만 의미 있음.
                if !db.configuration.readonly {
                    var flag: CInt = 1
                    let code = sqlite3_file_control(
                        db.sqliteConnection,
                        nil,
                        SQLITE_FCNTL_PERSIST_WAL,
                        &flag
                    )
                    if code != SQLITE_OK {
                        // 치명적이지 않음 — log 만 하고 진행
                        NSLog("⚠️ ClipRaven: SQLITE_FCNTL_PERSIST_WAL failed (code \(code))")
                    }
                }
            }

            let dbPool = try DatabasePool(path: dbURL.path, configuration: config)
            return try AppDatabase(dbPool)
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        IosMigrations.registerAll(&migrator)
        return migrator
    }
}
