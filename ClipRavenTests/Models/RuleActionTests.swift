import XCTest
@testable import ClipRaven

final class RuleActionTests: XCTestCase {

    func test_codableRoundtrip_multipleActions() throws {
        let original: [RuleAction] = [
            .assignTag(tagId: 42),
            .setTTL(days: 7)
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([RuleAction].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_codableRoundtrip_assignTag() throws {
        let original: RuleAction = .assignTag(tagId: 123)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuleAction.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_codableRoundtrip_setTTLZero() throws {
        let original: RuleAction = .setTTL(days: 0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuleAction.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_displayName_ttlZeroMeansPermanent() {
        let action: RuleAction = .setTTL(days: 0)
        XCTAssertTrue(action.displayName.contains("영구"))
    }

    func test_displayName_ttlShowsDays() {
        let action: RuleAction = .setTTL(days: 30)
        XCTAssertTrue(action.displayName.contains("30"))
    }
}
