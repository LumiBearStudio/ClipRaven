import XCTest
import ClipRavenSync
@testable import ClipRaven

final class TextNormalizerTests: XCTestCase {

    // MARK: - normalize (hashing input)

    func test_normalize_trimsWhitespace() {
        XCTAssertEqual(TextNormalizer.normalize("  hello  "), "hello")
    }

    func test_normalize_collapsesInternalWhitespace() {
        XCTAssertEqual(TextNormalizer.normalize("a     b\t\tc"), "a b c")
    }

    func test_normalize_dropsEmptyTokens() {
        XCTAssertEqual(TextNormalizer.normalize("  a \n\n b   "), "a b")
    }

    func test_normalize_appliesNFC() {
        // ㄱ + ㅏ (decomposed) should compose to 가
        let decomposed = "\u{1100}\u{1161}"  // Jamo
        let result = TextNormalizer.normalize(decomposed)
        // Precomposed syllable 가 is U+AC00
        XCTAssertEqual(result.unicodeScalars.first?.value, 0xAC00,
                       "decomposed jamo should compose to precomposed syllable")
    }

    func test_normalize_emptyStringStaysEmpty() {
        XCTAssertEqual(TextNormalizer.normalize(""), "")
    }

    // MARK: - stripInvisibleCharacters (display-safe)

    func test_stripInvisibleCharacters_removesBOM() {
        let input = "\u{FEFF}hello"
        XCTAssertEqual(TextNormalizer.stripInvisibleCharacters(input), "hello")
    }

    func test_stripInvisibleCharacters_removesZeroWidthSpace() {
        let input = "hel\u{200B}lo"
        XCTAssertEqual(TextNormalizer.stripInvisibleCharacters(input), "hello")
    }

    func test_stripInvisibleCharacters_removesZeroWidthNonJoiner() {
        let input = "a\u{200C}b"
        XCTAssertEqual(TextNormalizer.stripInvisibleCharacters(input), "ab")
    }

    func test_stripInvisibleCharacters_removesZeroWidthJoiner() {
        let input = "a\u{200D}b"
        XCTAssertEqual(TextNormalizer.stripInvisibleCharacters(input), "ab")
    }

    func test_stripInvisibleCharacters_removesWordJoiner() {
        let input = "a\u{2060}b"
        XCTAssertEqual(TextNormalizer.stripInvisibleCharacters(input), "ab")
    }

    func test_stripInvisibleCharacters_replacesNBSPWithSpace() {
        let input = "hello\u{00A0}world"
        XCTAssertEqual(TextNormalizer.stripInvisibleCharacters(input), "hello world")
    }

    func test_stripInvisibleCharacters_preservesOrdinaryText() {
        let input = "hello\nworld\t!"
        XCTAssertEqual(TextNormalizer.stripInvisibleCharacters(input), input,
                       "standard whitespace/newlines untouched")
    }

    func test_stripInvisibleCharacters_handlesMultipleBOMs() {
        let input = "\u{FEFF}\u{FEFF}hello"
        XCTAssertEqual(TextNormalizer.stripInvisibleCharacters(input), "hello")
    }
}
