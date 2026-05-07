import Foundation
import GRDB

/// Schema helpers for the iCloud-sync metadata columns shared by Mac and iOS.
///
/// Mac registers these via a `v12_syncMeta` migration on top of an existing v1
/// schema. iOS starts fresh with a single migration that creates the final
/// shape — both call into the same helpers here so column types, defaults,
/// and indexes are guaranteed identical across platforms.
///
/// Column rationale (also reflected in `Clip` / `Tag` Swift fields):
///   uuid             — CKRecord.recordName. Globally unique across devices.
///                      Nullable in DB (backfilled below) so we don't fail on
///                      pre-existing rows; new inserts are expected to supply one.
///   deviceId         — Origin device. Needed for "iPhone에서 복사" UI and to
///                      ignore our own changes echoing back through CloudKit.
///   schemaVersion    — Per-record schema version. Forward-compat for future
///                      field additions (CloudKit schema is additive-only).
///   updatedAt        — Server LWW basis for mutable fields.
///   ckSystemFields   — encodeSystemFields() blob. Required to preserve
///                      server change tags across local edits; without it the
///                      next upload becomes a "first save" and clobbers.
///   ckSyncState      — 0 synced / 1 pendingUpload / 2 pendingDelete / 3 conflict.
///   ckLastSyncedAt   — Last successful server round-trip (debugging/UX).
///   excludeFromSync  — Set by SyncFilters + user blacklist (Mac only field;
///                      iOS doesn't capture so this stays at the default).
public enum SyncSchema {

    /// Add the sync columns to an existing `clips` table (Mac v12 path).
    public static func addClipSyncColumns(_ t: TableAlteration) {
        t.add(column: "uuid",            .text)
        t.add(column: "deviceId",        .text)
        t.add(column: "schemaVersion",   .integer).notNull().defaults(to: 1)
        t.add(column: "updatedAt",       .datetime)
        t.add(column: "ckSystemFields",  .blob)
        t.add(column: "ckSyncState",     .integer).notNull().defaults(to: 0)
        t.add(column: "ckLastSyncedAt",  .datetime)
        t.add(column: "excludeFromSync", .boolean).notNull().defaults(to: false)
    }

    /// Add the sync columns to an existing `tags` table (Mac v12 path).
    /// Tags don't have `excludeFromSync` because tag opt-out doesn't make
    /// sense — a tag is metadata that follows clips around.
    public static func addTagSyncColumns(_ t: TableAlteration) {
        t.add(column: "uuid",           .text)
        t.add(column: "deviceId",       .text)
        t.add(column: "schemaVersion",  .integer).notNull().defaults(to: 1)
        t.add(column: "updatedAt",      .datetime)
        t.add(column: "ckSystemFields", .blob)
        t.add(column: "ckSyncState",    .integer).notNull().defaults(to: 0)
        t.add(column: "ckLastSyncedAt", .datetime)
    }

    /// Inline equivalents for fresh-table creation (iOS initial migration).
    /// Use these when defining a new `clips` / `tags` table from scratch
    /// instead of altering an existing one.
    public static func defineClipSyncColumns(_ t: TableDefinition) {
        t.column("uuid",            .text)
        t.column("deviceId",        .text)
        t.column("schemaVersion",   .integer).notNull().defaults(to: 1)
        t.column("updatedAt",       .datetime)
        t.column("ckSystemFields",  .blob)
        t.column("ckSyncState",     .integer).notNull().defaults(to: 0)
        t.column("ckLastSyncedAt",  .datetime)
        t.column("excludeFromSync", .boolean).notNull().defaults(to: false)
    }

    public static func defineTagSyncColumns(_ t: TableDefinition) {
        t.column("uuid",           .text)
        t.column("deviceId",       .text)
        t.column("schemaVersion",  .integer).notNull().defaults(to: 1)
        t.column("updatedAt",      .datetime)
        t.column("ckSystemFields", .blob)
        t.column("ckSyncState",    .integer).notNull().defaults(to: 0)
        t.column("ckLastSyncedAt", .datetime)
    }

    /// Create the unique-on-uuid + ckSyncState indexes both platforms need.
    /// Call AFTER any backfill that populates the uuid column on existing rows.
    public static func createSyncIndexes(_ db: Database) throws {
        try db.create(index: "idx_clips_uuid",        on: "clips", columns: ["uuid"],        unique: true)
        try db.create(index: "idx_tags_uuid",         on: "tags",  columns: ["uuid"],        unique: true)
        try db.create(index: "idx_clips_ckSyncState", on: "clips", columns: ["ckSyncState"])
    }

    /// Backfill `uuid`, `deviceId`, and `updatedAt` on every pre-existing row
    /// that the column-add migration left NULL. Only relevant on Mac (which
    /// has legacy data); iOS starts empty.
    ///
    /// Each clip's `updatedAt` is derived from `lastCopiedAt` (closest proxy
    /// to "when this row last reflected user intent"). Tags use `createdAt`
    /// because they have no copy timestamp.
    public static func backfillExistingRows(_ db: Database, deviceId: String) throws {
        let clipIds = try Int64.fetchAll(db, sql: "SELECT id FROM clips WHERE uuid IS NULL")
        for id in clipIds {
            try db.execute(
                sql: "UPDATE clips SET uuid = ?, deviceId = ?, updatedAt = lastCopiedAt WHERE id = ?",
                arguments: [UUID().uuidString, deviceId, id]
            )
        }

        let tagIds = try Int64.fetchAll(db, sql: "SELECT id FROM tags WHERE uuid IS NULL")
        for id in tagIds {
            try db.execute(
                sql: "UPDATE tags SET uuid = ?, deviceId = ?, updatedAt = createdAt WHERE id = ?",
                arguments: [UUID().uuidString, deviceId, id]
            )
        }
    }

    /// Tables required to back the SyncStateStore (CKSyncEngine state blob)
    /// and the device registry shown in Settings. Mac creates these in v13;
    /// iOS calls this during its initial migration.
    public static func createSyncEngineTables(_ db: Database) throws {
        try db.create(table: "sync_engine_state") { t in
            t.primaryKey("key", .text)
            t.column("value", .blob).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        try db.create(table: "device_registry") { t in
            t.primaryKey("deviceId", .text)
            t.column("displayName", .text)
            t.column("platform", .text)
            t.column("firstSeenAt", .datetime)
            t.column("lastSeenAt", .datetime)
        }
    }

    /// Seed `device_registry` with this device so Settings has something to
    /// show before any sync round-trip has occurred. Idempotent via
    /// INSERT OR IGNORE.
    public static func seedThisDevice(_ db: Database) throws {
        let now = Date()
        try db.execute(sql: """
            INSERT OR IGNORE INTO device_registry
                (deviceId, displayName, platform, firstSeenAt, lastSeenAt)
            VALUES (?, ?, ?, ?, ?)
        """, arguments: [
            DeviceIdentity.deviceId,
            DeviceIdentity.displayName,
            DeviceIdentity.platform,
            now,
            now,
        ])
    }
}
