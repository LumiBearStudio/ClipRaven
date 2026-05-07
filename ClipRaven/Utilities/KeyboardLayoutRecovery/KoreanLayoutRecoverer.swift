import Foundation

/// Bijective 두벌식 ↔ QWERTY mapping per KS X 5002. Every Latin letter
/// maps to exactly one base jamo and vice versa, and that mapping has
/// been stable since the mid-1990s — this table is a hard spec, not a
/// heuristic.
///
/// Layout visualised (only the letter rows matter):
///
///   q w e r t  y u i o p
///   ㅂ ㅈ ㄷ ㄱ ㅅ  ㅛ ㅕ ㅑ ㅐ ㅔ
///    a s d f g  h j k l
///    ㅁ ㄴ ㅇ ㄹ ㅎ  ㅗ ㅓ ㅏ ㅣ
///     z x c v b n m
///     ㅋ ㅌ ㅊ ㅍ ㅠ ㅜ ㅡ
///
/// Shift adds: Q→ㅃ W→ㅉ E→ㄸ R→ㄲ T→ㅆ O→ㅒ P→ㅖ
struct KoreanLayoutRecoverer: KeyboardLayoutRecoverer {
    let language = "ko"

    /// Minimum length for a candidate. 1-char queries are pure noise.
    /// 2-char Korean like "안녕" is common and meaningful — so we keep the
    /// floor at 2 and rely on the caller's "results > 0" gate to filter
    /// out weak Latin 2-grams like "an" → "무" that happen to be
    /// composable.
    private static let minimumQueryLength = 2

    // MARK: - Mapping tables

    private static let latinToJamo: [Character: Character] = [
        // Unshifted
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ",
        "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ",
        "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ",
        "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
        // Shifted — only the 7 jamo that change under Shift
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ",
        "O": "ㅒ", "P": "ㅖ",
    ]

    /// Reverse lookup. Built once at type-init. All entries are base jamo
    /// (compound vowels / 겹받침 are split before lookup).
    private static let jamoToLatin: [Character: Character] = {
        var dict: [Character: Character] = [:]
        for (latin, jamo) in latinToJamo {
            dict[jamo] = latin
        }
        return dict
    }()

    // MARK: - Skip patterns
    //
    // Heuristics that pre-filter obvious non-candidates. The cost of a
    // false negative (failing to offer a valid recovery) is low — the
    // user just doesn't see a banner. The cost of a false positive (a
    // banner that doesn't make sense) is a hit to product trust, so the
    // gates lean conservative.

    private static let shouldSkipPatterns: [NSRegularExpression] = {
        let patterns = [
            #"^https?://"#,        // URL
            #"@[^@\s]+\."#,        // email
            #"^[0-9]+$"#,          // pure numeric
            #"^[A-Fa-f0-9]{16,}$"#, // hex / hash
            #"^[\s]+$"#,           // whitespace only
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static func isLikelySkipCandidate(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return shouldSkipPatterns.contains { regex in
            regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    // MARK: - Decode Latin → Native

    /// Case: user typed English keys intending Korean. Convert every
    /// Latin letter to its paired jamo, then compose.
    func decodeLatinToNative(_ text: String) -> String? {
        guard text.count >= Self.minimumQueryLength else { return nil }
        guard !Self.isLikelySkipCandidate(text) else { return nil }

        // Require the text to be composed overwhelmingly of ASCII letters
        // — anything outside the Latin alphabet means the user was
        // already typing Korean (or mixing), so this direction doesn't
        // apply.
        let onlyLatinOrSpace = text.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) && $0.value < 128
                || CharacterSet.whitespaces.contains($0)
        }
        guard onlyLatinOrSpace else { return nil }

        var jamoSequence: [Character] = []
        for ch in text {
            if ch.isWhitespace {
                jamoSequence.append(ch)
                continue
            }
            guard let jamo = Self.latinToJamo[ch] else {
                // A non-mappable ASCII letter (digit, punctuation) means
                // the text is not plausibly a Korean mistype.
                return nil
            }
            jamoSequence.append(jamo)
        }

        let composed = HangulComposer.compose(jamo: jamoSequence)
        // Reject if composition produced no Hangul syllables — e.g.
        // the input was all vowels or all single-consonants.
        guard composed.unicodeScalars.contains(where: {
            (0xAC00...0xD7A3).contains($0.value)
        }) else {
            return nil
        }
        return composed
    }

    // MARK: - Decode Native → Latin

    /// Case: user typed Korean keys intending English. Decompose each
    /// syllable back to its jamo sequence, map each jamo to its Latin
    /// key.
    func decodeNativeToLatin(_ text: String) -> String? {
        guard text.count >= Self.minimumQueryLength else { return nil }
        guard !Self.isLikelySkipCandidate(text) else { return nil }

        // Require text to contain some Hangul — otherwise this direction
        // doesn't apply.
        let hasHangul = text.unicodeScalars.contains {
            (0xAC00...0xD7A3).contains($0.value)
                || (0x3131...0x318E).contains($0.value)  // bare jamo block
        }
        guard hasHangul else { return nil }

        let jamo = HangulComposer.decompose(text)
        var result = ""
        for ch in jamo {
            if ch.isWhitespace {
                result.append(ch)
                continue
            }
            guard let latin = Self.jamoToLatin[ch] else {
                // Unmappable character (for example Hanja, punctuation)
                // means the text isn't purely a mistyped-Korean-for-
                // -English case.
                return nil
            }
            result.append(latin)
        }
        // Return lowercase — users don't usually type Shift when
        // mistaking the layout, so upper-case output would look odd.
        return result.lowercased()
    }
}
