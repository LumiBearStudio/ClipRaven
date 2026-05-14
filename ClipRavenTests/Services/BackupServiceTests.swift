import XCTest
import GRDB
@testable import ClipRaven
import ClipRavenSync

/// `BackupService` 의 export → import round-trip 검증.
/// internal init 로 격리된 dbPool + 임시 images directory 주입.
final class BackupServiceTests: XCTestCase {

    private var testDB: TestDatabase!
    private var clipRepository: ClipRepository!
    private var tagRepository: TagRepository!
    private var smartRuleRepository: SmartRuleRepository!
    private var tempImagesDir: URL!
    private var sut: BackupService!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        clipRepository = ClipRepository(dbPool: testDB.dbPool)
        tagRepository = TagRepository(dbPool: testDB.dbPool)
        smartRuleRepository = SmartRuleRepository(dbPool: testDB.dbPool)

        tempImagesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempImagesDir,
            withIntermediateDirectories: true
        )

        sut = BackupService(
            clipRepository: clipRepository,
            tagRepository: tagRepository,
            smartRuleRepository: smartRuleRepository,
            dbPool: testDB.dbPool,
            imagesDirectory: tempImagesDir
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempImagesDir)
        testDB.cleanup()
        sut = nil
        clipRepository = nil
        tagRepository = nil
        smartRuleRepository = nil
        tempImagesDir = nil
        testDB = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func insertClip(text: String) throws -> Clip {
        var clip = Clip(contentType: .text, contentText: text)
        return try clipRepository.save(&clip)
    }

    @discardableResult
    private func insertTag(name: String) throws -> Tag {
        var tag = Tag(name: name, colorHex: "#FF0000")
        _ = try tagRepository.save(&tag)
        return tag
    }

    private func makeBackupURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString).zip")
    }

    // MARK: - Export

    func test_exportBackup_createsZipFile() throws {
        try insertClip(text: "first")
        try insertClip(text: "second")

        let backupURL = makeBackupURL()
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let count = try sut.exportBackup(to: backupURL)

        XCTAssertEqual(count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func test_exportBackup_emptyDB_returnsZero() throws {
        let backupURL = makeBackupURL()
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let count = try sut.exportBackup(to: backupURL)

        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    // MARK: - Round-trip

    func test_exportThenImport_overwrite_restoresAllClips() throws {
        let c1 = try insertClip(text: "alpha")
        let c2 = try insertClip(text: "beta")

        let backupURL = makeBackupURL()
        defer { try? FileManager.default.removeItem(at: backupURL) }
        try sut.exportBackup(to: backupURL)

        // 새 DB 로 import — overwrite 전략은 DB 비우고 복원
        let newDB = try TestDatabase()
        defer { newDB.cleanup() }
        let newRepo = ClipRepository(dbPool: newDB.dbPool)
        let newTagRepo = TagRepository(dbPool: newDB.dbPool)
        let newRuleRepo = SmartRuleRepository(dbPool: newDB.dbPool)
        let importer = BackupService(
            clipRepository: newRepo,
            tagRepository: newTagRepo,
            smartRuleRepository: newRuleRepo,
            dbPool: newDB.dbPool,
            imagesDirectory: tempImagesDir
        )

        let result = try importer.importBackup(from: backupURL, strategy: .overwrite)

        XCTAssertEqual(result.clipsImported, 2)
        XCTAssertEqual(result.clipsSkipped, 0)

        let restored = try newDB.dbPool.read { db in
            try Clip.fetchAll(db).compactMap { $0.contentText }.sorted()
        }
        XCTAssertEqual(restored, [c1.contentText!, c2.contentText!].sorted())
    }

    func test_exportThenImport_merge_skipsDuplicateClips() throws {
        try insertClip(text: "duplicate me")

        let backupURL = makeBackupURL()
        defer { try? FileManager.default.removeItem(at: backupURL) }
        try sut.exportBackup(to: backupURL)

        // 같은 DB 에 다시 import (merge) → contentHash 또는 contentText 매칭으로 skip
        let result = try sut.importBackup(from: backupURL, strategy: .merge)

        XCTAssertEqual(result.clipsImported, 0)
        XCTAssertEqual(result.clipsSkipped, 1)
    }

    func test_exportThenImport_merge_skipsDuplicateTags() throws {
        try insertTag(name: "Work")

        let backupURL = makeBackupURL()
        defer { try? FileManager.default.removeItem(at: backupURL) }
        try sut.exportBackup(to: backupURL)

        let result = try sut.importBackup(from: backupURL, strategy: .merge)

        XCTAssertEqual(result.tagsImported, 0)
        XCTAssertEqual(result.tagsSkipped, 1)
    }

    func test_exportThenImport_overwrite_clearsExistingClips() throws {
        // 1) 백업 만들기 — 클립 A 하나
        try insertClip(text: "A")
        let backupURL = makeBackupURL()
        defer { try? FileManager.default.removeItem(at: backupURL) }
        try sut.exportBackup(to: backupURL)

        // 2) DB 에 다른 클립 B 추가
        try insertClip(text: "B")

        // 3) overwrite import → B 사라지고 A 만 남아야 함
        let result = try sut.importBackup(from: backupURL, strategy: .overwrite)

        XCTAssertEqual(result.clipsImported, 1)
        let remaining = try testDB.dbPool.read { db in
            try Clip.fetchAll(db).compactMap { $0.contentText }
        }
        XCTAssertEqual(remaining, ["A"])
    }
}
