import XCTest
import JavaScriptCore
@testable import ClipRaven

/// 온보딩(HTML·JavaScript) 사전 검사 (테스트 계획 B5).
///
/// 온보딩 문구는 Swift 원시 문자열 안의 JavaScript 사전이라 컴파일러가 검사하지
/// 않는다. 따옴표·줄바꿈 하나로 스크립트 전체가 멈춰 빈 창이 뜰 수 있다.
final class OnboardingI18NTests: XCTestCase {

    private static let expectedLanguages: Set<String> = [
        "en", "ko", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt-BR",
    ]

    private var script: String {
        get throws {
            let html = OnboardingWindowController.onboardingHTML
            let open = try XCTUnwrap(html.range(of: "<script>"))
            let close = try XCTUnwrap(html.range(of: "</script>", range: open.upperBound..<html.endIndex))
            return String(html[open.upperBound..<close.lowerBound])
        }
    }

    /// 실행하지 않고 구문만 검사한다 (본문은 `document` 를 쓰므로 여기서 실행하면 안 된다).
    func test_scriptParses() throws {
        let context = try XCTUnwrap(JSContext())
        context.setObject(try script, forKeyedSubscript: "source" as NSString)
        context.evaluateScript("new Function(source)")
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
    }

    func test_allLanguagesDefineTheSameKeys() throws {
        let source = try script
        let start = try XCTUnwrap(source.range(of: "var I18N = {"))
        let end = try XCTUnwrap(source.range(of: "\n};", range: start.upperBound..<source.endIndex))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(String(source[start.lowerBound..<end.upperBound]))
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")

        let report = try XCTUnwrap(context.evaluateScript("""
            (function () {
              var langs = Object.keys(I18N);
              var base = Object.keys(I18N.en).sort().join(',');
              var empty = [];
              langs.forEach(function (l) {
                Object.keys(I18N[l]).forEach(function (k) {
                  var v = I18N[l][k];
                  if (typeof v === 'string' && v.trim() === '') empty.push(l + '.' + k);
                });
              });
              return JSON.stringify({
                langs: langs,
                mismatched: langs.filter(function (l) { return Object.keys(I18N[l]).sort().join(',') !== base; }),
                empty: empty
              });
            })()
            """)?.toString())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: [String]])
        XCTAssertEqual(Set(json["langs"] ?? []), Self.expectedLanguages)
        XCTAssertEqual(json["mismatched"], [], "키 구성이 영어와 다른 언어")
        XCTAssertEqual(json["empty"], [], "빈 문구")
    }

    /// 실제와 달랐던 안내가 되살아나지 않게 한다 (검색은 ⌘/, 카드 이동은 ←→).
    func test_shortcutHintsMatchTheApp() throws {
        let source = try script
        XCTAssertFalse(source.contains(#"keys:['⌘','F']"#), "패널 검색 단축키는 ⌘F 가 아니라 ⌘/ 다")
        XCTAssertFalse(source.contains(#"keys:['↑↓']"#), "카드 이동은 ↑↓ 가 아니라 ←→ 다")
    }
}
