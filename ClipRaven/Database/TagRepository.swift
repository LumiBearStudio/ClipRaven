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

    /// 여러 클립의 태그를 한 번의 JOIN 으로 모두 fetch.
    /// 성능 감사 D-C2: 이전엔 클립 200개 표시 시 `fetchTags(forClipId:)` 가 200번 호출
    /// (N+1 쿼리). 단일 SQL 로 통합.
    ///
    /// - Returns: clipId → [Tag] 매핑. 태그가 없는 clipId 는 key 없음.
    func fetchTagsMap(forClipIds clipIds: [Int64]) throws -> [Int64: [Tag]] {
        guard !clipIds.isEmpty else { return [:] }
        return try dbPool.read { db in
            // GRDB raw SQL — clipId 와 함께 Tag 컬럼 모두 가져옴.
            let placeholders = Array(repeating: "?", count: clipIds.count).joined(separator: ",")
            let sql = """
                SELECT clipTags.clipId AS _clipId, tags.*
                FROM clipTags
                JOIN tags ON tags.id = clipTags.tagId
                WHERE clipTags.clipId IN (\(placeholders))
                ORDER BY tags.name
            """
            var result: [Int64: [Tag]] = [:]
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(clipIds))
            for row in rows {
                guard let clipId: Int64 = row["_clipId"] else { continue }
                let tag = try Tag(row: row)
                result[clipId, default: []].append(tag)
            }
            return result
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
            _ = try ClipTag
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
