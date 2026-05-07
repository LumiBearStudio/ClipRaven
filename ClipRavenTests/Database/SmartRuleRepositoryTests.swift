import XCTest
import GRDB
@testable import ClipRaven

final class SmartRuleRepositoryTests: XCTestCase {
    private var testDB: TestDatabase!
    private var repo: SmartRuleRepository!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        repo = SmartRuleRepository(dbPool: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil; repo = nil
        super.tearDown()
    }

    // MARK: - Helper

    private func makeRule(
        name: String,
        enabled: Bool = true,
        condition: RuleCondition = .contentType("text"),
        actions: [RuleAction] = [.assignTag(tagId: 1)]
    ) -> SmartRule {
        SmartRule(
            name: name,
            isEnabled: enabled,
            condition: condition,
            actions: actions,
            createdAt: Date()
        )
    }

    // MARK: - save / fetch

    func test_save_assignsId() throws {
        var rule = makeRule(name: "r")
        XCTAssertNil(rule.id)
        try repo.save(&rule)
        XCTAssertNotNil(rule.id)
    }

    func test_fetchAll_returnsSavedRules() throws {
        var a = makeRule(name: "a"); try repo.save(&a)
        var b = makeRule(name: "b"); try repo.save(&b)
        XCTAssertEqual(try repo.fetchAll().count, 2)
    }

    func test_fetchEnabled_filtersOutDisabled() throws {
        var on = makeRule(name: "on", enabled: true); try repo.save(&on)
        var off = makeRule(name: "off", enabled: false); try repo.save(&off)

        let enabled = try repo.fetchEnabled()
        XCTAssertEqual(enabled.count, 1)
        XCTAssertEqual(enabled.first?.name, "on")
    }

    func test_fetchOne_byId() throws {
        var rule = makeRule(name: "find")
        try repo.save(&rule)
        let fetched = try repo.fetchOne(id: rule.id!)
        XCTAssertEqual(fetched?.name, "find")
    }

    // MARK: - update

    func test_toggleEnabled_flipsIsEnabled() throws {
        var rule = makeRule(name: "x", enabled: true)
        try repo.save(&rule)

        try repo.toggleEnabled(id: rule.id!)
        XCTAssertEqual(try repo.fetchOne(id: rule.id!)?.isEnabled, false)

        try repo.toggleEnabled(id: rule.id!)
        XCTAssertEqual(try repo.fetchOne(id: rule.id!)?.isEnabled, true)
    }

    // MARK: - JSON persistence (condition + actions)

    func test_roundtrip_preservesMultipleActions() throws {
        var rule = makeRule(
            name: "multi",
            condition: .textContains("report"),
            actions: [.assignTag(tagId: 5), .setTTL(days: 30)]
        )
        try repo.save(&rule)

        let fetched = try repo.fetchOne(id: rule.id!)
        XCTAssertEqual(fetched?.actions.count, 2)
        XCTAssertEqual(fetched?.actions, rule.actions)
    }

    func test_roundtrip_preservesSourceAppCondition() throws {
        var rule = makeRule(
            name: "from-chrome",
            condition: .sourceApp(bundleId: "com.google.Chrome")
        )
        try repo.save(&rule)

        let fetched = try repo.fetchOne(id: rule.id!)
        XCTAssertEqual(fetched?.condition, .sourceApp(bundleId: "com.google.Chrome"))
    }

    func test_roundtrip_preservesUrlDomainCondition() throws {
        var rule = makeRule(
            name: "gh-only",
            condition: .urlDomain("github.com")
        )
        try repo.save(&rule)

        let fetched = try repo.fetchOne(id: rule.id!)
        XCTAssertEqual(fetched?.condition, .urlDomain("github.com"))
    }

    // MARK: - delete

    func test_delete_removesRule() throws {
        var rule = makeRule(name: "gone")
        try repo.save(&rule)

        try repo.delete(id: rule.id!)
        XCTAssertNil(try repo.fetchOne(id: rule.id!))
        XCTAssertEqual(try repo.fetchAll().count, 0)
    }
}
