import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

/// Unit tests for `SyncChangeCapture` (Phase B.5a).
///
/// Strategy:
/// - Attach the observer to a fresh `TestDatabase` in each test.
/// - Use a closure that records every commit into a `CaptureRecord`
///   array so assertions can check both presence and ordering.
/// - All DB operations use the raw `dbPool` rather than `ClipRepository`
///   so the tests isolate the observer's own filtering from Repository
///   side-effects like the `updatedAt` stamping.
///
/// Scope matches B.5a: upload-only signals. Download/merge behavior is
/// not exercised here; those live in B.5b.
final class SyncChangeCaptureTests: XCTestCase {

    private var testDB: TestDatabase!
    private var recorded: CaptureRecord = CaptureRecord()
    private var capture: SyncChangeCapture!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        recorded = CaptureRecord()
        let rec = recorded
        capture = SyncChangeCapture { saves, deletes in
            rec.append(saves: saves, deletes: deletes)
        }
        testDB.dbPool.add(transactionObserver: capture)
    }

    override func tearDown() {
        if let db = testDB { db.cleanup() }
        testDB = nil
        capture = nil
        recorded = CaptureRecord()
        super.tearDown()
    }

    // MARK: - Basic capture paths

    /// Single insert should surface exactly one save uuid on commit.
    func test_insert_enqueuesSave() throws {
        let uuid = try insertClip(text: "hello")

        XCTAssertEqual(recorded.commits.count, 1, "commit handler should fire once per transaction")
        XCTAssertEqual(recorded.commits[0].saves, [uuid])
        XCTAssertTrue(recorded.commits[0].deletes.isEmpty)
    }

    /// A clip with `excludeFromSync = 1` never appears in any queue —
    /// this is the hard requirement for credentials/password managers.
    func test_excludeFromSync_skipsCompletely() throws {
        _ = try insertClip(text: "aws secret", excludeFromSync: true)

        XCTAssertEqual(recorded.commits.count, 0)
    }

    /// Rows without uuid must not reach the queue. In B.5a this is a
    /// defense-in-depth check — ClipProcessor.stampSyncMetadata should
    /// make this impossible for freshly-captured clips, but legacy
    /// data paths or tests might still insert raw.
    ///
    /// Note: when every buffered rowID is filtered out, onCommit is not
    /// called — there's nothing to tell the consumer. The callback
    /// contract is "fires when at least one save or delete is emitted."
    func test_nilUUID_isDropped() throws {
        try testDB.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO clips (contentType, contentText, copyCount, isDeleted, createdAt, lastCopiedAt, schemaVersion, excludeFromSync)
                VALUES (?, ?, 1, 0, ?, ?, 1, 0)
            """, arguments: ["text", "no-uuid row", Date(), Date()])
        }

        XCTAssertEqual(recorded.commits.count, 0, "nil-uuid row is filtered; no callback")
    }

    /// Insert-then-update within a single transaction should collapse
    /// into exactly one save (the post-commit state is what matters).
    func test_insertThenUpdate_inSameTransaction_isOneEnqueue() throws {
        let uuid = UUID().uuidString
        let now = Date()
        try testDB.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO clips (uuid, contentType, contentText, copyCount, isDeleted, createdAt, lastCopiedAt, schemaVersion, updatedAt, excludeFromSync)
                VALUES (?, ?, ?, 1, 0, ?, ?, 1, ?, 0)
            """, arguments: [uuid, "text", "initial", now, now, now])
            try db.execute(sql: "UPDATE clips SET nickname = ? WHERE uuid = ?", arguments: ["nickname", uuid])
        }

        XCTAssertEqual(recorded.commits.count, 1, "one commit = one callback")
        XCTAssertEqual(recorded.commits[0].saves, [uuid])
    }

    /// Soft-delete (isDeleted = 1) routes the row into the delete queue
    /// instead of the save queue. This is the supported delete path in
    /// B.5a — hard DELETE is not handled.
    func test_softDelete_enqueuesDelete() throws {
        let uuid = try insertClip(text: "to delete")
        // Reset recording so we only see the delete transaction.
        recorded.reset()

        try testDB.dbPool.write { db in
            try db.execute(sql: "UPDATE clips SET isDeleted = 1, updatedAt = ? WHERE uuid = ?",
                           arguments: [Date(), uuid])
        }

        XCTAssertEqual(recorded.commits.count, 1)
        XCTAssertTrue(recorded.commits[0].saves.isEmpty)
        XCTAssertEqual(recorded.commits[0].deletes, [uuid])
    }

    // MARK: - Infinite-loop guard (applyUploadAck)

    /// When `ckLastSyncedAt > updatedAt`, the row's last change was our
    /// own ack and must NOT re-enqueue. Without this guard we'd get an
    /// infinite upload loop: ack → observer → enqueue → upload → ack…
    ///
    /// Verified by the absence of a callback: the UPDATE commits, the
    /// observer fetches the row, the guard drops it, no save emitted,
    /// no callback fired.
    func test_ackFieldUpdate_doesNotReEnqueue() throws {
        let uuid = try insertClip(text: "acked")
        recorded.reset()

        // Simulate applyUploadAck writing ckSystemFields/ckLastSyncedAt
        // WITHOUT bumping updatedAt. This mirrors ClipRepository.applyUploadAck.
        let userEditTime = Date(timeIntervalSince1970: 1_000_000)  // "old" updatedAt
        let ackTime = Date(timeIntervalSince1970: 2_000_000)       // newer
        try testDB.dbPool.write { db in
            try db.execute(sql: """
                UPDATE clips
                   SET updatedAt = ?,
                       ckSystemFields = ?,
                       ckSyncState = 0,
                       ckLastSyncedAt = ?
                 WHERE uuid = ?
            """, arguments: [userEditTime, Data([0x01, 0x02]), ackTime, uuid])
        }

        XCTAssertEqual(
            recorded.commits.count, 0,
            "ack-only update (ckLastSyncedAt > updatedAt) must not re-enqueue"
        )
    }

    /// A subsequent user edit bumps `updatedAt` past `ckLastSyncedAt` and
    /// must re-enqueue normally.
    func test_userEditAfterAck_reEnqueuesSave() throws {
        let uuid = try insertClip(text: "will edit")
        // Seed an ack where ckLastSyncedAt > updatedAt.
        try testDB.dbPool.write { db in
            try db.execute(sql: """
                UPDATE clips
                   SET updatedAt = ?,
                       ckLastSyncedAt = ?
                 WHERE uuid = ?
            """, arguments: [Date(timeIntervalSince1970: 1_000_000),
                             Date(timeIntervalSince1970: 2_000_000),
                             uuid])
        }
        recorded.reset()

        // User edit bumps updatedAt past ckLastSyncedAt.
        let newUpdatedAt = Date(timeIntervalSince1970: 3_000_000)
        try testDB.dbPool.write { db in
            try db.execute(sql: "UPDATE clips SET nickname = ?, updatedAt = ? WHERE uuid = ?",
                           arguments: ["edit", newUpdatedAt, uuid])
        }

        XCTAssertEqual(recorded.commits.count, 1)
        XCTAssertEqual(recorded.commits[0].saves, [uuid])
    }

    // MARK: - Transaction safety

    /// Rollback after inserts should drop the buffered rowIDs entirely —
    /// no enqueue fires for a transaction that never committed.
    func test_rollback_dropsBufferedChanges() throws {
        do {
            try testDB.dbPool.writeWithoutTransaction { db in
                try db.beginTransaction()
                try db.execute(sql: """
                    INSERT INTO clips (uuid, contentType, contentText, copyCount, isDeleted, createdAt, lastCopiedAt, schemaVersion, updatedAt, excludeFromSync)
                    VALUES (?, ?, ?, 1, 0, ?, ?, 1, ?, 0)
                """, arguments: [UUID().uuidString, "text", "rollback me", Date(), Date(), Date()])
                try db.rollback()
            }
        }

        XCTAssertEqual(recorded.commits.count, 0, "rollback must not fire the commit handler")
    }

    /// Writes to tables other than `clips` should not buffer any rowIDs
    /// — the observer filter is at the table level.
    func test_otherTables_areIgnored() throws {
        try testDB.dbPool.write { db in
            try db.execute(sql: "INSERT INTO tags (name, colorHex, createdAt) VALUES (?, ?, ?)",
                           arguments: ["test-tag", "#FF0000", Date()])
        }

        XCTAssertEqual(recorded.commits.count, 0)
    }

    /// Multiple separate transactions should each fire the commit handler
    /// once with their own payload, in FIFO order.
    func test_multipleTransactions_fireInOrder() throws {
        let uuid1 = try insertClip(text: "first")
        let uuid2 = try insertClip(text: "second")
        let uuid3 = try insertClip(text: "third")

        XCTAssertEqual(recorded.commits.count, 3)
        XCTAssertEqual(recorded.commits[0].saves, [uuid1])
        XCTAssertEqual(recorded.commits[1].saves, [uuid2])
        XCTAssertEqual(recorded.commits[2].saves, [uuid3])
    }

    /// Two different clip inserts in the same transaction → one callback
    /// with both uuids. Set-based dedup doesn't collapse different rowIDs.
    func test_twoInsertsInSameTransaction_bothReported() throws {
        let uuid1 = UUID().uuidString
        let uuid2 = UUID().uuidString
        let now = Date()
        try testDB.dbPool.write { db in
            for uuid in [uuid1, uuid2] {
                try db.execute(sql: """
                    INSERT INTO clips (uuid, contentType, contentText, copyCount, isDeleted, createdAt, lastCopiedAt, schemaVersion, updatedAt, excludeFromSync)
                    VALUES (?, ?, ?, 1, 0, ?, ?, 1, ?, 0)
                """, arguments: [uuid, "text", "txn", now, now, now])
            }
        }

        XCTAssertEqual(recorded.commits.count, 1)
        XCTAssertEqual(Set(recorded.commits[0].saves), Set([uuid1, uuid2]))
    }

    /// Flipping `excludeFromSync` from 1 → 0 via UPDATE should enqueue a
    /// save (user removed the filter). Mirror case: flipping 0 → 1 should
    /// NOT enqueue a save (the clip is now ineligible — it just stays
    /// out of the upload queue, any prior server record is best-effort
    /// orphaned until Phase D decides sweep policy).
    func test_excludeFromSyncToggle_enqueuesOnUnset() throws {
        let uuid = try insertClip(text: "was excluded", excludeFromSync: true)
        XCTAssertEqual(recorded.commits.count, 0, "excluded clip doesn't enqueue on insert")

        // Unset exclude → should now enqueue.
        try testDB.dbPool.write { db in
            try db.execute(sql: "UPDATE clips SET excludeFromSync = 0, updatedAt = ? WHERE uuid = ?",
                           arguments: [Date(), uuid])
        }

        XCTAssertEqual(recorded.commits.count, 1)
        XCTAssertEqual(recorded.commits[0].saves, [uuid])
    }

    // MARK: - Helpers

    /// Insert a minimal text clip with the sync metadata that
    /// `ClipProcessor.stampSyncMetadata` would have set. Returns the uuid
    /// so assertions can reference it.
    @discardableResult
    private func insertClip(text: String, excludeFromSync: Bool = false) throws -> String {
        let uuid = UUID().uuidString
        let now = Date()
        try testDB.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO clips (uuid, contentType, contentText, copyCount, isDeleted, createdAt, lastCopiedAt, schemaVersion, updatedAt, excludeFromSync)
                VALUES (?, ?, ?, 1, 0, ?, ?, 1, ?, ?)
            """, arguments: [uuid, "text", text, now, now, now, excludeFromSync ? 1 : 0])
        }
        return uuid
    }
}

// MARK: - Capture recording helper

/// Shared mutable state wrapped in a class so the observer closure can
/// mutate it in-place across invocations.
private final class CaptureRecord {
    struct Commit {
        let saves: [String]
        let deletes: [String]
    }

    private(set) var commits: [Commit] = []

    func append(saves: [String], deletes: [String]) {
        commits.append(Commit(saves: saves, deletes: deletes))
    }

    func reset() {
        commits.removeAll()
    }
}
