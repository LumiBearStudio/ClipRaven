import AppIntents
import Foundation
import ClipRavenSync

/// Full-text search across the clip history. Returns up to `limit` matches as
/// `ClipEntity` list. Supports Korean chosung (초성) queries automatically.
struct SearchClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Clipboard History"
    static var description = IntentDescription(
        "Searches ClipRaven's clipboard history (FTS5, with Korean chosung support).",
        categoryName: "ClipRaven"
    )

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Query", description: "텍스트, URL 조각, 또는 한글 초성 (예: ㅇㅇ)")
    var query: String

    @Parameter(
        title: "Limit",
        description: "반환할 최대 결과 수",
        default: 20,
        inclusiveRange: (1, 100)
    )
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search ClipRaven for \(\.$query)") {
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ClipEntity]> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(value: [])
        }

        let repo = SearchRepository()
        let results: [Clip]
        if ChosungConverter.isChosungOnly(trimmed) {
            results = (try? repo.searchChosung(query: trimmed, limit: limit)) ?? []
        } else {
            results = (try? repo.search(query: trimmed, contentType: nil, limit: limit)) ?? []
        }
        return .result(value: results.map { ClipEntity(from: $0) })
    }
}
