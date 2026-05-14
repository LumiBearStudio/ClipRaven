import XCTest
@testable import ClipRaven
import ClipRavenSync

/// `ClipFilterEngine.apply(_:options:)` 의 각 필터 조건과 복합 케이스 검증.
/// 순수 함수 → DB / 시간 의존성 없음.
final class ClipFilterEngineTests: XCTestCase {

    // MARK: - 헬퍼

    private func makeClip(
        id: Int64,
        type: ContentType = .text,
        text: String? = "sample",
        nickname: String? = nil,
        sourceApp: String? = nil,
        createdAt: Date = Date(),
        aiCategory: String? = nil,
        isPinned: Bool = false,
        isDeleted: Bool = false
    ) -> Clip {
        var clip = Clip(
            id: id,
            contentType: type,
            contentText: text,
            sourceAppBundleId: sourceApp,
            nickname: nickname,
            createdAt: createdAt
        )
        clip.aiCategory = aiCategory
        clip.isPinned = isPinned
        clip.isDeleted = isDeleted
        return clip
    }

    // MARK: - 기본: 옵션 없음

    func test_apply_emptyOptions_returnsAllNonDeleted() {
        let clips = [makeClip(id: 1, text: "a"), makeClip(id: 2, text: "b")]
        let out = ClipFilterEngine.apply(clips, options: .init())
        XCTAssertEqual(out.count, 2)
    }

    func test_apply_softDeleted_excluded() {
        let clips = [
            makeClip(id: 1, text: "live"),
            makeClip(id: 2, text: "deleted", isDeleted: true)
        ]
        let out = ClipFilterEngine.apply(clips, options: .init())
        XCTAssertEqual(out.map { $0.contentText }, ["live"])
    }

    // MARK: - showPinned

    func test_apply_showPinnedFalse_excludesPinned() {
        let clips = [
            makeClip(id: 1, isPinned: true),
            makeClip(id: 2, isPinned: false)
        ]
        let out = ClipFilterEngine.apply(clips, options: .init(showPinned: false))
        XCTAssertEqual(out.map { $0.id }, [2])
    }

    // MARK: - contentType

    func test_apply_contentTypeText_filtersOnlyText() {
        let clips = [
            makeClip(id: 1, type: .text),
            makeClip(id: 2, type: .url),
            makeClip(id: 3, type: .image),
        ]
        let out = ClipFilterEngine.apply(clips, options: .init(contentType: .text))
        XCTAssertEqual(out.map { $0.id }, [1])
    }

    func test_apply_contentTypeNil_returnsAllTypes() {
        let clips = [
            makeClip(id: 1, type: .text),
            makeClip(id: 2, type: .image),
        ]
        let out = ClipFilterEngine.apply(clips, options: .init(contentType: nil))
        XCTAssertEqual(out.count, 2)
    }

    // MARK: - 태그 (AND 매칭)

    func test_apply_singleTag_filtersClipsWithThatTag() {
        let tag1 = Tag(id: 10, name: "Work", colorHex: "#000")
        let tag2 = Tag(id: 20, name: "Home", colorHex: "#000")
        let clips = [
            makeClip(id: 1),
            makeClip(id: 2),
            makeClip(id: 3),
        ]
        let clipTags: [Int64: [Tag]] = [
            1: [tag1],
            2: [tag2],
            3: [tag1, tag2],
        ]
        let out = ClipFilterEngine.apply(
            clips,
            options: .init(tagIds: [10], clipTags: clipTags)
        )
        XCTAssertEqual(Set(out.compactMap { $0.id }), Set([1, 3]))
    }

    func test_apply_multipleTagsAndLogic() {
        let tag1 = Tag(id: 10, name: "Work", colorHex: "#000")
        let tag2 = Tag(id: 20, name: "Urgent", colorHex: "#000")
        let clips = [
            makeClip(id: 1),
            makeClip(id: 2),
            makeClip(id: 3),
        ]
        let clipTags: [Int64: [Tag]] = [
            1: [tag1],
            2: [tag1, tag2],
            3: [tag2],
        ]
        let out = ClipFilterEngine.apply(
            clips,
            options: .init(tagIds: [10, 20], clipTags: clipTags)
        )
        XCTAssertEqual(out.compactMap { $0.id }, [2], "두 태그 모두 가진 클립만 (AND)")
    }

    // MARK: - 소스 앱

