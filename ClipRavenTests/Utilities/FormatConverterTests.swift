import XCTest
import AppKit
@testable import ClipRaven

final class FormatConverterTests: XCTestCase {

    // MARK: - looksLikeHTML

    func test_looksLikeHTML_trueForSimpleTag() {
        XCTAssertTrue(FormatConverter.looksLikeHTML("<p>hello</p>"))
    }

    func test_looksLikeHTML_trueForSelfClosingTag() {
        XCTAssertTrue(FormatConverter.looksLikeHTML("<br/>line"))
    }

    func test_looksLikeHTML_trueForTagWithAttributes() {
        XCTAssertTrue(FormatConverter.looksLikeHTML("<a href=\"x\">link</a>"))
    }

    func test_looksLikeHTML_falseForPlainText() {
        XCTAssertFalse(FormatConverter.looksLikeHTML("just plain text without tags"))
    }

    func test_looksLikeHTML_falseForLessThanOnly() {
        XCTAssertFalse(FormatConverter.looksLikeHTML("1 < 2 but 3 > 0"))
    }

    // MARK: - looksLikeMarkdown

    func test_looksLikeMarkdown_heading() {
        XCTAssertTrue(FormatConverter.looksLikeMarkdown("# Heading\ncontent"))
    }

    func test_looksLikeMarkdown_bulletList() {
        XCTAssertTrue(FormatConverter.looksLikeMarkdown("- item one\n- item two"))
    }

    func test_looksLikeMarkdown_numberedList() {
        XCTAssertTrue(FormatConverter.looksLikeMarkdown("1. first\n2. second"))
    }

    func test_looksLikeMarkdown_bold() {
        XCTAssertTrue(FormatConverter.looksLikeMarkdown("this is **bold** text"))
    }

    func test_looksLikeMarkdown_link() {
        XCTAssertTrue(FormatConverter.looksLikeMarkdown("see [the doc](https://x.com)"))
    }

    func test_looksLikeMarkdown_inlineCode() {
        XCTAssertTrue(FormatConverter.looksLikeMarkdown("use `let` keyword"))
    }

    func test_looksLikeMarkdown_falseForProse() {
        XCTAssertFalse(FormatConverter.looksLikeMarkdown("plain prose without any markdown markers"))
    }

    // MARK: - markdownToAttributed

    func test_markdownToAttributed_preservesVisibleText() {
        let md = "**hello** world"
        let attr = FormatConverter.markdownToAttributed(md)
        XCTAssertNotNil(attr)
        XCTAssertTrue(attr!.string.contains("hello"))
        XCTAssertTrue(attr!.string.contains("world"))
    }

    func test_markdownToAttributed_producesNonEmptyResult() {
        let attr = FormatConverter.markdownToAttributed("# Title\n\nBody paragraph.")
        XCTAssertNotNil(attr)
        XCTAssertGreaterThan(attr!.length, 0)
    }

    // MARK: - rtfData

    func test_rtfData_producesNonEmptyBytes() {
        let attr = NSAttributedString(string: "hello")
        let data = FormatConverter.rtfData(from: attr)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data!.count, 0)
    }

    // MARK: - htmlToMarkdown

    func test_htmlToMarkdown_heading() {
        let out = FormatConverter.htmlToMarkdown("<h1>Title</h1>")
        XCTAssertTrue(out.contains("# Title"))
    }

    func test_htmlToMarkdown_boldInline() {
        let out = FormatConverter.htmlToMarkdown("<p>this is <strong>bold</strong></p>")
        XCTAssertTrue(out.contains("**bold**"))
    }

    func test_htmlToMarkdown_stripsScriptAndStyle() {
        let html = "<p>keep</p><script>alert('x')</script><style>body{}</style>"
        let out = FormatConverter.htmlToMarkdown(html)
        XCTAssertFalse(out.contains("alert"))
        XCTAssertFalse(out.contains("body{"))
        XCTAssertTrue(out.contains("keep"))
    }

    func test_htmlToMarkdown_dropsComments() {
        let out = FormatConverter.htmlToMarkdown("<p>visible<!-- hidden --></p>")
        XCTAssertFalse(out.contains("hidden"))
        XCTAssertTrue(out.contains("visible"))
    }
}
