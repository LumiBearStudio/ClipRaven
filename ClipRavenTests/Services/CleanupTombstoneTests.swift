import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

/// 자동 정리가 iCloud tombstone 을 남기는지 검증 (감사 S1).
///
/// ## 회귀 배경
/// 만료·보관기간·개수제한 3종은 soft-delete 를 거치지 않고 곧바로
/// hard-delete 했다. `SyncChangeCapture` 는 hard-delete 된 rowID 를
/// "이미 tombstone 이 있을 것" 이라 가정하고 버리는데, 그 가정이 맞는 건
/// `deleteSoftDeleted()` 뿐이다. 결과:
///
/// - "보관 기간 7일" 로 설정해도 iCloud 에는 클립이 **영구 잔존** — 클립보드
///   앱에서 사용자가 기대하는 프라이버시와 정면으로 어긋난다.
/// - 다른 기기가 그 레코드를 건드리면 다시 내려와 **부활**한다.
///
/// ## 이 테스트가 고정하는 계약
/// 동기화가 켜져 있으면 정리는 soft-delete 로 표시만 하고(→ 업로드되어
/// tombstone 이 되고 → ack 후 `deleteSoftDeleted` 가 실제로 지운다),
/// 꺼져 있으면 알릴 서버가 없으므로 즉시 hard-delete 한다.
final class CleanupTombstoneTests: XCTestCase {

    private var testDB: TestDatabase!
    private var clipRepository: ClipRepository!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sut: CleanupService!
    private var syncWasEnabled: Bool!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        clipRepository = ClipRepository(dbPool: testDB.dbPool)
        suiteName = "CleanupTombstoneTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        sut = CleanupService(
            clipRepository: clipRepository,
            defaults: defaults,
            defaultMaxClipCount: 100
        )
        // SyncFeatureFlag 는 standard 를 보므로 원복을 위해 저장해 둔다.
        syncWasEnabled = SyncFeatureFlag.isEnabled
    }

    override func tearDownWithError() throws {
        SyncFeatureFlag.setEnabled(syncWasEnabled)
        defaults.removePersistentDomain(forName: suiteName)
        testDB.cleanup()
        sut = nil; defaults = nil; clipRepository = nil; testDB = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func insertClip(
        text: String,
        isPinned: Bool = false,
        lastCopiedAt: Date = Date(),
        expiresAt: Date? = nil
    ) throws -> Int64 {
        var clip = Clip(contentType: .text, contentText: text)
        clip.isPinned = isPinned
        clip.lastCopiedAt = lastCopiedAt
        clip.expiresAt = expiresAt
        let saved = try clipRepository.save(&clip)
        return try XCTUnwrap(saved.id)
    }

    private func row(_ text: String) throws -> Row? {
        try testDB.dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT isDeleted, isDeletedUpdatedAt, updatedAt FROM clips WHERE contentText = ?",
                arguments: [text]
            )
        }
    }

    // MARK: - 동기화 ON — tombstone 을 남겨야 한다

    func test_expiredClip_isSoftDeleted_whenSyncEnabled() async throws {
        SyncFeatureFlag.setEnabled(true)
        try insertClip(text: "expired", expiresAt: Date().addingTimeInterval(-3600))

        await sut.runCleanup()

        let row = try XCTUnwrap(try row("expired"), "동기화 중에는 행이 남아 tombstone 이 업로드될 수 있어야 한다")
        XCTAssertEqual(row["isDeleted"] as Bool?, true)
        XCTAssertNotNil(row["isDeletedUpdatedAt"] as Date?, "LWW 타임스탬프가 찍혀야 peer 가 삭제를 이긴다")
        XCTAssertNotNil(row["updatedAt"] as Date?, "updatedAt 이 갱신되어야 SyncChangeCapture 가 업로드 대상으로 잡는다")
    }

    func test_agedOutClip_isSoftDeleted_whenSyncEnabled() async throws {
        SyncFeatureFlag.setEnabled(true)
        defaults.set(7, forKey: "maxDaysToKeep")
        try insertClip(text: "old", lastCopiedAt: Date().addingTimeInterval(-10 * 86400))

        await sut.runCleanup()

        let row = try XCTUnwrap(try row("old"))
        XCTAssertEqual(row["isDeleted"] as Bool?, true)
    }

    func test_overLimitClip_isSoftDeleted_whenSyncEnabled() async throws {
        SyncFeatureFlag.setEnabled(true)
        defaults.set(2, forKey: "maxClipCount")
        for i in 0..<4 {
            try insertClip(text: "clip\(i)", lastCopiedAt: Date().addingTimeInterval(-Double(10 - i)))
        }

        await sut.runCleanup()

        let visible: Int = try await testDB.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips WHERE isDeleted = 0") ?? -1
        }
        let total: Int = try await testDB.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? -1
        }
        XCTAssertEqual(visible, 2, "보이는 클립은 상한을 지켜야 한다")
        XCTAssertEqual(total, 4, "지운 2개는 tombstone 업로드 전까지 행이 남아야 한다")
    }

    // MARK: - 동기화 OFF — 알릴 서버가 없으니 즉시 제거

    func test_expiredClip_isHardDeleted_whenSyncDisabled() async throws {
        SyncFeatureFlag.setEnabled(false)
        try insertClip(text: "expired", expiresAt: Date().addingTimeInterval(-3600))

        await sut.runCleanup()

        XCTAssertNil(try row("expired"), "동기화가 꺼져 있으면 즉시 삭제되어 DB 가 커지지 않아야 한다")
    }

    func test_agedOutClip_isHardDeleted_whenSyncDisabled() async throws {
        SyncFeatureFlag.setEnabled(false)
        defaults.set(7, forKey: "maxDaysToKeep")
        try insertClip(text: "old", lastCopiedAt: Date().addingTimeInterval(-10 * 86400))

        await sut.runCleanup()

        XCTAssertNil(try row("old"))
    }

    // MARK: - 핀 고정 보호 (감사 High — 만료 경로만 가드가 없었다)

    func test_pinnedClip_survivesExpiry() async throws {
        SyncFeatureFlag.setEnabled(false)
        // SmartRule TTL 이 찍힌 뒤 사용자가 핀을 꽂은 시나리오.
        try insertClip(text: "pinned", isPinned: true, expiresAt: Date().addingTimeInterval(-3600))

        await sut.runCleanup()

        let row = try XCTUnwrap(try row("pinned"), "핀 고정은 영구 보관 의도다 — 만료로 지우면 안 된다")
        XCTAssertEqual(row["isDeleted"] as Bool?, false)
    }
}
