import SwiftUI
import ClipRavenSync

/// 메인 패널의 콘텐츠 타입 필터.
///
/// `Clip.contentType` (텍스트/URL/코드/이미지/컬러/파일) 위에 "전체"를 추가한 UI 전용
/// 표현. 칩 row 와 카운트 뱃지가 이 enum 을 직접 사용한다.
///
/// ### 매핑 (`contentType` 속성)
/// - `.all` → `nil` (DB 쿼리에서 조건 생략)
/// - 그 외 → 대응하는 `ContentType`
///
/// ### 표시 (`displayName`, `systemImage`)
/// - 한국어 LocalizedStringKey 직접 사용 — 칩 라벨로 즉시 렌더
/// - SF Symbols 시스템 이미지로 칩 아이콘 표시
enum ContentTypeFilter: CaseIterable {
    case all, text, code, url, image, color, file

    /// 칩 라벨에 표시되는 한국어 이름.
    var displayName: LocalizedStringKey {
        switch self {
        case .all:   return "전체"
        case .text:  return "텍스트"
        case .code:  return "코드"
        case .url:   return "URL"
        case .image: return "이미지"
        case .color: return "컬러"
        case .file:  return "파일"
        }
    }

    /// 칩에 표시되는 SF Symbols 이름.
    var systemImage: String {
        switch self {
        case .all:   return "tray.full"
        case .text:  return "doc.text"
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .url:   return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file:  return "doc"
        }
    }

    /// DB 쿼리용 `ContentType` 매핑. `.all` 만 `nil` 을 반환해 호출자가 조건 생략하게 한다.
    var contentType: ContentType? {
        switch self {
        case .all:   return nil
        case .text:  return .text
        case .code:  return .code
        case .url:   return .url
        case .image: return .image
        case .color: return .color
        case .file:  return .file
        }
    }
}
