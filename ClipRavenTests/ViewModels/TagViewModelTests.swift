import XCTest
import GRDB
@testable import ClipRaven
import ClipRavenSync

/// `TagViewModel` 은 `TagRepository` 를 DI 받아 태그 CRUD + 클립별 할당 관리한다.
/// `TestDatabase` 로 격리된 SQLite 를 띄우고 Repository 를 주입해 검증한다.
@MainActor
final class TagViewModelTests: XCTestCase {

    private var testDB: TestDatabase!
    private var tagRepository: TagRepository!
    private var clipRepository: ClipRepository!
    private var vm: TagViewModel!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        tagRepository = TagRepository(dbPool: testDB.dbPool)
        clipRepository = ClipRepository(dbPool: testDB.dbPool)
        vm = TagViewModel(tagRepository: tagRepository)
    }

    override func tearDownWithError() throws {
        testDB.cleanup()
        testDB = nil
        tagRepository = nil
        clipRepository = nil
        vm = nil
    }

    // MARK: - Helpers

    /// 테스트용 클립을 DB에 저장하고 id 반환.
    private func insertTestClip() throws -> Int64 {
        var clip = Clip(
            contentType: .text,
            contentText: "test"
        )
        let saved = try clipRepository.save(&clip)
        return try XCTUnwrap(saved.id)
    }

    /// 테스트용 태그를 DB에 저장하고 반환.
    private func insertTag(name: String, color: String = "#FF0000") throws -> Tag {
        var tag = Tag(name: name, colorHex: color)
        _ = try tagRepository.save(&tag)
        return tag
    }

    // MARK: - createTag

    func test_createTag_appendsToAllTags() {
        XCTAssertTrue(vm.allTags.isEmpty)
        vm.createTag(name: "Work", colorHex: "#FF0000")
        XCTAssertEqual(vm.allTags.count, 1)
        XCTAssertEqual(vm.allTags.first?.name, "Work")
    }

    // MARK: - loadTags

    func test_loadTags_assignedTagIdsReflectsRepository() throws {
        let clipId = try insertTestClip()
        let tag = try insertTag(name: "Pinned")
        let tagId = try XCTUnwrap(tag.id)
        try tagRepository.assignTag(clipId: clipId, tagId: tagId)

        vm.loadTags(forClipId: clipId)

        XCTAssertEqual(vm.allTags.count, 1)
        XCTAssertTrue(vm.assignedTagIds.contains(tagId))
    }

    // MARK: - toggleTag

    func test_toggleTag_assignsWhenNotPresent() throws {
        let clipId = try insertTestClip()
        let tag = try insertTag(name: "Idea")
        let tagId = try XCTUnwrap(tag.id)
        vm.loadTags(forClipId: clipId)

        vm.toggleTag(tag, forClipId: clipId)

        XCTAssertTrue(vm.assignedTagIds.contains(tagId))
        let fetched = try tagRepository.fetchTags(forClipId: clipId)
        XCTAssertEqual(fetched.count, 1)
    }

    func test_toggleTag_removesWhenAlreadyAssigned() throws {
        let clipId = try insertTestClip()
        let tag = try insertTag(name: "Temp")
        let tagId = try XCTUnwrap(tag.id)
        try tagRepository.assignTag(clipId: clipId, tagId: tagId)
        vm.loadTags(forClipId: clipId)
        XCTAssertTrue(vm.assignedTagIds.contains(tagId))

        vm.toggleTag(tag, forClipId: clipId)

        XCTAssertFalse(vm.assignedTagIds.contains(tagId))
        let fetched = try tagRepository.fetchTags(forClipId: clipId)
        XCTAssertTrue(fetched.isEmpty)
    }

    // MARK: - deleteTag

    func test_deleteTag_removesFromAllTags() throws {
        let tag = try insertTag(name: "ToDelete")
        vm.createTag(name: "Keep", colorHex: "#00FF00") // populate allTags via vm path

        vm.deleteTag(tag)

        let names = vm.allTags.map(\.name)
        XCTAssertFalse(names.contains("ToDelete"))
        XCTAssertTrue(names.contains("Keep"))
    }
}
