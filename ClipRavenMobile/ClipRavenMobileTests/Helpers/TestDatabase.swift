import Foundation
import GRDB
@testable import ClipRavenMobile

/// iOS 테스트용 격리 SQLite DB. 임시 파일에 IosMigrations 전체를 적용.
/// `cleanup()` 으로 정리.
final class TestDatabase {
    let dbPool: DatabasePool
    private let dbURL: URL

    init() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipRavenMobileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.dbURL = tempDir.appendingPathComponent("test.sqlite")

        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbPool = try DatabasePool(path: dbURL.path, configuration: config)

        var migrator = DatabaseMigrator()
        IosMigrations.registerAll(&migrator)
        try migrator.migrate(dbPool)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }
}
