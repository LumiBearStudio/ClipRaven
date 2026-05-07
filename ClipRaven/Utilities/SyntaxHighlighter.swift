import SwiftUI

enum SyntaxHighlighter {
    // MARK: - Token Types
    enum TokenType {
        case keyword, string, comment, number, type, function, preprocessor
    }

    // MARK: - Regex patterns (applied in order, first match wins per range)
    private static let patterns: [(TokenType, NSRegularExpression)] = {
        let defs: [(TokenType, String)] = [
            // Comments: // line, /* block */, # line (Python/Ruby/Shell)
            (.comment,      #"//.*$|/\*[\s\S]*?\*/|(?<=^|\s)#(?!include|import|define|pragma|if).*$"#),
            // Strings: "...", '...', `...` (backtick), """...""" (triple-quote)
            (.string,       #"\"\"\"[\s\S]*?\"\"\"|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`[^`]*`"#),
            // Numbers: integers, floats, hex, binary
            (.number,       #"\b(?:0x[0-9a-fA-F]+|0b[01]+|0o[0-7]+|\d+\.?\d*(?:e[+-]?\d+)?)\b"#),
            // Preprocessor: import, #include, require, using, from...import
            (.preprocessor, #"^\s*(?:#\s*(?:include|import|define|pragma|if|endif|else)|import\b|from\b|require\b|using\b|package\b)"#),
            // Keywords
            (.keyword,      #"\b(?:func|def|function|class|struct|enum|protocol|interface|trait|if|else|else\s+if|elif|for|while|do|switch|case|default|guard|return|break|continue|let|var|const|val|pub|fn|impl|self|this|super|true|false|nil|null|None|undefined|async|await|try|catch|throw|throws|new|static|private|public|internal|protected|override|final|abstract|open|extension|where|in|as|is|not|and|or|pass|yield|with|lambda|mut|dyn|match|some|any)\b"#),
            // Types: PascalCase identifiers
            (.type,         #"\b[A-Z][a-zA-Z0-9_]*\b"#),
            // Functions: identifier followed by (
            (.function,     #"\b[a-zA-Z_]\w*(?=\s*\()"#),
        ]

        return defs.compactMap { (type, pattern) in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                return nil
            }
            return (type, regex)
        }
    }()

    // MARK: - Cache
    private static let cache = NSCache<NSString, CacheEntry>()

    private final class CacheEntry {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    // MARK: - Public API

    /// 카드 프리뷰용 — 최대 15줄 / 500자로 truncate
    static func highlight(_ code: String, isDark: Bool = true) -> AttributedString {
        let truncated = truncateForPreview(code)

        let cacheKey = "card_\(truncated.hashValue)_\(isDark)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }

        let result = performHighlight(truncated, isDark: isDark)
        cache.setObject(CacheEntry(result), forKey: cacheKey)
        return result
    }

    /// 프리뷰 패널용 — 전체 코드 하이라이팅 (truncation 없음)
    static func highlightFull(_ code: String, isDark: Bool = true) -> AttributedString {
        let cacheKey = "full_\(code.hashValue)_\(isDark)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }

        var result = performHighlight(code, isDark: isDark)
        // 프리뷰는 카드보다 폰트 크기를 살짝 키움 (12pt)
        result.font = .system(size: 12, design: .monospaced)

        cache.setObject(CacheEntry(result), forKey: cacheKey)
        return result
    }

    // MARK: - Private

    private static func truncateForPreview(_ code: String) -> String {
        let lines = code.components(separatedBy: .newlines)
        let trimmedLines = Array(lines.prefix(15))
        let joined = trimmedLines.joined(separator: "\n")
        return String(joined.prefix(500))
    }

    private static func performHighlight(_ code: String, isDark: Bool) -> AttributedString {
        var result = AttributedString(code)
        result.font = .system(size: 10, design: .monospaced)
        result.foregroundColor = isDark
            ? Color(red: 0.78, green: 0.80, blue: 0.83)  // ABB2BF
            : Color(red: 0.20, green: 0.20, blue: 0.25)

        let nsCode = code as NSString
        var claimed = IndexSet()

        for (tokenType, regex) in patterns {
            let matches = regex.matches(in: code, range: NSRange(location: 0, length: nsCode.length))

            for match in matches {
                let range = match.range
                guard range.length > 0 else { continue }

                // Skip already claimed ranges
                let rangeSet = IndexSet(integersIn: range.location..<(range.location + range.length))
                guard claimed.isDisjoint(with: rangeSet) else { continue }
                claimed.formUnion(rangeSet)

                // Convert NSRange → AttributedString.Index range
                guard let swiftRange = Range(range, in: code) else { continue }
                let startIdx = AttributedString.Index(swiftRange.lowerBound, within: result)
                let endIdx = AttributedString.Index(swiftRange.upperBound, within: result)
                guard let startIdx, let endIdx else { continue }

                result[startIdx..<endIdx].foregroundColor = color(for: tokenType, isDark: isDark)
            }
        }

        return result
    }

    // MARK: - One Dark / Light Theme Colors

    private static func color(for token: TokenType, isDark: Bool) -> Color {
        if isDark {
            switch token {
            case .keyword:      return Color(red: 0.78, green: 0.47, blue: 0.86) // #C678DD purple
            case .string:       return Color(red: 0.59, green: 0.77, blue: 0.49) // #98C379 green
            case .comment:      return Color(red: 0.45, green: 0.50, blue: 0.56) // #5C6370 gray
            case .number:       return Color(red: 0.82, green: 0.60, blue: 0.40) // #D19A66 orange
            case .type:         return Color(red: 0.90, green: 0.75, blue: 0.47) // #E5C07B yellow
            case .function:     return Color(red: 0.38, green: 0.71, blue: 0.93) // #61AFEF blue
            case .preprocessor: return Color(red: 0.88, green: 0.43, blue: 0.45) // #E06C75 red
            }
        } else {
            switch token {
            case .keyword:      return Color(red: 0.55, green: 0.22, blue: 0.67)
            case .string:       return Color(red: 0.31, green: 0.54, blue: 0.25)
            case .comment:      return Color(red: 0.45, green: 0.50, blue: 0.56)
            case .number:       return Color(red: 0.68, green: 0.45, blue: 0.15)
            case .type:         return Color(red: 0.15, green: 0.40, blue: 0.55)
            case .function:     return Color(red: 0.20, green: 0.45, blue: 0.70)
            case .preprocessor: return Color(red: 0.70, green: 0.30, blue: 0.20)
            }
        }
    }
}
