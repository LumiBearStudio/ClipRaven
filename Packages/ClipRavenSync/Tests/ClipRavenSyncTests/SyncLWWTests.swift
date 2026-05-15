import XCTest
import CloudKit
@testable import ClipRavenSync

/// v14 per-field LWW (last-write-wins) 회귀 방지 테스트.
///
/// 사용자 보고 시나리오 (한쪽 device 에서 핀 해제 → 다른 device 의 stale
/// background update 가 덮어써서 원복) 를 단위 테스트로 시뮬레이션해
/// 이후 회귀를 방지한다.
///
/// 테스트 두 갈래:
/// 1. `serverWinsLWW` 비교 헬퍼 자체의 NULL semantics + tie-break 정확성.
/// 2. `decode(_:merging:)` 의 per-field LWW 가 실제 race 시나리오에서
///    user-intent 변경을 보존하는지 end-to-end 검증.
final class SyncLWWTests: XCTestCase {

    // MARK: - serverWinsLWW table

    private let now = Date()
    private var earlier: Date { now.addingTimeInterval(-60) }
    private var later: Date { now.addingTimeInterval(60) }

    func test_serverWinsLWW_bothNil_returnsTrue_fallback() {
        // 두 device 모두 명시적 write 없음 → server-wins fallback (legacy 호환).
        XCTAssertTrue(SyncRecordMapper.serverWinsLWW(serverTS: nil, localTS: nil))
    }

    func test_serverWinsLWW_serverSet_localNil_returnsTrue() {
        // server 만 explicit write → server 가 정보를 가졌으니 win.
        XCTAssertTrue(SyncRecordMapper.serverWinsLWW(serverTS: now, localTS: nil))
    }

    func test_serverWinsLWW_serverNil_localSet_returnsFalse() {
        // local 만 explicit write → local 보존. 이게 사용자 회귀 보고 케이스의
        // 핵심: 다른 device 의 stale background update 가 timestamp 안 갱신
        // 했으니 local 의 user-intent 가 우선.
        XCTAssertFalse(SyncRecordMapper.serverWinsLWW(serverTS: nil, localTS: now))
    }

    func test_serverWinsLWW_serverNewer_returnsTrue() {
        XCTAssertTrue(SyncRecordMapper.serverWinsLWW(serverTS: later, localTS: earlier))
    }

    func test_serverWinsLWW_localNewer_returnsFalse() {
        XCTAssertFalse(SyncRecordMapper.serverWinsLWW(serverTS: earlier, localTS: later))
    }

    func test_serverWinsLWW_equal_returnsTrue_serverTieBreak() {
        // 두 device 가 같은 시각에 변경한 극히 드문 케이스 — tie 는 server-wins
        // 로 안정적 결정 (양쪽 어느 device 든 같은 결과를 본다).
        XCTAssertTrue(SyncRecordMapper.serverWinsLWW(serverTS: now, localTS: now))
    }

    // MARK: - decode end-to-end (사용자 회귀 시나리오)

    /// 사용자 보고 핵심 시나리오:
    /// 1. Mac 사용자 unpin → Mac DB: isPinned=false, isPinnedUpdatedAt=t1
    /// 2. iPhone background OG fetch → iPhone DB: ogTitle만 갱신,
    ///    isPinnedUpdatedAt 그대로 NULL (해당 field 안 건드림)
    /// 3. 두 device send → server 에 conflict 발생
    /// 4. handleSentRecordZoneChanges 의 conflict 처리 → applyServerChanges
    ///    → decode 의 per-field LWW → Mac 의 isPinned=false 보존
    func test_decode_macUnpin_iPhoneStaleBackgroundUpdate_macLocalWins() {
        let t1 = now.addingTimeInterval(-30)
        let t2 = now.addingTimeInterval(-10)   // iPhone background fetch 시점 (newer overall updatedAt)

        // Mac local state: 사용자가 막 unpin 한 상태.
        var macLocal = Clip(
            id: 1,
            contentType: .text,
            contentText: "hello",
            isPinned: false,                       // 사용자가 unpin 함
            uuid: "test-uuid",
            updatedAt: t1,
            isPinnedUpdatedAt: t1                  // unpin 시점 timestamp
        )
        macLocal.deviceId = "mac-device"

        // Server record: iPhone 가 background OG fetch 후 보낸 stale state.
        // iPhone 은 Mac 의 unpin 변경을 아직 못 받아 isPinned=true 그대로.
        // 단 OG fetch 가 isPinnedUpdatedAt 은 건드리지 않음 (background update
        // 정책) — record 에 isPinnedUpdatedAt 가 NULL 로 도착.
        let serverRecord = makeRecord(uuid: "test-uuid")
        serverRecord[SyncRecordMapper.Key.isPinned] = Int64(1)         // stale
        serverRecord[SyncRecordMapper.Key.isPinnedUpdatedAt] = nil
        serverRecord[SyncRecordMapper.Key.updatedAt] = t2              // newer overall updatedAt
        serverRecord[SyncRecordMapper.Key.ogTitle] = "fetched-title"   // background metadata 갱신
        serverRecord[SyncRecordMapper.Key.contentType] = "text"

        let merged = SyncRecordMapper.decode(serverRecord, merging: macLocal)

        XCTAssertEqual(merged.isPinned, false,
            "Mac 의 user-intent unpin 이 iPhone 의 stale state 로 덮어쓰여지지 않아야 함")
        XCTAssertEqual(merged.isPinnedUpdatedAt, t1,
            "local timestamp 유지")
        XCTAssertEqual(merged.ogTitle, "fetched-title",
            "background metadata (ogTitle) 은 server-wins")
    }

