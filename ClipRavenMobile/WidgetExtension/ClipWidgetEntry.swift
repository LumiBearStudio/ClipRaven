import Foundation
import WidgetKit
import ClipRavenSync

/// 위젯 타임라인 엔트리. 최근 클립 최대 8개를 담는다 (Large 위젯 대비).
///
/// 위젯 뷰가 직접 DB에 접근할 수 없으므로 Provider가 미리 읽어서
/// 이 엔트리에 담아 전달한다.
struct ClipWidgetEntry: TimelineEntry {
    let date: Date
    let clips: [ClipSnapshot]

    /// 프리뷰/에러 상태용 placeholder
    static let placeholder = ClipWidgetEntry(
        date: Date(),
        clips: [
            ClipSnapshot(
                id: 0,
                text: "회의 메모",
                contentType: "text",
                lastCopiedAt: Date().addingTimeInterval(-30),
                thumbnailData: nil,
                isPinned: true,
                hasNickname: true
            ),
            ClipSnapshot(
                id: 1,
                text: "https://github.com/lumibear/ClipRaven",
                contentType: "url",
                lastCopiedAt: Date().addingTimeInterval(-300),
                thumbnailData: nil,
                isPinned: false,
                hasNickname: false
            ),
            ClipSnapshot(
                id: 2,
                text: "let count = clips.count",
                contentType: "code",
                lastCopiedAt: Date().addingTimeInterval(-3600),
                thumbnailData: nil,
                isPinned: false,
                hasNickname: false
            ),
        ]
    )

    static let empty = ClipWidgetEntry(date: Date(), clips: [])
}

/// DB의 `Clip` 대신 위젯에서 쓰는 경량 스냅샷.
///
/// 의도적으로 컴팩트:
/// - `text`: nickname 우선, 없으면 contentText 앞 120자만 (전체 본문 보내면
///   메모리 압박 + 위젯이 작은 화면에 다 표시 못 함)
/// - `thumbnailData`: 썸네일은 메인 앱에서 미리 작은 사이즈 (~10-30KB)로
///   생성한 것. 위젯 메모리 한도 (~30MB) 안전 — 8개 × 30KB = 240KB.
/// - `isPinned`: 위젯에서 핀 아이콘 시각 표시 + 정렬에 활용.
struct ClipSnapshot: Identifiable, Codable {
    let id: Int64
    let text: String
    let contentType: String
    let lastCopiedAt: Date
    let thumbnailData: Data?
    let isPinned: Bool
    /// `text` 가 nickname 인지(true) contentText 인지(false). 표시 위계 구분에
    /// 사용 — nickname 은 약간 더 강조해서 보여줄 수 있음.
    let hasNickname: Bool

    var isURL: Bool   { contentType == "url" }
    var isImage: Bool { contentType == "image" }
    var isCode: Bool  { contentType == "code" }
    var isFile: Bool  { contentType == "file" }

    /// 위젯 카드에 표시할 짧은 미리보기 텍스트 (길이 제한).
    var preview: String { String(text.prefix(120)) }

    /// URL 클립이면 도메인만 (예: "github.com"), 아니면 preview 그대로.
    /// 위젯 좁은 행에서 전체 URL 보여주면 가독성 떨어짐.
    var displayText: String {
        if isURL,
           let url = URL(string: text),
           let host = url.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return preview
    }

    /// 상대 시간 표시 ("방금", "5분", "1시간", "어제", "3일", "2주").
    /// SwiftUI `.relative` 스타일 대신 직접 — Korean 단위 일관성.
    var relativeTime: String {
        let secs = Int(-lastCopiedAt.timeIntervalSinceNow)
        if secs < 60    { return "방금" }
        if secs < 3600  { return "\(secs / 60)분" }
        if secs < 86400 { return "\(secs / 3600)시간" }
        let days = secs / 86400
        if days == 1    { return "어제" }
        if days < 7     { return "\(days)일" }
        return "\(days / 7)주"
    }

    /// 콘텐츠 타입별 SF Symbol 이름.
    var typeIcon: String {
        if isPinned { return "pin.fill" }
        if isURL    { return "link" }
        if isCode   { return "chevron.left.forwardslash.chevron.right" }
        if isImage  { return "photo" }
        if isFile   { return "doc" }
        return "doc.text"
    }
}
