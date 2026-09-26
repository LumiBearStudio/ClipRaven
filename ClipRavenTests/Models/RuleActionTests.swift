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
        // 표시 이름은 현재 언어로 번역되므로 한국어 문구 대신 같은 키의 번역과 비교한다.
        let action: RuleAction = .setTTL(days: 0)
        XCTAssertEqual(action.displayName, String(localized: "TTL: 영구 보관"))
        XCTAssertNotEqual(action.displayName, RuleAction.setTTL(days: 30).displayName)
    }

    func test_displayName_ttlShowsDays() {
        let action: RuleAction = .setTTL(days: 30)
        XCTAssertTrue(action.displayName.contains("30"))
    }
}
