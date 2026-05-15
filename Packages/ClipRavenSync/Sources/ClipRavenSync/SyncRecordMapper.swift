import Foundation
import CloudKit
import os.log

/// Pure `Clip` ↔ `CKRecord` translation. No I/O, no CloudKit network calls —
/// callable on any thread, safe to unit-test offline, and intentionally
/// independent of the sync engine lifecycle.
///
/// Scope:
/// - Full text-clip round-trip (the record types our Mac-only v2.0 actually syncs).
/// - `ckSystemFields` is preserved across encode/decode so CloudKit
///   optimistic-concurrency (recordChangeTag) survives every round-trip.
/// - Immutable fields (see `immutableKeys`) are held on decode merges.
///
/// Out of scope (deferred):
/// - `encryptedValues["contentSecret"]` (user "비밀" tag).
/// - `encryptedValues[Key.contentText]` (보안 감사 A-M-6 / W2.4 plan):
///   CloudKit private DB 는 Apple 이 TLS + at-rest 암호화 제공. 추가 클라이언트
///   측 암호화 (encryptedValues — 사용자 iCloud Keychain 키 사용) 는 Apple
///   운영자도 복호화 불가하게 만들지만, 다음 제약이 있어 **별도 schema migration
///   사이클** 에서 진행 필요:
///   1. CKRecord 동일 field 를 regular ↔ encryptedValues 로 동시 사용 불가.
///      `contentText` 를 encrypted 로 옮기려면 **새 field 이름** (예: `contentText_e`)
///      추가 + 양쪽 decode 지원 + Production schema deploy 후 legacy field deprecate.
///   2. CloudKit Production schema 는 한 번 deploy 후 field 삭제 불가
///      (rename 도 deploy 시점에 freeze). 사전 schema 검토 + rollback 시나리오
///      검증이 필수.
///   3. 사용자 iCloud Keychain 미사용 (signed-in but keychain disabled) 케이스의
///      degradation policy 결정 필요.
///   현재 위협 모델 (사용자 본인 iCloud private DB) 대비 가치 < 비용이라 deferred.
/// - `tagUuids` relation resolution → field is omitted from encode today,
///   wired up once a tag observer lands.
/// - `CKAsset` thumbnail / original image attachments.
/// - LWW conflict merging — current `decode(_:merging:)` uses server-wins
///   for mutable fields.
///
/// Date precision contract (important when LWW is added):
/// - CloudKit stores Date fields at millisecond precision. Any sub-ms
///   component of a local `Date()` is truncated on the server round-trip.
/// - Consequence: never use `==` on Date fields for conflict comparison.
///   LWW must use `<` / `>` (inequality) only. `createdAt` equality in
///   tests is safe because fixtures use whole-second epoch values.
public enum SyncRecordMapper {

    private static let log = Logger(subsystem: "com.lumibear.ClipRaven", category: "SyncRecordMapper")


    /// CloudKit record type name. Once in Production schema, **never rename**.
    public static let clipRecordType = "Clip"

    /// Custom zone the sync engine owns. ID-only container — no CloudKit
    /// network call at construction. Zone itself is created lazily by the
    /// engine on first use.
    public static let zoneID = CKRecordZone.ID(
        zoneName: "ClipRavenItems",
        ownerName: CKCurrentUserDefaultName
    )

