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

    private static func makeShared() -> AppDatabase {
        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("ClipRaven", isDirectory: true)

            try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

            let dbURL = appSupportURL.appendingPathComponent("clipraven.sqlite")

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
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        DatabaseMigrations.registerAll(&migrator)
        return migrator
    }
}
