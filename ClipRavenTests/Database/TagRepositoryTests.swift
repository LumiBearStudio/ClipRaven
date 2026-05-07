import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

final class TagRepositoryTests: XCTestCase {
    private var testDB: TestDatabase!
    private var tagRepo: TagRepository!
    private var clipRepo: ClipRepository!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        tagRepo = TagRepository(dbPool: testDB.dbPool)
        clipRepo = ClipRepository(dbPool: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil; tagRepo = nil; clipRepo = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeClip(_ text: String) -> Clip {
        Clip(contentType: .text, contentText: text, contentHash: XXHash64Wrapper.hash(text))
    }

    private func makeTag(_ name: String, color: String = "#FF0000") -> Tag {
        Tag(name: name, colorHex: color)
    }

    // MARK: - save / fetchAll

    func test_save_assignsId() throws {
        var tag = makeTag("work")
        XCTAssertNil(tag.id)
        try tagRepo.save(&tag)
        XCTAssertNotNil(tag.id)
    }

    func test_fetchAll_ordersByName() throws {
        var z = makeTag("zeta"); try tagRepo.save(&z)
        var a = makeTag("alpha"); try tagRepo.save(&a)
        var m = makeTag("mu"); try tagRepo.save(&m)

        let names = try tagRepo.fetchAll().map { $0.name }
        XCTAssertEqual(names, ["alpha", "mu", "zeta"])
    }

    // MARK: - assignTag / removeTag

    func test_assignTag_linksClipToTag() throws {
        var clip = makeClip("hello"); try clipRepo.save(&clip)
        var tag = makeTag("work"); try tagRepo.save(&tag)

        try tagRepo.assignTag(clipId: clip.id!, tagId: tag.id!)

        let tags = try tagRepo.fetchTags(forClipId: clip.id!)
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags.first?.name, "work")
    }

    func test_assignTag_isIdempotent() throws {
        var clip = makeClip("x"); try clipRepo.save(&clip)
        var tag = makeTag("t"); try tagRepo.save(&tag)

        try tagRepo.assignTag(clipId: clip.id!, tagId: tag.id!)
        try tagRepo.assignTag(clipId: clip.id!, tagId: tag.id!)  // second call

        XCTAssertEqual(try tagRepo.fetchTags(forClipId: clip.id!).count, 1,
                       "duplicate assignTag should be ignored")
    }

    func test_removeTag_unlinksClipFromTag() throws {
        var clip = makeClip("x"); try clipRepo.save(&clip)
        var tag = makeTag("t"); try tagRepo.save(&tag)
        try tagRepo.assignTag(clipId: clip.id!, tagId: tag.id!)

        try tagRepo.removeTag(clipId: clip.id!, tagId: tag.id!)
        XCTAssertTrue(try tagRepo.fetchTags(forClipId: clip.id!).isEmpty)
    }

    // MARK: - delete cascade

    func test_delete_removesTagAndAllAssociations() throws {
        var c1 = makeClip("a"); try clipRepo.save(&c1)
        var c2 = makeClip("b"); try clipRepo.save(&c2)
        var tag = makeTag("shared"); try tagRepo.save(&tag)
        try tagRepo.assignTag(clipId: c1.id!, tagId: tag.id!)
        try tagRepo.assignTag(clipId: c2.id!, tagId: tag.id!)

        try tagRepo.delete(id: tag.id!)

        XCTAssertEqual(try tagRepo.fetchAll().count, 0)
        XCTAssertTrue(try tagRepo.fetchTags(forClipId: c1.id!).isEmpty)
        XCTAssertTrue(try tagRepo.fetchTags(forClipId: c2.id!).isEmpty)
    }

    // MARK: - clipCount

    func test_clipCount_returnsOnlyNonDeletedClips() throws {
        var tag = makeTag("t"); try tagRepo.save(&tag)
        var a = makeClip("a"); try clipRepo.save(&a)
        var b = makeClip("b"); try clipRepo.save(&b)
        try tagRepo.assignTag(clipId: a.id!, tagId: tag.id!)
        try tagRepo.assignTag(clipId: b.id!, tagId: tag.id!)

        XCTAssertEqual(try tagRepo.clipCount(forTagId: tag.id!), 2)

        try clipRepo.softDelete(id: a.id!)
        XCTAssertEqual(try tagRepo.clipCount(forTagId: tag.id!), 1,
                       "soft-deleted clip should not count")
    }

    // MARK: - fetchClipIds

    func test_fetchClipIds_returnsClipsHavingAnyOfTags() throws {
        var ta = makeTag("a"); try tagRepo.save(&ta)
        var tb = makeTag("b"); try tagRepo.save(&tb)

        var c1 = makeClip("1"); try clipRepo.save(&c1)
        var c2 = makeClip("2"); try clipRepo.save(&c2)
        var c3 = makeClip("3"); try clipRepo.save(&c3)

        try tagRepo.assignTag(clipId: c1.id!, tagId: ta.id!)
        try tagRepo.assignTag(clipId: c2.id!, tagId: tb.id!)
        // c3: no tag

        let ids = Set(try tagRepo.fetchClipIds(forTagIds: [ta.id!, tb.id!]))
        XCTAssertEqual(ids, Set([c1.id!, c2.id!]))
    }
}
