import Foundation
import CryptoKit

// MARK: - Category

enum TransformCategory: String, CaseIterable {
    case caseChange = "대소문자"
    case whitespace = "공백 / 줄바꿈"
    case encoding   = "인코딩"
    case hash       = "해시"
    case format     = "포맷"
}

// MARK: - TextTransform

/// 텍스트 변환 후 붙여넣기를 위한 변환 종류
enum TextTransform: String, CaseIterable, Identifiable {

    // 대소문자 (2)
    case uppercase
    case lowercase

    // 공백 / 줄바꿈 (4)
    case trim
    case joinLines
    case collapseSpaces
    case crlfToLf

    // 인코딩 (6)
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode
    case htmlEncode
    case htmlDecode

    // 해시 (2)
    case md5
    case sha256

    // 포맷 (3)
    case jsonFormat
    case jsonMinify
    case slugify

    var id: String { rawValue }

    // MARK: - Category

    var category: TransformCategory {
        switch self {
        case .uppercase, .lowercase:
            return .caseChange
        case .trim, .joinLines, .collapseSpaces, .crlfToLf:
            return .whitespace
        case .urlEncode, .urlDecode, .base64Encode, .base64Decode, .htmlEncode, .htmlDecode:
            return .encoding
        case .md5, .sha256:
            return .hash
        case .jsonFormat, .jsonMinify, .slugify:
            return .format
        }
    }

    // MARK: - Display Name

    var displayName: String {
        switch self {
        case .uppercase:      return "대문자로"
        case .lowercase:      return "소문자로"
        case .trim:           return "앞뒤 공백 제거"
        case .joinLines:      return "한 줄로 합치기"
        case .collapseSpaces: return "연속 공백 축소"
        case .crlfToLf:       return "CRLF → LF"
        case .urlEncode:      return "URL 인코딩"
        case .urlDecode:      return "URL 디코딩"
        case .base64Encode:   return "Base64 인코딩"
        case .base64Decode:   return "Base64 디코딩"
        case .htmlEncode:     return "HTML 인코딩"
        case .htmlDecode:     return "HTML 디코딩"
        case .md5:            return "MD5 해시"
        case .sha256:         return "SHA-256 해시"
        case .jsonFormat:     return "JSON 포맷 (들여쓰기)"
        case .jsonMinify:     return "JSON 압축"
        case .slugify:        return "Slug 변환"
        }
    }

    // MARK: - SF Symbol

    var systemImage: String {
        switch self {
        case .uppercase:      return "textformat.size.larger"
        case .lowercase:      return "textformat.size.smaller"
        case .trim:           return "scissors"
        case .joinLines:      return "text.alignleft"
        case .collapseSpaces: return "space"
        case .crlfToLf:       return "return"
        case .urlEncode:      return "link"
        case .urlDecode:      return "link.badge.plus"
        case .base64Encode:   return "lock.doc"
        case .base64Decode:   return "lock.open.doc"
        case .htmlEncode:     return "chevron.left.forwardslash.chevron.right"
        case .htmlDecode:     return "chevron.left.slash.chevron.right"
        case .md5:            return "number"
        case .sha256:         return "shield"
        case .jsonFormat:     return "curlybraces"
        case .jsonMinify:     return "curlybraces.square"
        case .slugify:        return "minus"
        }
    }

    // MARK: - Apply

    func apply(to input: String) -> String {
        switch self {

        // 대소문자
        case .uppercase:
            return input.uppercased()
        case .lowercase:
            return input.lowercased()

        // 공백 / 줄바꿈
        case .trim:
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        case .joinLines:
            let collapsed = input
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n",   with: " ")
                .replacingOccurrences(of: "\r",   with: " ")
            return collapsed.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .collapseSpaces:
            return input.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .crlfToLf:
            return input.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r",   with: "\n")

        // 인코딩
        case .urlEncode:
            return input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        case .urlDecode:
            return input.removingPercentEncoding ?? input
        case .base64Encode:
            return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: input, options: .ignoreUnknownCharacters),
                  let decoded = String(data: data, encoding: .utf8)
            else { return input }
            return decoded
        case .htmlEncode:
            return input
                .replacingOccurrences(of: "&",  with: "&amp;")
                .replacingOccurrences(of: "<",  with: "&lt;")
                .replacingOccurrences(of: ">",  with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'",  with: "&#39;")
        case .htmlDecode:
            return input
                .replacingOccurrences(of: "&amp;",  with: "&")
                .replacingOccurrences(of: "&lt;",   with: "<")
                .replacingOccurrences(of: "&gt;",   with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;",  with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")

        // 해시
        case .md5:
            let digest = Insecure.MD5.hash(data: Data(input.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        case .sha256:
            let digest = SHA256.hash(data: Data(input.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()

        // 포맷
        case .jsonFormat:
            guard let data = input.data(using: .utf8),
                  let obj  = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
                  let str = String(data: pretty, encoding: .utf8)
            else { return input }
            return str
        case .jsonMinify:
            guard let data = input.data(using: .utf8),
                  let obj  = try? JSONSerialization.jsonObject(with: data),
                  let minified = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
                  let str = String(data: minified, encoding: .utf8)
            else { return input }
            return str
        case .slugify:
            return input
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "-")).inverted)
                .joined()
                .components(separatedBy: "-")
                .filter { !$0.isEmpty }
                .joined(separator: "-")
        }
    }
}
