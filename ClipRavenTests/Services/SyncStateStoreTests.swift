import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

/// Unit tests for `SyncStateStore`.
///
/// Uses `TestDatabase` which runs the full production migrator, so v13
/// `sync_engine_state` table is live. No CloudKit / no network.
final class SyncStateStoreTests: XCTestCase {

    private var testDB: TestDatabase!
    private var store: SyncStateStore!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        store = SyncStateStore(dbWriter: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Round-trip

    func test_save_then_load_returnsIdenticalData() async {
        let payload = "mainEngine state blob v1".data(using: .utf8)!

        await store.save(payload, forKey: SyncStateStore.Key.mainEngine)
        let restored = store.load(forKey: SyncStateStore.Key.mainEngine)

        XCTAssertEqual(restored, payload)
    }

    func test_save_overwritesPreviousValue() async {
        let v1 = Data([0x01, 0x02, 0x03])
        let v2 = Data([0xFF, 0xEE, 0xDD, 0xCC])

        await store.save(v1, forKey: SyncStateStore.Key.mainEngine)
        await store.save(v2, forKey: SyncStateStore.Key.mainEngine)

        XCTAssertEqual(store.load(forKey: SyncStateStore.Key.mainEngine), v2)
    }

    func test_load_returnsNilForMissingKey() {
        XCTAssertNil(store.load(forKey: "never-written"))
        XCTAssertNil(store.load(forKey: SyncStateStore.Key.mainEngine))
    }

    func test_save_refusesEmptyBlob() async {
        await store.save(Data(), forKey: "empty-key")

        // Empty blobs are refused (see file header — sync state is never
        // legitimately zero-length; empty means upstream bug).
        XCTAssertNil(store.load(forKey: "empty-key"))
    }

    func test_save_handlesLargeBlob() async {
        // CKSyncEngine state can grow to tens of KB with many pending zones.
        let big = Data(count: 200 * 1024) // 200 KiB

        await store.save(big, forKey: SyncStateStore.Key.mainEngine)

        XCTAssertEqual(store.load(forKey: SyncStateStore.Key.mainEngine)?.count, big.count)
    }

    // MARK: - Clear

    func test_clear_removesSingleKey() async {
        await store.save(Data([1]), forKey: "a")
        await store.save(Data([2]), forKey: "b")

        await store.clear(forKey: "a")

        XCTAssertNil(store.load(forKey: "a"))
        XCTAssertEqual(store.load(forKey: "b"), Data([2]))
    }

    func test_clearAll_removesEveryKey() async {
        await store.save(Data([1]), forKey: "a")
        await store.save(Data([2]), forKey: "b")
        await store.save(Data([3]), forKey: "c")

        // @testable import lets us synthesize the shutdown token directly
        // so the destructive path is reachable without spinning up a real
        // SyncEngine (Phase B.4).
        await store.clearAll(afterShutdown: SyncEngineShutdownToken())

        XCTAssertNil(store.load(forKey: "a"))
        XCTAssertNil(store.load(forKey: "b"))
        XCTAssertNil(store.load(forKey: "c"))
    }

    // MARK: - Timestamp

    func test_lastUpdatedAt_returnsNilBeforeFirstSave() {
        XCTAssertNil(store.lastUpdatedAt(forKey: SyncStateStore.Key.mainEngine))
    }

    func test_lastUpdatedAt_advancesOnOverwrite() async throws {
        await store.save(Data([1]), forKey: SyncStateStore.Key.mainEngine)
        let t1 = try XCTUnwrap(store.lastUpdatedAt(forKey: SyncStateStore.Key.mainEngine))

        // Strict '>' needs real wall-clock advance. GRDB stores Date via
        // ISO8601-with-fractional-seconds, so sub-second advances round-trip
        // — but keep a margin above measurement noise.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        await store.save(Data([2]), forKey: SyncStateStore.Key.mainEngine)
        let t2 = try XCTUnwrap(store.lastUpdatedAt(forKey: SyncStateStore.Key.mainEngine))

        XCTAssertGreaterThan(t2, t1, "timestamp must strictly advance on overwrite")
    }

    // MARK: - Concurrent access

    func test_concurrentSaves_doNotCorrupt() async {
        let iterations = 50

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask { [store] in
                    let payload = Data([UInt8(i % 256)])
                    await store?.save(payload, forKey: "slot-\(i % 5)")
                }
            }
        }

        // All 5 slots must be readable — the last write to each wins.
        for slot in 0..<5 {
            XCTAssertNotNil(self.store.load(forKey: "slot-\(slot)"))
        }
    }

    // MARK: - In-transaction (reentrant-safe) save

    func test_save_inTransaction_upsertsViaProvidedDatabase() throws {
        let key = "in-txn"
        try testDB.dbPool.write { [store] db in
            try store!.save(Data([0xDE, 0xAD]), forKey: key, db: db)
            // Second call inside the same transaction must also succeed
            // — this is the ChangeCapture use case (multiple enqueues per
            // commit).
            try store!.save(Data([0xBE, 0xEF]), forKey: key, db: db)
        }

        XCTAssertEqual(store.load(forKey: key), Data([0xBE, 0xEF]))
    }

    func test_save_inTransaction_refusesEmpty() throws {
        try testDB.dbPool.write { [store] db in
            try store!.save(Data(), forKey: "empty-txn", db: db)
        }
        XCTAssertNil(store.load(forKey: "empty-txn"))
    }

    // MARK: - Cross-instance persistence

    func test_dataSurvivesStoreInstanceReplacement() async {
        let blob = Data([0xAA, 0xBB, 0xCC])

        await store.save(blob, forKey: SyncStateStore.Key.mainEngine)

        // Dropping the store and creating a new one against the same dbPool
        // simulates app relaunch (state must survive).
        store = nil
        let store2 = SyncStateStore(dbWriter: testDB.dbPool)

        XCTAssertEqual(store2.load(forKey: SyncStateStore.Key.mainEngine), blob)
    }
}
