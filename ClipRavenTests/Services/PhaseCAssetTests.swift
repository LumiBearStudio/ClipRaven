import XCTest
import CloudKit
import GRDB
@testable import ClipRavenSync
@testable import ClipRaven

/// Phase C — 이미지 원본 CKAsset round-trip / staging / TTL cleanup 단위 테스트.
///
/// 외부 CloudKit 서버를 호출하지 않는다 — Mapper는 순수 함수, AssetStaging은
/// 로컬 파일 I/O, Cleanup은 DB+FS만 만진다.
final class PhaseCAssetTests: XCTestCase {

    // MARK: - Test fixtures

    /// 테스트용 임시 디렉터리 + 격리된 ImageOriginalStore.
    /// 각 테스트는 자기 디렉터리를 setUp 에서 만들고 tearDown 에서 비운다.
    private var tempDir: URL!
    private var originalStore: ImageOriginalStore?

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PhaseCAssetTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        originalStore = ImageOriginalStoreRegistry.current  // 복원용
        ImageOriginalStoreRegistry.register(TestImageStore(rootDir: tempDir))
    }

    override func tearDown() {
        if let originalStore { ImageOriginalStoreRegistry.register(originalStore) }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - ImageSyncSettings

    func test_ImageSyncSettings_defaultsAreThumbnailOnly_10MB_noCellular() {
        // 격리된 UserDefaults 사용 — 시스템 standard 오염 방지
        let suite = UserDefaults(suiteName: "PhaseCAssetTests-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().description)

        let snap = ImageSyncSettings.current(from: suite)
        XCTAssertEqual(snap.mode, .thumbnailOnly)
        XCTAssertEqual(snap.sizeCap, .mb10)
        XCTAssertFalse(snap.cellularAllowed)
    }

    func test_ImageSyncSettings_setAndRead_roundTrips() {
        let suite = UserDefaults(suiteName: "PhaseCAssetTests-set-\(UUID().uuidString)")!

        ImageSyncSettings.setMode(.full, to: suite)
        ImageSyncSettings.setSizeCap(.mb50, to: suite)
        ImageSyncSettings.setCellularAllowed(true, to: suite)

        let snap = ImageSyncSettings.current(from: suite)
        XCTAssertEqual(snap.mode, .full)
        XCTAssertEqual(snap.sizeCap, .mb50)
        XCTAssertTrue(snap.cellularAllowed)
    }

    func test_ImageSyncSizeCap_bytesValueIsCorrect() {
        XCTAssertEqual(ImageSyncSizeCap.mb10.bytes, 10 * 1024 * 1024)
        XCTAssertEqual(ImageSyncSizeCap.mb25.bytes, 25 * 1024 * 1024)
        XCTAssertEqual(ImageSyncSizeCap.mb50.bytes, 50 * 1024 * 1024)
        XCTAssertEqual(ImageSyncSizeCap.unlimited.bytes, .max)
    }

    // MARK: - AssetStaging

    func test_AssetStaging_stageOriginal_returnsAssetForFileUnderCap() throws {
        let src = tempDir.appendingPathComponent("src.png")
        try Data(repeating: 0xAB, count: 1024).write(to: src)  // 1KB

        let asset = AssetStaging.shared.stageOriginal(
            uuid: "test-uuid-1",
            sourcePath: src,
            sizeCapBytes: 10 * 1024  // 10KB cap
        )
        XCTAssertNotNil(asset, "1KB file under 10KB cap should produce CKAsset")
        XCTAssertNotNil(asset?.fileURL)

        // staging 사본이 실제로 생성됐는지
        if let url = asset?.fileURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }

        // cleanup
        AssetStaging.shared.cleanup(uuid: "test-uuid-1")
    }

    func test_AssetStaging_stageOriginal_returnsNilOverCap() throws {
        let src = tempDir.appendingPathComponent("big.png")
        try Data(repeating: 0xCD, count: 5 * 1024).write(to: src)  // 5KB

        let asset = AssetStaging.shared.stageOriginal(
            uuid: "test-uuid-big",
            sourcePath: src,
            sizeCapBytes: 1024  // 1KB cap → 5KB 초과
        )
        XCTAssertNil(asset, "5KB file over 1KB cap should produce nil")
    }

    func test_AssetStaging_stageOriginal_returnsNilForMissingFile() {
        let missing = tempDir.appendingPathComponent("nope.png")
        let asset = AssetStaging.shared.stageOriginal(
            uuid: "test-uuid-miss",
            sourcePath: missing,
            sizeCapBytes: .max
        )
        XCTAssertNil(asset)
    }

    func test_AssetStaging_cleanup_isIdempotent() {
        // 존재하지 않는 uuid 에 대해서도 throw 없이 동작
        AssetStaging.shared.cleanup(uuid: "never-staged-uuid")
        AssetStaging.shared.cleanup(uuid: "never-staged-uuid")
    }

    // MARK: - SyncRecordMapper CKAsset encode

    func test_encode_image_full_mode_attachesCKAsset() throws {
        // 사용자 옵션을 .full 로 강제
        let suite = UserDefaults.standard
        let prevMode = suite.string(forKey: "imageSyncMode")
        defer {
            if let m = prevMode { suite.set(m, forKey: "imageSyncMode") }
            else { suite.removeObject(forKey: "imageSyncMode") }
        }
        ImageSyncSettings.setMode(.full)
        ImageSyncSettings.setSizeCap(.mb50)

        // 원본 파일 준비
        let uuid = UUID().uuidString
        let pngData = Data(repeating: 0x42, count: 2048)
        let savedPath = ImageOriginalStoreRegistry.current!
            .saveOriginal(pngData, uuid: uuid, preferredExt: "png")
        XCTAssertNotNil(savedPath)

        // image clip 만들고 encode
        let now = Date()
        var clip = Clip(
            contentType: .image,
            imageHash: "hash123",
            imagePath: savedPath,
            thumbnail: Data([0x01, 0x02, 0x03]),
            createdAt: now,
            lastCopiedAt: now,
            uuid: uuid,
            deviceId: "test-device",
            updatedAt: now
        )
        _ = clip  // suppress unused warning
        let record = SyncRecordMapper.encode(clip)
        XCTAssertNotNil(record, "image clip with imagePath + .full should encode")

        // CKAsset 첨부 확인
        let asset = record?[SyncRecordMapper.Key.imageOriginalAsset] as? CKAsset
        XCTAssertNotNil(asset, "imageOriginalAsset should be attached in .full mode")

        // assetExceeded == 0
        let exceeded = record?[SyncRecordMapper.Key.assetExceeded] as? Int64
        XCTAssertEqual(exceeded, 0)

        // cleanup
        AssetStaging.shared.cleanup(uuid: uuid)
    }

    func test_encode_image_thumbnailOnly_mode_doesNotAttachAsset() throws {
        let suite = UserDefaults.standard
        let prevMode = suite.string(forKey: "imageSyncMode")
        defer {
            if let m = prevMode { suite.set(m, forKey: "imageSyncMode") }
            else { suite.removeObject(forKey: "imageSyncMode") }
        }
        ImageSyncSettings.setMode(.thumbnailOnly)

        let uuid = UUID().uuidString
        let pngData = Data(repeating: 0x42, count: 1024)
        let savedPath = ImageOriginalStoreRegistry.current!
            .saveOriginal(pngData, uuid: uuid, preferredExt: "png")

        let now = Date()
        let clip = Clip(
            contentType: .image,
            imagePath: savedPath,
            thumbnail: Data([0x01]),
            createdAt: now,
            lastCopiedAt: now,
            uuid: uuid,
            deviceId: "test-device",
            updatedAt: now
        )
        let record = SyncRecordMapper.encode(clip)
        XCTAssertNotNil(record)
        XCTAssertNil(record?[SyncRecordMapper.Key.imageOriginalAsset] as? CKAsset,
                     "thumbnailOnly mode should NOT attach CKAsset")
    }

    func test_encode_image_full_mode_overCap_marksAssetExceeded() throws {
        let suite = UserDefaults.standard
        let prevMode = suite.string(forKey: "imageSyncMode")
        defer {
            if let m = prevMode { suite.set(m, forKey: "imageSyncMode") }
            else { suite.removeObject(forKey: "imageSyncMode") }
        }
        ImageSyncSettings.setMode(.full)
        // 매우 작은 cap 사용 — 1바이트도 초과
        ImageSyncSettings.setSizeCap(.mb10)  // 10MB

        let uuid = UUID().uuidString
        // 11MB 파일 생성 (10MB cap 초과)
        let bigData = Data(repeating: 0x55, count: 11 * 1024 * 1024)
        let savedPath = ImageOriginalStoreRegistry.current!
            .saveOriginal(bigData, uuid: uuid, preferredExt: "png")
        XCTAssertNotNil(savedPath)

        let now = Date()
        let clip = Clip(
            contentType: .image,
            imagePath: savedPath,
            thumbnail: Data([0x01]),
            createdAt: now,
            lastCopiedAt: now,
            uuid: uuid,
            deviceId: "test-device",
            updatedAt: now
        )
        let record = SyncRecordMapper.encode(clip)
        XCTAssertNotNil(record)
        XCTAssertNil(record?[SyncRecordMapper.Key.imageOriginalAsset] as? CKAsset,
                     "over-cap should NOT attach CKAsset")
        let exceeded = record?[SyncRecordMapper.Key.assetExceeded] as? Int64
        XCTAssertEqual(exceeded, 1, "over-cap should mark assetExceeded=1")
    }

    // MARK: - ImageBinaryCleanup

    func test_ImageBinaryCleanup_removesOlderThanRetention() async throws {
        // in-memory DB
        let dbQueue = try DatabaseQueue()
        try await dbQueue.write { db in
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contentType", .text).notNull()
                t.column("imagePath", .text)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }

        let store = TestImageStore(rootDir: tempDir)
        ImageOriginalStoreRegistry.register(store)

        let oldDate = Date().addingTimeInterval(-31 * 86400)  // 31일 전
        let recentDate = Date().addingTimeInterval(-5 * 86400)  // 5일 전

        // 케이스 1: 31일 전 + non-pinned + imagePath → 삭제 대상
        let oldUuid = "old"
        _ = store.saveOriginal(Data([0x01, 0x02]), uuid: oldUuid, preferredExt: "png")
        let oldFile = store.fullURL(for: "\(oldUuid).png")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO clips (contentType, imagePath, isPinned, createdAt)
                VALUES ('image', ?, 0, ?)
                """, arguments: ["\(oldUuid).png", oldDate])
        }

        // 케이스 2: 31일 전 + pinned → 보존
        let pinnedUuid = "pinned"
        _ = store.saveOriginal(Data([0x03]), uuid: pinnedUuid, preferredExt: "png")
        let pinnedFile = store.fullURL(for: "\(pinnedUuid).png")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO clips (contentType, imagePath, isPinned, createdAt)
                VALUES ('image', ?, 1, ?)
                """, arguments: ["\(pinnedUuid).png", oldDate])
        }

        // 케이스 3: 5일 전 + non-pinned → 보존 (cutoff 미만)
        let recentUuid = "recent"
        _ = store.saveOriginal(Data([0x04]), uuid: recentUuid, preferredExt: "png")
        let recentFile = store.fullURL(for: "\(recentUuid).png")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO clips (contentType, imagePath, isPinned, createdAt)
                VALUES ('image', ?, 0, ?)
                """, arguments: ["\(recentUuid).png", recentDate])
        }

        // 실행
        let result = try await ImageBinaryCleanup.run(
            dbPool: dbQueue,
            retentionDays: 30,
            store: store
        )

        // 31일 전 + non-pinned 만 삭제됨
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path),
                       "old non-pinned should be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedFile.path),
                      "pinned should be preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFile.path),
                      "recent should be preserved")

        // DB 의 imagePath 도 삭제된 케이스만 nil
        try await dbQueue.read { db in
            let oldRow = try Row.fetchOne(
                db, sql: "SELECT imagePath FROM clips WHERE imagePath IS NULL"
            )
            XCTAssertNotNil(oldRow, "deleted clip's imagePath should be NULL")
        }
    }
}

// MARK: - Cellular policy tests

extension PhaseCAssetTests {

    /// Mock NetworkStateProvider — cellular/online 강제 설정 가능.
    private struct MockNetwork: NetworkStateProvider {
        let isCellular: Bool
        let isOnline: Bool
    }

    /// 4가지 매트릭스 케이스를 한 번에 검증 — 사용자 옵션 × 네트워크 종류.
    /// 검증 대상: `NetworkPolicy.canSendLargeAssets`.
    func test_NetworkPolicy_matrix() {
        // 옵션 OFF (cellularAllowed=false) — 기본값
        let optionOff = ImageSyncSettings.Snapshot(
            mode: .full, sizeCap: .mb10, cellularAllowed: false
        )
        // 옵션 ON
        let optionOn = ImageSyncSettings.Snapshot(
            mode: .full, sizeCap: .mb10, cellularAllowed: true
        )

        // Wi-Fi (non-cellular) — OFF / ON 모두 통과
        let wifi = MockNetwork(isCellular: false, isOnline: true)
        XCTAssertTrue(NetworkPolicy.canSendLargeAssets(provider: wifi, settings: optionOff))
        XCTAssertTrue(NetworkPolicy.canSendLargeAssets(provider: wifi, settings: optionOn))

        // Cellular + 옵션 OFF → 차단
        let cell = MockNetwork(isCellular: true, isOnline: true)
        XCTAssertFalse(NetworkPolicy.canSendLargeAssets(provider: cell, settings: optionOff))

        // Cellular + 옵션 ON → 통과
        XCTAssertTrue(NetworkPolicy.canSendLargeAssets(provider: cell, settings: optionOn))

        // Offline — 옵션 무관하게 차단 (보낼 곳이 없음)
        let off = MockNetwork(isCellular: false, isOnline: false)
        XCTAssertFalse(NetworkPolicy.canSendLargeAssets(provider: off, settings: optionOn))
    }

    /// Mapper.encode 가 Cellular + 옵션 OFF 일 때 CKAsset 부착 안 함.
    /// 텍스트 / 썸네일 등 다른 필드는 정상 — 차단 범위가 정확한지 회귀.
    func test_encode_image_full_cellular_optionOff_skipsAsset() throws {
        // 옵션 .full + cellularAllowed=false 강제
        ImageSyncSettings.setMode(.full)
        ImageSyncSettings.setSizeCap(.mb50)
        ImageSyncSettings.setCellularAllowed(false)
        defer {
            ImageSyncSettings.setMode(.thumbnailOnly)
            ImageSyncSettings.setCellularAllowed(false)
        }

        // Network = cellular 로 mock
        let prevProvider = NetworkStateRegistry.current
        NetworkStateRegistry.register(MockNetwork(isCellular: true, isOnline: true))
        defer { NetworkStateRegistry.register(prevProvider) }

        // 원본 파일 + clip 준비
        let uuid = UUID().uuidString
        let pngData = Data(repeating: 0xAB, count: 1024)
        _ = ImageOriginalStoreRegistry.current!
            .saveOriginal(pngData, uuid: uuid, preferredExt: "png")

        let now = Date()
        let clip = Clip(
            contentType: .image,
            imagePath: "\(uuid).png",
            thumbnail: Data([0x01, 0x02]),  // 썸네일은 정상
            createdAt: now,
            lastCopiedAt: now,
            uuid: uuid,
            deviceId: "test-device",
            updatedAt: now
        )

        let record = SyncRecordMapper.encode(clip)
        XCTAssertNotNil(record)

        // 셀룰러 차단 → CKAsset 미부착
        XCTAssertNil(record?[SyncRecordMapper.Key.imageOriginalAsset] as? CKAsset,
                     "cellular + option-off should NOT attach CKAsset")

        // 셀룰러 차단은 cap 초과와 다름 — assetExceeded 도 미설정
        // (Wi-Fi 복귀 시 자연 재시도 가능하도록)
        XCTAssertNil(record?[SyncRecordMapper.Key.assetExceeded] as? Int64)

        // 썸네일 / 메타는 정상
        XCTAssertNotNil(record?[SyncRecordMapper.Key.thumbnail] as? Data,
                        "thumbnail should still sync on cellular")
    }

    /// Cellular + 옵션 ON → CKAsset 정상 부착.
    func test_encode_image_full_cellular_optionOn_attachesAsset() throws {
        ImageSyncSettings.setMode(.full)
        ImageSyncSettings.setSizeCap(.mb50)
        ImageSyncSettings.setCellularAllowed(true)
        defer {
            ImageSyncSettings.setMode(.thumbnailOnly)
            ImageSyncSettings.setCellularAllowed(false)
        }

        let prevProvider = NetworkStateRegistry.current
        NetworkStateRegistry.register(MockNetwork(isCellular: true, isOnline: true))
        defer { NetworkStateRegistry.register(prevProvider) }

        let uuid = UUID().uuidString
        let pngData = Data(repeating: 0xCD, count: 2048)
        _ = ImageOriginalStoreRegistry.current!
            .saveOriginal(pngData, uuid: uuid, preferredExt: "png")

        let now = Date()
        let clip = Clip(
            contentType: .image,
            imagePath: "\(uuid).png",
            thumbnail: Data([0x01]),
            createdAt: now,
            lastCopiedAt: now,
            uuid: uuid,
            deviceId: "test-device",
            updatedAt: now
        )

        let record = SyncRecordMapper.encode(clip)
        XCTAssertNotNil(record?[SyncRecordMapper.Key.imageOriginalAsset] as? CKAsset,
                       "cellular + option-on should attach CKAsset")

        // cleanup
        AssetStaging.shared.cleanup(uuid: uuid)
    }
}

// MARK: - Test helpers

/// 테스트 격리된 ImageOriginalStore. 임시 root 디렉터리 사용.
private struct TestImageStore: ImageOriginalStore {
    let rootDir: URL

    func fullURL(for relativePath: String) -> URL {
        rootDir.appendingPathComponent(relativePath)
    }

    func saveOriginal(_ data: Data, uuid: String, preferredExt: String) -> String? {
        let filename = "\(uuid).\(preferredExt)"
        let url = rootDir.appendingPathComponent(filename)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url)
            return filename
        } catch {
            return nil
        }
    }
}
