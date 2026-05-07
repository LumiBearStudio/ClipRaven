import AppIntents
import Foundation

/// Enumerable query — Shortcuts knows the full tag set up front so it can render
/// a plain dropdown instead of a search-as-you-type field.
struct TagQuery: EntityQuery, EnumerableEntityQuery {

    /// Called when a user binds a tag parameter — returns the complete tag list.
    func allEntities() async throws -> [TagEntity] {
        let repo = TagRepository()
        let tags = (try? repo.fetchAll()) ?? []
        return tags.map { TagEntity(from: $0) }
    }

    /// Called when Shortcuts restores a saved intent — look tags up by their IDs.
    func entities(for identifiers: [TagEntity.ID]) async throws -> [TagEntity] {
        let all = try await allEntities()
        let wanted = Set(identifiers)
        return all.filter { wanted.contains($0.id) }
    }
}
