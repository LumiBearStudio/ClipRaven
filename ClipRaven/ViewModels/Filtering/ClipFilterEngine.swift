import Foundation
import ClipRavenSync

/// In-memory clip 필터 엔진. 순수 함수로 단위 테스트 가능.
///
/// `MainPanelViewModel` 의 라이브 필터링은 DB observation 측에서 (인덱스 적용된)
/// SQL 로 진행되지만, 필터 규칙 자체의 정합성은 별도로 검증할 가치가 있다.
/// 또한 검색 결과 / OG 메타 등 in-memory array 에 적용 가능한 필터링이
/// 필요한 곳(서비스간 검증, 회귀 방지)에 재사용할 수 있다.
enum ClipFilterEngine {

    /// 필터 옵션. 모두 옵셔널 / 빈 컬렉션 → 해당 조건 무시.
    struct Options {
        var contentType: ContentType?
        var tagIds: Set<Int64>
        var clipTags: [Int64: [Tag]]  // clipId → assigned tags
        var sourceAppBundleId: String?
        var dateRange: (from: Date, to: Date)?
        var aiCategory: String?
        var searchText: String
        var showPinned: Bool

        init(
            contentType: ContentType? = nil,
            tagIds: Set<Int64> = [],
            clipTags: [Int64: [Tag]] = [:],
            sourceAppBundleId: String? = nil,
            dateRange: (from: Date, to: Date)? = nil,
            aiCategory: String? = nil,
            searchText: String = "",
            showPinned: Bool = true
        ) {
            self.contentType = contentType
            self.tagIds = tagIds
            self.clipTags = clipTags
            self.sourceAppBundleId = sourceAppBundleId
            self.dateRange = dateRange
            self.aiCategory = aiCategory
            self.searchText = searchText
            self.showPinned = showPinned
        }
    }

    /// 필터를 적용한 결과를 반환. 정렬은 호출자가 책임.
    /// 핀(`isPinned`) 클립은 `showPinned == false` 일 때 결과에서 제외.
    static func apply(_ clips: [Clip], options: Options) -> [Clip] {
        let trimmedSearch = options.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return clips.filter { clip in
            // 1. softDeleted 제외 (안전망)
            if clip.isDeleted { return false }

            // 2. 핀 제외 옵션
            if !options.showPinned && clip.isPinned { return false }

            // 3. 콘텐츠 타입
            if let ct = options.contentType, clip.contentType != ct { return false }

            // 4. 태그 (AND — 선택된 모든 태그가 클립에 할당돼 있어야)
            if !options.tagIds.isEmpty {
                guard let id = clip.id else { return false }
                let assigned = Set((options.clipTags[id] ?? []).compactMap { $0.id })
                guard options.tagIds.isSubset(of: assigned) else { return false }
            }

            // 5. 소스 앱 (정확히 일치)
            if let bundleId = options.sourceAppBundleId,
               clip.sourceAppBundleId != bundleId { return false }

            // 6. 날짜 범위 (createdAt 기준)
            if let range = options.dateRange {
                let created = clip.createdAt
                if created < range.from || created >= range.to { return false }
            }

            // 7. AI 카테고리
            if let cat = options.aiCategory, clip.aiCategory != cat { return false }

            // 8. 검색어 (contentText / nickname 부분 일치, case-insensitive)
            if !trimmedSearch.isEmpty {
                let text = (clip.contentText ?? "").lowercased()
                let nickname = (clip.nickname ?? "").lowercased()
                if !text.contains(trimmedSearch) && !nickname.contains(trimmedSearch) {
                    return false
                }
            }

            return true
        }
    }
}
