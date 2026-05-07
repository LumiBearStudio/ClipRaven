import AppIntents
import Foundation
import ClipRavenSync

/// Returns every live clip that carries the given tag.
/// The `tag` parameter is a dropdown populated by `TagQuery`.
struct GetClipsByTagIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Clips by Tag"
    static var description = IntentDescription(
        "Returns all clips that have a specific tag.",
        categoryName: "ClipRaven"
    )

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Tag")
    var tag: TagEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get clips tagged \(\.$tag)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ClipEntity]> {
        let tagRepo = TagRepository()
        let clipIds = (try? tagRepo.fetchClipIds(forTagIds: [tag.tagId])) ?? []
        guard !clipIds.isEmpty else {
            return .result(value: [])
        }

        let clipRepo = ClipRepository()
        // Deduplicate while preserving order (a clip may have multiple tags in the join table)
        var seen = Set<Int64>()
        var clips: [Clip] = []
        for id in clipIds where !seen.contains(id) {
            seen.insert(id)
            if let clip = try? clipRepo.fetchOne(id: id), !clip.isDeleted {
                clips.append(clip)
            }
        }

        // Match in-app ordering: pinned first, then by lastCopiedAt DESC
        clips.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }

        return .result(value: clips.map { ClipEntity(from: $0) })
    }
}
