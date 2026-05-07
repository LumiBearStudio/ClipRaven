import Foundation
import GRDB

struct PasteStackRepository {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
    }

    @discardableResult
    func add(clipId: Int64) throws -> PasteStackItem {
        try dbPool.write { db in
            let maxOrder = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM pasteStack"
            ) ?? -1

            var item = PasteStackItem(
                clipId: clipId,
                sortOrder: maxOrder + 1
            )
            try item.insert(db)
            return item
        }
    }

    func fetchAll() throws -> [PasteStackItem] {
        try dbPool.read { db in
            try PasteStackItem
                .order(Column("sortOrder").asc)
                .fetchAll(db)
        }
    }

    func fetchNext() throws -> PasteStackItem? {
        try dbPool.read { db in
            try PasteStackItem
                .filter(Column("isPasted") == false)
                .order(Column("sortOrder").asc)
                .fetchOne(db)
        }
    }

    func markPasted(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE pasteStack SET isPasted = 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func reorder(id: Int64, newOrder: Int) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE pasteStack SET sortOrder = ? WHERE id = ?",
                arguments: [newOrder, id]
            )
        }
    }

    func clear() throws {
        try dbPool.write { db in
            _ = try PasteStackItem.deleteAll(db)
        }
    }

    func count() throws -> Int {
        try dbPool.read { db in
            try PasteStackItem.fetchCount(db)
        }
    }

    func remove(clipId: Int64) throws {
        try dbPool.write { db in
            try PasteStackItem
                .filter(Column("clipId") == clipId)
                .deleteAll(db)
        }
    }
}
