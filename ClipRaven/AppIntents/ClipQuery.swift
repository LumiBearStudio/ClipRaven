import AppIntents
import Foundation
import ClipRavenSync

/// Lookup strategy for `ClipEntity` parameters.
/// Supports id-based retrieval, free-text search, and "suggested" entities
/// (recent clips shown in Shortcuts dropdowns before the user types).
struct ClipQuery: EntityStringQuery {

    // MARK: - By ID
    /// Called when Shortcuts restores a saved intent — we get a list of IDs and
    /// must return the corresponding live entities (or nothing if deleted).
    func entities(for identifiers: [ClipEntity.ID]) async throws -> [ClipEntity] {
        let repo = ClipRepository()
        return identifiers.compactMap { idString -> ClipEntity? in
            guard let id = Int64(idString),
                  let clip = try? repo.fetchOne(id: id),
                  !clip.isDeleted else {
                return nil
            }
            return ClipEntity(from: clip)
        }
    }

    // MARK: - By search string
    /// Powers the "find a clip" search box in Shortcuts.
    /// Uses FTS5 (or chosung for Korean consonant queries) — identical to the
    /// in-panel search experience.
    func entities(matching string: String) async throws -> [ClipEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await suggestedEntities() }

        let repo = SearchRepository()
        let results: [Clip]
        if ChosungConverter.isChosungOnly(trimmed) {
            results = (try? repo.searchChosung(query: trimmed, limit: 50)) ?? []
        } else {
            results = (try? repo.search(query: trimmed, contentType: nil, limit: 50)) ?? []
        }
        return results.map { ClipEntity(from: $0) }
    }

    // MARK: - Suggestions
    /// Default dropdown contents — shown before the user searches.
    /// We surface the 20 most-recent non-deleted clips.
    func suggestedEntities() async throws -> [ClipEntity] {
        let repo = ClipRepository()
        let clips = (try? repo.fetchAll(limit: 20)) ?? []
        return clips.map { ClipEntity(from: $0) }
    }
}
