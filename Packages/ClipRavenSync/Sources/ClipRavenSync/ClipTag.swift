import Foundation
import GRDB

public struct ClipTag: Codable, Equatable {
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
