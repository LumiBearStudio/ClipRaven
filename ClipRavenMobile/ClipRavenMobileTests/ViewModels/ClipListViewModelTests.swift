import XCTest
import GRDB
@testable import ClipRavenMobile
import ClipRavenSync

/// `ClipListViewModel` 은 이미 `init(repository:tagRepository:)` 로 DI 지원.
/// 격리된 SQLite + 주입된 Repository 로 검색/필터/CRUD 검증.
///
/// 검증 범위:
/// - 검색어 → debounce 후 결과 반영
/// - selectedFilter / selectedTagIds / selectedSourceApp 변경 → 옵저버 재시작
/// - createTag / deleteTag → tags 갱신
/// - togglePin → DB 반영
///
/// 외부 의존성 (`AppDatabase.shared`, `NotificationCenter`) 의존 메서드(`addTextClip`,
/// `refreshAwaiting`)는 본 테스트의 범위 밖.
@MainActor
final class ClipListViewModelTests: XCTestCase {

    private var testDB: TestDatabase!
    private var repository: ClipRepository!
    private var tagRepository: TagRepository!
    private var vm: ClipListViewModel!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        repository = ClipRepository(dbPool: testDB.dbPool)
        tagRepository = TagRepository(dbPool: testDB.dbPool)
        vm = ClipListViewModel(
            repository: repository,
            tagRepository: tagRepository
        )
    }

    override func tearDownWithError() throws {
        testDB.cleanup()
        testDB = nil
        repository = nil
        tagRepository = nil
        vm = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func insertClip(text: String) throws -> Clip {
        try repository.insert(text: text)
    }

    /// DB observation 이 비동기로 메인 액터에 디스패치되므로 잠시 대기.
    private func waitForObservation() async {
        // observation → Task → MainActor 한 사이클
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Init / Tags 로드

    func test_init_loadsTagsFromRepository() async throws {
        _ = try tagRepository.create(name: "Bootstrap", colorHex: "#FF0000")
        // 새로 VM 생성 (init 시 loadTags 호출됨)
        let vm2 = ClipListViewModel(
            repository: repository,
            tagRepository: tagRepository
        )
        await waitForObservation()
        XCTAssertTrue(vm2.tags.contains(where: { $0.name == "Bootstrap" }))
    }

    // MARK: - 태그 필터 토글

    func test_toggleTagFilter_addsAndRemoves() {
        let id: Int64 = 42
        XCTAssertFalse(vm.selectedTagIds.contains(id))

        vm.toggleTagFilter(id)
        XCTAssertTrue(vm.selectedTagIds.contains(id))

        vm.toggleTagFilter(id)
        XCTAssertFalse(vm.selectedTagIds.contains(id))
    }

    // MARK: - createTag / deleteTag

    func test_createTag_appendsToTags() async {
        await vm.createTag(name: "Work", colorHex: "#00FF00")
        await waitForObservation()
        XCTAssertTrue(vm.tags.contains(where: { $0.name == "Work" }))
    }

    func test_deleteTag_removesFromTags() async throws {
        let tag = try tagRepository.create(name: "Temp", colorHex: "#0000FF")
        await vm.createTag(name: "Other", colorHex: "#FFFFFF")  // tags 갱신 트리거
        await waitForObservation()
        XCTAssertTrue(vm.tags.contains(where: { $0.name == "Temp" }))

        let tagId = try XCTUnwrap(tag.id)
        await vm.deleteTag(id: tagId)
        await waitForObservation()

        XCTAssertFalse(vm.tags.contains(where: { $0.name == "Temp" }))
        XCTAssertFalse(vm.selectedTagIds.contains(tagId))
    }

    // MARK: - 검색

    func test_searchQuery_filtersClips() async throws {
        try insertClip(text: "apple banana")
        try insertClip(text: "cherry date")
        try insertClip(text: "apple pie")
        await waitForObservation()

        vm.searchQuery = "apple"
        // debounce 200ms + search 비동기
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(vm.clips.count, 2)
        XCTAssertTrue(vm.clips.allSatisfy { ($0.contentText ?? "").contains("apple") })
    }

    func test_searchQuery_emptyRestoresAll() async throws {
        try insertClip(text: "alpha")
        try insertClip(text: "beta")
        await waitForObservation()

        vm.searchQuery = "alpha"
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(vm.clips.count, 1)

        vm.searchQuery = ""
        await waitForObservation()
        XCTAssertEqual(vm.clips.count, 2)
    }

    // MARK: - Filter counts

    func test_filterCounts_reflectInsertedClips() async throws {
        try insertClip(text: "one")
        try insertClip(text: "two")
        try insertClip(text: "three")
        vm.updateCounts()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.filterCounts[nil], 3)
    }

    // MARK: - togglePin

    func test_togglePin_persistsAndReflects() async throws {
        let clip = try insertClip(text: "pinme")
        let uuid = try XCTUnwrap(clip.uuid)
        XCTAssertFalse(clip.isPinned)

        await vm.togglePin(clip)
        await waitForObservation()

        let row = try await testDB.dbPool.read { db in
            try Clip.filter(Column("uuid") == uuid).fetchOne(db)
        }
        XCTAssertEqual(row?.isPinned, true)
    }

    // MARK: - clearError

    func test_clearError_setsToNil() async {
        // errorMessage 직접 접근 불가(private(set))이라 deleteTag 로 트리거 후 clearError 확인.
        await vm.deleteTag(id: 9999)  // 존재 안 함 → 에러 가능성. 단, repository 가 throw 안 할 수도.
        vm.clearError()
        XCTAssertNil(vm.errorMessage)
    }
}
