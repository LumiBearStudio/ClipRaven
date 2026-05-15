import GRDB
import SQLite3        // SQLITE_FCNTL_PERSIST_WAL, sqlite3_file_control
import Foundation
import ClipRavenSync

/// iOS 로컬 SQLite 데이터베이스. Mac 앱과 같은 `Clip` 모델을 그대로 쓰지만
/// 마이그레이션은 iOS 전용으로 단일 통합 마이그레이션을 적용한다.
///
/// 왜 통합 마이그레이션 1개?
/// Mac은 v1→v13에 걸쳐 점진적으로 진화한 스키마를 따라간다 (v1 초기 스키마,
/// v12 에서 sync 컬럼 추가, v13 에서 sync_engine_state 추가). iOS는 legacy
/// 데이터가 없으므로 처음부터 최종 모양으로 만드는 게 단순하고 빠르다.
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
    static let appGroupID = "63ZN5B3LHU.com.lumibear.ClipRaven"

    /// UserDefaults flag — corruption recovery 발생 시 다음 launch 에서
    /// 사용자에게 알림 띄울 수 있게 marker. UI 가 읽고 표시 후 클리어.
    static let corruptionRecoveryFlagKey = "clipraven.db.corruptionRecoveredAt"

    private static func makeShared() -> AppDatabase {
        let fileManager = FileManager.default
        let dbDir: URL
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
        } catch {
            // 컨테이너 디렉토리 생성 실패는 진짜 unrecoverable.
            fatalError("Application Support / App Group directory unavailable: \(error)")
        }

        let dbURL = dbDir.appendingPathComponent("clipraven.sqlite")

        // First attempt — 정상 경로.
        do {
            return try makeAppDatabase(at: dbURL)
        } catch {
            NSLog("⚠️ ClipRaven: first DB init attempt failed: \(error)")
            // Recovery: 손상된 sqlite + WAL/SHM 을 `.corrupted-{timestamp}`
            // 로 백업 이동 (best-effort). 빈 DB 로 재시도 → 앱이 적어도
            // 사용 가능 상태. 사용자 데이터 영구 손실은 막음.
            quarantineCorruptedDB(at: dbURL, error: error)
            UserDefaults.standard.set(
                Date(), forKey: corruptionRecoveryFlagKey
            )
        }

        // Second attempt — fresh DB.
        do {
            return try makeAppDatabase(at: dbURL)
        } catch {
            // 백업 + fresh init 도 실패하면 진짜 unrecoverable.
            fatalError("Database initialization failed after recovery attempt: \(error)")
        }
    }

    /// 손상된 DB 파일 (sqlite + wal + shm) 을 timestamp suffix 붙여 백업 이동.
    /// 실패해도 best-effort — 백업 못 살리면 그냥 새 DB 로 진행.
    private static func quarantineCorruptedDB(at dbURL: URL, error: Error) {
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffix = ".corrupted-\(ts)"
        let fm = FileManager.default
        for ext in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: dbURL.path + ext)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: dbURL.path + ext + suffix)
            do {
                try fm.moveItem(at: src, to: dst)
                NSLog("📦 ClipRaven: quarantined \(src.lastPathComponent) → \(dst.lastPathComponent)")
            } catch {
                NSLog("⚠️ ClipRaven: quarantine failed for \(src.lastPathComponent): \(error)")
            }
        }
    }

    /// 단일 DB pool 생성 + migrator 실행. 두 번 호출되므로 (정상 + recovery 후)
    /// 별도 함수로 분리.
    private static func makeAppDatabase(at dbURL: URL) throws -> AppDatabase {
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
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        IosMigrations.registerAll(&migrator)
        return migrator
    }

    // MARK: - Extension helpers
    //
    // Extension (Keyboard / Share / Widget / Intent) 용 헬퍼는 ClipRavenSync 패키지의
    // `AppGroupDatabase` 로 이전되었다. 양쪽이 같은 app group ID 와 같은 sqlite 파일
    // 경로를 사용한다. 이전엔 각 extension 이 인라인으로 같은 코드를 4번 중복 작성했고
    // busyMode / synchronous 설정이 일관되지 않았다 (아키텍처 감사 C 트랙).
}
