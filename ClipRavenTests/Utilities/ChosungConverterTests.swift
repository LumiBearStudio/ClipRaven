import XCTest
@testable import ClipRaven

final class ChosungConverterTests: XCTestCase {

    // MARK: - extractChosung

    func test_extractChosung_basicHangul() {
        XCTAssertEqual(ChosungConverter.extractChosung(from: "감사합니다"), "ㄱㅅㅎㄴㄷ")
    }

    func test_extractChosung_clipraven() {
        XCTAssertEqual(ChosungConverter.extractChosung(from: "클립보드"), "ㅋㄹㅂㄷ")
    }

    func test_extractChosung_skipsNonKorean() {
        // English chars 사이의 한글만 초성으로
        let out = ChosungConverter.extractChosung(from: "Hello 안녕 World")
        XCTAssertEqual(out, "ㅇㄴ")
    }

    func test_extractChosung_keepsStandaloneChosungChar() {
        // 이미 초성인 ㄱ/ㅎ는 그대로 유지
        let out = ChosungConverter.extractChosung(from: "ㄱㅎ")
        XCTAssertEqual(out, "ㄱㅎ")
    }

    func test_extractChosung_emptyInput() {
        XCTAssertEqual(ChosungConverter.extractChosung(from: ""), "")
    }

    func test_extractChosung_mixedWithNumbersAndPunctuation() {
        let out = ChosungConverter.extractChosung(from: "안녕123하세요!")
        XCTAssertEqual(out, "ㅇㄴㅎㅅㅇ")
    }

    func test_extractChosung_handlesAllDoubleConsonants() {
        // 까, 따, 빠, 싸, 짜 → ㄲ, ㄸ, ㅃ, ㅆ, ㅉ
        XCTAssertEqual(ChosungConverter.extractChosung(from: "까따빠싸짜"), "ㄲㄸㅃㅆㅉ")
    }

    // MARK: - isChosungOnly

    func test_isChosungOnly_trueForPureChosungString() {
        XCTAssertTrue(ChosungConverter.isChosungOnly("ㄱㅅ"))
    }

    func test_isChosungOnly_falseForFullHangul() {
        XCTAssertFalse(ChosungConverter.isChosungOnly("감사"))
    }

    func test_isChosungOnly_falseForEmpty() {
        XCTAssertFalse(ChosungConverter.isChosungOnly(""))
    }

    func test_isChosungOnly_falseForMixed() {
        XCTAssertFalse(ChosungConverter.isChosungOnly("ㄱ가"))
    }

    func test_isChosungOnly_falseForEnglish() {
        XCTAssertFalse(ChosungConverter.isChosungOnly("abc"))
    }

    // MARK: - shouldUseChosungSearch

    func test_shouldUseChosung_pureChosungQuery_returnsTrue() {
        // "ㄱㅅ" → 초성만 → 초성 경로
        XCTAssertTrue(ChosungConverter.shouldUseChosungSearch("ㄱㅅ"))
    }

    func test_shouldUseChosung_fullHangul_returnsFalse() {
        // "감사" → 완성형 → FTS 경로
        XCTAssertFalse(ChosungConverter.shouldUseChosungSearch("감사"))
    }

    func test_shouldUseChosung_mixedChosungAndFullHangul_returnsFalse() {
        // "ㄱ가" → 초성 있지만 완성형도 있음 → FTS 경로 (더 정확)
        XCTAssertFalse(ChosungConverter.shouldUseChosungSearch("ㄱ가"))
    }

    func test_shouldUseChosung_englishOnly_returnsFalse() {
        XCTAssertFalse(ChosungConverter.shouldUseChosungSearch("hello"))
    }

    func test_shouldUseChosung_emptyString_returnsFalse() {
        XCTAssertFalse(ChosungConverter.shouldUseChosungSearch(""))
    }

    func test_shouldUseChosung_doubleConsonantChosung_returnsTrue() {
        // ㄲ, ㄸ 같은 쌍자음 초성도 초성 경로로 처리
        XCTAssertTrue(ChosungConverter.shouldUseChosungSearch("ㄲㄸ"))
    }

    func test_shouldUseChosung_chosungMixedWithNumbers_returnsTrue() {
        // "ㄱ1" — 숫자는 완성형 한글 아님 → 초성 경로
        XCTAssertTrue(ChosungConverter.shouldUseChosungSearch("ㄱ1"))
    }

    func test_shouldUseChosung_chosungMixedWithEnglish_returnsTrue() {
        // "ㄱa" — 영어는 완성형 한글 아님 → 초성 경로
        XCTAssertTrue(ChosungConverter.shouldUseChosungSearch("ㄱa"))
    }

    func test_shouldUseChosung_realWorldQuery_clipraven() {
        // "ㅋㄹ" → "클립" 검색 → 초성 경로
        XCTAssertTrue(ChosungConverter.shouldUseChosungSearch("ㅋㄹ"))
    }

    func test_shouldUseChosung_singleChosung_returnsTrue() {
        XCTAssertTrue(ChosungConverter.shouldUseChosungSearch("ㅎ"))
    }
}
