import Foundation
import GRDB
import ClipRavenSync

struct PasteStackItem: Identifiable, Codable, Equatable {
    var id: Int64?
    var clipId: Int64
    var sortOrder: Int
    var isPasted: Bool = false
    var addedAt: Date = Date()
}

extension PasteStackItem: TableRecord, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pasteStack"

    static let clip = belongsTo(Clip.self)

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