    /// 정상 단방향 sync — server 가 explicit write 했고 local 은 NULL.
    /// 한 쪽이 정상으로 pin 토글 → 다른 쪽이 fetch 받음.
    func test_decode_serverExplicitPin_localNeverWrote_serverWins() {
        let t1 = now.addingTimeInterval(-10)

        var iPhoneLocal = Clip(
            id: 1,
            contentType: .text,
            contentText: "hello",
            isPinned: false,
            uuid: "test-uuid",
            updatedAt: now.addingTimeInterval(-100),
            isPinnedUpdatedAt: nil                 // iPhone 은 한 번도 explicit write 안 함
        )

        // Server: Mac 사용자가 pin 한 record.
        let serverRecord = makeRecord(uuid: "test-uuid")
        serverRecord[SyncRecordMapper.Key.isPinned] = Int64(1)
        serverRecord[SyncRecordMapper.Key.isPinnedUpdatedAt] = t1
        serverRecord[SyncRecordMapper.Key.updatedAt] = t1
        serverRecord[SyncRecordMapper.Key.contentType] = "text"

        let merged = SyncRecordMapper.decode(serverRecord, merging: iPhoneLocal)

        XCTAssertEqual(merged.isPinned, true, "server 의 explicit pin 이 적용됨")
        XCTAssertEqual(merged.isPinnedUpdatedAt, t1)
    }

    /// 양쪽 모두 user-intent 변경한 경우 — 더 최신 변경이 win.
    func test_decode_bothExplicit_newerWins() {
        let earlier = now.addingTimeInterval(-30)
        let laterTime = now.addingTimeInterval(-10)

        // local 이 더 newer
        var localNewer = Clip(
            id: 1, contentType: .text, contentText: "hello",
            isPinned: false,                       // 사용자가 더 늦게 unpin
            uuid: "u",
            updatedAt: laterTime,
            isPinnedUpdatedAt: laterTime
        )

        let serverRecord = makeRecord(uuid: "u")
        serverRecord[SyncRecordMapper.Key.isPinned] = Int64(1)     // server 가 더 일찍 pin
        serverRecord[SyncRecordMapper.Key.isPinnedUpdatedAt] = earlier
        serverRecord[SyncRecordMapper.Key.updatedAt] = earlier
        serverRecord[SyncRecordMapper.Key.contentType] = "text"

        let mergedLocalWins = SyncRecordMapper.decode(serverRecord, merging: localNewer)
        XCTAssertEqual(mergedLocalWins.isPinned, false, "local 이 newer → 유지")

        // server 가 더 newer
        var localOlder = Clip(
            id: 1, contentType: .text, contentText: "hello",
            isPinned: false,
            uuid: "u",
            updatedAt: earlier,
            isPinnedUpdatedAt: earlier
        )
        let serverRecord2 = makeRecord(uuid: "u")
        serverRecord2[SyncRecordMapper.Key.isPinned] = Int64(1)
        serverRecord2[SyncRecordMapper.Key.isPinnedUpdatedAt] = laterTime
        serverRecord2[SyncRecordMapper.Key.updatedAt] = laterTime
        serverRecord2[SyncRecordMapper.Key.contentType] = "text"

        let mergedServerWins = SyncRecordMapper.decode(serverRecord2, merging: localOlder)
        XCTAssertEqual(mergedServerWins.isPinned, true, "server 가 newer → 적용")
    }

