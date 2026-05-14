import Foundation

/// 텍스트 콘텐츠 정규화 — 일관된 해시(중복 검출) 와 sync 호환성을 위한 단일 진입점.
///
/// 두 가지 핵심 작업:
/// 1. **`normalize(_:)`** — trim + 공백 정리 + NFC 정규화. macOS / iOS 양쪽이
///    같은 해시를 계산할 수 있게 한다. cross-device dedup 의 기반.
/// 2. **`stripInvisibleCharacters(_:)`** — BOM, zero-width joiner, NBSP 등 invisible
///    제어 문자를 정리. UserDefaults `stripInvisibleChars` (기본 ON) 가 활성화되면
///    캡처 시 자동 적용.
public enum TextNormalizer {
    /// Normalize text for consistent hashing: trim, collapse whitespace, NFC normalization
    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping  // Unicode NFC
    }

    /// Invisible/control characters that commonly get pasted in by accident.
    /// Code points are compared on the `unicodeScalars` view because Swift's
    /// default String.contains uses grapheme clusters, where ZWJ/ZWNJ never
    /// stand alone and would never match (e.g. "a\u{200C}b".contains("\u{200C}")
    /// returns false).
    ///
    /// - U+FEFF (BOM / zero-width no-break space)     → drop
    /// - U+200B (zero-width space)                    → drop
    /// - U+200C (zero-width non-joiner)               → drop
    /// - U+200D (zero-width joiner)                   → drop
    /// - U+2060 (word joiner)                         → drop
    /// - U+00A0 (non-breaking space)                  → replace with U+0020
    private static let invisibleScalars: [(scalar: Unicode.Scalar, replacement: Unicode.Scalar?)] = [
        (Unicode.Scalar(0xFEFF)!, nil),            // BOM
        (Unicode.Scalar(0x200B)!, nil),            // zero-width space
        (Unicode.Scalar(0x200C)!, nil),            // zero-width non-joiner
        (Unicode.Scalar(0x200D)!, nil),            // zero-width joiner
        (Unicode.Scalar(0x2060)!, nil),            // word joiner
        (Unicode.Scalar(0x00A0)!, Unicode.Scalar(0x20)!)  // NBSP → regular space
    ]

    /// Strip invisible/control characters that pollute pasted text.
    /// Does not affect the original `contentType` — safe for text, code, URL, color.
    public static func stripInvisibleCharacters(_ text: String) -> String {
        let replacementMap = Dictionary(
            uniqueKeysWithValues: invisibleScalars.map { ($0.scalar, $0.replacement) }
        )
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let replacement = replacementMap[scalar] {
                if let r = replacement { out.append(r) }
                // else: drop
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
