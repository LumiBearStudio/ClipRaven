import XCTest
import GRDB
@testable import ClipRaven
import ClipRavenSync

/// `SearchViewModel` 의 핵심 로직 검증: FTS 검색 결과, recovery suggestion, recent searches.
/// DI 적용된 SearchRepository + UserDefaults suite 격리.
///
/// debounce 타이밍에 의존하지 않도록 `performSearchForTesting` 직접 호출.
@MainActor
final class SearchViewModelTests: XCTestCase {

    private var testDB: TestDatabase!
    private var clipRepository: ClipRepository!
    private var searchRepository: SearchRepository!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var vm: SearchViewModel!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        clipRepository = ClipRepository(dbPool: testDB.dbPool)
        searchRepository = SearchRepository(dbPool: testDB.dbPool)
        suiteName = "SearchViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        vm = SearchViewModel(
            searchRepository: searchRepository,
            defaults: defaults
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        testDB.cleanup()
        vm = nil
        defaults = nil
        searchRepository = nil
        clipRepository = nil
        testDB = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func insertClip(text: String) throws -> Clip {
        var clip = Clip(contentType: .text, contentText: text)
        return try clipRepository.save(&clip)
    }

    /// performSearch 비동기 Task 완료 대기.
    private func waitForSearch() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - 기본 검색

    func test_performSearch_emptyQuery_clearsResults() {
        vm.results = [SearchResult(
            clip: Clip(contentType: .text, contentText: "stub"),
            snippet: "x"
        )]

        vm.performSearchForTesting("")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.recoverySuggestion)
    }

    func test_performSearch_whitespaceQuery_clearsResults() {
        vm.performSearchForTesting("   ")
        XCTAssertTrue(vm.results.isEmpty)
    }

    // MARK: - Recent Searches 저장 (직접 호출)

    func test_saveRecentSearch_addsToFrontOfList() {
        vm.saveRecentSearch("hello")
        vm.saveRecentSearch("world")
        XCTAssertEqual(vm.recentSearches, ["world", "hello"])
    }

    func test_saveRecentSearch_movesDuplicateToFront() {
        vm.saveRecentSearch("alpha")
        vm.saveRecentSearch("beta")
        vm.saveRecentSearch("alpha")  // 다시 검색
        XCTAssertEqual(vm.recentSearches, ["alpha", "beta"])
    }

    func test_saveRecentSearch_limitsToTen() {
        for i in 0..<15 {
            vm.saveRecentSearch("query \(i)")
        }
        XCTAssertEqual(vm.recentSearches.count, 10)
        // 가장 최근(14)이 맨 앞
        XCTAssertEqual(vm.recentSearches.first, "query 14")
        // 가장 오래된 5개 (0~4)는 제거
        XCTAssertFalse(vm.recentSearches.contains("query 0"))
        XCTAssertFalse(vm.recentSearches.contains("query 4"))
    }

    func test_saveRecentSearch_persistsToDefaults() {
        vm.saveRecentSearch("persistent")
        let arr = defaults.stringArray(forKey: "recentSearches")
        XCTAssertEqual(arr, ["persistent"])
    }

    // MARK: - Recent Searches 로드

    func test_init_loadsRecentSearchesFromDefaults() {
        defaults.set(["x", "y", "z"], forKey: "recentSearches")
        let vm2 = SearchViewModel(
            searchRepository: searchRepository,
            defaults: defaults
        )
        XCTAssertEqual(vm2.recentSearches, ["x", "y", "z"])
    }

    // MARK: - acceptRecoverySuggestion

    func test_acceptRecoverySuggestion_setsQueryToSuggested() {
        vm.recoverySuggestion = SearchRecoverySuggestion(
            originalQuery: "didfh",
            suggestedQuery: "안녕",
            resultCount: 3,
            language: "ko"
        )
        vm.acceptRecoverySuggestion()
        XCTAssertEqual(vm.query, "안녕")
    }

    func test_acceptRecoverySuggestion_noopWhenNoSuggestion() {
        vm.query = "before"
        vm.recoverySuggestion = nil
        vm.acceptRecoverySuggestion()
        XCTAssertEqual(vm.query, "before")
    }
}
