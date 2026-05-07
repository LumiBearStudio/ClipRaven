import XCTest
import CloudKit
import ClipRavenSync
@testable import ClipRaven

/// Unit tests for `SyncRecordMapper`.
///
/// CloudKit entitlements and a real iCloud account are NOT required — these
/// tests construct `CKRecord` instances directly and exercise the mapper's
/// pure translation logic. This is exactly the behaviour we need offline
/// before Phase B.4 lights up the real sync engine.
final class SyncRecordMapperTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSampleClip(uuid: String = UUID().uuidString) -> Clip {
        var c = Clip(contentType: .text, contentText: "hello world")
        c.uuid = uuid
        c.deviceId = "test-device-abc"
        c.contentHash = "abc123"
        c.tagsText = "work, idea"
        c.copyCount = 3
        c.isPinned = true
        c.pinOrder = 2
        c.manualOrder = 5
        c.nickname = "greeting"
        c.sourceAppBundleId = "com.apple.Safari"
        c.sourceAppName = "Safari"
        c.sourceUrl = "https://example.com"
        c.ogTitle = "Example"
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        c.createdAt = fixedDate
        c.lastCopiedAt = fixedDate.addingTimeInterval(60)
        c.ogFetchedAt = fixedDate.addingTimeInterval(30)
        c.updatedAt = fixedDate.addingTimeInterval(120)
        c.aiCategory = "other"
        c.aiCategoryGeneratedAt = fixedDate.addingTimeInterval(90)
        c.schemaVersion = 1
        return c
    }

    // MARK: - Round-trip

    func test_encode_then_decode_preservesAllMappedFields() throws {
        let original = makeSampleClip()

        let record = try XCTUnwrap(SyncRecordMapper.encode(original))
        let decoded = SyncRecordMapper.decode(record, merging: nil)

        XCTAssertEqual(decoded.uuid, original.uuid)
        XCTAssertEqual(decoded.contentType, original.contentType)
        XCTAssertEqual(decoded.contentText, original.contentText)
        XCTAssertEqual(decoded.contentHash, original.contentHash)
        XCTAssertEqual(decoded.tagsText, original.tagsText)
        XCTAssertEqual(decoded.copyCount, original.copyCount)
        XCTAssertEqual(decoded.isPinned, original.isPinned)
        XCTAssertEqual(decoded.pinOrder, original.pinOrder)
        XCTAssertEqual(decoded.manualOrder, original.manualOrder)
        XCTAssertEqual(decoded.nickname, original.nickname)
        XCTAssertEqual(decoded.sourceAppBundleId, original.sourceAppBundleId)
        XCTAssertEqual(decoded.sourceAppName, original.sourceAppName)
        XCTAssertEqual(decoded.sourceUrl, original.sourceUrl)
        XCTAssertEqual(decoded.ogTitle, original.ogTitle)
        XCTAssertEqual(decoded.ogFetchedAt, original.ogFetchedAt)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.lastCopiedAt, original.lastCopiedAt)
        XCTAssertEqual(decoded.updatedAt, original.updatedAt)
        XCTAssertEqual(decoded.aiCategory, original.aiCategory)
        XCTAssertEqual(decoded.aiCategoryGeneratedAt, original.aiCategoryGeneratedAt)
        XCTAssertEqual(decoded.deviceId, original.deviceId)
        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion)
    }

    func test_encode_stampsPlatformAndDeviceIdWhenMissing() throws {
        var clip = makeSampleClip()
        clip.deviceId = nil

        let record = try XCTUnwrap(SyncRecordMapper.encode(clip))

        XCTAssertNotNil(record[SyncRecordMapper.Key.deviceId] as? String)
        XCTAssertEqual(
            record[SyncRecordMapper.Key.platformCreatedOn] as? String,
            DeviceIdentity.platform
        )
    }

    // MARK: - Contract violations return nil (defensive, not fatal)

    func test_encode_returnsNilWhenUuidMissing() {
        var clip = makeSampleClip()
        clip.uuid = nil
        XCTAssertNil(SyncRecordMapper.encode(clip))
    }

    func test_encode_returnsNilWhenUuidEmpty() {
        var clip = makeSampleClip()
        clip.uuid = ""
        XCTAssertNil(SyncRecordMapper.encode(clip))
    }

    func test_encode_returnsNilWhenUpdatedAtMissing() {
        var clip = makeSampleClip()
        clip.updatedAt = nil
        XCTAssertNil(SyncRecordMapper.encode(clip))
    }

    // MARK: - Fail-closed on excludeFromSync (sec review H2)

    func test_encode_returnsNilWhenExcludeFromSyncIsTrue() {
        var clip = makeSampleClip()
        clip.excludeFromSync = true
        XCTAssertNil(
            SyncRecordMapper.encode(clip),
            "encode must fail closed on excludeFromSync regardless of uuid/updatedAt validity"
        )
    }

    func test_encode_excludeFromSyncTakesPrecedenceOverMissingUuid() {
        var clip = makeSampleClip()
        clip.excludeFromSync = true
        clip.uuid = nil
        // Either the exclusion guard or the uuid guard will reject — just
        // confirm the result is nil and no crash. Order of checks is
        // covered by the preceding test.
        XCTAssertNil(SyncRecordMapper.encode(clip))
    }

    // MARK: - systemFields preservation

    func test_encode_reusesExistingSystemFieldsBlob() throws {
        // First encode generates a record whose systemFields we capture.
        let clip1 = makeSampleClip(uuid: "fixed-uuid-1")
        let record1 = try XCTUnwrap(SyncRecordMapper.encode(clip1))
        let sysFields = SyncRecordMapper.encodedSystemFields(of: record1)
        XCTAssertFalse(sysFields.isEmpty)

        // Simulate a locally-persisted Clip that came back from a prior sync.
        var clip2 = makeSampleClip(uuid: "fixed-uuid-1")
        clip2.ckSystemFields = sysFields
        clip2.nickname = "updated nickname"

        let record2 = try XCTUnwrap(SyncRecordMapper.encode(clip2))

        // Same record ID reused from rehydrated systemFields — not a new one.
        XCTAssertEqual(record2.recordID.recordName, record1.recordID.recordName)
        XCTAssertEqual(record2.recordID.zoneID, SyncRecordMapper.zoneID)
        XCTAssertEqual(record2[SyncRecordMapper.Key.nickname] as? String, "updated nickname")
    }

    func test_recordFromSystemFields_returnsNilForCorruptBlob() {
        let garbage = Data([0x00, 0xFF, 0x00, 0xFF])
        XCTAssertNil(SyncRecordMapper.recordFromSystemFields(garbage))
    }

    // MARK: - Optional field handling

    func test_encode_clearsFieldWhenLocalOptionalIsNil() throws {
        var clip = makeSampleClip()
        clip.nickname = nil
        clip.sourceUrl = nil
        clip.ogTitle = nil
        clip.aiCategory = nil

        let record = try XCTUnwrap(SyncRecordMapper.encode(clip))

        XCTAssertNil(record[SyncRecordMapper.Key.nickname])
        XCTAssertNil(record[SyncRecordMapper.Key.sourceUrl])
        XCTAssertNil(record[SyncRecordMapper.Key.ogTitle])
        XCTAssertNil(record[SyncRecordMapper.Key.aiCategory])
    }

    func test_decode_nilOptionalFieldsRemainNil() throws {
        var clip = makeSampleClip()
        clip.nickname = nil
        clip.sourceUrl = nil
        let record = try XCTUnwrap(SyncRecordMapper.encode(clip))

        let decoded = SyncRecordMapper.decode(record, merging: nil)

        XCTAssertNil(decoded.nickname)
        XCTAssertNil(decoded.sourceUrl)
    }

    // MARK: - Unknown enum degradation

    func test_decode_unknownContentTypeDegradesToText() {
        let id = CKRecord.ID(recordName: "future-clip", zoneID: SyncRecordMapper.zoneID)
        let record = CKRecord(recordType: SyncRecordMapper.clipRecordType, recordID: id)
        record[SyncRecordMapper.Key.contentType] = "video" // added in hypothetical v3.0
        record[SyncRecordMapper.Key.createdAt] = Date()
        record[SyncRecordMapper.Key.lastCopiedAt] = Date()
        record[SyncRecordMapper.Key.copyCount] = Int64(1)
        record[SyncRecordMapper.Key.isPinned] = Int64(0)
        record[SyncRecordMapper.Key.isDeleted] = Int64(0)
        record[SyncRecordMapper.Key.deviceId] = "some-device"

        let decoded = SyncRecordMapper.decode(record, merging: nil)

        XCTAssertEqual(decoded.contentType, .text, "unknown enum raw should degrade")
        XCTAssertEqual(decoded.uuid, "future-clip")
    }

    // MARK: - Immutable field protection in merge

    func test_decode_merging_keepsLocalImmutableFields() throws {
        let original = makeSampleClip(uuid: "stable-1")
        let record = try XCTUnwrap(SyncRecordMapper.encode(original))

        // Server returns the record with hostile changes to immutable fields.
        record[SyncRecordMapper.Key.contentText] = "SERVER TRIED TO CHANGE CONTENT"
        record[SyncRecordMapper.Key.contentHash] = "SERVER_HASH"
        record[SyncRecordMapper.Key.deviceId] = "SERVER_DEVICE"
        record[SyncRecordMapper.Key.createdAt] = Date(timeIntervalSince1970: 1)

        let decoded = SyncRecordMapper.decode(record, merging: original)

        XCTAssertEqual(decoded.contentText, original.contentText)
        XCTAssertEqual(decoded.contentHash, original.contentHash)
        XCTAssertEqual(decoded.deviceId, original.deviceId)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
    }

    func test_decode_merging_appliesServerMutableFields() throws {
        let original = makeSampleClip(uuid: "stable-2")
        let record = try XCTUnwrap(SyncRecordMapper.encode(original))

        // Server has newer mutable state.
        record[SyncRecordMapper.Key.isPinned] = Int64(0)
        record[SyncRecordMapper.Key.copyCount] = Int64(99)
        record[SyncRecordMapper.Key.nickname] = "renamed on other Mac"

        let decoded = SyncRecordMapper.decode(record, merging: original)

        XCTAssertFalse(decoded.isPinned)
        XCTAssertEqual(decoded.copyCount, 99)
        XCTAssertEqual(decoded.nickname, "renamed on other Mac")
    }

    func test_decode_stampsSystemFieldsAndSyncState() throws {
        let original = makeSampleClip(uuid: "stable-3")
        let record = try XCTUnwrap(SyncRecordMapper.encode(original))

        let decoded = SyncRecordMapper.decode(record, merging: nil)

        XCTAssertNotNil(decoded.ckSystemFields)
        XCTAssertFalse(decoded.ckSystemFields!.isEmpty)
        XCTAssertEqual(decoded.ckSyncState, 0)
        XCTAssertNotNil(decoded.ckLastSyncedAt)
    }

    // MARK: - Decode backfills immutable fields on rows that lack them

    func test_decode_backfillsDeviceIdOnExistingRowWithNilDeviceId() throws {
        // Sim: pre-v12 migration row that got its deviceId column added
        // but never backfilled, then received a server update. The server
        // record's deviceId should win since the local column is empty.
        var local = makeSampleClip(uuid: "pre-v12-like")
        local.deviceId = nil // the pathological case

        let remoteAuthoritative = makeSampleClip(uuid: "pre-v12-like")
        let record = try XCTUnwrap(SyncRecordMapper.encode(remoteAuthoritative))

        let decoded = SyncRecordMapper.decode(record, merging: local)

        XCTAssertEqual(decoded.deviceId, remoteAuthoritative.deviceId)
    }

    func test_decode_doesNotClobberPresentLocalDeviceId() throws {
        var local = makeSampleClip(uuid: "stable-device")
        local.deviceId = "local-device-id"

        let remote = makeSampleClip(uuid: "stable-device")
        let record = try XCTUnwrap(SyncRecordMapper.encode(remote))

        let decoded = SyncRecordMapper.decode(record, merging: local)

        // Present local value is held; server is ignored (immutable contract).
        XCTAssertEqual(decoded.deviceId, "local-device-id")
    }

    // MARK: - Round-trip edge cases pinned by contract

    func test_decode_roundTripsTombstoneAndExpiry() throws {
        var clip = makeSampleClip(uuid: "tombstone-1")
        clip.isDeleted = true
        let expiry = Date(timeIntervalSince1970: 1_700_604_800)
        clip.expiresAt = expiry

        let record = try XCTUnwrap(SyncRecordMapper.encode(clip))
        let decoded = SyncRecordMapper.decode(record, merging: nil)

        XCTAssertTrue(decoded.isDeleted, "tombstone flag must survive round-trip")
        XCTAssertEqual(decoded.expiresAt, expiry)
    }

    func test_decode_roundTripsImageDhashAndOcrConfidence() throws {
        var clip = makeSampleClip(uuid: "image-1")
        clip.imageDhash = 0x1234_5678_9ABC_DEF0
        clip.ocrConfidence = 0.876543210987

        let record = try XCTUnwrap(SyncRecordMapper.encode(clip))
        let decoded = SyncRecordMapper.decode(record, merging: nil)

        XCTAssertEqual(decoded.imageDhash, 0x1234_5678_9ABC_DEF0)
        XCTAssertEqual(decoded.ocrConfidence ?? 0, 0.876543210987, accuracy: 1e-9)
    }

    // MARK: - Contract checks

    func test_immutableKeys_includeExpectedFields() {
        let keys = SyncRecordMapper.protectedImmutableKeys
        XCTAssertTrue(keys.contains(SyncRecordMapper.Key.contentText))
        XCTAssertTrue(keys.contains(SyncRecordMapper.Key.contentHash))
        XCTAssertTrue(keys.contains(SyncRecordMapper.Key.createdAt))
        XCTAssertTrue(keys.contains(SyncRecordMapper.Key.deviceId))
        XCTAssertTrue(keys.contains(SyncRecordMapper.Key.platformCreatedOn))
    }

    func test_zoneID_isStableConstant() {
        XCTAssertEqual(SyncRecordMapper.zoneID.zoneName, "ClipRavenItems")
        XCTAssertEqual(SyncRecordMapper.zoneID.ownerName, CKCurrentUserDefaultName)
    }
}
