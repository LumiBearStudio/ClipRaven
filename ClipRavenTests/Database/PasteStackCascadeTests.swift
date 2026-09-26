import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

/// `pasteStack` → `clips` 외래키가 클립 삭제를 막지 않는지 검증 (감사 D1).
///
/// 회귀 배경: v1 스키마에서 `pasteStack.clipId` 가 `ON DELETE` 절 없이
/// `clips` 를 참조했고 (`clipTags` 는 cascade 가 있었다), production 은
/// `foreignKeysEnabled = true` 로 동작한다. 그래서 페이스트 스택에 한 번이라도
/// 담겼던 클립을 hard-delete 하려는 **모든** 경로가
/// `FOREIGN KEY constraint failed` 로 throw 했다:
///
/// - `CleanupService` 의 정리 4단계 (하나의 do/catch 라 첫 단계 실패 시 전부 중단)
/// - 백업 `.overwrite` 복원의 `DELETE FROM clips`
/// - iCloud 에서 내려온 삭제 적용 (트랜잭션 롤백 → 그 배치 전체 유실)
///
/// 스택 행은 `markPasted` 후에도 남고 삭제 경로 어디에도 정리 코드가 없어서,
/// 한 번 담긴 클립은 영구적으로 "지울 수 없는" 상태가 됐다.
final class PasteStackCascadeTests: XCTestCase {

    private var testDB: TestDatabase!
    private var clipRepo: ClipRepository!
    private var stackRepo: PasteStackRepository!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        clipRepo = ClipRepository(dbPool: testDB.dbPool)
        stackRepo = PasteStackRepository(dbPool: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil; clipRepo = nil; stackRepo = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func insertClip(_ text: String, isDeleted: Bool = false) throws -> Int64 {
        var clip = Clip(
            contentType: .text,
            contentText: text,
            contentHash: XXHash64Wrapper.hash(text)
        )
        clip.isDeleted = isDeleted
        try clipRepo.save(&clip)
        return clip.id!
    }

    /// 외래키가 실제로 켜져 있는지 — 이 테스트들의 전제.
    func test_foreignKeysAreEnabled() throws {
        let enabled = try testDB.dbPool.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(enabled, true, "production 과 동일하게 FK 가 켜져 있어야 이 회귀를 재현할 수 있다")
    }

    // MARK: - 스택에 담긴 클립 삭제

    func test_deleteSoftDeleted_succeeds_whenClipIsInPasteStack() throws {
        let id = try insertClip("stacked", isDeleted: true)
        _ = try stackRepo.add(clipId: id)

        // 회귀 전에는 여기서 FOREIGN KEY constraint failed 로 throw 했다.
        let removed = try clipRepo.deleteSoftDeleted()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try clipRepo.count(), 0)
        XCTAssertEqual(try stackRepo.count(), 0, "cascade 로 스택 행도 함께 사라져야 한다")
    }

