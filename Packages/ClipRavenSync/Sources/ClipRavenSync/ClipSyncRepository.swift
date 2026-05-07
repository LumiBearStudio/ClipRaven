import Foundation
import CloudKit
import GRDB
import os.log

/// GRDB-backed sync repository. Provides the three DB operations the
/// `SyncEngine` needs and nothing else — no domain CRUD, no UI helpers.
///
/// The Mac and iOS host apps each construct one with their own `DatabasePool`
/// and pass it into `SyncEngine`. Mac's full-fat `ClipRepository` delegates
/// its sync methods here so production code paths stay identical.
///
/// Why a value type wrapping `DatabasePool`:
/// - `DatabasePool` is itself thread-safe and can be shared. The repo just
///   bundles the sync-specific SQL with the pool reference.
/// - Tests in either host can inject a temporary in-memory pool without
///   touching the production database.
public struct ClipSyncRepository {

    private let dbPool: DatabasePool

    static let log = Logger(
        subsystem: "com.lumibear.ClipRaven",
        category: "ClipSyncRepository"
    )

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Upload-side

    /// Fetch UUIDs of soft-deleted clips whose deletion hasn't been confirmed
    /// synced yet. Used at startup to re-enqueue any deletes that were stranded
    /// by a crash between the DB commit and `enqueueDelete` being persisted in
    /// the CKSyncEngine state.
    ///
    /// A deletion is considered un-synced when:
    /// - `ckLastSyncedAt` is NULL (never reached CloudKit), OR
    /// - `ckLastSyncedAt < updatedAt` (deleted after last sync ack)
    ///
    /// Clips with `excludeFromSync = 1` are skipped — they were never
    /// uploaded, so there's no CloudKit record to delete.
    public func fetchPendingDeleteUUIDs() throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT uuid FROM clips
                WHERE isDeleted = 1
                  AND uuid IS NOT NULL
                  AND uuid != ''
                  AND excludeFromSync = 0
                  AND (ckLastSyncedAt IS NULL OR ckLastSyncedAt < updatedAt)
            """)
        }
    }

    /// Mark a batch of successfully-deleted CloudKit records as ack'd.
    /// Sets `ckLastSyncedAt = now` on each soft-deleted row so:
    /// 1. `SyncChangeCapture`'s `ckLastSyncedAt > updatedAt` guard prevents
    ///    the delete from being re-enqueued on the next commit.
    /// 2. `ClipRepository.deleteSoftDeleted()` can now safely hard-delete
    ///    the row, knowing the delete was confirmed by CloudKit.
    public func applyDeleteAck(uuids: [String]) async throws {
        guard !uuids.isEmpty else { return }
        let now = Date()
        try await dbPool.write { db in
            for uuid in uuids {
                try db.execute(
                    sql: "UPDATE clips SET ckLastSyncedAt = ? WHERE uuid = ? AND isDeleted = 1",
                    arguments: [now, uuid]
                )
            }
        }
    }

    /// Fetch a clip by its CloudKit recordName (= `clips.uuid`). Used by
    /// `SyncEngine.nextRecordZoneChangeBatch` to resolve a pending upload
    /// back to the current local row.
    ///
    /// Returns nil when the row has vanished (user hard-deleted between
    /// enqueue and batch). Callers should treat nil as "drop from batch".
    public func fetchByUUID(_ uuid: String) throws -> Clip? {
        try dbPool.read { db in
            try Clip
                .filter(Column("uuid") == uuid)
                .fetchOne(db)
        }
    }

    /// Persist the CloudKit system fields + ack bookkeeping after a
    /// successful upload. `SyncEngine` calls this from
    /// `.sentRecordZoneChanges` for every saved record.
    ///
    /// The ack UPDATE intentionally does NOT bump `updatedAt` — doing so
    /// would re-trigger ChangeCapture and re-enqueue the same upload,
    /// creating an infinite loop. SyncChangeCapture additionally guards
    /// with `ckLastSyncedAt > updatedAt` as defense in depth.
    public func applyUploadAck(records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        let now = Date()
        let recordsForWriter = records  // [CKRecord] is @unchecked Sendable
        try await dbPool.write { db in
            for record in recordsForWriter {
                let uuid = record.recordID.recordName
                let systemFields = SyncRecordMapper.encodedSystemFields(of: record)
                try db.execute(
                    sql: """
                        UPDATE clips
                           SET ckSystemFields = ?,
                               ckSyncState = 0,
                               ckLastSyncedAt = ?
                         WHERE uuid = ?
                    """,
                    arguments: [systemFields, now, uuid]
                )
            }
        }
    }

    // MARK: - Download-side

    /// Apply a batch of server-originated changes to the local DB. Called
    /// by `SyncEngine` from `.fetchedRecordZoneChanges`. All writes land
    /// in a single GRDB transaction so a crash mid-apply leaves the DB
    /// consistent — either every record in this fetch is visible or none.
    ///
    /// Infinite-loop safety: every upserted row has `ckLastSyncedAt = now`
    /// set strictly after any `updatedAt` the server sent. `SyncChangeCapture`'s
    /// filter `ckLastSyncedAt > updatedAt` therefore drops the re-enqueue.
    /// As belt-and-suspenders we also clear `ckSyncState = 0` so the row
    /// reads as "synced".
    ///
    /// Hard-delete tombstones (`deletedRecordIDs` from the server) map to
    /// local DELETE.
    ///
    /// Soft-delete tombstones (record with `isDeleted=1`) arrive via
    /// `modifications`, not `deletions` — they update the local row's
    /// `isDeleted` flag, and the usual re-enqueue guard prevents loopback.
    @discardableResult
    public func applyServerChanges(
        modifications: [CKRecord],
        deletions: [CKRecord.ID]
    ) throws -> (inserted: Int, updated: Int, deleted: Int) {
        guard !modifications.isEmpty || !deletions.isEmpty else {
            return (0, 0, 0)
        }
        return try dbPool.write { db in
            try Self.applyServerChangesBody(
                db: db,
                modifications: modifications,
                deletions: deletions
            )
        }
    }

    @discardableResult
    public func applyServerChanges(
        modifications: [CKRecord],
        deletions: [CKRecord.ID]
    ) async throws -> (inserted: Int, updated: Int, deleted: Int) {
        guard !modifications.isEmpty || !deletions.isEmpty else {
            return (0, 0, 0)
        }
        let modsForWriter = modifications
        let delsForWriter = deletions
        return try await dbPool.write { db in
            try Self.applyServerChangesBody(
                db: db,
                modifications: modsForWriter,
                deletions: delsForWriter
            )
        }
    }

    /// Shared body for both sync and async variants. Executes inside a
    /// GRDB writer transaction — callers MUST wrap accordingly.
    private static func applyServerChangesBody(
        db: Database,
        modifications: [CKRecord],
        deletions: [CKRecord.ID]
    ) throws -> (inserted: Int, updated: Int, deleted: Int) {
        var insertedCount = 0
        var updatedCount = 0
        var deletedCount = 0

        for record in modifications {
            let uuid = record.recordID.recordName
            guard !uuid.isEmpty else { continue }

            let existing = try Clip
                .filter(Column("uuid") == uuid)
                .fetchOne(db)

            var merged = SyncRecordMapper.decode(record, merging: existing)
            // decode() sets ckLastSyncedAt = Date() and ckSyncState = 0.
            // Clock-skew defense: peer device with a clock ahead of ours
            // can produce `record.updatedAt > Date()`, which would flip
            // the `ckLastSyncedAt > updatedAt` guard and re-enqueue the
            // row — a ping-pong between devices. Force the invariant
            // to hold by bumping `ckLastSyncedAt` ≥ updatedAt + 1ms.
            if let serverUpdatedAt = merged.updatedAt {
                let floor = serverUpdatedAt.addingTimeInterval(0.001)
                if (merged.ckLastSyncedAt ?? .distantPast) < floor {
                    merged.ckLastSyncedAt = floor
                }
            }

            if existing == nil {
                // Fresh row by uuid. **이미지 클립만** hash dedup —
                // 같은 사진이 두 장 카드로 보이면 사용자에게 명백한 중복
                // (visual identity).
                //
                // **텍스트는 dedup 하지 않음** — 다른 device 에서 만든
                // 같은 텍스트 record 는 별개 row 로 유지하는 게 사용자
                // 기대 (각 device 의 시점/source 가 정보로 가치 있음).
                // 같은 device 자체 capture 시 중복은 각 platform 의
                // ClipProcessor / PasteboardCaptureService 가 이미
                // contentHash dedup (incrementCopyCount) 처리.
                if let imgHash = merged.imageHash, !imgHash.isEmpty {
                    let dup = try Clip
                        .filter(Column("imageHash") == imgHash)
                        .filter(Column("isDeleted") == false)
                        .fetchOne(db)
                    if dup != nil {
                        Self.log.info("server record uuid=\(uuid, privacy: .public) skipped — imageHash dup of local id=\(dup?.id ?? -1, privacy: .public)")
                        continue
                    }
                }

                // Fresh row from another device. `id` is nil so GRDB
                // assigns autoincrement on insert.
                try merged.save(db)
                insertedCount += 1
            } else {
                // Preserve local-only fields decode() doesn't touch:
                //   imagePath, contentChosung, customShortcut*, excludeFromSync.
                // These are either device-local artifacts (file path is
                // sandbox-relative; chosung/shortcut are Mac-only) or user
                // opt-out flags that must not be overwritten by the server's
                // absence of them.
                //
                // `thumbnail` USED to be local-only but is now a synced field
                // (added via Key.thumbnail). decode() writes it from the
                // record, so we preserve the existing value only as fallback
                // — if the server didn't ship a thumbnail (e.g. legacy clip
                // synced before the field existed), keep what we have locally.
                merged.id = existing?.id
                merged.imagePath = existing?.imagePath
                if merged.thumbnail == nil {
                    merged.thumbnail = existing?.thumbnail
                }
                merged.contentChosung = existing?.contentChosung
                merged.customShortcutKeyCode = existing?.customShortcutKeyCode
                merged.customShortcutModifiers = existing?.customShortcutModifiers
                merged.excludeFromSync = existing?.excludeFromSync ?? false
                try merged.update(db)
                updatedCount += 1
            }
        }

        for recordID in deletions {
            let uuid = recordID.recordName
            guard !uuid.isEmpty else { continue }
            try db.execute(
                sql: "DELETE FROM clips WHERE uuid = ?",
                arguments: [uuid]
            )
            // `changesCount` reflects rows affected by the most recent
            // statement — treat a no-op DELETE (row never existed, or
            // already hard-deleted locally) as a silent success.
            if db.changesCount > 0 {
                deletedCount += db.changesCount
            }
        }

        return (insertedCount, updatedCount, deletedCount)
    }
}
