import Foundation

enum CodeLanguageDetector {
    /// Detect if text looks like source code
    static func isCode(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return false }

        var codeScore = 0

        // Check for common code patterns
        let patterns: [(String, Int)] = [
            ("^\\s*(func |def |function |class |struct |enum |protocol |interface )", 3),
            ("^\\s*(import |#include |using |require |from .+ import)", 3),
            ("^\\s*(if |else |for |while |switch |guard |do \\{)", 2),
            ("\\{\\s*$", 1),
            ("^\\s*\\}", 1),
            ("^\\s*(let |var |const |val |int |string )", 2),
            ("^\\s*//|^\\s*/\\*|^\\s*\\*|^\\s*#", 1),
            ("\\);\\s*$|;\\s*$", 1),
            ("=>|->|\\|>", 1),
            ("^\\s*@\\w+", 1),
            ("\\b(return |print\\(|console\\.|println)", 1),
        ]

        for line in lines.prefix(20) {
            for (pattern, score) in patterns {
                if line.range(of: pattern, options: .regularExpression) != nil {
                    codeScore += score
                }
            }
        }

        // Threshold: need at least some code-like patterns
        return codeScore >= 4
    }

    /// Detect likely language
    static func detectLanguage(_ text: String) -> String? {
        let indicators: [(String, [String])] = [
            ("swift", ["func ", "var ", "let ", "guard ", "@objc", "import SwiftUI", "import Foundation"]),
            ("python", ["def ", "import ", "from ", "self.", "__init__", "print("]),
            ("javascript", ["const ", "function ", "=>", "console.", "require(", "module.exports"]),
            ("typescript", ["interface ", ": string", ": number", "export ", "import {"]),
            ("html", ["<div", "<span", "<html", "<!DOCTYPE"]),
            ("css", ["{", "margin:", "padding:", "display:", "color:"]),
            ("rust", ["fn ", "let mut ", "impl ", "pub ", "use "]),
            ("go", ["func ", "package ", "import (", "fmt.", ":= "]),
        ]

        var bestMatch: (String, Int) = ("", 0)
        for (lang, keywords) in indicators {
            let count = keywords.filter { text.contains($0) }.count
            if count > bestMatch.1 {
                bestMatch = (lang, count)
            }
        }

        return bestMatch.1 >= 2 ? bestMatch.0 : nil
    }
}
