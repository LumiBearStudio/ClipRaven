import XCTest
@testable import ClipRaven

final class ColorParserTests: XCTestCase {

    // MARK: - isColor

    func test_isColor_acceptsHex6()    { XCTAssertTrue(ColorParser.isColor("#FF00AA")) }
    func test_isColor_acceptsHex3()    { XCTAssertTrue(ColorParser.isColor("#F0A")) }
    func test_isColor_acceptsHex8()    { XCTAssertTrue(ColorParser.isColor("#FF00AAFF")) }
    func test_isColor_acceptsHex4()    { XCTAssertTrue(ColorParser.isColor("#F0A8")) }
    func test_isColor_acceptsHexNoHash() { XCTAssertTrue(ColorParser.isColor("FF00AA")) }
    func test_isColor_acceptsLowercaseHex() { XCTAssertTrue(ColorParser.isColor("#ff00aa")) }

    func test_isColor_acceptsRGB()     { XCTAssertTrue(ColorParser.isColor("rgb(255, 0, 170)")) }
    func test_isColor_acceptsRGBA()    { XCTAssertTrue(ColorParser.isColor("rgba(255, 0, 170, 0.5)")) }
    func test_isColor_acceptsHSL()     { XCTAssertTrue(ColorParser.isColor("hsl(180, 50%, 50%)")) }
    func test_isColor_acceptsHSLA()    { XCTAssertTrue(ColorParser.isColor("hsla(180, 50%, 50%, 0.8)")) }

    func test_isColor_rejectsInvalidHex5()   { XCTAssertFalse(ColorParser.isColor("#FFAAB")) }  // 5 hex chars invalid (valid: 3/4/6/8)
    func test_isColor_rejectsPlainText()     { XCTAssertFalse(ColorParser.isColor("hello")) }
    func test_isColor_rejectsRGBWithoutParens() { XCTAssertFalse(ColorParser.isColor("rgb 255 0 0")) }
    func test_isColor_rejectsEmpty()         { XCTAssertFalse(ColorParser.isColor("")) }

    func test_isColor_trimsWhitespace()      { XCTAssertTrue(ColorParser.isColor("  #FF0000  ")) }

    // MARK: - normalizeToHex8

    func test_normalize_hex3ToHex8() {
        XCTAssertEqual(ColorParser.normalizeToHex8("#F0A"), "FF00AAFF")
    }

    func test_normalize_hex4ToHex8() {
        XCTAssertEqual(ColorParser.normalizeToHex8("F0A8"), "FF00AA88")
    }

    func test_normalize_hex6ToHex8() {
        XCTAssertEqual(ColorParser.normalizeToHex8("#ff00aa"), "FF00AAFF")
    }

    func test_normalize_hex8Passthrough() {
        XCTAssertEqual(ColorParser.normalizeToHex8("ff00aa80"), "FF00AA80")
    }

    func test_normalize_rejectsInvalidLength() {
        XCTAssertNil(ColorParser.normalizeToHex8("#FFFFF"))  // 5 hex chars
    }
}
