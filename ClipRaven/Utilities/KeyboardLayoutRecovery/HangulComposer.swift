import Foundation

/// Hangul syllable ↔ jamo math. Pure code, no Unicode data files, no
/// third-party dependency. Based on the KS X 1001 /ko 표준 Unicode block
/// U+AC00..U+D7A3 which lays out all 11,172 modern Hangul syllables as a
/// dense Cartesian product:
///
/// ```
/// syllable_code = 0xAC00 + (L × 588) + (V × 28) + T
///   L ∈ 0..<19   — 초성 index (ㄱ..ㅎ including 쌍자음)
///   V ∈ 0..<21   — 중성 index (ㅏ..ㅣ including 복합모음)
///   T ∈ 0..<28   — 종성 index (0 = 받침 없음, 1..27 = 받침 including 겹받침)
/// ```
///
/// Every modern Hangul syllable decomposes uniquely to (L, V, T), and
/// every (L, V, T) composes uniquely to one syllable — so both directions
/// are trivial math once the jamo index tables are in place.
enum HangulComposer {

    // MARK: - Index tables (KS X 1001 canonical order)

    /// 초성 (19). Index position matters for U+AC00 math.
    static let choseongList: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]

    /// 중성 (21). Includes the 7 compound vowels the IME composes from
    /// two key presses (ㅘㅙㅚㅝㅞㅟㅢ).
    static let jungseongList: [Character] = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ",
        "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ",
        "ㅣ",
    ]

    /// 종성 (28). Index 0 is "no final" — not a character. Includes the
    /// 11 겹받침 (ㄳㄵㄶㄺㄻㄼㄽㄾㄿㅀㅄ) the IME composes from two
    /// consonant key presses.
    static let jongseongList: [Character?] = [
        nil,
        "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ",
        "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ", "ㅆ",
        "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]

    // MARK: - Compound composition rules

    /// Compound 중성 produced by the IME from two vowel key presses.
    /// Example: ㅗ + ㅏ → ㅘ. These are not on the keyboard directly.
    static let vowelCompoundRules: [Character: [Character: Character]] = [
        "ㅗ": ["ㅏ": "ㅘ", "ㅐ": "ㅙ", "ㅣ": "ㅚ"],
        "ㅜ": ["ㅓ": "ㅝ", "ㅔ": "ㅞ", "ㅣ": "ㅟ"],
        "ㅡ": ["ㅣ": "ㅢ"],
    ]

    /// Compound 종성 (겹받침) produced from two consonant key presses.
    static let finalCompoundRules: [Character: [Character: Character]] = [
        "ㄱ": ["ㅅ": "ㄳ"],
        "ㄴ": ["ㅈ": "ㄵ", "ㅎ": "ㄶ"],
        "ㄹ": ["ㄱ": "ㄺ", "ㅁ": "ㄻ", "ㅂ": "ㄼ", "ㅅ": "ㄽ",
                "ㅌ": "ㄾ", "ㅍ": "ㄿ", "ㅎ": "ㅀ"],
        "ㅂ": ["ㅅ": "ㅄ"],
    ]

    // MARK: - Compose (jamo sequence → syllables)

    /// Compose a sequence of jamo characters into Hangul syllables using
    /// the same maximal-munch automaton that real IMEs use. Leftover
    /// jamo at the end (e.g. an orphan 초성 with no following 중성) is
    /// discarded rather than emitted as a raw jamo — keeps decoded
    /// search queries clean. Non-jamo characters pass through unchanged.
    static func compose(jamo input: [Character]) -> String {
        var output = ""
        var i = 0
        while i < input.count {
            // Start a new syllable by looking for a 초성.
            let ch = input[i]
            guard let lIdx = choseongIndex(for: ch) else {
                // Not a leading consonant. If it's a stray vowel or
                // unmatched jamo, drop it silently — a recovery query
                // should never surface raw jamo. Non-jamo characters
                // (whitespace, Latin letters, punctuation) pass through.
                if jungseongList.contains(ch) {
                    i += 1
                } else {
                    output.append(ch)
                    i += 1
                }
                continue
            }

            // We have a 초성. Need at least a 중성 to complete a syllable.
            // If there isn't one, drop the orphan 초성.
            guard i + 1 < input.count else {
                i += 1
                continue
            }

            // Collect 중성 (possibly a compound via two vowels).
            var vIdx: Int?
            var consumed = 1
            if let firstVowel = jungseongBaseCharacter(at: i + 1, in: input) {
                if i + 2 < input.count,
                   let compound = compoundVowel(first: firstVowel, second: input[i + 2])
                {
                    vIdx = jungseongIndex(for: compound)
                    consumed = 3
                } else {
                    vIdx = jungseongIndex(for: firstVowel)
                    consumed = 2
                }
            }
            guard let v = vIdx else {
                // 초성 followed by a non-vowel. Drop the orphan.
                i += 1
                continue
            }

            // Collect optional 종성.
            var tIdx = 0
            let afterVowel = i + consumed
            if afterVowel < input.count,
               let firstFinal = jongseongIndex(for: input[afterVowel])
            {
                // 두벌식 ambiguity — if the next-next jamo is a vowel,
                // what looked like a 종성 is actually the next syllable's
                // 초성 (받침 이동 원리). Peek to decide.
                let hasVowelAfter = afterVowel + 1 < input.count
                    && jungseongBaseCharacter(at: afterVowel + 1, in: input) != nil

                if hasVowelAfter {
                    // Do not consume as 종성 — let next iteration pick it
                    // up as the next 초성.
                    tIdx = 0
                    consumed += 0
                } else if afterVowel + 1 < input.count,
                          let compoundFinal = compoundFinal(
                            first: input[afterVowel],
                            second: input[afterVowel + 1])
                {
                    // Check: is the next-next-next jamo a vowel?
                    // If so, the compound's second half actually belongs
                    // to the next syllable (받침 이동 two-character case).
                    let hasVowelAfterCompound = afterVowel + 2 < input.count
                        && jungseongBaseCharacter(at: afterVowel + 2, in: input) != nil
                    if hasVowelAfterCompound {
                        tIdx = firstFinal
                        consumed += 1
                    } else if let compoundIdx = jongseongIndexAllowingNil(for: compoundFinal) {
                        tIdx = compoundIdx
                        consumed += 2
                    } else {
                        tIdx = firstFinal
                        consumed += 1
                    }
                } else {
                    tIdx = firstFinal
                    consumed += 1
                }
            }

            let code = 0xAC00 + (lIdx * 588) + (v * 28) + tIdx
            if let scalar = Unicode.Scalar(code) {
                output.append(Character(scalar))
            }
            i += consumed
        }
        return output
    }

    // MARK: - Decompose (syllables → jamo sequence)

    /// Reverse of `compose`. Given a Hangul string, return the exact
    /// sequence of base jamo keys the user would have to press on
    /// 두벌식 to produce it. Non-Hangul characters pass through unchanged.
    static func decompose(_ text: String) -> [Character] {
        var jamo: [Character] = []
        for scalar in text.unicodeScalars {
            let code = Int(scalar.value)
            guard (0xAC00...0xD7A3).contains(code) else {
                jamo.append(Character(scalar))
                continue
            }
            let offset = code - 0xAC00
            let lIdx = offset / 588
            let vIdx = (offset % 588) / 28
            let tIdx = offset % 28

            jamo.append(choseongList[lIdx])

            // 중성 — split compound vowels back into their two bases.
            let vowel = jungseongList[vIdx]
            jamo.append(contentsOf: splitCompoundVowel(vowel))

            // 종성 — split 겹받침 back into its two base consonants.
            if tIdx > 0, let final = jongseongList[tIdx] {
                jamo.append(contentsOf: splitCompoundFinal(final))
            }
        }
        return jamo
    }

    // MARK: - Index helpers

    static func choseongIndex(for ch: Character) -> Int? {
        choseongList.firstIndex(of: ch)
    }

    static func jungseongIndex(for ch: Character) -> Int? {
        jungseongList.firstIndex(of: ch)
    }

    static func jongseongIndex(for ch: Character) -> Int? {
        for (i, slot) in jongseongList.enumerated() where slot == ch {
            return i
        }
        return nil
    }

    static func jongseongIndexAllowingNil(for ch: Character) -> Int? {
        jongseongIndex(for: ch)
    }

    // MARK: - Compound detection

    /// Returns the base jungseong character at position `i` if the
    /// character there is a simple vowel. Unlike `jungseongIndex`, this
    /// rejects compound vowels (which should have been produced via two
    /// key presses, not as a single jamo).
    static func jungseongBaseCharacter(at i: Int, in list: [Character]) -> Character? {
        let ch = list[i]
        let compounds: Set<Character> = ["ㅘ", "ㅙ", "ㅚ", "ㅝ", "ㅞ", "ㅟ", "ㅢ"]
        if compounds.contains(ch) { return nil }
        return jungseongList.contains(ch) ? ch : nil
    }

    static func compoundVowel(first: Character, second: Character) -> Character? {
        vowelCompoundRules[first]?[second]
    }

    static func compoundFinal(first: Character, second: Character) -> Character? {
        finalCompoundRules[first]?[second]
    }

    static func splitCompoundVowel(_ v: Character) -> [Character] {
        let reverse: [Character: (Character, Character)] = [
            "ㅘ": ("ㅗ", "ㅏ"), "ㅙ": ("ㅗ", "ㅐ"), "ㅚ": ("ㅗ", "ㅣ"),
            "ㅝ": ("ㅜ", "ㅓ"), "ㅞ": ("ㅜ", "ㅔ"), "ㅟ": ("ㅜ", "ㅣ"),
            "ㅢ": ("ㅡ", "ㅣ"),
        ]
        if let pair = reverse[v] { return [pair.0, pair.1] }
        return [v]
    }

    static func splitCompoundFinal(_ f: Character) -> [Character] {
        let reverse: [Character: (Character, Character)] = [
            "ㄳ": ("ㄱ", "ㅅ"), "ㄵ": ("ㄴ", "ㅈ"), "ㄶ": ("ㄴ", "ㅎ"),
            "ㄺ": ("ㄹ", "ㄱ"), "ㄻ": ("ㄹ", "ㅁ"), "ㄼ": ("ㄹ", "ㅂ"),
            "ㄽ": ("ㄹ", "ㅅ"), "ㄾ": ("ㄹ", "ㅌ"), "ㄿ": ("ㄹ", "ㅍ"),
            "ㅀ": ("ㄹ", "ㅎ"), "ㅄ": ("ㅂ", "ㅅ"),
        ]
        if let pair = reverse[f] { return [pair.0, pair.1] }
        return [f]
    }
}
