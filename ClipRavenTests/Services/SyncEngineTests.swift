import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

/// Unit tests for `SyncEngine` skeleton (Phase B.4).
///
/// Scope is deliberately narrow. We verify the flag-gating, idempotency,
/// and shutdown paths — which are pure Swift logic and run offline. The
/// CloudKit-dependent paths (actual engine init, delegate event handling,
/// account status branching) need a real entitlement + iCloud account
/// and are covered by the 2-device round-trip smoke test in Phase B.5.
@available(macOS 14.0, *)
final class SyncEngineTests: XCTestCase {

    private var testDB: TestDatabase!
    private var stateStore: SyncStateStore!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        stateStore = SyncStateStore(dbWriter: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil
        stateStore = nil
        super.tearDown()
    }

    // MARK: - Flag gating

    @MainActor
    func test_startIfEligible_isNoOpWhenFlagOff() async {
        SyncFeatureFlag.setEnabled(false)
        defer { SyncFeatureFlag.setEnabled(false) }

        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        // Flag off → engine never initializes CKSyncEngine nor touches the
        // state store. No network calls happen (accountStatus isn't even
        // reached).
        await engine.startIfEligible()

        // No stateUpdate was received, so the store has no row.
        XCTAssertNil(stateStore.load(forKey: SyncStateStore.Key.mainEngine))
    }

    @MainActor
    func test_startIfEligible_isIdempotent() async {
        SyncFeatureFlag.setEnabled(false)
        defer { SyncFeatureFlag.setEnabled(false) }

        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        // Two consecutive starts with flag off — each is a logged no-op
        // and does not error. The test passes if no exception is thrown
        // and the second call behaves identically to the first.
        await engine.startIfEligible()
        await engine.startIfEligible()
    }

    // MARK: - Shutdown vends the token that SyncStateStore requires

    @MainActor
    func test_shutdown_returnsUsableToken() async {
        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        let token = engine.shutdown()

        // Token is the type system proof that the engine is down. We can
        // now perform the destructive clearAll — if the wiring was wrong
        // (e.g., token declared `private init`) this line would fail to
        // compile.
        await stateStore.clearAll(afterShutdown: token)
    }

    @MainActor
    func test_shutdown_isIdempotent() {
        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        _ = engine.shutdown()
        _ = engine.shutdown()
        _ = engine.shutdown()
        // No crash = pass. Shutdown after shutdown is a normal state for
        // account-change handlers that fire repeatedly.
    }

    // MARK: - State store interaction still works after shutdown

    @MainActor
    func test_stateStoreSurvivesEngineLifecycle() async {
        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        // Simulate a previous session's state that we want preserved across
        // an engine shutdown (e.g., user toggling sync off then on in
        // Settings). clearAll is NOT called.
        let priorBlob = "prior session state".data(using: .utf8)!
        await stateStore.save(priorBlob, forKey: SyncStateStore.Key.mainEngine)

        _ = engine.shutdown()

        XCTAssertEqual(
            stateStore.load(forKey: SyncStateStore.Key.mainEngine),
            priorBlob
        )
    }

    // MARK: - One-shot latch: shutdown cannot be undone

    @MainActor
    func test_startIfEligible_refusesAfterShutdown() async {
        // Even if the flag flips on after shutdown, a one-shot engine must
        // stay down. Anyone who wants sync back must create a new instance.
        SyncFeatureFlag.setEnabled(true)
        defer { SyncFeatureFlag.setEnabled(false) }

        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        _ = engine.shutdown()
        await engine.startIfEligible()
        // No crash, no engine resurrection, no state written.
        // (The flag-on + CloudKit-less env would normally hit
        // accountStatus; the shutdown latch preempts it.)
    }

    // MARK: - Enqueue API (Phase B.5a)

    /// Enqueue operations are no-ops when the engine hasn't been brought up.
    /// This is the production path under flag-off — ChangeCapture still calls
    /// into SyncEngine, and SyncEngine silently drops. The test asserts the
    /// no-op contract by verifying no crash + no state-store writes.
    @MainActor
    func test_enqueueSave_isNoOpWhenEngineNotStarted() {
        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        engine.enqueueSave(uuid: UUID().uuidString)
        engine.enqueueSaves(uuids: [UUID().uuidString, UUID().uuidString])
        engine.enqueueDelete(uuid: UUID().uuidString)

        // State store should remain untouched — engine never came up, so no
        // stateUpdate was received, so there's nothing to persist.
        XCTAssertNil(stateStore.load(forKey: SyncStateStore.Key.mainEngine))
    }

    /// After shutdown, every enqueue call must be a no-op. This guards
    /// against late firings from ChangeCapture after the lifecycle has
    /// already torn down (e.g., async DB commit handlers fired after
    /// applicationWillTerminate ran shutdown()).
    @MainActor
    func test_enqueueSave_isNoOpAfterShutdown() {
        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )
        _ = engine.shutdown()

        engine.enqueueSave(uuid: UUID().uuidString)
        engine.enqueueSaves(uuids: [UUID().uuidString])
        engine.enqueueDelete(uuid: UUID().uuidString)
        // No crash = pass. The shutdown latch drops every enqueue on the floor.
    }

    /// Empty-string guard — CKRecord.ID rejects empty recordName with a
    /// runtime assertion. We guard earlier so ChangeCapture logging points
    /// at the actual caller bug, not at CloudKit.
    @MainActor
    func test_enqueueSave_ignoresEmptyUUID() {
        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        engine.enqueueSave(uuid: "")
        engine.enqueueDelete(uuid: "")
        engine.enqueueSaves(uuids: ["", "", ""])
        // No crash = pass.
    }

    /// `enqueueSaves` with an empty array should be a no-op, not a crash
    /// on the CKSyncEngine API. ChangeCapture may call this with an empty
    /// array when every row in a committed transaction was filtered out
    /// (e.g., all excludeFromSync).
    @MainActor
    func test_enqueueSaves_emptyArrayIsNoOp() {
        let engine = SyncEngine(
            stateStore: stateStore,
            containerIdentifier: "iCloud.test.fake",
            clipRepository: ClipSyncRepository(dbPool: testDB.dbPool)
        )

        engine.enqueueSaves(uuids: [])
        // No crash = pass.
    }
}