    /// CKRecord field keys. Keep in sync with icloud-sync.plan.md §4.
    /// Never change a value once shipped — CloudKit schemas are additive-only.
    public enum Key {
        public static let schemaVersion = "schemaVersion"
        public static let contentType = "contentType"
        public static let contentText = "contentText"
        public static let contentHash = "contentHash"
        public static let imageHash = "imageHash"
        public static let imageDhash = "imageDhash"
        /// 이미지 클립의 작은 썸네일 (~200x200 JPEG, 보통 10–50KB).
        /// CKRecord Data field 한도(1MB) 안에 넉넉히 들어감.
        public static let thumbnail = "thumbnail"
        /// **Phase C** — 이미지 원본 CKAsset. 사용자 옵션 ON +
        /// size cap 통과 시에만 첨부. 다운로드 측은 staging/cache로 받아
        /// `imagePath`를 채운다.
        public static let imageOriginalAsset = "imageOriginalAsset"
        /// **Phase C** — 원본이 size cap 초과해 sync 누락됐음을 알리는 플래그.
        /// 1 일 경우 다른 디바이스 UI는 "원본 너무 큼" 배지를 표시.
        public static let assetExceeded = "assetExceeded"
        public static let ocrText = "ocrText"
        public static let ocrConfidence = "ocrConfidence"
        public static let sourceAppBundleId = "sourceAppBundleId"
        public static let sourceAppName = "sourceAppName"
        public static let sourceUrl = "sourceUrl"
        public static let ogTitle = "ogTitle"
        public static let ogFetchedAt = "ogFetchedAt"
        public static let nickname = "nickname"
        public static let tagsText = "tagsText"
        public static let tagUuids = "tagUuids"
        public static let pinOrder = "pinOrder"
        public static let manualOrder = "manualOrder"
        public static let copyCount = "copyCount"
        public static let isPinned = "isPinned"
        public static let isDeleted = "isDeleted"
        public static let expiresAt = "expiresAt"
        public static let createdAt = "createdAt"
        public static let lastCopiedAt = "lastCopiedAt"
        public static let aiCategory = "aiCategory"
        public static let aiCategoryGeneratedAt = "aiCategoryGeneratedAt"
        public static let deviceId = "deviceId"
        public static let platformCreatedOn = "platformCreatedOn"
        public static let updatedAt = "updatedAt"
        // Per-field LWW timestamps (v14). `decode` 가 server 의 timestamp 가
        // local 보다 newer 일 때만 해당 field 의 server value 를 적용 — stale
        // background-update (OG/AI/OCR) 가 사용자 user-intent 를 역행 못 하게.
        public static let isPinnedUpdatedAt         = "isPinnedUpdatedAt"
        public static let pinOrderUpdatedAt         = "pinOrderUpdatedAt"
        public static let manualOrderUpdatedAt      = "manualOrderUpdatedAt"
        public static let isDeletedUpdatedAt        = "isDeletedUpdatedAt"
        public static let nicknameUpdatedAt         = "nicknameUpdatedAt"
        public static let excludeFromSyncUpdatedAt  = "excludeFromSyncUpdatedAt"
        public static let expiresAtUpdatedAt        = "expiresAtUpdatedAt"
        public static let customShortcutUpdatedAt   = "customShortcutUpdatedAt"
    }

    /// Fields that must never be overwritten once written. Server-side reject
    /// is the belt; this set is the suspenders — mirrored from plan §4.
    private static let immutableKeys: Set<String> = [
        Key.contentText,
        Key.contentHash,
        Key.createdAt,
        Key.deviceId,
        Key.platformCreatedOn,
    ]

    // MARK: - Encode (Clip → CKRecord)

