import Foundation
import GRDB
import os.log

/// GRDB-backed key/value store for CloudKit sync engine state.
///
/// Why it lives in SQLite (not a plist):
/// - `ChangeCapture` enqueues pending uploads from within the same
///   `databaseDidCommit` callback that persists the local insert. If
///   sync engine state lived outside GRDB, a crash between "row committed"
///   and "state file fsync'd" would leave the system in an inconsistent
///   place. Co-locating state with user data makes that impossible —
///   either both land or neither does.
///
/// Why data-typed (not `CKSyncEngine.State.Serialization`-typed):
/// - Keeps this layer testable offline. CloudKit types can't be
///   meaningfully constructed in unit tests without a live engine, so the
///   typed encode/decode happens one level up in `SyncEngine`.
/// - Also future-proofs the store for per-zone change tokens and arbitrary
///   metadata without adding a new API each time.
///
/// Error policy:
/// - Write failures are logged and swallowed. A corrupted sync state is
///   recoverable (engine rebuilds from server state); halting the app
///   over it is not. See icloud-sync.plan.md rollback criteria.
/// - Read failures return `nil`, which the engine treats as "first run".
///
/// Reentrancy contract:
/// - `save/clear/clearAll/load/lastUpdatedAt` open their own GRDB
///   transaction. Do NOT call them from inside a `TransactionObserver`
///   callback — you will deadlock on the writer queue.
/// - For inside-transaction writes (e.g. ChangeCapture) use the
///   `save(_:forKey:db:)` overload that takes the active `Database`.

/// Proof token that the sync engine has been cleanly shut down. Only
/// `SyncEngine` can produce one via its `shutdown()` method.
/// Required to call destructive operations like `clearAll()` so the engine
/// cannot be re-saving state while we wipe rows out from under it.
///
/// Tests use `@testable import` to synthesize this directly — in
/// production, the app target only ever receives one from the engine.
public struct SyncEngineShutdownToken {
    public init() {}
}

public final class SyncStateStore {

    /// Well-known keys. Add here — never hard-code strings at call sites.
    public enum Key {
        /// Serialized `CKSyncEngine.State.Serialization` for the single
        /// user-account engine. One row per app install.
        public static let mainEngine = "mainEngine"

        /// Sentinel flag (any non-empty blob) set after a successful
        /// `CKDatabaseSubscription` registration. Reading a hit lets us
        /// skip the subscription lookup+modify round-trip on every launch.
        /// Cleared by `clearAll(afterShutdown:)` so a post-wipe re-auth
        /// re-registers cleanly.
        public static let subscriptionRegistered = "databaseSubscriptionV1"
    }

    private static let log = Logger(subsystem: "com.lumibear.ClipRaven", category: "SyncStateStore")
    private let dbWriter: DatabaseWriter

    public init(dbWriter: DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - Read

    /// Returns the stored blob, or nil if the key has never been written or
    /// the read fails. Reads are safe to call from any thread; GRDB
    /// serializes internally.
    public func load(forKey key: String) -> Data? {
        do {
            return try dbWriter.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT value FROM sync_engine_state WHERE key = ?",
                    arguments: [key]
                )
            }
        } catch {
            Self.log.error("load failed for key=\(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Write

    /// Upserts the blob under `key`. Fire-and-forget — failures are logged
    /// but do not throw. Opens its own GRDB transaction, so this must NOT
    /// be called from inside a `TransactionObserver` callback. Use the
    /// `db:` overload for that path.
    ///
    /// `async` so callers can invoke it from the main actor without
    /// blocking the main thread on disk I/O. The write body runs on
    /// GRDB's internal writer queue; `await` only yields the calling
    /// actor until GRDB schedules the work.
    ///
    /// Ordering: GRDB's writer queue is serial, so a chain of `await
    /// save(...)` calls from a single actor persists in strict FIFO
    /// order. The sync engine relies on this for `stateUpdate` events.
    ///
    /// Empty blobs are refused — they are almost always a bug upstream
    /// (a truncated write or an encoder that returned empty). Sync state
    /// blobs are never legitimately zero-length.
    public func save(_ data: Data, forKey key: String) async {
        guard !data.isEmpty else {
            Self.log.error("save refused empty blob for key=\(key, privacy: .public)")
            return
        }
        do {
            try await dbWriter.write { db in
                try Self.upsert(data, key: key, db: db)
            }
        } catch {
            Self.log.error("save failed for key=\(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// In-transaction save. Used by `ChangeCapture` inside
    /// `databaseDidCommit(_:)` where the writer queue is already occupied
    /// — reentering with `dbWriter.write` would deadlock. The caller holds
    /// the active `Database` from the observer callback.
    ///
    /// Throws on error so the caller can decide whether to abort the
    /// transaction; fire-and-forget swallowing only makes sense for the
    /// queue-based variant.
    public func save(_ data: Data, forKey key: String, db: Database) throws {
        guard !data.isEmpty else {
            Self.log.error("save refused empty blob for key=\(key, privacy: .public)")
            return
        }
        try Self.upsert(data, key: key, db: db)
    }

    private static func upsert(_ data: Data, key: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO sync_engine_state (key, value, updatedAt)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updatedAt = excluded.updatedAt
            """,
            arguments: [key, data, Date()]
        )
    }

    /// Remove a single key. Used during sign-out / "reset iCloud data" flows
    /// (plan §13 "iCloud에서 모두 지우기" UX). Async for the same reason
    /// `save` is — main-thread-safe.
    public func clear(forKey key: String) async {
        do {
            try await dbWriter.write { db in
                try db.execute(
                    sql: "DELETE FROM sync_engine_state WHERE key = ?",
                    arguments: [key]
                )
            }
        } catch {
            Self.log.error("clear failed for key=\(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Truncate every key. Requires a `SyncEngineShutdownToken` — without
    /// the engine stopped first, a live `save` could resurrect rows mid-wipe.
    /// The `_` parameter underscore is intentional: the token is a proof
    /// value, we never need to inspect it.
    public func clearAll(afterShutdown _: SyncEngineShutdownToken) async {
        do {
            try await dbWriter.write { db in
                try db.execute(sql: "DELETE FROM sync_engine_state")
            }
        } catch {
            Self.log.error("clearAll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Diagnostics

    /// Timestamp of the last successful save for `key`, or nil if never
    /// written. Used by Settings → Sync to display "last synced".
    public func lastUpdatedAt(forKey key: String) -> Date? {
        do {
            return try dbWriter.read { db in
                try Date.fetchOne(
                    db,
                    sql: "SELECT updatedAt FROM sync_engine_state WHERE key = ?",
                    arguments: [key]
                )
            }
        } catch {
            return nil
        }
    }
}
