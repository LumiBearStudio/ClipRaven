import GRDB
import SQLite3
import Foundation

final class AppDatabase {
    static let shared = makeShared()

    let dbPool: DatabasePool

    var databaseReader: some DatabaseReader { dbPool }
    var databaseWriter: some DatabaseWriter { dbPool }

    private init(_ dbPool: DatabasePool) throws {
        self.dbPool = dbPool
        try migrator.migrate(dbPool)
    }

    /// UserDefaults flag — corruption recovery 발생 시 다음 앱 launch 에서
    /// 사용자에게 알림 띄울 수 있게 marker 저장. UI 가 읽고 표시 후 클리어.
    static let corruptionRecoveryFlagKey = "clipraven.db.corruptionRecoveredAt"

    private static func makeShared() -> AppDatabase {
        let fileManager = FileManager.default
        let appSupportURL: URL
        do {
            appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("ClipRaven", isDirectory: true)
            try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        } catch {
            // Application Support 디렉토리 생성도 실패하는 케이스는 진짜
            // unrecoverable — 디스크 공간 부족, 권한 없음, 디스크 손상 등.
            fatalError("Application Support directory unavailable: \(error)")
        }

        let dbURL = appSupportURL.appendingPathComponent("clipraven.sqlite")

        // First attempt — 정상 경로.
        do {
            return try makeAppDatabase(at: dbURL)
        } catch {
            NSLog("⚠️ ClipRaven: first DB init attempt failed: \(error)")
            // Recovery: 손상된 sqlite 파일 + WAL/SHM 을 `.corrupted-{timestamp}`
            // 로 백업 이동. 사용자 데이터가 영구 손실되지 않도록 보관 (Finder 로
            // 사용자가 직접 옮기거나 우리가 제공할 future recovery 도구로 살림).
            // 이후 빈 DB 로 재시도 → 사용자는 적어도 앱은 사용 가능한 상태.
            quarantineCorruptedDB(at: dbURL, error: error)
            UserDefaults.standard.set(
                Date(), forKey: corruptionRecoveryFlagKey
            )
        }

        // Second attempt — fresh DB.
        do {
            return try makeAppDatabase(at: dbURL)
        } catch {
            // 백업 + fresh init 도 실패하면 진짜 unrecoverable. fatalError 마지막.
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
                // best-effort — 백업 실패 시 그냥 src 그대로 두고 진행.
                // 두 번째 makeAppDatabase 시도가 또 실패하면 fatalError 로 종료.
            }
        }
    }

    /// 단일 DB pool 생성 + migrator 실행. 두 번 호출되므로 (정상 + recovery 후)
    /// 별도 함수로 분리.
    private static func makeAppDatabase(at dbURL: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // 다른 connection 이 lock 잡고 있을 때 즉시 BUSY 내지 않고 5초 대기.
        // 향후 Mac widget extension 이 같은 DB 공유 시 안전망.
        config.busyMode = .timeout(5.0)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")

            // Persistent WAL — `-wal`/`-shm` 파일을 connection close 시
            // 자동 삭제하지 않도록. iOS 버전에서 keyboard/widget extension
            // 이 readonly reader 로 정상 동작하기 위한 필수 설정.
            // Mac 도 동일 코드 — 향후 Mac widget extension 이 같은 DB
            // 접근 시 즉시 호환되는 safety net.
            if !db.configuration.readonly {
                var flag: CInt = 1
                let code = sqlite3_file_control(
                    db.sqliteConnection,
                    nil,
                    SQLITE_FCNTL_PERSIST_WAL,
                    &flag
                )
                if code != SQLITE_OK {
                    NSLog("⚠️ ClipRaven: SQLITE_FCNTL_PERSIST_WAL failed (code \(code))")
                }
            }
        }

        let dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        return try AppDatabase(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        DatabaseMigrations.registerAll(&migrator)
        return migrator
    }
}