    /// Produce a CKRecord ready to be attached to a `CKSyncEngine` pending
    /// change. If the clip has an existing `ckSystemFields` blob, the record
    /// is rehydrated from it so CloudKit's recordChangeTag is preserved
    /// (required for optimistic-concurrency updates).
    ///
    /// Returns `nil` and logs when the clip violates the upstream contract
    /// (missing uuid or updatedAt). Sync is best-effort — one malformed row
    /// must not tear down the engine's batch. Callers (ChangeCapture) must
    /// ensure the contract holds for every enqueued row; a nil return here
    /// indicates a real bug upstream.
    ///
    /// Contract (ChangeCapture guarantees both inside the same DB transaction
    /// as insert/update):
    /// - `clip.uuid` is non-nil and non-empty.
    /// - `clip.updatedAt` is non-nil and reflects the local mutation time.
    ///   Falling back to `Date()` here would silently drift LWW.
    public static func encode(_ clip: Clip) -> CKRecord? {
        // Defense in depth. ChangeCapture drops excluded rows before they
        // reach the queue, but if an excluded clip ever reaches this path —
        // via a direct test call, a future caller, or an upstream bug —
        // fail closed. Plan §9 requires excluded clips never enter the
        // upload queue.
        if clip.excludeFromSync {
            log.info("encode skipped: excludeFromSync=true (id=\(clip.id ?? -1, privacy: .public))")
            return nil
        }
        guard let uuid = clip.uuid, !uuid.isEmpty else {
            log.error("encode skipped: clip has nil/empty uuid (id=\(clip.id ?? -1, privacy: .public))")
            return nil
        }
        guard let updatedAt = clip.updatedAt else {
            log.error("encode skipped: clip.updatedAt is nil (uuid=\(uuid, privacy: .public))")
            return nil
        }

        let record = baseRecord(for: clip, uuid: uuid)

        // Required fields — always present on every encoded record.
        record[Key.schemaVersion] = Int64(clip.schemaVersion)
        record[Key.contentType] = clip.contentType.rawValue
        record[Key.createdAt] = clip.createdAt
        record[Key.lastCopiedAt] = clip.lastCopiedAt
        record[Key.copyCount] = Int64(clip.copyCount)
        record[Key.isPinned] = clip.isPinned ? Int64(1) : Int64(0)
        record[Key.isDeleted] = clip.isDeleted ? Int64(1) : Int64(0)
        record[Key.deviceId] = clip.deviceId ?? DeviceIdentity.deviceId
        record[Key.platformCreatedOn] = DeviceIdentity.platform
        record[Key.tagsText] = clip.tagsText
        // tagUuids: CloudKit Development schema inference cannot deduce the
        // list's element type from an empty `[String]()` — the server
        // rejects the upload with "cannot use an empty list to initialize
        // a new field". Leave the field unset until tag-relation sync
        // populates real uuids; CloudKit treats an absent field
        // identically to an empty list on read.

        record[Key.updatedAt] = updatedAt

        // Optional fields — direct assignment; CKRecord accepts nil as
        // "clear the field" so a removed local nickname propagates to server.
        record[Key.contentText] = clip.contentText
        record[Key.contentHash] = clip.contentHash
        record[Key.imageHash] = clip.imageHash
        record[Key.imageDhash] = clip.imageDhash
        // Thumbnail: 이미지 클립이 다른 device에서도 즉시 보이도록 작은
        // JPEG 데이터 동봉. CKRecord 단일 field 한도(1MB) 안에 안전.
        // 너무 큰 thumbnail은 sync 비용만 키우므로 200KB 컷 — 그 이상은
        // ClipProcessor가 잘못 만든 거이고 sync 안 보내는 게 안전.
        if let thumb = clip.thumbnail, thumb.count <= 200 * 1024 {
            record[Key.thumbnail] = thumb
        }

        // Phase C — 원본 이미지 CKAsset 첨부.
        // 조건: contentType=.image AND imagePath 존재 AND 옵션 .full
        //       AND size cap 통과 AND 셀룰러 정책 통과(NetworkPolicy).
        // 실패 케이스(파일 없음/cap 초과)는 record["assetExceeded"]=1 로 표시 →
        // 다른 디바이스 UI가 "원본은 다른 기기에서만" 배지를 띄움.
        // 셀룰러 차단으로 미첨부 시는 두 플래그 모두 미설정 — Wi-Fi 복귀 후
        // 같은 클립이 사용자에 의해 다시 트리거되거나(updatedAt 변경) 별도
        // deferred queue 가 재 enqueue 할 때 자연스럽게 재시도.
        if clip.contentType == .image,
           let relPath = clip.imagePath,
           let store = ImageOriginalStoreRegistry.current
        {
            let settings = ImageSyncSettings.current()
            if settings.mode == .full && NetworkPolicy.canSendLargeAssets(settings: settings) {
                let fullURL = store.fullURL(for: relPath)
                if let asset = AssetStaging.shared.stageOriginal(
                    uuid: uuid,
                    sourcePath: fullURL,
                    sizeCapBytes: settings.sizeCap.bytes
                ) {
                    record[Key.imageOriginalAsset] = asset
                    record[Key.assetExceeded] = Int64(0)
                } else if FileManager.default.fileExists(atPath: fullURL.path) {
                    // 파일이 있는데 stage 실패 == cap 초과(또는 디스크 I/O 실패).
                    record[Key.assetExceeded] = Int64(1)
                }
                // 파일 자체 없음(thumbnail-only 클립)이면 두 플래그 모두 미설정.
            }
        }
        // 보안 감사 A-M-5: ocrText / nickname / tagsText 는 SyncFilters 가 검사하지
        // 않는 free-form 사용자 입력. 영수증 사진 OCR 결과에 카드번호/주민번호가
        // 들어가거나, 사용자가 nickname 에 비밀번호를 적어두는 경우 sync 로 누출 가능.
        // 각 필드에 패턴 매치되면 redact (clip 자체는 로컬 유지, sync 시 해당 필드만 nil).
        record[Key.ocrText] = Self.redactedIfSensitive(clip.ocrText, label: "ocrText", uuid: uuid)
        record[Key.ocrConfidence] = clip.ocrConfidence
        record[Key.sourceAppBundleId] = clip.sourceAppBundleId
        record[Key.sourceAppName] = clip.sourceAppName
        record[Key.sourceUrl] = clip.sourceUrl
        record[Key.ogTitle] = clip.ogTitle
        record[Key.ogFetchedAt] = clip.ogFetchedAt
        record[Key.nickname] = Self.redactedIfSensitive(clip.nickname, label: "nickname", uuid: uuid)
        record[Key.pinOrder] = clip.pinOrder.map { Int64($0) }
        record[Key.manualOrder] = clip.manualOrder.map { Int64($0) }
        record[Key.expiresAt] = clip.expiresAt
        record[Key.aiCategory] = clip.aiCategory
        record[Key.aiCategoryGeneratedAt] = clip.aiCategoryGeneratedAt
        // tagsText 도 동일하게 검사 (위 record[Key.tagsText] 라인 187 에서 set 한 값을 덮어쓰기).
        // tagsText 는 non-optional String 이므로 empty 는 nil 로 처리.
        let tagsOptional: String? = clip.tagsText.isEmpty ? nil : clip.tagsText
        record[Key.tagsText] = Self.redactedIfSensitive(tagsOptional, label: "tagsText", uuid: uuid)

        // Per-field LWW timestamps (v14). nil 은 nil 그대로 전송 — "이 device 가
        // 이 field 를 명시적으로 set 한 적 없음" 의미. 받는 측 decode 가 NULL <
        // 모든 concrete Date 로 취급해 다른 device 가 처음 set 한 시점부터 LWW
        // 정상 작동.
        record[Key.isPinnedUpdatedAt]        = clip.isPinnedUpdatedAt
        record[Key.pinOrderUpdatedAt]        = clip.pinOrderUpdatedAt
        record[Key.manualOrderUpdatedAt]     = clip.manualOrderUpdatedAt
        record[Key.isDeletedUpdatedAt]       = clip.isDeletedUpdatedAt
        record[Key.nicknameUpdatedAt]        = clip.nicknameUpdatedAt
        record[Key.excludeFromSyncUpdatedAt] = clip.excludeFromSyncUpdatedAt
        record[Key.expiresAtUpdatedAt]       = clip.expiresAtUpdatedAt
        record[Key.customShortcutUpdatedAt]  = clip.customShortcutUpdatedAt

        return record
    }

