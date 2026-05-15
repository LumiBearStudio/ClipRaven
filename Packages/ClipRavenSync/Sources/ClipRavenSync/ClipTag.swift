import Foundation
import GRDB

/// 클립 ↔ 태그 다대다 조인. `clipTags` 테이블의 단일 row.
/// `clipId` / `tagId` 외래 키 쌍이 유일성을 보장.
public struct ClipTag: Codable, Equatable, Sendable {
    public var clipId: Int64
    public var tagId: Int64

    public init(clipId: Int64, tagId: Int64) {
        self.clipId = clipId
        self.tagId = tagId
    }
}

extension ClipTag: TableRecord, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "clipTags"

    public static let clip = belongsTo(Clip.self)
    public static let tag = belongsTo(Tag.self)
}
