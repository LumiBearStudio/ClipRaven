import Foundation
import Combine
import ClipRavenSync

@MainActor
final class TagViewModel: ObservableObject {
    @Published var allTags: [Tag] = []
    @Published var assignedTagIds: Set<Int64> = []

    private let tagRepository = TagRepository()

    func loadTags(forClipId clipId: Int64) {
        allTags = (try? tagRepository.fetchAll()) ?? []
        let assigned = (try? tagRepository.fetchTags(forClipId: clipId)) ?? []
        assignedTagIds = Set(assigned.compactMap { $0.id })
    }

    func toggleTag(_ tag: Tag, forClipId clipId: Int64) {
        guard let tagId = tag.id else { return }

        if assignedTagIds.contains(tagId) {
            try? tagRepository.removeTag(clipId: clipId, tagId: tagId)
            assignedTagIds.remove(tagId)
        } else {
            try? tagRepository.assignTag(clipId: clipId, tagId: tagId)
            assignedTagIds.insert(tagId)
        }
    }

    func createTag(name: String, colorHex: String) {
        var tag = Tag(name: name, colorHex: colorHex)
        _ = try? tagRepository.save(&tag)
        allTags = (try? tagRepository.fetchAll()) ?? []
    }

    func deleteTag(_ tag: Tag) {
        guard let id = tag.id else { return }
        try? tagRepository.delete(id: id)
        allTags = (try? tagRepository.fetchAll()) ?? []
    }
}
