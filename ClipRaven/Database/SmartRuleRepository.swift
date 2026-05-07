import Foundation
import GRDB

struct SmartRuleRepository {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
    }

    // MARK: - Create

    @discardableResult
    func save(_ rule: inout SmartRule) throws -> SmartRule {
        try dbPool.write { db in
            try rule.save(db)
        }
        return rule
    }

    // MARK: - Read

    func fetchAll() throws -> [SmartRule] {
        try dbPool.read { db in
            try SmartRule.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func fetchEnabled() throws -> [SmartRule] {
        try dbPool.read { db in
            try SmartRule
                .filter(Column("isEnabled") == true)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func fetchOne(id: Int64) throws -> SmartRule? {
        try dbPool.read { db in
            try SmartRule.fetchOne(db, id: id)
        }
    }

    // MARK: - Update

    func update(_ rule: SmartRule) throws {
        try dbPool.write { db in
            try rule.update(db)
        }
    }

    func toggleEnabled(id: Int64) throws {
        try dbPool.write { db in
            guard var rule = try SmartRule.fetchOne(db, id: id) else { return }
            rule.isEnabled.toggle()
            try rule.update(db)
        }
    }

    // MARK: - Delete

    func delete(id: Int64) throws {
        try dbPool.write { db in
            _ = try SmartRule.deleteOne(db, id: id)
        }
    }
}
