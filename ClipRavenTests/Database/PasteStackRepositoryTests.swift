import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

final class PasteStackRepositoryTests: XCTestCase {
    private var testDB: TestDatabase!
    private var repo: PasteStackRepository!
    private var clipRepo: ClipRepository!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        repo = PasteStackRepository(dbPool: testDB.dbPool)
        clipRepo = ClipRepository(dbPool: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil; repo = nil; clipRepo = nil
        super.tearDown()
    }

    // pasteStack.clipId is a FOREIGN KEY → clips.id. Insert a real clip first
    // and return the generated ID so add(clipId:) satisfies the constraint.
    private func insertClip(_ text: String = "clip") throws -> Int64 {
        var clip = Clip(
            contentType: .text,
            contentText: text,
            contentHash: XXHash64Wrapper.hash(text)
        )
        try clipRepo.save(&clip)
        return clip.id!
    }

    // MARK: - add / fetchAll

    func test_add_assignsIncreasingSortOrder() throws {
        let a = try repo.add(clipId: try insertClip("a"))
        let b = try repo.add(clipId: try insertClip("b"))
        let c = try repo.add(clipId: try insertClip("c"))

        XCTAssertEqual(a.sortOrder, 0)
        XCTAssertEqual(b.sortOrder, 1)
        XCTAssertEqual(c.sortOrder, 2)
    }

    func test_fetchAll_sortedAscending() throws {
        let id1 = try insertClip("1")
        let id2 = try insertClip("2")
        let id3 = try insertClip("3")
        _ = try repo.add(clipId: id1)
        _ = try repo.add(clipId: id2)
        _ = try repo.add(clipId: id3)

        let all = try repo.fetchAll()
        XCTAssertEqual(all.map(\.clipId), [id1, id2, id3])
    }

    // MARK: - fetchNext

    func test_fetchNext_returnsOldestUnpasted() throws {
        let id1 = try insertClip("1")
        let id2 = try insertClip("2")
        _ = try repo.add(clipId: id1)
        _ = try repo.add(clipId: id2)

        XCTAssertEqual(try repo.fetchNext()?.clipId, id1)
    }

    func test_fetchNext_skipsMarkedPasted() throws {
        let id1 = try insertClip("1")
        let id2 = try insertClip("2")
        let first = try repo.add(clipId: id1)
        _ = try repo.add(clipId: id2)
        try repo.markPasted(id: first.id!)

        XCTAssertEqual(try repo.fetchNext()?.clipId, id2)
    }

    func test_fetchNext_nilWhenAllPasted() throws {
        let only = try repo.add(clipId: try insertClip("x"))
        try repo.markPasted(id: only.id!)

        XCTAssertNil(try repo.fetchNext())
    }

    // MARK: - markPasted / count / clear

    func test_count_reflectsAdds() throws {
        XCTAssertEqual(try repo.count(), 0)
        _ = try repo.add(clipId: try insertClip("a"))
        _ = try repo.add(clipId: try insertClip("b"))
        XCTAssertEqual(try repo.count(), 2)
    }

    func test_clear_removesAll() throws {
        _ = try repo.add(clipId: try insertClip("a"))
        _ = try repo.add(clipId: try insertClip("b"))
        try repo.clear()
        XCTAssertEqual(try repo.count(), 0)
    }

    // MARK: - remove (by clipId)

    func test_remove_byClipId() throws {
        let idA = try insertClip("a")
        let idB = try insertClip("b")
        _ = try repo.add(clipId: idA)
        _ = try repo.add(clipId: idB)
        try repo.remove(clipId: idA)

        let remaining = try repo.fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.clipId, idB)
    }

    // MARK: - reorder

    func test_reorder_updatesSortOrder() throws {
        let a = try repo.add(clipId: try insertClip("a"))
        _ = try repo.add(clipId: try insertClip("b"))

        try repo.reorder(id: a.id!, newOrder: 99)
        let fetched = try repo.fetchAll().first { $0.id == a.id }
        XCTAssertEqual(fetched?.sortOrder, 99)
    }
}
