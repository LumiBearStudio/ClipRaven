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

    /// v15 는 테이블을 재생성한다 — 기존 스택 내용이 살아남아야 한다.
    /// (마이그레이션 자체는 TestDatabase 생성 시 이미 전부 적용됐으므로,
    ///  여기서는 재생성 후에도 스키마와 동작이 온전한지 확인한다.)
    func test_pasteStackSchema_survivesMigration_withWorkingColumns() throws {
        let a = try insertClip("a")
        let b = try insertClip("b")
        let first = try stackRepo.add(clipId: a)
        let second = try stackRepo.add(clipId: b)

        XCTAssertEqual(try stackRepo.count(), 2)
        XCTAssertLessThan(first.sortOrder, second.sortOrder, "sortOrder 컬럼이 재생성 후에도 동작해야 한다")

        try stackRepo.markPasted(id: first.id!)
        XCTAssertEqual(try stackRepo.fetchNext()?.clipId, b, "isPasted 컬럼이 재생성 후에도 동작해야 한다")
    }
}
