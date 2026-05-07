import XCTest
@testable import ClipRaven

final class URLNormalizerTests: XCTestCase {

    // MARK: - isURL

    func test_isURL_acceptsHTTPS()  { XCTAssertTrue(URLNormalizer.isURL("https://example.com")) }
    func test_isURL_acceptsHTTP()   { XCTAssertTrue(URLNormalizer.isURL("http://example.com")) }
    func test_isURL_acceptsFTP()    { XCTAssertTrue(URLNormalizer.isURL("ftp://example.com/file.zip")) }
    func test_isURL_rejectsPlain()  { XCTAssertFalse(URLNormalizer.isURL("hello world")) }
    func test_isURL_rejectsMailto() { XCTAssertFalse(URLNormalizer.isURL("mailto:a@b.c")) }
    func test_isURL_rejectsMultiline() {
        XCTAssertFalse(URLNormalizer.isURL("https://a.com\nhttps://b.com"))
    }
    func test_isURL_trimsWhitespace() {
        XCTAssertTrue(URLNormalizer.isURL("  https://example.com  "))
    }

    // MARK: - stripTracking (display-safe)

    func test_stripTracking_removesUTMParams() {
        let input  = "https://example.com/page?utm_source=twitter&utm_campaign=spring&id=5"
        let output = URLNormalizer.stripTracking(input)
        XCTAssertFalse(output.contains("utm_source"))
        XCTAssertFalse(output.contains("utm_campaign"))
        XCTAssertTrue(output.contains("id=5"), "non-tracking params preserved")
    }

    func test_stripTracking_removesFbclidAndGclid() {
        let input  = "https://example.com?fbclid=abc&gclid=def&q=hello"
        let output = URLNormalizer.stripTracking(input)
        XCTAssertEqual(output, "https://example.com?q=hello")
    }

    func test_stripTracking_returnsOriginalWhenNoTrackingFound() {
        let input = "https://example.com/page?q=hello&page=2"
        XCTAssertEqual(URLNormalizer.stripTracking(input), input,
                       "URL with only legitimate params should return verbatim")
    }

    func test_stripTracking_handlesURLWithoutQuery() {
        let input = "https://example.com/page"
        XCTAssertEqual(URLNormalizer.stripTracking(input), input)
    }

    func test_stripTracking_preservesCaseInHost() {
        let input = "https://Example.COM/Path?utm_source=x"
        let out = URLNormalizer.stripTracking(input)
        XCTAssertTrue(out.contains("Example.COM"), "stripTracking must not lowercase host")
    }

    func test_stripTracking_allParamsAreTracking_dropsQuery() {
        let input  = "https://example.com/page?utm_source=a&fbclid=b"
        let output = URLNormalizer.stripTracking(input)
        XCTAssertFalse(output.contains("?"))
        XCTAssertFalse(output.contains("utm_source"))
    }

    // MARK: - normalize (dedup-hash aggressive)

    func test_normalize_lowercasesHost() {
        let out = URLNormalizer.normalize("https://Example.COM/path")
        XCTAssertTrue(out.contains("example.com"))
    }

    func test_normalize_removesFragment() {
        let out = URLNormalizer.normalize("https://example.com/page#section2")
        XCTAssertFalse(out.contains("#"))
    }

    func test_normalize_removesTrailingSlash() {
        let out = URLNormalizer.normalize("https://example.com/page/")
        XCTAssertFalse(out.hasSuffix("/"))
    }

    func test_normalize_keepsRootSlash() {
        XCTAssertEqual(URLNormalizer.normalize("https://example.com/"), "https://example.com/")
    }

    func test_normalize_stripsTrackingParams() {
        let out = URLNormalizer.normalize("https://example.com?utm_source=x&id=1")
        XCTAssertFalse(out.contains("utm_source"))
        XCTAssertTrue(out.contains("id=1"))
    }

    // MARK: - Case insensitivity on param names

    func test_stripTracking_paramNameCaseInsensitive() {
        let input = "https://example.com?UTM_SOURCE=x&FBCLID=y"
        let out = URLNormalizer.stripTracking(input)
        XCTAssertFalse(out.lowercased().contains("utm_source"))
        XCTAssertFalse(out.lowercased().contains("fbclid"))
    }
}
