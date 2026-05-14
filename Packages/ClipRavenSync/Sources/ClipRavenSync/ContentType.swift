import Foundation

/// 클립 콘텐츠 타입. `Clip.contentType` 의 값.
///
/// - `text`: 일반 텍스트
/// - `code`: 코드 (휴리스틱 분류 — `CodeLanguageDetector`)
/// - `url`: URL 문자열 (`URLNormalizer.isURL` 통과)
/// - `image`: 이미지 (raw 데이터는 별도 디스크에, `imagePath` 가 가리킴)
/// - `color`: 컬러 hex (`ColorParser` 가 인식한 #RRGGBB / rgb() 등)
/// - `file`: 파일 URL — single 또는 newline-join 다중
///
/// `rawValue` 는 SQLite 컬럼에 그대로 저장된다. 한 번 정해진 값은 마이그레이션
/// 없이 변경 불가.
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
