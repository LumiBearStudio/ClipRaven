import Foundation
import GRDB
import os.log

/// GRDB `TransactionObserver` that watches the `clips` table and surfaces
/// syncable changes to a consumer closure after each successful commit.
///
/// Why a TransactionObserver (not a Repository wrapper):
/// - We want every write path to feed sync automatically, including
///   ClipRepository callers we haven't enumerated (future cleanup cron,
///   trigger-driven tagsText updates). Hooking at the GRDB boundary
///   guarantees 100% coverage with zero call-site changes.
/// - Rollbacks are free — if the transaction aborts, `databaseDidRollback`
///   drops every buffered rowID and no upload is ever enqueued.
///
/// Thread / reentrancy contract:
/// - `databaseDidChange(with:)` is called on GRDB's writer queue during
///   the transaction. It must not read the DB (reentrant write lock).
///   We only record the event's `rowID`.
/// - `databaseDidCommit(_:)` is also on the writer queue, but the
///   transaction has ended — reads are safe via the passed `Database`.
///   Must not call back into `dbPool.write` (that would deadlock).
/// - The consumer closure receives arrays of String uuids. It is
///   responsible for any further actor hopping (main actor, detached
///   task, etc.). The closure runs on the GRDB writer queue, so it
///   should not block — typical pattern is `Task { @MainActor in ... }`.
///
/// Scope:
/// - Insert & update → save queue (via clip.uuid).
/// - Update to `isDeleted = 1` → delete queue (soft-delete path).
/// - Hard delete (DELETE statement) → dropped (rowID resolves to nil
///   post-commit). Hard deletes only happen in cleanup cron, and those
///   clips have already been soft-deleted + synced earlier.
/// - `excludeFromSync = 1` filter → both capture skips and Mapper defense.
/// - `ckLastSyncedAt > updatedAt` guard → prevents ack-triggered
///   re-upload (infinite loop protection).
///
/// Out of scope (deferred):
/// - `tags` and `clipTags` tables (tag sync deferred).
/// - CKAsset staging for image clips.
public final class SyncChangeCapture: TransactionObserver {

    /// Closure invoked once per successful commit that produced at least
    /// one sync-relevant change. Either or both arrays may be non-empty.
    public typealias OnCommit = (_ savesUUID: [String], _ deletesUUID: [String]) -> Void

    private static let log = Logger(
        subsystem: "com.lumibear.ClipRaven",
        category: "SyncChangeCapture"
    )

    private let onCommit: OnCommit

    /// rowIDs touched by insert/update during the current transaction.
    /// Using a Set dedupes the "insert then update" case into a single
    /// enqueue — the fetch in `databaseDidCommit` reads the post-commit
    /// state either way.
    private var pendingRowIDs: Set<Int64> = []

    /// rowIDs deleted by DELETE statement during the current transaction.
    /// Only logged — we don't emit server deletes from hard-delete.
    /// See "Scope" on the class doc.
    private var deletedRowIDs: Set<Int64> = []

    public init(onCommit: @escaping OnCommit) {
        self.onCommit = onCommit
    }

    // MARK: - TransactionObserver

    /// Filter events at the table level so we don't buffer rowIDs for
    /// tags/clipTags/etc. that we don't care about today.
    public func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == "clips"
    }

    /// Called for every row event within an observed table. Reads from the
    /// passed `Database` are forbidden here — the write transaction is
    /// still open and reentry deadlocks. Just record the rowID.
    public func databaseDidChange(with event: DatabaseEvent) {
        switch event.kind {
        case .insert, .update:
            pendingRowIDs.insert(event.rowID)
        case .delete:
            deletedRowIDs.insert(event.rowID)
        }
    }

    /// Commit succeeded — buffered rowIDs now refer to final state. Read
    /// each row via the post-commit `db` handle, filter, and hand uuids
    /// off to the consumer closure.
    public func databaseDidCommit(_ db: Database) {
        let savesSnapshot = pendingRowIDs
        let deletesSnapshot = deletedRowIDs
        pendingRowIDs.removeAll()
        deletedRowIDs.removeAll()

        if !deletesSnapshot.isEmpty {
            // Hard-delete path lands here. We only know the rowID, which
            // is useless for CKRecord addressing — we'd need the uuid that
            // has already been freed. Log for visibility; the cleanup
            // cron's hard-deleted rows were all soft-deleted (and synced)
            // earlier, so the server already has the tombstone.
            Self.log.debug(
                "ignoring \(deletesSnapshot.count, privacy: .public) hard-deleted rowID(s) (uuid unavailable post-DELETE)"
            )
        }

        guard !savesSnapshot.isEmpty else { return }

        var saves: [String] = []
        var deletes: [String] = []

        for rowID in savesSnapshot {
            let clip: Clip?
            do {
                clip = try Clip.fetchOne(db, id: rowID)
            } catch {
                Self.log.error(
                    "fetchOne(rowID=\(rowID, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            guard let clip else {
                // Row was inserted then hard-deleted in the same transaction.
                // Nothing to sync.
                continue
            }

            // Filter 1 — opt-out set by SyncFilters at capture time.
            if clip.excludeFromSync { continue }

            // Filter 2 — sync metadata missing. Pre-v12 backfill covers
            // existing rows; any gap here means ClipProcessor missed a new
            // code path. Log for surveillance.
            guard let uuid = clip.uuid, !uuid.isEmpty else {
                Self.log.error(
                    "clip has nil/empty uuid (id=\(clip.id ?? -1, privacy: .public)); check ClipProcessor stampSyncMetadata coverage"
                )
                continue
            }

            // Filter 3 — infinite-loop guard. If the only UPDATE touching
            // this row is our own applyUploadAck, `ckLastSyncedAt` is
            // strictly newer than `updatedAt` and we must NOT re-enqueue.
            // A user edit bumps `updatedAt`, flipping the inequality.
            if let lastSynced = clip.ckLastSyncedAt,
               let updatedAt = clip.updatedAt,
               lastSynced > updatedAt {
                continue
            }

            if clip.isDeleted {
                deletes.append(uuid)
            } else {
                saves.append(uuid)
            }
        }

        guard !saves.isEmpty || !deletes.isEmpty else { return }

        Self.log.debug(
            "commit produced \(saves.count, privacy: .public) save(s) and \(deletes.count, privacy: .public) delete(s)"
        )
        onCommit(saves, deletes)
    }

    public func databaseDidRollback(_ db: Database) {
        // Transaction aborted — drop every buffered rowID. No upload is
        // enqueued for changes that never landed.
        pendingRowIDs.removeAll()
        deletedRowIDs.removeAll()
    }
}
