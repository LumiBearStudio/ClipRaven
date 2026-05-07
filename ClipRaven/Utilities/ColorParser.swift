import Foundation

enum ColorParser {
    /// Check if text is a color representation
    static func isColor(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isHexColor(trimmed) || isRGBColor(trimmed) || isHSLColor(trimmed)
    }

    private static func isHexColor(_ text: String) -> Bool {
        let pattern = "^#?([0-9A-Fa-f]{3}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isRGBColor(_ text: String) -> Bool {
        let pattern = "^rgba?\\(\\s*\\d{1,3}\\s*,\\s*\\d{1,3}\\s*,\\s*\\d{1,3}(\\s*,\\s*[\\d.]+)?\\s*\\)$"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isHSLColor(_ text: String) -> Bool {
        let pattern = "^hsla?\\(\\s*\\d{1,3}\\s*,\\s*\\d{1,3}%\\s*,\\s*\\d{1,3}%(\\s*,\\s*[\\d.]+)?\\s*\\)$"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Normalize color to 8-digit hex (RRGGBBAA)
    static func normalizeToHex8(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")

        switch trimmed.count {
        case 3: // RGB -> RRGGBBFF
            let expanded = trimmed.map { "\($0)\($0)" }.joined()
            return expanded.uppercased() + "FF"
        case 4: // RGBA -> RRGGBBAA
            let expanded = trimmed.map { "\($0)\($0)" }.joined()
            return expanded.uppercased()
        case 6: // RRGGBB -> RRGGBBFF
            return trimmed.uppercased() + "FF"
        case 8: // RRGGBBAA
            return trimmed.uppercased()
        default:
            return nil
        }
    }
}
