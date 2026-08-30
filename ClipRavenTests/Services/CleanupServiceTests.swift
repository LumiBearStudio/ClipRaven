import XCTest
import GRDB
@testable import ClipRaven
import ClipRavenSync

/// `CleanupService` 의 4가지 정리 전략 (softDeleted/expired/aged/limit) 을 검증.
/// DI 적용된 ClipRepository + UserDefaults suite 격리.
final class CleanupServiceTests: XCTestCase {

    private var testDB: TestDatabase!
    private var clipRepository: ClipRepository!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sut: CleanupService!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        clipRepository = ClipRepository(dbPool: testDB.dbPool)
        suiteName = "CleanupServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        sut = CleanupService(
            clipRepository: clipRepository,
            defaults: defaults,
            defaultMaxClipCount: 100  // 작게
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        testDB.cleanup()
        sut = nil
        defaults = nil
        clipRepository = nil
        testDB = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func insertClip(
        text: String,
        isDeleted: Bool = false,
        isPinned: Bool = false,
        lastCopiedAt: Date = Date(),
        expiresAt: Date? = nil,
        excludeFromSync: Bool = false,
        updatedAt: Date = Date(),
        ckLastSyncedAt: Date? = nil
    ) throws -> Int64 {
        var clip = Clip(
            contentType: .text,
            contentText: text
        )
        clip.isDeleted = isDeleted
        clip.isPinned = isPinned
        clip.lastCopiedAt = lastCopiedAt
        clip.expiresAt = expiresAt
        clip.excludeFromSync = excludeFromSync
        clip.updatedAt = updatedAt
        clip.ckLastSyncedAt = ckLastSyncedAt
        let saved = try clipRepository.save(&clip)
        return try XCTUnwrap(saved.id)
    }

    private func clipCount() async throws -> Int {
        try await testDB.dbPool.read { db in
            try Clip.filter(Column("isDeleted") == false).fetchCount(db)
        }
    }

    // MARK: - 1. Soft-deleted 정리

    func test_runCleanup_removesSoftDeleted_whenExcludedFromSync() async throws {
        let id1 = try insertClip(text: "live")
        let id2 = try insertClip(text: "softdel", isDeleted: true, excludeFromSync: true)

        await sut.runCleanup()

        let remaining = try await testDB.dbPool.read { db in
            try Clip.fetchAll(db).map { $0.id }
        }
        XCTAssertTrue(remaining.contains(id1))
        XCTAssertFalse(remaining.contains(id2))
    }

    // MARK: - 2. 만료된 (expiresAt) 정리

    func test_runCleanup_removesExpired() async throws {
        let past = Date().addingTimeInterval(-3600)
        let id1 = try insertClip(text: "fresh")
        let id2 = try insertClip(text: "old", expiresAt: past)

        await sut.runCleanup()

        let ids = try await testDB.dbPool.read { db in
            try Clip.fetchAll(db).map { $0.id }
        }
        XCTAssertTrue(ids.contains(id1))
        XCTAssertFalse(ids.contains(id2))
    }

    // MARK: - 3. 보관 기간 (aged-out) 정리

    func test_runCleanup_removesAgedOut_whenMaxDaysSet() async throws {
        defaults.set(7, forKey: "maxDaysToKeep")

        let veryOld = Date().addingTimeInterval(-30 * 86400)
        let recent = Date().addingTimeInterval(-1 * 86400)

        let oldId = try insertClip(text: "old", lastCopiedAt: veryOld)
        let newId = try insertClip(text: "new", lastCopiedAt: recent)

        await sut.runCleanup()

        let ids = try await testDB.dbPool.read { db in
            try Clip.fetchAll(db).map { $0.id }
        }
        XCTAssertTrue(ids.contains(newId))
        XCTAssertFalse(ids.contains(oldId))
    }

    func test_runCleanup_pinnedClipsExcludedFromAged() async throws {
        defaults.set(7, forKey: "maxDaysToKeep")
        let veryOld = Date().addingTimeInterval(-30 * 86400)

        let pinnedOldId = try insertClip(text: "pinned old",
                                         isPinned: true,
                                         lastCopiedAt: veryOld)
        let plainOldId = try insertClip(text: "plain old", lastCopiedAt: veryOld)

        await sut.runCleanup()

        let ids = try await testDB.dbPool.read { db in
            try Clip.fetchAll(db).map { $0.id }
        }
        XCTAssertTrue(ids.contains(pinnedOldId), "고정 클립은 aged-out 에서 제외")
        XCTAssertFalse(ids.contains(plainOldId))
    }

    // MARK: - 4. maxClipCount 제한

    func test_runCleanup_enforcesMaxClipCount() async throws {
        defaults.set(3, forKey: "maxClipCount")

        // 5개 삽입
        for i in 0..<5 {
            try insertClip(
                text: "clip \(i)",
                lastCopiedAt: Date().addingTimeInterval(-Double(5 - i))
            )
        }

        await sut.runCleanup()

        let count = try await clipCount()
        XCTAssertEqual(count, 3)
    }

    func test_runCleanup_maxCountZero_usesDefault() async throws {
        // maxClipCount 미설정 → defaultMaxClipCount=100 사용
        // 100개 안 넘으면 cleanup 안 일어남
        for i in 0..<5 {
            try insertClip(text: "clip \(i)")
        }

        await sut.runCleanup()

        let count = try await clipCount()
        XCTAssertEqual(count, 5)
    }

    // MARK: - 단계 격리 (감사 D1)

    /// 한 정리 전략이 실패해도 나머지 전략은 계속 실행되어야 한다.
    ///
    /// 이전 구현은 4단계가 하나의 `do/catch` 안에 직렬로 있어서, 1단계가
    /// throw 하면 만료·보관기간·개수제한 정리가 **한 번도 실행되지 않았다**.
    /// 실제로 pasteStack FK 때문에 1단계가 영구 실패했고, 그 결과 6시간마다
    /// 같은 실패만 반복하며 DB 가 무한히 커졌다.
    ///
    /// 여기서는 cascade 없는 FK 테이블을 하나 만들어 **1단계만** 실패시키고,
    /// 2단계(만료 정리)가 그래도 수행되는지 확인한다. mock 없이 실제 SQLite
    /// 제약으로 실패를 만든다.
    func test_runCleanup_oneFailingStep_doesNotBlockOthers() async throws {
        // 1단계 대상: soft-delete 된 클립 (sync 확인됨)
        let blocked = try insertClip(
            text: "blocked",
            isDeleted: true,
            excludeFromSync: true
        )
        // 2단계 대상: 이미 만료된 클립
        try insertClip(
            text: "expired",
            expiresAt: Date().addingTimeInterval(-3600)
        )

        // cascade 가 없는 참조를 걸어 1단계 DELETE 를 실패시킨다.
        try await testDB.dbPool.write { db in
            try db.execute(sql: """
                CREATE TABLE fkBlocker (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    clipId INTEGER NOT NULL REFERENCES clips(id)
                )
            """)
            try db.execute(sql: "INSERT INTO fkBlocker (clipId) VALUES (?)", arguments: [blocked])
        }

        await sut.runCleanup()

        let remaining: [String] = try await testDB.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT contentText FROM clips ORDER BY contentText")
        }
        XCTAssertEqual(
            remaining, ["blocked"],
            "1단계는 FK 때문에 실패해 'blocked' 가 남고, 2단계는 정상 수행되어 'expired' 는 지워져야 한다"
        )
    }
}