    /// Per-field LWW compare. Returns `true` when the **server** value should
    /// be applied (server wins). Returns `false` when the **local** value
    /// should be retained.
    ///
    /// NULL semantics: NULL is treated as strictly older than any concrete
    /// Date — a device that never explicitly wrote this field is "stale"
    /// relative to one that did. If both sides are NULL we fall back to
    /// server-wins (legacy behavior, no information available to discriminate).
    ///
    /// Tie (equal Dates) also resolves to server-wins so the order in which
    /// two devices' identical-instant writes land on the server is stable.
    ///
    /// Internal access so the package's unit tests can exercise the table
    /// directly without indirection through `decode(_:merging:)`. Production
    /// callers go through decode.
    internal static func serverWinsLWW(serverTS: Date?, localTS: Date?) -> Bool {
        switch (serverTS, localTS) {
        case (nil, nil):      return true   // both unset → fallback server-wins
        case (nil, _):        return false  // only local explicit → local wins
        case (_, nil):        return true   // only server explicit → server wins
        case let (s?, l?):    return s >= l // strict LWW (tie → server)
        }
    }

    /// 텍스트가 `SyncFilters.shouldExclude` 가 잡는 sensitive 패턴이면 nil 반환.
    /// 그 외엔 입력 그대로 반환. CloudKit 으로 업로드되는 free-form 필드 (ocrText,
    /// nickname, tagsText) 가 누수 통로가 되지 않도록 마지막 방어선.
    private static func redactedIfSensitive(_ text: String?, label: String, uuid: String) -> String? {
        guard let text, !text.isEmpty else { return text }
        // SyncFilters 가 잡으면 (true) → redact (nil)
        // 단 SyncFilters.shouldExclude 는 sourceAppBundleId / userAppBlacklist 도 받지만
        // 여기선 텍스트 자체 패턴 매치만 보면 됨.
        if SyncFilters.shouldExclude(
            text: text,
            sourceAppBundleId: nil,
            userAppBlacklist: []
        ) {
            log.info("redacted \(label, privacy: .public) on sync (uuid=\(uuid, privacy: .public))")
            return nil
        }
        return text
    }

    // MARK: - Decode (CKRecord → Clip)

