import Foundation

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
