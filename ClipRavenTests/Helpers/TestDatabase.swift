import Foundation
import GRDB
@testable import ClipRaven

/// Creates a throwaway DatabasePool backed by a temp file and runs all
/// migrations, then returns it for use by Repository tests.
///
/// Each test gets a fresh DB by creating a new instance. The temp file is
/// removed when `cleanup()` is called (typically in `tearDown()`).
final class TestDatabase {
    let dbPool: DatabasePool
    private let dbURL: URL

    init() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipRavenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.dbURL = tempDir.appendingPathComponent("test.sqlite")

        var config = Configuration()
        config.foreignKeysEnabled = true

        self.dbPool = try DatabasePool(path: dbURL.path, configuration: config)

        // Run all production migrations against the fresh DB.
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(&migrator)
        try migrator.migrate(dbPool)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }
}
