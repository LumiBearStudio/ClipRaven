import XCTest
import ClipRavenSync
@testable import ClipRaven

final class RuleConditionTests: XCTestCase {

    // MARK: - Helper

    private func clip(
        _ text: String? = "x",
        type: ContentType = .text,
        app: String? = nil
    ) -> Clip {
        var c = Clip(contentType: type, contentText: text)
        c.sourceAppBundleId = app
        return c
    }

    // MARK: - sourceApp

    func test_sourceApp_matches() {
        XCTAssertTrue(
            RuleCondition.sourceApp(bundleId: "com.x")
                .matches(clip(app: "com.x"))
        )
    }

    func test_sourceApp_rejectsMismatched() {
        XCTAssertFalse(
            RuleCondition.sourceApp(bundleId: "com.x")
                .matches(clip(app: "com.y"))
        )
    }

    func test_sourceApp_rejectsNilApp() {
        XCTAssertFalse(
            RuleCondition.sourceApp(bundleId: "com.x")
                .matches(clip(app: nil))
        )
    }

    // MARK: - contentType

    func test_contentType_matches() {
        XCTAssertTrue(
            RuleCondition.contentType("code").matches(clip(type: .code))
        )
    }

    func test_contentType_rejectsMismatched() {
        XCTAssertFalse(
            RuleCondition.contentType("code").matches(clip(type: .text))
        )
    }

    // MARK: - textContains

    func test_textContains_matchesSubstring() {
        XCTAssertTrue(
            RuleCondition.textContains("hello")
                .matches(clip("say hello world"))
        )
    }

    func test_textContains_caseInsensitive() {
        XCTAssertTrue(
            RuleCondition.textContains("HELLO")
                .matches(clip("hello world"))
        )
    }

    func test_textContains_emptyKeywordNeverMatches() {
        XCTAssertFalse(
            RuleCondition.textContains("").matches(clip("anything"))
        )
    }

    func test_textContains_nilContentText() {
        XCTAssertFalse(
            RuleCondition.textContains("foo").matches(clip(nil))
        )
    }

    // MARK: - urlDomain

    func test_urlDomain_matchesHost() {
        XCTAssertTrue(
            RuleCondition.urlDomain("github.com")
                .matches(clip("https://github.com/foo", type: .url))
        )
    }

    func test_urlDomain_matchesSubdomain() {
        XCTAssertTrue(
            RuleCondition.urlDomain("github")
                .matches(clip("https://raw.github.com/foo", type: .url)),
            "substring match on host"
        )
    }

    func test_urlDomain_rejectsNonURLContentType() {
        XCTAssertFalse(
            RuleCondition.urlDomain("github.com")
                .matches(clip("https://github.com", type: .text))
        )
    }

    func test_urlDomain_rejectsInvalidURL() {
        XCTAssertFalse(
            RuleCondition.urlDomain("github.com")
                .matches(clip("not a url", type: .url))
        )
    }

    func test_urlDomain_emptyNeverMatches() {
        XCTAssertFalse(
            RuleCondition.urlDomain("")
                .matches(clip("https://github.com", type: .url))
        )
    }
}
