import Foundation
import GRDB

/// 사용자 정의 태그 — 클립을 분류하는 단위. `tags` 테이블에 1행씩 저장된다.
///
/// 클립 ↔ 태그 다대다 관계는 `ClipTag` 조인 테이블이 담당. 동기화 단위로
/// `uuid` / `deviceId` / `updatedAt` 메타가 v12 부터 추가됨.
public struct Tag: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    public var colorHex: String
    public var createdAt: Date = Date()

    // iCloud sync metadata (v12). See DatabaseMigrations.v12_syncMeta.
    public var uuid: String?
    public var deviceId: String?
    public var schemaVersion: Int = 1
    public var updatedAt: Date?
    public var ckSystemFields: Data?
    public var ckSyncState: Int = 0
    public var ckLastSyncedAt: Date?

    public init(
        id: Int64? = nil,
        name: String,
        colorHex: String,
        createdAt: Date = Date(),
        uuid: String? = nil,
        deviceId: String? = nil,
        schemaVersion: Int = 1,
        updatedAt: Date? = nil,
        ckSystemFields: Data? = nil,
        ckSyncState: Int = 0,
        ckLastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.uuid = uuid
        self.deviceId = deviceId
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.ckSystemFields = ckSystemFields
        self.ckSyncState = ckSyncState
        self.ckLastSyncedAt = ckLastSyncedAt
    }
}

extension Tag: TableRecord, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tags"

    public static let clipTags = hasMany(ClipTag.self)
    public static let clips = hasMany(Clip.self, through: clipTags, using: ClipTag.clip)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
