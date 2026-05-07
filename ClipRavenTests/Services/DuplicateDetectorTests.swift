import XCTest
@testable import ClipRaven

final class DuplicateDetectorTests: XCTestCase {
    private var detector: DuplicateDetector!

    override func setUp() {
        super.setUp()
        detector = DuplicateDetector()
    }

    override func tearDown() {
        detector = nil
        super.tearDown()
    }

    // MARK: - generateHash — text (normalized before hashing)

    func test_generateHash_textIsDeterministic() async {
        let a = await detector.generateHash(contentType: .text, text: "hello world")
        let b = await detector.generateHash(contentType: .text, text: "hello world")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func test_generateHash_textIgnoresInternalWhitespace() async {
        // Normalize collapses runs of whitespace; dedup-hash should match.
        let a = await detector.generateHash(contentType: .text, text: "hello   world")
        let b = await detector.generateHash(contentType: .text, text: "hello world")
        XCTAssertEqual(a, b)
    }

    func test_generateHash_textIgnoresLeadingTrailingWhitespace() async {
        let a = await detector.generateHash(contentType: .text, text: "  hi  ")
        let b = await detector.generateHash(contentType: .text, text: "hi")
        XCTAssertEqual(a, b)
    }

    func test_generateHash_textCaseSensitive() async {
        let a = await detector.generateHash(contentType: .text, text: "Hello")
        let b = await detector.generateHash(contentType: .text, text: "hello")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - generateHash — URL (tracking params stripped)

    func test_generateHash_urlStripsTrackingParams() async {
        let a = await detector.generateHash(
            contentType: .url,
            text: "https://example.com/page?utm_source=x&id=1"
        )
        let b = await detector.generateHash(
            contentType: .url,
            text: "https://example.com/page?id=1"
        )
        XCTAssertEqual(a, b, "URL dedup must normalize tracking params away")
    }

    func test_generateHash_urlLowercasesHost() async {
        let a = await detector.generateHash(contentType: .url, text: "https://Example.COM/path")
        let b = await detector.generateHash(contentType: .url, text: "https://example.com/path")
        XCTAssertEqual(a, b)
    }

    // MARK: - generateHash — color (normalized to hex8)

    func test_generateHash_color3vs6SameDigest() async {
        // #F0A expands to #FF00AAFF, same as #FF00AA
        let a = await detector.generateHash(contentType: .color, text: "#F0A")
        let b = await detector.generateHash(contentType: .color, text: "#FF00AA")
        XCTAssertEqual(a, b)
    }

    func test_generateHash_colorDifferentValuesDiffer() async {
        let a = await detector.generateHash(contentType: .color, text: "#FF0000")
        let b = await detector.generateHash(contentType: .color, text: "#00FF00")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - generateHash — image returns nil

    func test_generateHash_imageReturnsNil() async {
        // Images dedup via imageHash field, not contentHash
        let h = await detector.generateHash(contentType: .image, text: nil)
        XCTAssertNil(h)
    }

    // MARK: - generateHash — nil text

    func test_generateHash_nilTextReturnsNil() async {
        let h = await detector.generateHash(contentType: .text, text: nil)
        XCTAssertNil(h)
    }

    // MARK: - generateImageHash (SHA256)

    func test_generateImageHash_isDeterministic() async {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG sig
        let a = await detector.generateImageHash(data)
        let b = await detector.generateImageHash(data)
        XCTAssertEqual(a, b)
    }

    func test_generateImageHash_differentBytesDifferentHashes() async {
        let a = await detector.generateImageHash(Data([0x00]))
        let b = await detector.generateImageHash(Data([0x01]))
        XCTAssertNotEqual(a, b)
    }

    func test_generateImageHash_producesExpectedLength() async {
        let h = await detector.generateImageHash(Data([0x00]))
        XCTAssertEqual(h.count, 64, "SHA-256 hex digest is 64 chars")
    }

    // MARK: - SHA256Hash static helper

    func test_sha256_emptyInput() {
        // SHA-256 of empty bytes is a well-known constant.
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(SHA256Hash.compute(Data()), expected)
    }
}
