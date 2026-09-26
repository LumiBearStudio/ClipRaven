import AppKit
import GRDB
import SQLite3
import Foundation
import ClipRavenSync

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

        // 실패 원인에 따라 다르게 처리한다 (v1 리뷰 M5, `DatabaseOpenRecovery` 문서).
        // 이전에는 어떤 오류든 손상으로 보고 히스토리를 격리한 뒤 빈 DB 로 시작했다 —
        // 잠금 대기(BUSY)나 GRDB 의 전역 FK 검사 실패처럼 파일이 멀쩡한 경우에도.
        var retries = 0
        while true {
            do {
                return try makeAppDatabase(at: dbURL)
            } catch {
                let action = DatabaseOpenRecovery.action(for: error) {
                    DatabaseOpenRecovery.quickCheck(at: dbURL)
                }
                NSLog("⚠️ ClipRaven: DB open failed (\(action)): \(error)")
                switch action {
                case .retry where retries < 2:
                    // 다른 프로세스(막 종료 중인 이전 인스턴스 등)가 잠금을 쥐고 있다.
                    retries += 1
                    Thread.sleep(forTimeInterval: Double(retries))
                case .quarantine:
                    // 손상이 확인됐다 — 원본을 보관하고 새로 시작한다.
                    guard let folder = DatabaseOpenRecovery.quarantine(databaseAt: dbURL) else {
                        // 본 파일을 옮기지 못했는데 새 DB 를 만들면 남은 -wal 이 재생될 수 있다.
                        abortLaunch(error)
                    }
                    UserDefaults.standard.set(Date(), forKey: corruptionRecoveryFlagKey)
                    UserDefaults.standard.set(folder.path, forKey: quarantineFolderKey)
                    do { return try makeAppDatabase(at: dbURL) } catch { abortLaunch(error) }
                default:
                    abortLaunch(error)
                }
            }
        }
    }

    /// 격리한 파일이 있는 폴더 경로 (복구 안내에서 "Finder 에서 보기" 에 쓴다).
    static let quarantineFolderKey = "clipraven.db.quarantineFolder"

    /// 데이터를 건드리지 않고 사용자에게 알린 뒤 종료한다.
    ///
    /// 빈 DB 로 조용히 시작하는 것보다 낫다 — 기록은 디스크에 그대로 있고, 원인
    /// (디스크 부족, 권한, 마이그레이션 문제)이 해결되면 다음 실행에서 그대로 열린다.
    private static func abortLaunch(_ error: Error) -> Never {
        NSLog("⛔️ ClipRaven: cannot open the history database: \(error)")
        if Thread.isMainThread {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "기록 데이터베이스를 열 수 없습니다")
            alert.informativeText = String(localized: "기존 기록은 삭제되지 않고 그대로 있습니다. 디스크 공간을 확인한 뒤 ClipRaven을 다시 실행해 주세요. 문제가 계속되면 지원 페이지로 알려 주세요.")
                + "\n\n" + String(describing: error)
            alert.addButton(withTitle: String(localized: "종료"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        exit(1)
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