    func test_apply_sourceAppBundleId_exactMatch() {
        let clips = [
            makeClip(id: 1, sourceApp: "com.apple.Safari"),
            makeClip(id: 2, sourceApp: "com.apple.dt.Xcode"),
        ]
        let out = ClipFilterEngine.apply(
            clips,
            options: .init(sourceAppBundleId: "com.apple.Safari")
        )
        XCTAssertEqual(out.compactMap { $0.id }, [1])
    }

    // MARK: - 날짜 범위

    func test_apply_dateRange_includesWithinAndExcludesOutside() {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86400)

        let clips = [
            makeClip(id: 1, createdAt: oneHourAgo),
            makeClip(id: 2, createdAt: twoDaysAgo),
        ]
        let range: (from: Date, to: Date) = (now.addingTimeInterval(-7200), now.addingTimeInterval(1))
        let out = ClipFilterEngine.apply(
            clips,
            options: .init(dateRange: range)
        )
        XCTAssertEqual(out.compactMap { $0.id }, [1])
    }

    // MARK: - AI 카테고리

    func test_apply_aiCategory_exactMatch() {
        let clips = [
            makeClip(id: 1, aiCategory: "code"),
            makeClip(id: 2, aiCategory: "receipt"),
            makeClip(id: 3, aiCategory: nil),
        ]
        let out = ClipFilterEngine.apply(clips, options: .init(aiCategory: "code"))
        XCTAssertEqual(out.compactMap { $0.id }, [1])
    }

    // MARK: - 검색

    func test_apply_searchText_caseInsensitivePartialMatch() {
        let clips = [
            makeClip(id: 1, text: "Hello World"),
            makeClip(id: 2, text: "foo bar"),
            makeClip(id: 3, text: "Helsinki"),
        ]
        let out = ClipFilterEngine.apply(
            clips,
            options: .init(searchText: "HEL")
        )
        XCTAssertEqual(Set(out.compactMap { $0.id }), Set([1, 3]))
    }

    func test_apply_searchText_matchesNicknameToo() {
        let clips = [
            makeClip(id: 1, text: "abc", nickname: "important note"),
            makeClip(id: 2, text: "xyz", nickname: nil),
        ]
        let out = ClipFilterEngine.apply(
            clips,
            options: .init(searchText: "important")
        )
        XCTAssertEqual(out.compactMap { $0.id }, [1])
    }

    func test_apply_searchTextWhitespace_treatedEmpty() {
        let clips = [makeClip(id: 1, text: "a"), makeClip(id: 2, text: "b")]
        let out = ClipFilterEngine.apply(clips, options: .init(searchText: "   "))
        XCTAssertEqual(out.count, 2)
    }

    // MARK: - 복합 필터

    func test_apply_combinedTypeAndSearch() {
        let clips = [
            makeClip(id: 1, type: .text, text: "hello"),
            makeClip(id: 2, type: .url, text: "https://hello.com"),
            makeClip(id: 3, type: .text, text: "world"),
        ]
        let out = ClipFilterEngine.apply(
            clips,
            options: .init(contentType: .text, searchText: "hello")
        )
        XCTAssertEqual(out.compactMap { $0.id }, [1])
    }

    func test_apply_combinedTagAndDate() {
        let tag = Tag(id: 5, name: "Important", colorHex: "#000")
        let now = Date()
        let clips = [
            makeClip(id: 1, createdAt: now),
            makeClip(id: 2, createdAt: now.addingTimeInterval(-30 * 86400)),
        ]
        let clipTags: [Int64: [Tag]] = [1: [tag], 2: [tag]]
        let recent: (from: Date, to: Date) = (now.addingTimeInterval(-3600), now.addingTimeInterval(1))

        let out = ClipFilterEngine.apply(
            clips,
            options: .init(tagIds: [5], clipTags: clipTags, dateRange: recent)
        )
        XCTAssertEqual(out.compactMap { $0.id }, [1])
    }

    func test_apply_combinedShowPinnedOffAndSearch() {
        let clips = [
            makeClip(id: 1, text: "pinned hello", isPinned: true),
            makeClip(id: 2, text: "plain hello", isPinned: false),
            makeClip(id: 3, text: "plain bye", isPinned: false),
        ]
        let out = ClipFilterEngine.apply(
            clips,
            options: .init(searchText: "hello", showPinned: false)
        )
        XCTAssertEqual(out.compactMap { $0.id }, [2])
    }
}
