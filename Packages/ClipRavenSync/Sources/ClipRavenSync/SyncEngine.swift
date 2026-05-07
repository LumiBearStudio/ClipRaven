import Foundation
import CloudKit
import GRDB
import os.log

/// Thin wrapper around `CKSyncEngine`. Owns the engine lifecycle, bridges
/// delegate events into `SyncStateStore` + `ClipRepository`, and is the
/// single entry point for enqueueing local changes into the sync queue.
///
/// Current scope:
/// - Gate startup behind `SyncFeatureFlag` AND `CKAccountStatus.available`.
/// - Initialize `CKSyncEngine` with restored state from `SyncStateStore`.
/// - Persist `stateUpdate` events back to the store (recordChangeTag
///   continuity), with a fuse that blocks persist when local apply failed.
/// - Upload: `nextRecordZoneChangeBatch` builds CKRecords from pending
///   uuids via `ClipRepository.fetchByUUID` + `SyncRecordMapper.encode`.
/// - Upload ACK: `sentRecordZoneChanges` writes back `ckSystemFields` +
///   `ckLastSyncedAt` via `applyUploadAck`.
/// - Download: `fetchedRecordZoneChanges` upserts server records into
///   local DB via `applyServerChanges`. Hard-deletes drop local rows;
///   soft-deletes flow through the normal upsert path.
/// - Conflict: `serverRecordChanged` on upload triggers a server-wins
///   merge through the same download path (LWW deferred).
/// - Silent push: `CKDatabaseSubscription` registered on first run;
///   `AppDelegate` calls `fetchChangesOnWake` on remote notification.
/// - Provides a clean `shutdown()` that vends a `SyncEngineShutdownToken`,
///   satisfying `SyncStateStore.clearAll(afterShutdown:)`.
///
/// Out of scope (deferred):
/// - Tag relation (`tagUuids`) sync — text-only today.
/// - Asset handling for image clips.
/// - LWW conflict resolution.
/// - Settings UI for the sync toggle.
///
/// Why `@available(macOS 14.0, iOS 17.0, *)`:
/// - `CKSyncEngine` was added in macOS 14 / iOS 17. Mac's deployment target
///   is 13.0, so callers must gate with `if #available(macOS 14.0, *)`.
///   That gate lives exactly once in each host app's lifecycle entry point.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class SyncEngine: NSObject {

    nonisolated private static let log = Logger(subsystem: "com.lumibear.ClipRaven", category: "SyncEngine")

    private let stateStore: SyncStateStore
    private let containerIdentifier: String
    private let clipRepository: ClipSyncRepository

    /// Underlying engine. Nil until `startIfEligible()` succeeds. Nil after
    /// `shutdown()`.
    private var engine: CKSyncEngine?

    /// Latching shutdown flag. Once set, `startIfEligible()` refuses to
    /// bring the engine back — a SyncEngine instance is one-shot. This is
    /// the belt-and-suspenders against late-firing start tasks (the
    /// suspenders are `syncStartTask.cancel()` in AppDelegate).
    private var isShutDown: Bool = false

    /// In-memory fuse preventing concurrent subscription-registration tasks
    /// when `startIfEligible()` is called multiple times before the first
    /// task finishes (the future account-change path will do this). The
    /// persisted sentinel in `SyncStateStore` handles cross-launch
    /// idempotency; this flag handles same-launch races.
    private var subscriptionEnsured: Bool = false

    /// Sticky flag set when a `fetchedRecordZoneChanges` apply fails. Blocks
    /// the next `stateUpdate` persist so the server-side change token
    /// doesn't advance past records we failed to save locally — which
    /// would otherwise cause permanent drift (server says "you've seen
    /// everything" while local DB has nothing).
    ///
    /// Cleared automatically once we skip one state persist. The
    /// underlying fetched events are re-delivered on the next cycle
    /// because the engine still holds them in the unadvanced token.
    ///
    /// Rationale: Apple's canonical sample persists applied records and
    /// state together in a single JSON blob via `try?` — an atomic write.
    /// Ours uses two GRDB writes to different tables, so we need an
    /// explicit gate instead of atomicity. See research/apple-sample.
    private var fetchApplyFailed: Bool = false

    /// Handle for the 30-minute periodic safety-net sync cycle.
    /// Cancelled and nil'd in `shutdown()`.
    private var periodicFetchTask: Task<Void, Never>?

    /// True while an explicit fetch→send sync cycle is in progress.
    /// Prevents concurrent cycles from interleaving their fetch/send phases.
    private var isSyncCycleRunning: Bool = false

    /// Set when a new sync request arrives while a cycle is already running.
    /// The pending cycle runs immediately after the current one completes.
    private var pendingSyncAfterCycle: Bool = false

    public init(
        stateStore: SyncStateStore,
        containerIdentifier: String,
        clipRepository: ClipSyncRepository
    ) {
        self.stateStore = stateStore
        self.containerIdentifier = containerIdentifier
        self.clipRepository = clipRepository
        super.init()
    }

    // MARK: - Lifecycle

    /// Bring up the engine iff:
    /// - `SyncFeatureFlag.isEnabled` (user opt-in or dev override),
    /// - `CKContainer.accountStatus()` returns `.available`.
    ///
    /// Safe to call multiple times. After the first successful start,
    /// subsequent calls are no-ops. Idempotent is the contract so callers
    /// (account-change notifications, app foreground events) can fire
    /// freely without tracking state themselves.
    ///
    /// Today the only caller is `applicationDidFinishLaunching`. The future
    /// Settings toggle will also call this when the flag flips on.
    public func startIfEligible() async {
        guard !isShutDown else {
            Self.log.info("startIfEligible ignored: engine already shut down")
            return
        }
        guard engine == nil else {
            Self.log.debug("startIfEligible: engine already up")
            return
        }
        guard SyncFeatureFlag.isEnabled else {
            Self.log.info("sync disabled by flag; engine not started")
            return
        }

        let container = CKContainer(identifier: containerIdentifier)
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            Self.log.error("accountStatus fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard status == .available else {
            Self.log.info("iCloud account not available (status=\(String(describing: status), privacy: .public)); engine not started")
            return
        }

        // Restore prior serialization if any. A decode failure means the
        // stored blob is from an incompatible engine version; start fresh
        // rather than crash — CloudKit will re-fetch from the server.
        let serialization: CKSyncEngine.State.Serialization? = {
            guard let data = stateStore.load(forKey: SyncStateStore.Key.mainEngine) else {
                return nil
            }
            do {
                return try JSONDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
            } catch {
                Self.log.error("state decode failed, starting fresh: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }()

        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        // Disable automatic scheduling so we control fetch→send order.
        //
        // Why: with automaticallySync=true the engine advances the zone-change
        // token on every upload ACK to the server's then-current position —
        // which already includes records other devices uploaded between our
        // last fetch and this send. The advanced token is then persisted via
        // `stateUpdate` (and survives app restarts), so those remote records
        // are permanently skipped. We hit this in production: iPhone clips
        // never reached the Mac while Mac kept uploading frequently.
        //
        // Apple's "post-send fetch" workaround (Task.detached after every send
        // ACK) doesn't help because `stateUpdate` fires and persists BEFORE
        // the detached task runs.
        //
        // Manual sequencing (fetch → send via `executeCycle`) guarantees we
        // always pull remote changes before our upload can advance the token
        // past them. Apple flags this option as "testing only", but every
        // sync trigger in this app (startup, silent push, foreground, panel
        // open, periodic, enqueue) is wired through `requestSyncCycle` so
        // the engine never needs to self-schedule.
        config.automaticallySync = false

        let newEngine = CKSyncEngine(config)
        self.engine = newEngine

        // Ensure the custom zone exists. Idempotent — CKSyncEngine treats
        // "zone already exists" as success, and duplicate pending saveZone
        // entries are coalesced server-side. Required because:
        // - `_defaultZone` doesn't support `fetchRecordZoneChanges`.
        // - If a serialized engine state is restored but the server-side zone
        //   was deleted (user signed out of iCloud + signed back in), we
        //   need to recreate it before any records can be uploaded.
        let zone = CKRecordZone(zoneID: SyncRecordMapper.zoneID)
        newEngine.state.add(pendingDatabaseChanges: [.saveZone(zone)])

        Self.log.info("sync engine initialized (serialization=\(serialization == nil ? "fresh" : "restored", privacy: .public))")

        // Crash-recovery: re-enqueue any soft-deleted clips whose delete
        // wasn't persisted to the engine's pending-changes queue in the
        // previous session (the app crashed or was force-quit in the
        // sub-millisecond window between the DB commit and `enqueueDelete`).
        // CKSyncEngine deduplicates by recordID, so re-enqueueing an already-
        // pending delete is a safe no-op.
        let pendingDeletes = (try? clipRepository.fetchPendingDeleteUUIDs()) ?? []
        if !pendingDeletes.isEmpty {
            Self.log.info("startup: re-enqueueing \(pendingDeletes.count, privacy: .public) pending delete(s) from previous session")
            let pendingDeleteChanges: [CKSyncEngine.PendingRecordZoneChange] = pendingDeletes.map {
                .deleteRecord(CKRecord.ID(recordName: $0, zoneID: SyncRecordMapper.zoneID))
            }
            newEngine.state.add(pendingRecordZoneChanges: pendingDeleteChanges)
        }

        // Subscribe for silent push so device B wakes up when device A
        // commits. CKSyncEngine doesn't manage subscriptions — we own this
        // side-channel. Safe to fire-and-forget; a failure degrades to
        // polling (fetchChanges on app foreground + 30-min periodic).
        //
        // Gated on a local in-memory flag (subscriptionEnsured) AND a
        // persisted SyncStateStore sentinel — the latter survives app
        // relaunches so we skip the lookup+modify round-trip on every
        // launch. The in-memory flag prevents a double-register race if
        // a future caller invokes startIfEligible concurrently.
        if !subscriptionEnsured {
            subscriptionEnsured = true
            let db = container.privateCloudDatabase
            let store = stateStore
            Task.detached(priority: .utility) {
                await Self.ensureDatabaseSubscription(
                    database: db,
                    stateStore: store
                )
            }
        }

        // Run an initial sync cycle (fetch → send) on startup. fetch pulls
        // changes accumulated while the app was closed; send flushes locally
        // queued records including the zone save above.
        requestSyncCycle(reason: "startup")

        // 30-minute safety-net cycle in case silent push doesn't arrive.
        startPeriodicFetch()
    }

    /// Ensure a `CKDatabaseSubscription` is registered on the private DB.
    /// Idempotent across app launches: reads the persisted sentinel from
    /// `SyncStateStore` first. On a cache hit no network I/O happens.
    ///
    /// Why `CKDatabaseSubscription` and not `CKRecordZoneSubscription`:
    /// we own exactly one zone today, so database-scope is equivalent and
    /// survives adding future zones without requiring a migration.
    private static func ensureDatabaseSubscription(
        database: CKDatabase,
        stateStore: SyncStateStore
    ) async {
        let subscriptionID = "clipraven-private-db-v1"

        if stateStore.load(forKey: SyncStateStore.Key.subscriptionRegistered) != nil {
            log.debug("CKDatabaseSubscription cached; skipping remote check")
            return
        }

        do {
            _ = try await database.subscription(for: subscriptionID)
            log.debug("CKDatabaseSubscription already registered remotely")
            await Self.persistSubscriptionSentinel(stateStore: stateStore)
            return
        } catch let error as CKError where error.code == .unknownItem {
            // Expected on first launch — fall through to create.
        } catch {
            log.error("subscription lookup failed: \(error.localizedDescription, privacy: .public)")
            // Try to create anyway — an already-present subscription will
            // be handled idempotently by modifySubscriptions (server-side
            // merge on duplicate subscriptionID).
        }

        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true  // silent push
        subscription.notificationInfo = info

        do {
            _ = try await database.modifySubscriptions(
                saving: [subscription],
                deleting: []
            )
            log.info("CKDatabaseSubscription registered (silent push enabled)")
            await Self.persistSubscriptionSentinel(stateStore: stateStore)
        } catch {
            log.error("subscription save failed: \(error.localizedDescription, privacy: .public). Falling back to foreground polling.")
        }
    }

    private static func persistSubscriptionSentinel(stateStore: SyncStateStore) async {
        // Any non-empty blob satisfies the hit-test. Use a single byte
        // to keep the row small — `SyncStateStore` rejects empty blobs.
        await stateStore.save(Data([0x01]), forKey: SyncStateStore.Key.subscriptionRegistered)
    }

    /// Public entry point for AppDelegate (silent push, foreground, panel open).
    /// Schedules a full fetch→send cycle. Idempotent — concurrent calls are
    /// coalesced into one pending cycle rather than stacking.
    public func fetchChangesOnWake() {
        requestSyncCycle(reason: "wake/push")
    }

    /// Schedule a fetch→send cycle. If a cycle is already running, marks a
    /// pending cycle to run immediately after the current one completes.
    /// Safe to call from any trigger point on the main actor.
    ///
    /// Why we coalesce instead of queuing N cycles: rapid-fire triggers
    /// (a clipboard burst, several enqueueSave calls in one transaction,
    /// silent push arriving while a cycle is in-flight) would otherwise
    /// schedule a stack of redundant fetch/send round-trips. We only need
    /// "another cycle after the current one settles" — the engine's
    /// pending-changes queue already accumulates whatever needs to be sent.
    public func requestSyncCycle(reason: String = "") {
        guard engine != nil, !isShutDown else { return }
        guard !isSyncCycleRunning else {
            Self.log.debug("requestSyncCycle queued: reason=\(reason, privacy: .public) (cycle in progress)")
            pendingSyncAfterCycle = true
            return
        }
        Self.log.info("cycle start: reason=\(reason, privacy: .public)")
        isSyncCycleRunning = true
        Task { [weak self] in
            await self?.executeCycle()
        }
    }

    /// Run one fetch→send cycle.
    ///
    /// Order matters: fetch always runs first so the zone-change token is
    /// current (includes remote-device records) before our send can advance
    /// it. See `automaticallySync = false` in `startIfEligible` for the full
    /// rationale — running send first risks permanently skipping records
    /// other devices uploaded between our last fetch and this send.
    ///
    /// App Nap (`beginActivity` with `.userInitiated`/`.latencyCritical`) is
    /// suppressed for the duration so the cycle isn't suspended mid-request
    /// when the app is in the background. Without this the OS can pause the
    /// network task and the user sees stale clips for minutes.
    private func executeCycle() async {
        defer {
            isSyncCycleRunning = false
            if pendingSyncAfterCycle && !isShutDown {
                pendingSyncAfterCycle = false
                requestSyncCycle(reason: "deferred")
            } else {
                pendingSyncAfterCycle = false
            }
        }

        guard let capturedEngine = engine, !isShutDown else { return }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "ClipRaven: iCloud sync cycle"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        do {
            Self.log.debug("cycle: fetch start")
            try await capturedEngine.fetchChanges()
            Self.log.debug("cycle: fetch done")

            guard !isShutDown else { return }

            Self.log.debug("cycle: send start")
            try await capturedEngine.sendChanges()
            Self.log.debug("cycle: send done")
        } catch {
            Self.log.error("sync cycle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts a periodic 30-minute fallback sync loop.
    ///
    /// Why this safety net exists: silent push is the primary wake-up
    /// channel for cross-device sync, but it can fail silently — APS
    /// registration may be denied on dev signing, the device may have
    /// notifications muted, or the push may simply be dropped. Without
    /// a polling backstop, a device that misses a push never receives
    /// the corresponding record until the user opens the app.
    ///
    /// Why 30 minutes: short enough that a missed record surfaces within
    /// half an hour without user action; long enough to stay well below
    /// CloudKit's request budget even when many devices share an account.
    ///
    /// Safe to call multiple times — cancels any previous loop first.
    /// The loop exits cleanly when the Task is cancelled (shutdown) or
    /// when `isShutDown` / `engine` becomes nil (late-firing resume).
    private func startPeriodicFetch() {
        periodicFetchTask?.cancel()
        periodicFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                guard !Task.isCancelled else { break }
                guard let self, !self.isShutDown else { break }
                self.requestSyncCycle(reason: "periodic")
            }
        }
    }

    // MARK: - Enqueue API

    /// Schedule a record upload. Called by `SyncChangeCapture` when the
    /// clip is inserted or updated. The actual `CKRecord` is built lazily
    /// in `nextRecordZoneChangeBatch` — so if the clip is soft-deleted or
    /// mutated again before the upload fires, the latest state is sent.
    ///
    /// No-op when the engine isn't running (flag off, account unavailable,
    /// or shutdown). Callers don't need to gate — enqueue is idempotent
    /// and cheap regardless.
    public func enqueueSave(uuid: String) {
        guard let engine = engine, !isShutDown else { return }
        guard !uuid.isEmpty else {
            Self.log.error("enqueueSave refused empty uuid")
            return
        }
        let recordID = CKRecord.ID(recordName: uuid, zoneID: SyncRecordMapper.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        requestSyncCycle(reason: "enqueue.save")
    }

    /// Batch variant of `enqueueSave(uuid:)`. Preferred when a single
    /// transaction produces multiple clip saves (e.g., paste stack reorder,
    /// bulk tag assignment).
    public func enqueueSaves(uuids: [String]) {
        guard let engine = engine, !isShutDown else { return }
        guard !uuids.isEmpty else { return }
        let changes: [CKSyncEngine.PendingRecordZoneChange] = uuids.compactMap { uuid in
            guard !uuid.isEmpty else { return nil }
            let recordID = CKRecord.ID(recordName: uuid, zoneID: SyncRecordMapper.zoneID)
            return .saveRecord(recordID)
        }
        // Caller passed only empty-uuid entries — treat as no-op rather than
        // schedule a redundant sync cycle for nothing to send.
        guard !changes.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: changes)
        requestSyncCycle(reason: "enqueue.saves(\(changes.count))")
    }

    /// Schedule a record deletion. Called by `SyncChangeCapture` when the
    /// clip flips to `isDeleted = 1`. Hard deletes (cleanup cron) are
    /// not propagated — soft-delete first, or the tombstone never
    /// reaches the server.
    public func enqueueDelete(uuid: String) {
        guard let engine = engine, !isShutDown else { return }
        guard !uuid.isEmpty else {
            Self.log.error("enqueueDelete refused empty uuid")
            return
        }
        let recordID = CKRecord.ID(recordName: uuid, zoneID: SyncRecordMapper.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        requestSyncCycle(reason: "enqueue.delete")
    }

    /// Tear down the engine. Returns a token required by
    /// `SyncStateStore.clearAll(afterShutdown:)` — callers that want to
    /// wipe stored state must invoke this first so the engine can't
    /// re-save mid-wipe.
    @discardableResult
    public func shutdown() -> SyncEngineShutdownToken {
        if engine != nil {
            Self.log.info("sync engine shutting down")
        }
        periodicFetchTask?.cancel()
        periodicFetchTask = nil
        engine = nil
        isShutDown = true
        return SyncEngineShutdownToken()
    }

    // MARK: - State persistence (delegate helper)

    /// Async so the disk write runs on GRDB's writer queue, not the main
    /// actor. `handleEvent` awaits this — events are processed serially
    /// by CKSyncEngine + GRDB's serial writer queue, so stateUpdate
    /// ordering is preserved end-to-end.
    private func persistState(_ serialization: CKSyncEngine.State.Serialization) async {
        do {
            let data = try JSONEncoder().encode(serialization)
            await stateStore.save(data, forKey: SyncStateStore.Key.mainEngine)
        } catch {
            Self.log.error("state encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - CKSyncEngineDelegate

@available(macOS 14.0, *)
extension SyncEngine: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if fetchApplyFailed {
                // A prior `fetchedRecordZoneChanges` in this cycle failed to
                // apply. Dropping this persist keeps the on-disk token behind
                // the server, forcing the engine to re-deliver those records
                // on the next fetch. Without this gate, token advance + local
                // apply failure = permanent drift (the same shape of bug as
                // the upload-token-advance issue, but on the download side).
                Self.log.error("skipped stateUpdate persist due to prior apply failure; next fetch will retry")
                fetchApplyFailed = false
                return
            }
            await persistState(update.stateSerialization)

        case .accountChange(let change):
            // Account flip (sign-in/out, different iCloud user). Logged
            // for visibility; actual state-wipe on sign-out is deferred
            // until `SyncStateStore.clearAll(afterShutdown:)` gets wired
            // in here. We intentionally preserve pending changes across
            // sign-in so a re-auth doesn't drop queued uploads.
            Self.log.info("accountChange: \(String(describing: change.changeType), privacy: .public)")

        case .sentRecordZoneChanges(let event):
            // Persist system fields and ack bookkeeping for each successfully
            // uploaded record so the next update uses the correct
            // `recordChangeTag`.
            await handleSentRecordZoneChanges(event)

        case .fetchedRecordZoneChanges(let event):
            Self.log.debug("fetchedRecordZoneChanges: mods=\(event.modifications.count, privacy: .public), dels=\(event.deletions.count, privacy: .public)")
            // Server → local upsert + tombstone. If apply fails, we flip
            // `fetchApplyFailed` so the next stateUpdate skips its persist
            // and the server-side token stays behind. The engine will
            // re-deliver these records on the next fetch cycle, giving
            // us a retry without data loss.
            do {
                try await handleFetchedRecordZoneChanges(event)
                fetchApplyFailed = false
            } catch {
                fetchApplyFailed = true
                Self.log.error("fetchedRecordZoneChanges apply failed: \(error.localizedDescription, privacy: .public). Token will NOT advance.")
            }

        case .willFetchChanges,
             .didFetchChanges,
             .willSendChanges,
             .didSendChanges,
             .fetchedDatabaseChanges,
             .sentDatabaseChanges,
             .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges:
            Self.log.debug("handleEvent: \(String(describing: event), privacy: .public)")

        @unknown default:
            Self.log.debug("handleEvent: unknown event case")
        }
    }

    /// Apply `ckSystemFields` and `ckLastSyncedAt` to the local row for
    /// every successfully-uploaded record. Also logs failures; transient
    /// errors (network, throttle) are auto-retried by CKSyncEngine so we
    /// don't re-enqueue here. `serverRecordChanged` conflicts are merged
    /// inline below via `applyServerChanges`.
    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges
    ) async {
        let saved = event.savedRecords
        if !saved.isEmpty {
            Self.log.info("uploaded \(saved.count) record(s) to CloudKit")
            do {
                try await clipRepository.applyUploadAck(records: saved)
            } catch {
                Self.log.error("applyUploadAck failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Collect `serverRecordChanged` conflicts — server already has a
        // newer version, so current policy is "server wins": merge the
        // server record into the local row (same path as fetch) and let
        // CKSyncEngine decide whether to retry. The engine drops the
        // saveRecord from the pending queue on this error, so we do NOT
        // re-enqueue; the user's next edit will bump `updatedAt` and
        // trigger a fresh send with the rehydrated `ckSystemFields`.
        //
        // Server-wins sanctions losing the local mutable-field delta
        // (immutables are protected by decode's merge). Log the pre-merge
        // local `updatedAt` at `.info` so Console diagnostics can surface
        // incidents until a per-field LWW path is added.
        var conflictServerRecords: [CKRecord] = []
        for failure in event.failedRecordSaves {
            let name = failure.record.recordID.recordName
            if let ckError = failure.error as? CKError,
               ckError.code == .serverRecordChanged,
               let serverRecord = ckError.serverRecord
            {
                let localTag = failure.record[SyncRecordMapper.Key.updatedAt] as? Date
                let serverTag = serverRecord[SyncRecordMapper.Key.updatedAt] as? Date
                Self.log.info(
                    "serverRecordChanged for \(name, privacy: .public); local updatedAt=\(String(describing: localTag), privacy: .public) server updatedAt=\(String(describing: serverTag), privacy: .public); applying server copy"
                )
                conflictServerRecords.append(serverRecord)
            } else {
                Self.log.error("upload failed \(name, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        if !conflictServerRecords.isEmpty {
            do {
                _ = try await clipRepository.applyServerChanges(
                    modifications: conflictServerRecords,
                    deletions: []
                )
            } catch {
                Self.log.error("applyServerChanges (conflict) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if !event.deletedRecordIDs.isEmpty {
            Self.log.info("server confirmed delete of \(event.deletedRecordIDs.count) record(s)")
            // Ack confirmed deletes so:
            // 1. SyncChangeCapture won't re-enqueue them (ckLastSyncedAt > updatedAt guard).
            // 2. ClipRepository.deleteSoftDeleted() can safely hard-delete them.
            let deletedUUIDs = event.deletedRecordIDs.map(\.recordName)
            do {
                try await clipRepository.applyDeleteAck(uuids: deletedUUIDs)
            } catch {
                Self.log.error("applyDeleteAck failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        for (recordID, error) in event.failedRecordDeletes {
            Self.log.error("delete failed \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Apply server-originated record changes to the local DB.
    ///
    /// Throws on apply failure so the caller in `handleEvent` can set the
    /// `fetchApplyFailed` fuse. The engine's change token must NOT advance
    /// when this throws — that's the contract that prevents drift.
    ///
    /// - `modifications` are inserts/updates from other devices; merged via
    ///   `SyncRecordMapper.decode` with "server-wins" policy (LWW deferred).
    ///   Immutable-field protection lives in decode.
    /// - `deletions` are hard deletes from the server (the other device
    ///   called `enqueueDelete`); local row is removed outright. Soft
    ///   deletes arrive as a modification with `isDeleted=1` and flow
    ///   through the normal upsert path.
    ///
    /// Both paths run off the main actor — the DB transaction is on
    /// GRDB's writer queue, and `SyncChangeCapture` sees the writes as
    /// ordinary commits but drops them via the `ckLastSyncedAt > updatedAt`
    /// re-enqueue guard (see `applyServerChanges` doc).
    private func handleFetchedRecordZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async throws {
        let modifications = event.modifications.map(\.record)
        let deletions = event.deletions.map(\.recordID)

        guard !modifications.isEmpty || !deletions.isEmpty else { return }

        let counts = try await clipRepository.applyServerChanges(
            modifications: modifications,
            deletions: deletions
        )
        Self.log.info(
            "downloaded: +\(counts.inserted, privacy: .public) inserted, ~\(counts.updated, privacy: .public) updated, -\(counts.deleted, privacy: .public) deleted"
        )
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Drop all work if we've been shut down mid-flight. engine can be nil
        // after a shutdown() called while a batch request was already queued.
        guard !isShutDown else { return nil }

        // Honor the context's scope — CKSyncEngine can pass a scoped send
        // context (e.g., for a specific zone or subscription) and
        // returning unrelated pending changes here confuses its batching.
        // Matches Apple's sample-cloudkit-sync-engine pattern.
        let scope = context.options.scope
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            scope.contains($0)
        }
        guard !pendingChanges.isEmpty else { return nil }

        let repo = clipRepository

        // The closure is called once per recordID that needs a CKRecord
        // body. It runs off the main thread (async) so DB reads are safe.
        // Returning nil causes CKSyncEngine to drop that change from the
        // pending queue — the correct behaviour when the local row has
        // been hard-deleted between enqueue and send.
        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges,
            recordProvider: { recordID in
                let uuid = recordID.recordName
                guard let clip = try? repo.fetchByUUID(uuid) else {
                    Self.log.info("recordProvider: clip vanished (uuid=\(uuid, privacy: .public)); dropping")
                    return nil
                }
                // SyncRecordMapper.encode already gates on excludeFromSync
                // and returns nil for malformed rows. Logging there covers
                // the diagnostic signal.
                return SyncRecordMapper.encode(clip)
            }
        )

        return batch
    }
}
