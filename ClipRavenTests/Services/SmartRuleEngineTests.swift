import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

final class SmartRuleEngineTests: XCTestCase {
    private var testDB: TestDatabase!
    private var engine: SmartRuleEngine!
    private var ruleRepo: SmartRuleRepository!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        ruleRepo = SmartRuleRepository(dbPool: testDB.dbPool)
        engine = SmartRuleEngine(dbPool: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil; engine = nil; ruleRepo = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func addRule(
        name: String = "r",
        condition: RuleCondition,
        actions: [RuleAction],
        enabled: Bool = true
    ) throws {
        var rule = SmartRule(
            name: name,
            isEnabled: enabled,
            condition: condition,
            actions: actions,
            createdAt: Date()
        )
        try ruleRepo.save(&rule)
        engine.reloadRules()
    }

    private func makeClip(
        _ text: String,
        type: ContentType = .text,
        sourceApp: String? = nil
    ) -> Clip {
        var clip = Clip(
            contentType: type,
            contentText: text,
            contentHash: XXHash64Wrapper.hash(text)
        )
        clip.sourceAppBundleId = sourceApp
        return clip
    }

    // MARK: - applyRules (tag ID extraction)

    func test_applyRules_returnsEmptyWhenNoRulesDefined() {
        let ids = engine.applyRules(to: makeClip("hi"))
        XCTAssertTrue(ids.isEmpty)
    }

    func test_applyRules_matchesContentTypeCondition() throws {
        try addRule(
            condition: .contentType("code"),
            actions: [.assignTag(tagId: 42)]
        )
        let ids = engine.applyRules(to: makeClip("let x = 1", type: .code))
        XCTAssertEqual(ids, [42])
    }

    func test_applyRules_doesNotMatchMismatchedContentType() throws {
        try addRule(
            condition: .contentType("code"),
            actions: [.assignTag(tagId: 42)]
        )
        let ids = engine.applyRules(to: makeClip("plain text", type: .text))
        XCTAssertTrue(ids.isEmpty)
    }

    func test_applyRules_matchesTextContainsCondition() throws {
        try addRule(
            condition: .textContains("TODO"),
            actions: [.assignTag(tagId: 7)]
        )
        let ids = engine.applyRules(to: makeClip("TODO: fix this"))
        XCTAssertEqual(ids, [7])
    }

    func test_applyRules_textContainsIsCaseInsensitive() throws {
        try addRule(
            condition: .textContains("todo"),
            actions: [.assignTag(tagId: 7)]
        )
        let ids = engine.applyRules(to: makeClip("TODO upper case"))
        XCTAssertEqual(ids, [7])
    }

    func test_applyRules_matchesSourceAppCondition() throws {
        try addRule(
            condition: .sourceApp(bundleId: "com.google.Chrome"),
            actions: [.assignTag(tagId: 99)]
        )
        let ids = engine.applyRules(
            to: makeClip("x", sourceApp: "com.google.Chrome")
        )
        XCTAssertEqual(ids, [99])
    }

    func test_applyRules_urlDomainMatchesHost() throws {
        try addRule(
            condition: .urlDomain("github.com"),
            actions: [.assignTag(tagId: 10)]
        )
        let ids = engine.applyRules(
            to: makeClip("https://github.com/anthropic/claude", type: .url)
        )
        XCTAssertEqual(ids, [10])
    }

    func test_applyRules_dedupesDuplicateTagsAcrossMultipleRules() throws {
        try addRule(name: "a", condition: .contentType("text"), actions: [.assignTag(tagId: 5)])
        try addRule(name: "b", condition: .textContains("hello"), actions: [.assignTag(tagId: 5)])

        let ids = engine.applyRules(to: makeClip("hello world"))
        XCTAssertEqual(ids, [5], "duplicate tag IDs across rules must be collapsed")
    }

    func test_applyRules_ignoresDisabledRules() throws {
        try addRule(
            condition: .contentType("text"),
            actions: [.assignTag(tagId: 1)],
            enabled: false
        )
        let ids = engine.applyRules(to: makeClip("x"))
        XCTAssertTrue(ids.isEmpty, "disabled rule must not contribute tags")
    }

    func test_applyRules_ignoresSetTTLActionForTagList() throws {
        try addRule(
            condition: .contentType("text"),
            actions: [.setTTL(days: 7)]  // no assignTag
        )
        let ids = engine.applyRules(to: makeClip("x"))
        XCTAssertTrue(ids.isEmpty, "TTL-only rule must not produce tag IDs")
    }
}
