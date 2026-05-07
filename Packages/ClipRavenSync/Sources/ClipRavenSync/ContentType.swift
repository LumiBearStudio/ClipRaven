import Foundation

public enum ContentType: String, Codable, CaseIterable {
    case text
    case code
    case url
    case image
    case color
    case file

    public var displayName: String {
        switch self {
        case .text: return String(localized: "텍스트", bundle: .module)
        case .code: return String(localized: "코드", bundle: .module)
        case .url: return "URL"
        case .image: return String(localized: "이미지", bundle: .module)
        case .color: return String(localized: "컬러", bundle: .module)
        case .file: return String(localized: "파일", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .text: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .url: return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file: return "doc"
        }
    }
}
