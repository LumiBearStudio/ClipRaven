import XCTest
@testable import ClipRaven

/// Tests for the Korean keyboard-layout recovery used by the search
/// "Did you mean?" feature. The bar is precision: false positives
/// annoy users far more than false negatives, so several tests
/// deliberately assert "no suggestion" on inputs that the naive
/// implementation would try to recover.
final class KoreanLayoutRecoveryTests: XCTestCase {
    private let recoverer = KoreanLayoutRecoverer()

    // MARK: - Latin → Native (happy path)

    func test_decode_zkzkdh_to_kakao() {
        // 카카오 = ㅋㅏ ㅋㅏ ㅇㅗ → keys: z k z k d h
        XCTAssertEqual(recoverer.decodeLatinToNative("zkzkdh"), "카카오")
    }

    func test_decode_dkssudgktpdy_to_annyeonghaseyo() {
        XCTAssertEqual(recoverer.decodeLatinToNative("dkssudgktpdy"), "안녕하세요")
    }

    func test_decode_gksrmf_to_hangeul() {
        // 한글 = ㅎㅏㄴㄱㅡㄹ → keys: g k s r m f
        XCTAssertEqual(recoverer.decodeLatinToNative("gksrmf"), "한글")
    }

    func test_decode_preservesInternalSpaces() {
        XCTAssertEqual(recoverer.decodeLatinToNative("zkzkdh zkzkdh"), "카카오 카카오")
    }

    // MARK: - Latin → Native (edge cases that must be rejected)

    func test_decode_skipsSingleCharInput() {
        XCTAssertNil(recoverer.decodeLatinToNative("z"))
        XCTAssertNil(recoverer.decodeLatinToNative(""))
    }

    func test_decode_skipsURL() {
        XCTAssertNil(recoverer.decodeLatinToNative("https://example.com"))
    }

    func test_decode_skipsEmail() {
        XCTAssertNil(recoverer.decodeLatinToNative("user@example.com"))
    }

    func test_decode_skipsPureNumeric() {
        XCTAssertNil(recoverer.decodeLatinToNative("12345"))
    }

    func test_decode_skipsHexHash() {
        XCTAssertNil(recoverer.decodeLatinToNative("abcdef0123456789abcdef"))
    }

    func test_decode_skipsInputWithDigitsOrPunctuation() {
        // `asdf-123` contains a digit: not plausibly a Korean mistype
        XCTAssertNil(recoverer.decodeLatinToNative("asdf-123"))
    }

    func test_decode_rejectsNonMappableLetters() {
        // `xyz` has no mapping for `x` alone being meaningful here — but
        // every Latin letter in our table does map. Check an input whose
        // letters are all in the table but compose into no syllables:
        // three vowels only → no syllable. We should reject.
        XCTAssertNil(recoverer.decodeLatinToNative("ooo"))   // ㅐㅐㅐ
    }

    // MARK: - Native → Latin

    func test_decode_dkssud_back_from_annyeong() {
        XCTAssertEqual(recoverer.decodeNativeToLatin("안녕"), "dkssud")
    }

    func test_decode_native_mixedWithHangul_and_space() {
        XCTAssertEqual(recoverer.decodeNativeToLatin("안녕 하세요"), "dkssud gktpdy")
    }

    func test_decode_native_rejectsNonKoreanText() {
        XCTAssertNil(recoverer.decodeNativeToLatin("hello"))
        XCTAssertNil(recoverer.decodeNativeToLatin("12345"))
    }

    func test_decode_native_rejectsHanjaOrPunctuation() {
        // Hanja 安 — unmappable — should reject (cannot confidently
        // round-trip).
        XCTAssertNil(recoverer.decodeNativeToLatin("안녕安"))
    }

    // MARK: - HangulComposer unit coverage

    func test_compose_simple_CV() {
        // ㄱ+ㅏ → 가
        XCTAssertEqual(HangulComposer.compose(jamo: ["ㄱ", "ㅏ"]), "가")
    }

