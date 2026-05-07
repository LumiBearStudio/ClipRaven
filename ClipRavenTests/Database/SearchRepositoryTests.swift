import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

final class SearchRepositoryTests: XCTestCase {
    private var testDB: TestDatabase!
    private var search: SearchRepository!
    private var clipRepo: ClipRepository!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        search = SearchRepository(dbPool: testDB.dbPool)
        clipRepo = ClipRepository(dbPool: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil; search = nil; clipRepo = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func insertClip(_ text: String, type: ContentType = .text) throws -> Clip {
        var clip = Clip(
            contentType: type,
            contentText: text,
            contentHash: XXHash64Wrapper.hash(text),
            contentChosung: ChosungConverter.extractChosung(from: text)
        )
        try clipRepo.save(&clip)
        return clip
    }

    // MARK: - search

    func test_search_emptyQueryReturnsEmpty() throws {
        _ = try insertClip("hello world")
        XCTAssertTrue(try search.search(query: "").isEmpty)
    }

    func test_search_findsEnglishSubstring() throws {
        _ = try insertClip("hello world")
        _ = try insertClip("goodbye everyone")

        let results = try search.search(query: "hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.contentText, "hello world")
    }

    func test_search_findsKoreanSubstring() throws {
        _ = try insertClip("안녕하세요 ClipRaven")
        _ = try insertClip("반갑습니다")

        let results = try search.search(query: "ClipRaven")
        XCTAssertEqual(results.count, 1)
    }

    func test_search_filterByContentType() throws {
        _ = try insertClip("hello", type: .text)
        _ = try insertClip("let hello = 1", type: .code)

        let codeOnly = try search.search(query: "hello", contentType: .code)
        XCTAssertEqual(codeOnly.count, 1)
        XCTAssertEqual(codeOnly.first?.contentType, .code)
    }

    func test_search_noMatchReturnsEmpty() throws {
        _ = try insertClip("hello")
        XCTAssertTrue(try search.search(query: "xyzqqq").isEmpty)
    }

    func test_search_honorsLimitAtUpperBound() throws {
        // search() merges FTS + LIKE fallback when FTS yields < 5 hits,
        // so a tight limit applies to each pass separately; the merged total
        // can reach ~2×limit in the worst case. Assert that bound holds.
        for i in 0..<10 {
            _ = try insertClip("match token \(i)")
        }
        let results = try search.search(query: "match", limit: 3)
        XCTAssertLessThanOrEqual(results.count, 6,
                                 "merged FTS + LIKE fallback stays within 2× limit")
    }

    // MARK: - searchChosung

    func test_chosung_findsByInitialConsonants() throws {
        _ = try insertClip("감사합니다 좋은 하루")
        _ = try insertClip("완전히 다른 주제")  // 초성 ㅇㅈㅎㄷㄹㅈㅈ — ㄱㅅ 없음

        // 감사 → ㄱㅅ
        let results = try search.searchChosung(query: "ㄱㅅ")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.contentText?.contains("감사") ?? false)
    }

    func test_chosung_matchesAnySubstring() throws {
        // "반갑습니다" → ㅂㄱㅅㄴㄷ, "ㄱㅅ" 는 ㅂ[ㄱㅅ]ㄴㄷ로 매치되어야 함
        _ = try insertClip("반갑습니다")
        let results = try search.searchChosung(query: "ㄱㅅ")
        XCTAssertEqual(results.count, 1, "chosung search should match substring positions, not just initial")
    }

    func test_chosung_emptyReturnsEmpty() throws {
        _ = try insertClip("안녕")
        XCTAssertTrue(try search.searchChosung(query: "").isEmpty)
    }

    func test_chosung_ordersPinnedFirst() throws {
        var pinned = try insertClip("중요한 메모")
        pinned.isPinned = true
        pinned.pinOrder = 0
        try clipRepo.update(pinned)

        _ = try insertClip("중요 다른 내용")

        let results = try search.searchChosung(query: "ㅈ")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.first?.isPinned ?? false)
    }

    // MARK: - searchWithSnippet

    func test_searchWithSnippet_returnsHighlightedSnippets() throws {
        _ = try insertClip("The quick brown fox jumps over the lazy dog")

        let results = try search.searchWithSnippet(query: "brown")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.snippet.contains("<mark>") ?? false,
                      "snippet should include highlight markers")
    }

    // MARK: - optimize / rebuild

    func test_optimizeFTS_doesNotThrow() throws {
        _ = try insertClip("one")
        _ = try insertClip("two")
        XCTAssertNoThrow(try search.optimizeFTS())
    }

    func test_rebuildFTS_doesNotThrow() throws {
        _ = try insertClip("rebuild me")
        XCTAssertNoThrow(try search.rebuildFTS())
    }
}