    /// Merge a server record back into a local `Clip`. If `local` is nil the
    /// record represents a clip this device hasn't seen — a fresh row is
    /// built. If `local` is present, immutable fields are held and mutable
    /// fields are overwritten by server values ("server-wins" today; per-
    /// field LWW deferred).
    ///
    /// The returned Clip has `ckSystemFields` freshly captured from the
    /// record — callers should persist this verbatim so the next encode
    /// round keeps the recordChangeTag.
    public static func decode(_ record: CKRecord, merging local: Clip?) -> Clip {
        var c = local ?? Clip(contentType: .text, contentText: nil)
        c.uuid = record.recordID.recordName

        // contentType — unknown raw values are degraded to .text and the
        // raw string is dropped (forward-compat: future releases can add
        // .video etc; older clients at least surface the clip rather than
        // drop it).
        if let raw = record[Key.contentType] as? String,
           let parsed = ContentType(rawValue: raw)
        {
            c.contentType = parsed
        } else if local == nil {
            c.contentType = .text
        }

        // Immutable — only copy from server when the local value is
        // absent. "Absent" means either no local row at all, or a local
        // row whose value is nil (e.g., migrated pre-v12 row that never
        // got backfilled, corrupted write). Once present, local wins.
        if local == nil {
            c.contentText = record[Key.contentText] as? String
            c.contentHash = record[Key.contentHash] as? String
            c.createdAt = (record[Key.createdAt] as? Date) ?? Date()
        }
        if c.contentText == nil {
            c.contentText = record[Key.contentText] as? String
        }
        if c.contentHash == nil {
            c.contentHash = record[Key.contentHash] as? String
        }
        // deviceId is special: plan §11 requires the server-authored value
        // to be restored so Settings → Sync can render "Mac Studio에서
        // 복사됨" badges even after the local row was touched. This is the
        // only immutable field we backfill on an existing row.
        if c.deviceId == nil {
            c.deviceId = record[Key.deviceId] as? String
        }

        // Mutable — server-wins for background metadata (OG/AI/OCR/etc).
        // User-intent fields (isPinned, pinOrder, manualOrder, isDeleted,
        // nickname, expiresAt, customShortcut*) use per-field LWW below
        // so a stale background update from one device can't reverse a
        // user toggle on another. v14.
        c.schemaVersion = Int(record[Key.schemaVersion] as? Int64 ?? 1)
        c.tagsText = (record[Key.tagsText] as? String) ?? ""
        c.copyCount = Int(record[Key.copyCount] as? Int64 ?? 1)
        c.lastCopiedAt = (record[Key.lastCopiedAt] as? Date) ?? c.lastCopiedAt
        c.updatedAt = record[Key.updatedAt] as? Date

        // Per-field LWW (v14) — user-intent fields. `c` starts as `local` so
        // when LWW returns false ("local wins") the local value is preserved
        // automatically; only the server-wins branch overwrites.
        let serverIsPinnedTS = record[Key.isPinnedUpdatedAt] as? Date
        if Self.serverWinsLWW(serverTS: serverIsPinnedTS, localTS: local?.isPinnedUpdatedAt) {
            c.isPinned = ((record[Key.isPinned] as? Int64) ?? 0) != 0
            c.isPinnedUpdatedAt = serverIsPinnedTS
        }

        let serverPinOrderTS = record[Key.pinOrderUpdatedAt] as? Date
        if Self.serverWinsLWW(serverTS: serverPinOrderTS, localTS: local?.pinOrderUpdatedAt) {
            c.pinOrder = (record[Key.pinOrder] as? Int64).map { Int($0) }
            c.pinOrderUpdatedAt = serverPinOrderTS
        }

        let serverManualOrderTS = record[Key.manualOrderUpdatedAt] as? Date
        if Self.serverWinsLWW(serverTS: serverManualOrderTS, localTS: local?.manualOrderUpdatedAt) {
            c.manualOrder = (record[Key.manualOrder] as? Int64).map { Int($0) }
            c.manualOrderUpdatedAt = serverManualOrderTS
        }

        let serverIsDeletedTS = record[Key.isDeletedUpdatedAt] as? Date
        if Self.serverWinsLWW(serverTS: serverIsDeletedTS, localTS: local?.isDeletedUpdatedAt) {
            c.isDeleted = ((record[Key.isDeleted] as? Int64) ?? 0) != 0
            c.isDeletedUpdatedAt = serverIsDeletedTS
        }

        let serverNicknameTS = record[Key.nicknameUpdatedAt] as? Date
        if Self.serverWinsLWW(serverTS: serverNicknameTS, localTS: local?.nicknameUpdatedAt) {
            c.nickname = record[Key.nickname] as? String
            c.nicknameUpdatedAt = serverNicknameTS
        }

        let serverExpiresTS = record[Key.expiresAtUpdatedAt] as? Date
        if Self.serverWinsLWW(serverTS: serverExpiresTS, localTS: local?.expiresAtUpdatedAt) {
            c.expiresAt = record[Key.expiresAt] as? Date
            c.expiresAtUpdatedAt = serverExpiresTS
        }

        // customShortcut LWW 는 timestamp 인프라만 갖춰두고 활성 안 함 (v14).
        // 이유: customShortcutKeyCode / customShortcutModifiers 자체가 CKRecord
        // schema 에 정의 안 됨 (Mac-only Carbon hotkey, iOS 미지원). value 가
        // record 에 없으니 LWW server-wins 가 의미 없음. timestamp 컬럼만
        // 미래 sync 활성 시 즉시 사용 가능하게 schema 추가.
        // applyServerChangesBody 가 기존대로 local 값 보존.

        c.imageHash = record[Key.imageHash] as? String
        c.imageDhash = (record[Key.imageDhash] as? Int64)
        // Thumbnail data — Mac이 이미지 클립 업로드 시 동봉.
        // 기존 클립 (sync 전에 만들어진 거)은 nil 유지.
        c.thumbnail = record[Key.thumbnail] as? Data

        // Phase C — 원본 이미지 CKAsset 수신 처리.
        // CKAsset이 있으면 즉시 영구 저장소로 복사하고 imagePath 채움.
        // CloudKit이 캐시한 임시 fileURL은 언제든 사라질 수 있으므로 복사 필수.
        if let asset = record[Key.imageOriginalAsset] as? CKAsset,
           let store = ImageOriginalStoreRegistry.current,
           let assetURL = asset.fileURL,
           let uuid = c.uuid
        {
            do {
                let data = try Data(contentsOf: assetURL)
                let ext = assetURL.pathExtension.isEmpty ? "png" : assetURL.pathExtension
                if let savedRelPath = store.saveOriginal(data, uuid: uuid, preferredExt: ext) {
                    c.imagePath = savedRelPath
                }
            } catch {
                log.error("decode: copying CKAsset failed for \(uuid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        c.ocrText = record[Key.ocrText] as? String
        c.ocrConfidence = record[Key.ocrConfidence] as? Double
        c.sourceAppBundleId = record[Key.sourceAppBundleId] as? String
        c.sourceAppName = record[Key.sourceAppName] as? String
        c.sourceUrl = record[Key.sourceUrl] as? String
        c.ogTitle = record[Key.ogTitle] as? String
        c.ogFetchedAt = record[Key.ogFetchedAt] as? Date
        // nickname / pinOrder / manualOrder / expiresAt 는 LWW 분기에서 결정.
        // 여기서 다시 record 값으로 덮어쓰면 LWW 무효화되므로 제거 (v14).
        c.aiCategory = record[Key.aiCategory] as? String
        c.aiCategoryGeneratedAt = record[Key.aiCategoryGeneratedAt] as? Date

        // Always capture the latest systemFields for the next encode.
        c.ckSystemFields = encodedSystemFields(of: record)
        c.ckSyncState = 0 // synced
        c.ckLastSyncedAt = Date()

        return c
    }

    // MARK: - System fields archive/unarchive

    /// Serialize CKRecord metadata (recordID, zone, change tag, timestamps)
    /// for the `clips.ckSystemFields` blob. Custom field values are NOT
    /// included — those travel in `encode(_:)`.
    public static func encodedSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        return archiver.encodedData
    }

    /// Rehydrate CKRecord metadata from `clips.ckSystemFields`. Returns nil
    /// when the blob is missing or corrupted — callers should build a fresh
    /// record in that case.
    public static func recordFromSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    // MARK: - Private helpers

    private static func baseRecord(for clip: Clip, uuid: String) -> CKRecord {
        if let data = clip.ckSystemFields,
           let rehydrated = recordFromSystemFields(data)
        {
            return rehydrated
        }
        let id = CKRecord.ID(recordName: uuid, zoneID: zoneID)
        return CKRecord(recordType: clipRecordType, recordID: id)
    }

    /// `immutableKeys` is exposed for tests and for upstream observers that
    /// want to assert "this local edit would not be allowed server-side."
    public static var protectedImmutableKeys: Set<String> { immutableKeys }
}
