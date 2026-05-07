import Foundation
import GRDB
import ClipRavenSync

/// iOS Tag CRUD — Mac TagRepository와 동일한 인터페이스 서브셋.
/// tags / clipTags 테이블은 IosMigrations.v1_iosInitial에서 이미 생성됨.
struct TagRepository {

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
    }

    // MARK: - Read

    func fetchAll() throws -> [Tag] {
        try dbPool.read { db in
            try Tag.order(Column("name")).fetchAll(db)
        }
    }

    func fetchTags(forClipId clipId: Int64) throws -> [Tag] {
        try dbPool.read { db in
            let clipTagIds = try ClipTag
                .filter(Column("clipId") == clipId)
                .select(Column("tagId"))
                .asRequest(of: Int64.self)
                .fetchAll(db)
            return try Tag
                .filter(clipTagIds.contains(Column("id")))
                .order(Column("name"))
                .fetchAll(db)
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

    // MARK: - Write

    @discardableResult
    func create(name: String, colorHex: String) throws -> Tag {
        var tag = Tag(
            name: name,
            colorHex: colorHex,
            createdAt: Date(),
            uuid: UUID().uuidString,
            deviceId: DeviceIdentity.deviceId,
            updatedAt: Date()
        )
        try dbPool.write { db in try tag.save(db) }
        return tag
    }

    func update(id: Int64, name: String, colorHex: String) throws {
        try dbPool.write { db in
            guard var tag = try Tag.fetchOne(db, id: id) else { return }
            tag.name = name
            tag.colorHex = colorHex
            tag.updatedAt = Date()
            try tag.update(db)
        }
    }

    func delete(id: Int64) throws {
        try dbPool.write { db in
            try ClipTag.filter(Column("tagId") == id).deleteAll(db)
            _ = try Tag.deleteOne(db, id: id)
        }
    }

    // MARK: - Assign / Remove

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
}