    func test_deleteExpired_succeeds_whenClipIsInPasteStack() throws {
        var clip = Clip(
            contentType: .text,
            contentText: "expiring",
            contentHash: XXHash64Wrapper.hash("expiring")
        )
        clip.expiresAt = Date().addingTimeInterval(-60)
        try clipRepo.save(&clip)
        _ = try stackRepo.add(clipId: clip.id!)

        let removed = try clipRepo.deleteExpired()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try stackRepo.count(), 0)
    }

    func test_hardDelete_succeeds_whenClipIsInPasteStack() throws {
        let id = try insertClip("stacked")
        _ = try stackRepo.add(clipId: id)

        try clipRepo.hardDelete(id: id)

        XCTAssertEqual(try clipRepo.count(), 0)
        XCTAssertEqual(try stackRepo.count(), 0)
    }

    /// `markPasted` 로 소비 표시만 된 행도 여전히 FK 참조를 들고 있다 —
    /// 실사용에서 가장 흔한 상태(스택을 쓰고 비우지 않은 채 둔 경우).
    func test_delete_succeeds_whenStackItemAlreadyPasted() throws {
        let id = try insertClip("pasted", isDeleted: true)
        let item = try stackRepo.add(clipId: id)
        try stackRepo.markPasted(id: item.id!)

        let removed = try clipRepo.deleteSoftDeleted()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try stackRepo.count(), 0)
    }

    /// 스택에 없는 클립을 지울 때 스택의 **다른** 항목이 말려 들어가면 안 된다.
    func test_deletingUnstackedClip_leavesOtherStackItemsIntact() throws {
        let stacked = try insertClip("keep-me")
        _ = try stackRepo.add(clipId: stacked)

        let orphan = try insertClip("delete-me", isDeleted: true)

        let removed = try clipRepo.deleteSoftDeleted()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try stackRepo.count(), 1, "무관한 클립 삭제가 스택을 건드리면 안 된다")
        XCTAssertEqual(try stackRepo.fetchAll().first?.clipId, stacked)
        XCTAssertNotEqual(try stackRepo.fetchAll().first?.clipId, orphan)
    }

    // MARK: - 마이그레이션 데이터 보존

    /// **v14 에서 만들어진 기존 데이터**가 v15 테이블 재생성을 거쳐 살아남는지.
    ///
    /// 개발 머신과 TestFlight 사용자 DB 는 v14 스키마에 실제 데이터를 담은 채
    /// v15 를 맞는다. v15 는 테이블을 DROP 후 재생성하므로, 여기서 행이 빠지거나
    /// 컬럼 값이 어긋나면 조용한 데이터 손실이다. 마이그레이션을 v14 까지만 적용한
    /// DB 를 직접 만들어 그 상태에서 v15 를 올린다.
    func test_v15_preservesExistingPasteStackRows_andEnablesCascade() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipRavenTests-v15-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path, configuration: config)

        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(&migrator)

        // 1) v14 까지만 — pasteStack 은 아직 cascade 없는 v1 정의
        try migrator.migrate(pool, upTo: "v14_userIntentTimestamps")
        let fkBefore = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT on_delete FROM pragma_foreign_key_list('pasteStack')")
        }
        XCTAssertEqual(fkBefore, "NO ACTION", "전제: v14 에서는 cascade 가 없어야 이 테스트가 의미 있다")

        // 2) v14 상태에서 실데이터 생성 — 소비 표시된 행 포함
        let clips = ClipRepository(dbPool: pool)
        let stack = PasteStackRepository(dbPool: pool)
        func insert(_ text: String) throws -> Int64 {
            var clip = Clip(contentType: .text, contentText: text, contentHash: XXHash64Wrapper.hash(text))
            try clips.save(&clip)
            return clip.id!
        }
        let a = try insert("a"), b = try insert("b"), c = try insert("c")
        let itemA = try stack.add(clipId: a)
        let itemB = try stack.add(clipId: b)
        let itemC = try stack.add(clipId: c)
        try stack.markPasted(id: itemA.id!)

        struct Snapshot: Equatable { let id: Int64; let clipId: Int64; let sortOrder: Int; let isPasted: Bool }
        func snapshot() throws -> [Snapshot] {
            try pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, clipId, sortOrder, isPasted FROM pasteStack ORDER BY id")
                    .map { Snapshot(id: $0["id"], clipId: $0["clipId"], sortOrder: $0["sortOrder"], isPasted: $0["isPasted"]) }
            }
        }
        let before = try snapshot()
        XCTAssertEqual(before.count, 3)

        // 3) v15 적용
        try migrator.migrate(pool)

        // 행·컬럼 값이 그대로여야 한다
        XCTAssertEqual(try snapshot(), before, "v15 재생성 후 기존 행이 한 글자도 달라지면 안 된다")

        // FK 가 cascade 로 바뀌었고 DB 전체에 위반이 없어야 한다
        let fkAfter = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT on_delete FROM pragma_foreign_key_list('pasteStack')")
        }
        XCTAssertEqual(fkAfter, "CASCADE")
        let violations = try pool.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }
        XCTAssertTrue(violations.isEmpty, "마이그레이션 후 FK 위반이 없어야 한다")

        // 실제 동작: 스택에 담긴 클립 삭제가 성공하고 해당 행만 사라진다
        try clips.hardDelete(id: b)
        XCTAssertEqual(try snapshot().map(\.id), [itemA.id!, itemC.id!])

        // 재생성 후에도 새 항목 추가가 정상 동작 (sortOrder 는 기존 최대값 다음)
        let d = try insert("d")
        let itemD = try stack.add(clipId: d)
        XCTAssertGreaterThan(itemD.sortOrder, itemC.sortOrder)
    }
}
