import Foundation
import AppKit

/// Converts between plain text, Markdown, Rich Text, and HTML for the
/// "Paste As…" context-menu flow.
///
/// Strategy:
/// - **Markdown → RTF** uses Apple's native `NSAttributedString(markdown:)` (macOS 12+),
///   which handles headings, bold/italic, links, lists, code blocks, etc.
/// - **HTML → Markdown** is a best-effort regex converter — good enough for most
///   web-copied blocks but not a full parser. For demanding cases users can round-trip
///   through NSAttributedString's HTML importer.
/// - **HTML → RTF** leverages `NSAttributedString(data:options:)` with the HTML type.
enum FormatConverter {

    // MARK: - Detection

    /// Heuristic: true if the input looks like HTML (contains at least one tag).
    static func looksLikeHTML(_ text: String) -> Bool {
        // Match `<foo>` or `<foo/>` or `<foo ...>`
        return text.range(of: #"<[a-zA-Z][^>]*>"#, options: .regularExpression) != nil
    }

    /// Heuristic: true if the input looks like Markdown (headings, list bullets, bold, links).
    static func looksLikeMarkdown(_ text: String) -> Bool {
        let patterns = [
            #"^\s{0,3}#{1,6} "#,      // headings
            #"^\s*[-*+] "#,            // bullet list
            #"^\s*\d+\.\s"#,           // numbered list
            #"\*\*[^*]+\*\*"#,         // bold
            #"\[[^\]]+\]\([^)]+\)"#,   // link [text](url)
            #"`[^`]+`"#                // inline code
        ]
        for p in patterns {
            if text.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Markdown → Rich Text (RTF)

    /// Convert Markdown-formatted text to an `NSAttributedString` ready for `.rtf` pasteboard.
    /// Returns nil if conversion fails.
    static func markdownToAttributed(_ markdown: String) -> NSAttributedString? {
        // .full option = paragraph-level parsing (headings, lists, blockquotes, code blocks)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.allowsExtendedAttributes = true

        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return nil
        }
        return NSAttributedString(attributed)
    }

    /// Encode an `NSAttributedString` as RTF data.
    static func rtfData(from attributed: NSAttributedString) -> Data? {
        try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    // MARK: - HTML → Rich Text

    /// Parse HTML into an NSAttributedString (via AppKit's HTML importer).
    static func htmlToAttributed(_ html: String) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    // MARK: - HTML → Markdown (best-effort)

    /// Convert simple HTML to a close-enough Markdown representation.
    /// Not a full parser — handles common tags produced by typical web copies.
    static func htmlToMarkdown(_ html: String) -> String {
        var s = html

        // Drop common wrapper noise
        s = s.replacingOccurrences(of: #"<!DOCTYPE[^>]+>"#, with: "", options: .regularExpression)
        // Script/style: remove tag PLUS their inline contents (security: user-facing Markdown
        // should never include executable JS or raw CSS).
        s = s.replacingOccurrences(of: #"<\s*script[^>]*>[\s\S]*?</\s*script\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<\s*style[^>]*>[\s\S]*?</\s*style\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        // Remaining structural tags: strip tags only (content often wraps body text).
        s = s.replacingOccurrences(of: #"<\s*(html|body|head|meta|link)[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"</\s*(html|body|head)\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        // Strip HTML comments
        s = s.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)

        // Headings
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level)
            s = s.replacingOccurrences(
                of: "<\\s*h\(level)[^>]*>([\\s\\S]*?)</\\s*h\(level)\\s*>",
                with: "\n\n\(prefix) $1\n\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Inline: strong/b, em/i, code
        s = s.replacingOccurrences(of: #"<\s*(strong|b)\s*>([\s\S]*?)</\s*\1\s*>"#,
                                    with: "**$2**",
                                    options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<\s*(em|i)\s*>([\s\S]*?)</\s*\1\s*>"#,
                                    with: "*$2*",
                                    options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<\s*code\s*>([\s\S]*?)</\s*code\s*>"#,
                                    with: "`$1`",
                                    options: [.regularExpression, .caseInsensitive])

        // Links: <a href="URL">text</a> → [text](URL)
        s = s.replacingOccurrences(
            of: #"<\s*a[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</\s*a\s*>"#,
            with: "[$2]($1)",
            options: [.regularExpression, .caseInsensitive]
        )

        // Images: <img src="URL" alt="text"> → ![text](URL)
        s = s.replacingOccurrences(
            of: #"<\s*img[^>]*src\s*=\s*["']([^"']+)["'][^>]*alt\s*=\s*["']([^"']*)["'][^>]*/?>"#,
            with: "![$2]($1)",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"<\s*img[^>]*src\s*=\s*["']([^"']+)["'][^>]*/?>"#,
            with: "![]($1)",
            options: [.regularExpression, .caseInsensitive]
        )

        // Line breaks / paragraphs
        s = s.replacingOccurrences(of: #"<\s*br\s*/?\s*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"</\s*p\s*>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<\s*p[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])

        // Lists — unordered
        s = s.replacingOccurrences(
            of: #"<\s*li[^>]*>([\s\S]*?)</\s*li\s*>"#,
            with: "- $1\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: #"<\s*/?\s*(ul|ol)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])

        // Code blocks <pre><code> or <pre>
        s = s.replacingOccurrences(
            of: #"<\s*pre[^>]*>\s*<\s*code[^>]*>([\s\S]*?)</\s*code\s*>\s*</\s*pre\s*>"#,
            with: "\n```\n$1\n```\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"<\s*pre[^>]*>([\s\S]*?)</\s*pre\s*>"#,
            with: "\n```\n$1\n```\n",
            options: [.regularExpression, .caseInsensitive]
        )

        // Blockquotes
        s = s.replacingOccurrences(
            of: #"<\s*blockquote[^>]*>([\s\S]*?)</\s*blockquote\s*>"#,
            with: "\n> $1\n",
            options: [.regularExpression, .caseInsensitive]
        )

        // Strip any remaining tags
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // Decode HTML entities
        s = decodeHTMLEntities(s)

        // Tidy whitespace
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        return s
    }

    // MARK: - HTML entity decoding

    private static let htmlEntities: [String: String] = [
        "&amp;": "&",   "&lt;": "<",   "&gt;": ">",
        "&quot;": "\"", "&apos;": "'", "&#39;": "'",
        "&nbsp;": " ",  "&mdash;": "—", "&ndash;": "–",
        "&hellip;": "…", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}"
    ]

    private static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        for (entity, replacement) in htmlEntities {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities like &#65; → 'A'
        out = out.replacingOccurrences(
            of: #"&#(\d+);"#,
            with: "",
            options: .regularExpression
        ) // Strip rare numeric entities (intentionally simple)
        return out
    }
}