    func test_compose_CVC() {
        // ㄱ+ㅏ+ㄴ → 간
        XCTAssertEqual(HangulComposer.compose(jamo: ["ㄱ", "ㅏ", "ㄴ"]), "간")
    }

    func test_compose_compoundVowel_wa() {
        // ㄱ+ㅗ+ㅏ → 과 (compound 중성 ㅘ)
        XCTAssertEqual(HangulComposer.compose(jamo: ["ㄱ", "ㅗ", "ㅏ"]), "과")
    }

    func test_compose_batchimMigration() {
        // ㄱㅏㄴㅣ → 가 + 니 (종성이 아닌 다음 초성으로 이월)
        // expected output: 가니
        XCTAssertEqual(HangulComposer.compose(jamo: ["ㄱ", "ㅏ", "ㄴ", "ㅣ"]), "가니")
    }

    func test_compose_attachesTrailingConsonantAsBatchim() {
        // Trailing consonant on a vowel-final syllable becomes its
        // batchim — this matches real IME behavior (the user clearly
        // typed the extra key, it must end up somewhere).
        // ㅋㅏㅇㅗㅎ → 카옿 (옿 = ㅇ+ㅗ+ㅎ)
        XCTAssertEqual(
            HangulComposer.compose(jamo: ["ㅋ", "ㅏ", "ㅇ", "ㅗ", "ㅎ"]),
            "카옿"
        )
    }

    func test_compose_dropsLeadingOrphanVowel() {
        // Leading vowel with no onset is dropped — otherwise a recovery
        // suggestion would show raw jamo to the user.
        // ㅗ + ㅋ + ㅏ → 카 (leading ㅗ silently dropped)
        XCTAssertEqual(
            HangulComposer.compose(jamo: ["ㅗ", "ㅋ", "ㅏ"]),
            "카"
        )
    }

    func test_compose_dropsMiddleOrphanVowel() {
        // Orphan vowel between syllables (no onset to attach to) is
        // dropped. ㅋㅏ + stray ㅗ + ㅋㅏ → 카카.
        XCTAssertEqual(
            HangulComposer.compose(jamo: ["ㅋ", "ㅏ", "ㅗ", "ㅋ", "ㅏ"]),
            "카카"
        )
    }

    func test_decompose_roundTripsSimpleSyllable() {
        XCTAssertEqual(HangulComposer.decompose("가"), ["ㄱ", "ㅏ"])
    }

    func test_decompose_splitsCompoundVowel() {
        XCTAssertEqual(HangulComposer.decompose("과"), ["ㄱ", "ㅗ", "ㅏ"])
    }

    func test_decompose_splitsBatchim() {
        XCTAssertEqual(HangulComposer.decompose("값"), ["ㄱ", "ㅏ", "ㅂ", "ㅅ"])
    }

    func test_decompose_passesThroughNonHangul() {
        XCTAssertEqual(HangulComposer.decompose("ab"), ["a", "b"])
    }

    // MARK: - Round-trip

    func test_roundTrip_nativeToLatinToNative() {
        // 안녕 → dkssud → 안녕 (no data loss)
        let latin = recoverer.decodeNativeToLatin("안녕")!
        let backToKorean = recoverer.decodeLatinToNative(latin)
        XCTAssertEqual(backToKorean, "안녕")
    }

    func test_roundTrip_kakao() {
        // 카카오 decomposes to the jamo pairs (ㅋ,ㅏ)(ㅋ,ㅏ)(ㅇ,ㅗ)
        // which map to the 두벌식 keys z k z k d h.
        let latin = recoverer.decodeNativeToLatin("카카오")!
        XCTAssertEqual(latin, "zkzkdh")
        let back = recoverer.decodeLatinToNative(latin)
        XCTAssertEqual(back, "카카오")
    }
}
