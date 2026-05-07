import Foundation
import GRDB
import ClipRavenSync

struct TagRepository {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
    }

    @discardableResult
    func save(_ tag: inout Tag) throws -> Tag {
        try dbPool.write { db in
            try tag.save(db)
        }
        return tag
    }

    func fetchAll() throws -> [Tag] {
        try dbPool.read { db in
            try Tag.order(Column("name")).fetchAll(db)
        }
    }

    func fetchTags(forClipId clipId: Int64) throws -> [Tag] {
        try dbPool.read { db in
            try Clip
                .filter(id: clipId)
                .including(all: Clip.tags)
                .asRequest(of: ClipWithTags.self)
                .fetchOne(db)?
                .tags ?? []
        }
    }

    func assignTag(clipId: Int64, tagId: Int64) throws {
        try dbPool.write { db in
            let clipTag = ClipTag(clipId: clipId, tagId: tagId)
            try clipTag.insert(db, onConflict: .ignore)
        }
    }

    func removeTag(clipId: Int64, tagId: Int64) throws {
        try dbPool.write { db in
            try ClipTag
                .filter(Column("clipId") == clipId && Column("tagId") == tagId)
                .deleteAll(db)
        }
    }

    func delete(id: Int64) throws {
        try dbPool.write { db in
            // Remove all clip-tag associations first
            try ClipTag.filter(Column("tagId") == id).deleteAll(db)
            _ = try Tag.deleteOne(db, id: id)
        }
    }

    func fetchClipIds(forTagIds tagIds: Set<Int64>) throws -> [Int64] {
        try dbPool.read { db in
            try ClipTag
                .filter(tagIds.contains(Column("tagId")))
                .select(Column("clipId"))
                .asRequest(of: Int64.self)
                .fetchAll(db)
        }
    }

    func clipCount(forTagId tagId: Int64) throws -> Int {
        try dbPool.read { db in
            try ClipTag
                .filter(Column("tagId") == tagId)
                .joining(required: ClipTag.clip.filter(Column("isDeleted") == false))
                .fetchCount(db)
        }
    }
}

// Helper for fetching clips with associated tags
struct ClipWithTags: Decodable, FetchableRecord {
    var clip: Clip
    var tags: [Tag]
}