    /// nickname 도 동일 LWW. user-intent 명명 변경.
    func test_decode_nickname_localWinsWhenNewer() {
        let earlier = now.addingTimeInterval(-30)
        let laterTime = now.addingTimeInterval(-10)

        var local = Clip(
            id: 1, contentType: .text, contentText: "hello",
            nickname: "local-name",
            uuid: "u",
            updatedAt: laterTime,
            nicknameUpdatedAt: laterTime
        )

        let serverRecord = makeRecord(uuid: "u")
        serverRecord[SyncRecordMapper.Key.nickname] = "server-name"
        serverRecord[SyncRecordMapper.Key.nicknameUpdatedAt] = earlier
        serverRecord[SyncRecordMapper.Key.updatedAt] = earlier
        serverRecord[SyncRecordMapper.Key.contentType] = "text"

        let merged = SyncRecordMapper.decode(serverRecord, merging: local)
        XCTAssertEqual(merged.nickname, "local-name", "local nickname 이 더 newer → 유지")
        XCTAssertEqual(merged.nicknameUpdatedAt, laterTime)
    }

    /// expiresAt 도 user-intent. 사용자가 만료일 설정.
    func test_decode_expiresAt_LWW_appliesCorrectly() {
        let t1 = now.addingTimeInterval(-30)
        let exp = now.addingTimeInterval(86400 * 7)  // 1주일 뒤

        var local = Clip(
            id: 1, contentType: .text, contentText: "hello",
            uuid: "u",
            updatedAt: now,
            expiresAtUpdatedAt: nil                 // local 은 expiresAt explicit write 없음
        )

        let serverRecord = makeRecord(uuid: "u")
        serverRecord[SyncRecordMapper.Key.expiresAt] = exp
        serverRecord[SyncRecordMapper.Key.expiresAtUpdatedAt] = t1
        serverRecord[SyncRecordMapper.Key.updatedAt] = t1
        serverRecord[SyncRecordMapper.Key.contentType] = "text"

        let merged = SyncRecordMapper.decode(serverRecord, merging: local)
        XCTAssertEqual(merged.expiresAt, exp, "server explicit + local NULL → server wins")
        XCTAssertEqual(merged.expiresAtUpdatedAt, t1)
    }

    // MARK: - encode

    /// encode 가 user-intent timestamp 들을 모두 record 에 송신하는지.
    /// 빠뜨리면 다른 device 가 LWW 판단을 못 함.
    func test_encode_includesAllUserIntentTimestamps() {
        let t = now
        let clip = Clip(
            id: 1, contentType: .text, contentText: "hello",
            pinOrder: 3,
            manualOrder: 7,
            nickname: "n",
            isPinned: true,
            isDeleted: false,
            expiresAt: now.addingTimeInterval(100),
            customShortcutKeyCode: 9,
            customShortcutModifiers: 256,
            uuid: "u",
            updatedAt: t,
            isPinnedUpdatedAt: t,
            pinOrderUpdatedAt: t,
            manualOrderUpdatedAt: t,
            isDeletedUpdatedAt: t,
            nicknameUpdatedAt: t,
            excludeFromSyncUpdatedAt: t,
            expiresAtUpdatedAt: t,
            customShortcutUpdatedAt: t
        )

        guard let record = SyncRecordMapper.encode(clip) else {
            XCTFail("encode returned nil"); return
        }

        XCTAssertNotNil(record[SyncRecordMapper.Key.isPinnedUpdatedAt])
        XCTAssertNotNil(record[SyncRecordMapper.Key.pinOrderUpdatedAt])
        XCTAssertNotNil(record[SyncRecordMapper.Key.manualOrderUpdatedAt])
        XCTAssertNotNil(record[SyncRecordMapper.Key.isDeletedUpdatedAt])
        XCTAssertNotNil(record[SyncRecordMapper.Key.nicknameUpdatedAt])
        XCTAssertNotNil(record[SyncRecordMapper.Key.excludeFromSyncUpdatedAt])
        XCTAssertNotNil(record[SyncRecordMapper.Key.expiresAtUpdatedAt])
        XCTAssertNotNil(record[SyncRecordMapper.Key.customShortcutUpdatedAt])
    }

    /// encode 가 NULL timestamp 는 record 에 NULL 로 보냄.
    /// "이 device 가 이 field 를 명시적으로 set 한 적 없음" 정보 전달.
    func test_encode_nilTimestamp_sentAsNil() {
        let clip = Clip(
            id: 1, contentType: .text, contentText: "hello",
            uuid: "u",
            updatedAt: now
        )

        guard let record = SyncRecordMapper.encode(clip) else {
            XCTFail("encode returned nil"); return
        }

        XCTAssertNil(record[SyncRecordMapper.Key.isPinnedUpdatedAt])
        XCTAssertNil(record[SyncRecordMapper.Key.nicknameUpdatedAt])
    }

    // MARK: - Helpers

    private func makeRecord(uuid: String) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: uuid,
            zoneID: SyncRecordMapper.zoneID
        )
        return CKRecord(recordType: SyncRecordMapper.clipRecordType, recordID: recordID)
    }
}
