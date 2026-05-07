import XCTest
import CloudKit
import GRDB
import ClipRavenSync
@testable import ClipRaven

final class ClipRepositoryTests: XCTestCase {
    private var testDB: TestDatabase!
    private var repo: ClipRepository!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        repo = ClipRepository(dbPool: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil
        repo = nil
        super.tearDown()
    }

    // MARK: - Helper

    private func makeClip(
        _ text: String,
        type: ContentType = .text,
        isPinned: Bool = false
    ) -> Clip {
        Clip(
            contentType: type,
            contentText: text,
            contentHash: XXHash64Wrapper.hash(text),
            isPinned: isPinned
        )
    }

    // MARK: - save / fetch

    func test_save_assignsId() throws {
        var clip = makeClip("hello")
        XCTAssertNil(clip.id)
        try repo.save(&clip)
        XCTAssertNotNil(clip.id)
    }

    func test_fetchOne_returnsPersistedClip() throws {
        var clip = makeClip("sample")
        try repo.save(&clip)
        let fetched = try repo.fetchOne(id: clip.id!)
        XCTAssertEqual(fetched?.contentText, "sample")
    }

    func test_fetchAll_returnsAllNonDeleted() throws {
        var a = makeClip("a"); try repo.save(&a)
        var b = makeClip("b"); try repo.save(&b)
        var c = makeClip("c"); try repo.save(&c)

        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, 3)
    }

    func test_fetchAll_filteredByContentType() throws {
        var txt = makeClip("plain", type: .text); try repo.save(&txt)
        var code = makeClip("def foo(): pass", type: .code); try repo.save(&code)

        let codeOnly = try repo.fetchAll(contentType: .code)
        XCTAssertEqual(codeOnly.count, 1)
        XCTAssertEqual(codeOnly.first?.contentType, .code)
    }

    func test_fetchAll_filteredByPinned() throws {
        var a = makeClip("a", isPinned: false); try repo.save(&a)
        var b = makeClip("b", isPinned: true); try repo.save(&b)

        let pinned = try repo.fetchAll(isPinned: true)
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned.first?.contentText, "b")
    }

    // MARK: - fetchByHash (dedup)

    func test_fetchByHash_findsExistingClip() throws {
        var clip = makeClip("dup test")
        try repo.save(&clip)

        let found = try repo.fetchByHash(clip.contentHash!)
        XCTAssertEqual(found?.id, clip.id)
    }

    func test_fetchByHash_returnsNilForMissing() throws {
        XCTAssertNil(try repo.fetchByHash("nonexistent_hash"))
    }

    // MARK: - count

    func test_count_totalNonDeleted() throws {
        for i in 0..<5 {
            var clip = makeClip("item-\(i)")
            try repo.save(&clip)
        }
        XCTAssertEqual(try repo.count(), 5)
    }

    func test_count_byContentType() throws {
        var t1 = makeClip("a"); try repo.save(&t1)
        var t2 = makeClip("b"); try repo.save(&t2)
        var c1 = makeClip("code", type: .code); try repo.save(&c1)

        XCTAssertEqual(try repo.count(contentType: .text), 2)
        XCTAssertEqual(try repo.count(contentType: .code), 1)
    }

    // MARK: - update

    func test_update_mutatesFields() throws {
        var clip = makeClip("original")
        try repo.save(&clip)
        clip.nickname = "my-snippet"
        try repo.update(clip)

        let fetched = try repo.fetchOne(id: clip.id!)
        XCTAssertEqual(fetched?.nickname, "my-snippet")
    }

    func test_incrementCopyCount() throws {
        var clip = makeClip("x")
        try repo.save(&clip)
        XCTAssertEqual(clip.copyCount, 1)

        try repo.incrementCopyCount(id: clip.id!)
        let after = try repo.fetchOne(id: clip.id!)
        XCTAssertEqual(after?.copyCount, 2)
    }

    // MARK: - togglePin

    func test_togglePin_pinsUnpinnedClip() throws {
        var clip = makeClip("pin-me")
        try repo.save(&clip)
        XCTAssertFalse(clip.isPinned)

        try repo.togglePin(id: clip.id!)
        let after = try repo.fetchOne(id: clip.id!)
        XCTAssertTrue(after!.isPinned)
        XCTAssertEqual(after!.pinOrder, 0)
    }

    func test_togglePin_unpinsPinnedClip() throws {
        var clip = makeClip("unpin-me", isPinned: true)
        clip.pinOrder = 0
        try repo.save(&clip)

        try repo.togglePin(id: clip.id!)
        let after = try repo.fetchOne(id: clip.id!)
        XCTAssertFalse(after!.isPinned)
        XCTAssertNil(after!.pinOrder)
    }

    // MARK: - soft delete

    func test_softDelete_excludesFromFetchAll() throws {
        var a = makeClip("keep"); try repo.save(&a)
        var b = makeClip("delete"); try repo.save(&b)

        try repo.softDelete(id: b.id!)

        let visible = try repo.fetchAll()
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.contentText, "keep")
    }

    func test_softDeleteBatch_removesMultiple() throws {
        var a = makeClip("a"); try repo.save(&a)
        var b = makeClip("b"); try repo.save(&b)
        var c = makeClip("c"); try repo.save(&c)

        try repo.softDeleteBatch(ids: [a.id!, b.id!])
        let visible = try repo.fetchAll()
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.contentText, "c")
    }

    // MARK: - deleteExpired

    func test_deleteExpired_removesExpiredClips() throws {
        var live = makeClip("live")
        live.expiresAt = Date().addingTimeInterval(86400)  // +1 day
        try repo.save(&live)

        var expired = makeClip("expired")
        expired.expiresAt = Date().addingTimeInterval(-86400)  // -1 day
        try repo.save(&expired)

        let removed = try repo.deleteExpired()
        XCTAssertEqual(removed, 1)

        XCTAssertEqual(try repo.count(), 1)
        XCTAssertNotNil(try repo.fetchOne(id: live.id!))
    }

    // MARK: - deleteOldest (count limit)

    func test_deleteOldest_trimsExcessUnpinnedByOldestFirst() throws {
        for i in 0..<5 {
            var c = makeClip("old-\(i)")
            c.lastCopiedAt = Date().addingTimeInterval(Double(i))  // increasing time
            try repo.save(&c)
        }

        let removed = try repo.deleteOldest(keepCount: 3)
        XCTAssertEqual(removed, 2)

        let remaining = try repo.fetchAll()
        XCTAssertEqual(remaining.count, 3)
        // Oldest (old-0, old-1) should be gone
        let remainingText = Set(remaining.compactMap { $0.contentText })
        XCTAssertFalse(remainingText.contains("old-0"))
        XCTAssertFalse(remainingText.contains("old-1"))
    }

    func test_deleteOldest_preservesPinnedClips() throws {
        for i in 0..<3 {
            var c = makeClip("normal-\(i)")
            try repo.save(&c)
        }
        var pinned = makeClip("PIN", isPinned: true)
        pinned.pinOrder = 0
        try repo.save(&pinned)

        // Keep only 1 non-pinned; pinned are exempt
        _ = try repo.deleteOldest(keepCount: 1)
        let all = try repo.fetchAll()
        XCTAssertTrue(all.contains { $0.contentText == "PIN" })
    }

    // MARK: - custom shortcut

    func test_updateCustomShortcut_persistsKeyCodeAndModifiers() throws {
        var clip = makeClip("shortcut-me")
        try repo.save(&clip)

        try repo.updateCustomShortcut(id: clip.id!, keyCode: 9, modifiers: 0x100)
        let fetched = try repo.fetchOne(id: clip.id!)
        XCTAssertEqual(fetched?.customShortcutKeyCode, 9)
        XCTAssertEqual(fetched?.customShortcutModifiers, 0x100)
    }

    func test_fetchClipsWithShortcuts_returnsOnlyShortcutBoundClips() throws {
        var a = makeClip("a"); try repo.save(&a)
        var b = makeClip("b"); try repo.save(&b)
        try repo.updateCustomShortcut(id: b.id!, keyCode: 9, modifiers: 0x100)

        let bound = try repo.fetchClipsWithShortcuts()
        XCTAssertEqual(bound.count, 1)
        XCTAssertEqual(bound.first?.id, b.id)
    }

    func test_fetchClipByShortcut_findsByKeyCombo() throws {
        var clip = makeClip("x")
        try repo.save(&clip)
        try repo.updateCustomShortcut(id: clip.id!, keyCode: 9, modifiers: 0x100)

        let found = try repo.fetchClipByShortcut(keyCode: 9, modifiers: 0x100)
        XCTAssertEqual(found?.id, clip.id)
    }

    // MARK: - B.5b applyServerChanges (download path)

    /// Build a CKRecord that exactly mirrors `encode()` output, without
    /// needing to stage a CKSyncEngine. Uses the zone the mapper ships.
    private func makeServerRecord(
        uuid: String,
        contentText: String,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        isDeleted: Bool = false,
        deviceId: String = "remote-device-xyz"
    ) -> CKRecord {
        let id = CKRecord.ID(
            recordName: uuid,
            zoneID: SyncRecordMapper.zoneID
        )
        let record = CKRecord(recordType: SyncRecordMapper.clipRecordType, recordID: id)
        record[SyncRecordMapper.Key.schemaVersion] = Int64(1)
        record[SyncRecordMapper.Key.contentType] = "text"
        record[SyncRecordMapper.Key.contentText] = contentText
        record[SyncRecordMapper.Key.contentHash] = "hash-\(uuid.prefix(6))"
        record[SyncRecordMapper.Key.createdAt] = updatedAt.addingTimeInterval(-60)
        record[SyncRecordMapper.Key.lastCopiedAt] = updatedAt
        record[SyncRecordMapper.Key.updatedAt] = updatedAt
        record[SyncRecordMapper.Key.copyCount] = Int64(1)
        record[SyncRecordMapper.Key.isPinned] = Int64(0)
        record[SyncRecordMapper.Key.isDeleted] = isDeleted ? Int64(1) : Int64(0)
        record[SyncRecordMapper.Key.deviceId] = deviceId
        record[SyncRecordMapper.Key.tagsText] = ""
        return record
    }

    func test_applyServerChanges_insertsNewRowFromServer() throws {
        let uuid = UUID().uuidString
        let record = makeServerRecord(uuid: uuid, contentText: "from other mac")

        let counts = try repo.applyServerChanges(
            modifications: [record],
            deletions: []
        )

        XCTAssertEqual(counts.inserted, 1)
        XCTAssertEqual(counts.updated, 0)
        XCTAssertEqual(counts.deleted, 0)

        let fetched = try XCTUnwrap(repo.fetchByUUID(uuid))
        XCTAssertEqual(fetched.contentText, "from other mac")
        XCTAssertEqual(fetched.deviceId, "remote-device-xyz")
        XCTAssertNotNil(fetched.ckSystemFields)
    }

    func test_applyServerChanges_updatesExistingRowWithServerWinsPolicy() throws {
        // Seed a local row with stale content + tombstone flag off.
        let uuid = UUID().uuidString
        var local = makeClip("local version")
        local.uuid = uuid
        local.deviceId = "this-mac"
        local.updatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        local.copyCount = 5
        try repo.save(&local)
        let localId = local.id!

        // Server sends a newer record with different content.
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        let record = makeServerRecord(
            uuid: uuid,
            contentText: "server version",
            updatedAt: serverDate
        )
        // Tweak a mutable field the server owns.
        record[SyncRecordMapper.Key.copyCount] = Int64(42)

        let counts = try repo.applyServerChanges(
            modifications: [record],
            deletions: []
        )

        XCTAssertEqual(counts.inserted, 0)
        XCTAssertEqual(counts.updated, 1)

        let fetched = try XCTUnwrap(repo.fetchByUUID(uuid))
        // Primary key preserved — row wasn't deleted-and-reinserted.
        XCTAssertEqual(fetched.id, localId)
        // Mutable → server wins.
        XCTAssertEqual(fetched.copyCount, 42)
        XCTAssertEqual(fetched.updatedAt, serverDate)
        // contentText: immutable, but local had "local version" which the
        // decode path preserves. Server value is dropped.
        XCTAssertEqual(fetched.contentText, "local version")
    }

    func test_applyServerChanges_preservesLocalOnlyFieldsOnUpdate() throws {
        // Local row has thumbnail, custom shortcut, excludeFromSync — none
        // of these travel over CloudKit. They must survive an update.
        let uuid = UUID().uuidString
        var local = makeClip("local")
        local.uuid = uuid
        local.updatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        local.thumbnail = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic
        local.customShortcutKeyCode = 9
        local.customShortcutModifiers = 0x100
        local.excludeFromSync = true
        try repo.save(&local)

        let record = makeServerRecord(
            uuid: uuid,
            contentText: "remote",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        _ = try repo.applyServerChanges(
            modifications: [record],
            deletions: []
        )

        let fetched = try XCTUnwrap(repo.fetchByUUID(uuid))
        XCTAssertEqual(fetched.thumbnail, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(fetched.customShortcutKeyCode, 9)
        XCTAssertEqual(fetched.customShortcutModifiers, 0x100)
        XCTAssertTrue(fetched.excludeFromSync)
    }

    func test_applyServerChanges_loopPreventionGuardHolds() throws {
        // After apply, `ckLastSyncedAt > updatedAt` must hold so
        // ChangeCapture's guard drops the re-enqueue.
        let uuid = UUID().uuidString
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        let record = makeServerRecord(
            uuid: uuid,
            contentText: "inbound",
            updatedAt: serverDate
        )

        _ = try repo.applyServerChanges(
            modifications: [record],
            deletions: []
        )

        let fetched = try XCTUnwrap(repo.fetchByUUID(uuid))
        let lastSynced = try XCTUnwrap(fetched.ckLastSyncedAt)
        let updatedAt = try XCTUnwrap(fetched.updatedAt)
        XCTAssertGreaterThan(
            lastSynced, updatedAt,
            "loop guard requires ckLastSyncedAt > updatedAt"
        )
        XCTAssertEqual(fetched.ckSyncState, 0)
    }

    func test_applyServerChanges_loopGuardHoldsUnderClockSkew() throws {
        // Peer device with a clock 10 minutes ahead would otherwise
        // produce `record.updatedAt > Date()`, flipping the guard. The
        // applyServerChanges clamp must enforce the invariant regardless.
        let uuid = UUID().uuidString
        let futureDate = Date().addingTimeInterval(600)  // +10 min
        let record = makeServerRecord(
            uuid: uuid,
            contentText: "from-future",
            updatedAt: futureDate
        )

        _ = try repo.applyServerChanges(
            modifications: [record],
            deletions: []
        )

        let fetched = try XCTUnwrap(repo.fetchByUUID(uuid))
        let lastSynced = try XCTUnwrap(fetched.ckLastSyncedAt)
        let updatedAt = try XCTUnwrap(fetched.updatedAt)
        XCTAssertGreaterThan(
            lastSynced, updatedAt,
            "clock-skew clamp must hold the guard even when server clock is ahead"
        )
    }

    func test_applyServerChanges_softDeleteFlagArrivesViaModification() throws {
        // Another device soft-deleted the clip; we receive it as a
        // modification with isDeleted=1, not a deletion.
        let uuid = UUID().uuidString
        var local = makeClip("will be tombstoned")
        local.uuid = uuid
        local.updatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        try repo.save(&local)

        let record = makeServerRecord(
            uuid: uuid,
            contentText: "will be tombstoned",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isDeleted: true
        )

        _ = try repo.applyServerChanges(
            modifications: [record],
            deletions: []
        )

        let fetched = try XCTUnwrap(repo.fetchByUUID(uuid))
        XCTAssertTrue(fetched.isDeleted)
        // fetchAll excludes soft-deleted rows.
        let visible = try repo.fetchAll()
        XCTAssertFalse(visible.contains { $0.uuid == uuid })
    }

    func test_applyServerChanges_hardDeleteRemovesLocalRow() throws {
        let uuid = UUID().uuidString
        var local = makeClip("hard delete target")
        local.uuid = uuid
        local.updatedAt = Date()
        try repo.save(&local)

        let recordID = CKRecord.ID(
            recordName: uuid,
            zoneID: SyncRecordMapper.zoneID
        )

        let counts = try repo.applyServerChanges(
            modifications: [],
            deletions: [recordID]
        )

        XCTAssertEqual(counts.deleted, 1)
        XCTAssertNil(try repo.fetchByUUID(uuid))
    }

    func test_applyServerChanges_hardDeleteOfMissingRowIsNoOp() throws {
        let recordID = CKRecord.ID(
            recordName: UUID().uuidString,
            zoneID: SyncRecordMapper.zoneID
        )

        let counts = try repo.applyServerChanges(
            modifications: [],
            deletions: [recordID]
        )

        XCTAssertEqual(counts.deleted, 0)
    }

    func test_applyServerChanges_isAtomicAcrossBatch() throws {
        // All modifications land in a single transaction — either the
        // whole batch is visible or none of it. The guarantee matters
        // because CKSyncEngine delivers a batch as one event.
        let u1 = UUID().uuidString
        let u2 = UUID().uuidString
        let r1 = makeServerRecord(uuid: u1, contentText: "one")
        let r2 = makeServerRecord(uuid: u2, contentText: "two")

        let counts = try repo.applyServerChanges(
            modifications: [r1, r2],
            deletions: []
        )
        XCTAssertEqual(counts.inserted, 2)
        XCTAssertNotNil(try repo.fetchByUUID(u1))
        XCTAssertNotNil(try repo.fetchByUUID(u2))
    }

    func test_applyServerChanges_emptyBatchIsZeroCostNoOp() throws {
        let counts = try repo.applyServerChanges(
            modifications: [],
            deletions: []
        )
        XCTAssertEqual(counts.inserted, 0)
        XCTAssertEqual(counts.updated, 0)
        XCTAssertEqual(counts.deleted, 0)
    }

    // MARK: - togglePin pinOrder management

    func test_togglePin_assignsPinOrderSequentially() throws {
        // 첫 번째 핀 → pinOrder 0, 두 번째 핀 → pinOrder 1
        var a = makeClip("first"); try repo.save(&a)
        var b = makeClip("second"); try repo.save(&b)

        try repo.togglePin(id: a.id!)
        try repo.togglePin(id: b.id!)

        let pinnedA = try repo.fetchOne(id: a.id!)!
        let pinnedB = try repo.fetchOne(id: b.id!)!

        XCTAssertNotNil(pinnedA.pinOrder, "핀 고정 후 pinOrder가 설정되어야 함")
        XCTAssertNotNil(pinnedB.pinOrder, "핀 고정 후 pinOrder가 설정되어야 함")
        XCTAssertLessThan(pinnedA.pinOrder!, pinnedB.pinOrder!, "먼저 핀한 클립이 더 낮은 pinOrder")
    }

    func test_togglePin_unpinClearsPinOrder() throws {
        var clip = makeClip("pinme"); try repo.save(&clip)
        try repo.togglePin(id: clip.id!)  // pin
        try repo.togglePin(id: clip.id!)  // unpin

        let unpinned = try repo.fetchOne(id: clip.id!)!
        XCTAssertFalse(unpinned.isPinned)
        XCTAssertNil(unpinned.pinOrder, "핀 해제 후 pinOrder는 nil이어야 함")
    }

    func test_togglePin_pinnedClipsAppearBeforeUnpinned() throws {
        var a = makeClip("unpinned-first"); try repo.save(&a)
        var b = makeClip("pinned-later");  try repo.save(&b)
        try repo.togglePin(id: b.id!)

        let all = try repo.fetchAll()
        let first = all.first!
        XCTAssertEqual(first.id, b.id, "핀된 클립이 fetchAll 정렬에서 앞에 위치해야 함")
    }

    // MARK: - softDelete behavior

    func test_softDelete_doesNotPhysicallyRemoveRow() throws {
        // softDelete는 isDeleted=1로 표시만 할 뿐, DB 행 자체는 남아있음
        // (SyncEngine 업로드 대기용)
        var clip = makeClip("keep me")
        try repo.save(&clip)
        let id = clip.id!

        try repo.softDelete(id: id)

        // fetchAll은 보여주지 않지만 직접 DB로는 확인 가능
        let stillExists = try testDB.dbPool.read { db in
            try Clip.filter(Column("id") == id).fetchOne(db)
        }
        XCTAssertNotNil(stillExists, "softDelete는 행을 물리적으로 삭제하지 않음")
        XCTAssertTrue(stillExists!.isDeleted, "isDeleted = 1 이어야 함")
    }

    func test_fetchAll_excludesSoftDeletedClips() throws {
        var a = makeClip("visible"); try repo.save(&a)
        var b = makeClip("deleted"); try repo.save(&b)
        try repo.softDelete(id: b.id!)

        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.contentText, "visible")
    }
}
