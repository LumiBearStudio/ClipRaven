import Foundation
import GRDB

/// 클립보드에 캡처된 단일 항목 — 텍스트/URL/코드/이미지/컬러/파일.
///
/// macOS 앱과 iOS 앱이 동일한 `clips` SQLite 테이블에 GRDB Codable 로 매핑되며,
/// CKSyncEngine 을 통한 iCloud 동기화의 단위이기도 하다.
///
/// ### 필드 그룹
/// - **콘텐츠**: `contentType`, `contentText`, `contentHash`, `imageHash`, `imagePath`, `thumbnail`
/// - **OCR (Vision)**: `ocrText`, `ocrConfidence` — 이미지에서 추출한 텍스트 + 신뢰도
/// - **소스 앱**: `sourceAppBundleId`, `sourceAppName` — 어느 앱에서 복사되었는지
/// - **메타**: `nickname`, `isPinned`, `pinOrder`, `manualOrder`, `copyCount`, `lastCopiedAt`
/// - **만료 / 검색**: `expiresAt`, `contentChosung` (한글 초성), `aiCategory`
/// - **동기화 (v12+)**: `uuid` (CloudKit recordName), `deviceId`, `schemaVersion`,
///   `ckLastSyncedAt`, `ckSystemFields`, `excludeFromSync`
public struct Clip: Identifiable, Codable, Equatable, Hashable {
    public var id: Int64?
    public var contentType: ContentType
    public var contentText: String?
    public var contentHash: String?
    public var imageHash: String?
    public var imageDhash: Int64?
    public var imagePath: String?
    public var thumbnail: Data?
    public var ocrText: String?
    public var ocrConfidence: Double?
    public var sourceAppBundleId: String?
    public var sourceAppName: String?
    public var sourceUrl: String?
    public var tagsText: String = ""
    public var contentChosung: String?
    public var pinOrder: Int?
    public var manualOrder: Int?
    public var copyCount: Int = 1
    public var nickname: String?
    public var ogTitle: String?
    public var ogFetchedAt: Date?
    public var isPinned: Bool = false
    public var isDeleted: Bool = false
    public var expiresAt: Date?
    public var createdAt: Date = Date()
    public var lastCopiedAt: Date = Date()

    // Per-clip custom global hotkey (v10). When non-nil, the user can paste this clip
    // into the frontmost app without opening the panel.
    // Mac-only field — iOS doesn't register Carbon hotkeys but the column is shared.
    public var customShortcutKeyCode: UInt32?
    public var customShortcutModifiers: UInt32?

    // AI-assigned category (v11, Foundation Models macOS 26+).
    // Possible values: receipt, meeting, code, phone, email, address, link, other, nil = uncategorized.
    public var aiCategory: String?
    public var aiCategoryGeneratedAt: Date?

    // iCloud sync metadata (v12). Optional where the pre-migration backfill may
    // leave a value, non-optional with a default where the migration column has
    // NOT NULL + DEFAULT. See DatabaseMigrations.v12_syncMeta for rationale.
    public var uuid: String?
    public var deviceId: String?
    public var schemaVersion: Int = 1
    public var updatedAt: Date?
    public var ckSystemFields: Data?
    public var ckSyncState: Int = 0
    public var ckLastSyncedAt: Date?
    public var excludeFromSync: Bool = false

    // Per-field LWW timestamps (v14) — 사용자 의도(user-intent) field 가 변경된
    // 정확한 시점. server-wins 정책이 background metadata update (OG fetch/AI/
    // OCR 결과)로 갱신된 stale state 가 다른 device 의 user toggle 을 역행시키는
    // 회귀를 막기 위해 도입.
    //
    // 의미론: 해당 field 가 마지막으로 사용자 의도로 변경된 시각.
    // - NULL → "최초 시점부터 변경된 적 없음" (default, backfill 안 함)
    // - Date → 그 시각 이후 user-intent 변경 발생
    //
    // 충돌 해소: server 의 timestamp 가 local 보다 newer 일 때만 server value 적용
    // (LWW). 동률 또는 local 이 newer 면 local 유지.
    public var isPinnedUpdatedAt: Date?
    public var pinOrderUpdatedAt: Date?
    public var manualOrderUpdatedAt: Date?
    public var isDeletedUpdatedAt: Date?
    public var nicknameUpdatedAt: Date?
    public var excludeFromSyncUpdatedAt: Date?
    public var expiresAtUpdatedAt: Date?
    /// `customShortcutKeyCode` + `customShortcutModifiers` 묶음 timestamp.
    /// 단축키는 항상 두 컬럼 함께 set/clear 되므로 단일 timestamp 로 충분.
    public var customShortcutUpdatedAt: Date?

    /// Memberwise public initializer. Swift only synthesizes an `internal`
    /// memberwise init for structs, so consumers in the host apps need this
    /// to construct Clips outside the package.
    public init(
        id: Int64? = nil,
        contentType: ContentType,
        contentText: String? = nil,
        contentHash: String? = nil,
        imageHash: String? = nil,
        imageDhash: Int64? = nil,
        imagePath: String? = nil,
        thumbnail: Data? = nil,
        ocrText: String? = nil,
        ocrConfidence: Double? = nil,
        sourceAppBundleId: String? = nil,
        sourceAppName: String? = nil,
        sourceUrl: String? = nil,
        tagsText: String = "",
        contentChosung: String? = nil,
        pinOrder: Int? = nil,
        manualOrder: Int? = nil,
        copyCount: Int = 1,
        nickname: String? = nil,
        ogTitle: String? = nil,
        ogFetchedAt: Date? = nil,
        isPinned: Bool = false,
        isDeleted: Bool = false,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        customShortcutKeyCode: UInt32? = nil,
        customShortcutModifiers: UInt32? = nil,
        aiCategory: String? = nil,
        aiCategoryGeneratedAt: Date? = nil,
        uuid: String? = nil,
        deviceId: String? = nil,
        schemaVersion: Int = 1,
        updatedAt: Date? = nil,
        ckSystemFields: Data? = nil,
        ckSyncState: Int = 0,
        ckLastSyncedAt: Date? = nil,
        excludeFromSync: Bool = false,
        isPinnedUpdatedAt: Date? = nil,
        pinOrderUpdatedAt: Date? = nil,
        manualOrderUpdatedAt: Date? = nil,
        isDeletedUpdatedAt: Date? = nil,
        nicknameUpdatedAt: Date? = nil,
        excludeFromSyncUpdatedAt: Date? = nil,
        expiresAtUpdatedAt: Date? = nil,
        customShortcutUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.contentType = contentType
        self.contentText = contentText
        self.contentHash = contentHash
        self.imageHash = imageHash
        self.imageDhash = imageDhash
        self.imagePath = imagePath
        self.thumbnail = thumbnail
        self.ocrText = ocrText
        self.ocrConfidence = ocrConfidence
        self.sourceAppBundleId = sourceAppBundleId
        self.sourceAppName = sourceAppName
        self.sourceUrl = sourceUrl
        self.tagsText = tagsText
        self.contentChosung = contentChosung
        self.pinOrder = pinOrder
        self.manualOrder = manualOrder
        self.copyCount = copyCount
        self.nickname = nickname
        self.ogTitle = ogTitle
        self.ogFetchedAt = ogFetchedAt
        self.isPinned = isPinned
        self.isDeleted = isDeleted
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.customShortcutKeyCode = customShortcutKeyCode
        self.customShortcutModifiers = customShortcutModifiers
        self.aiCategory = aiCategory
        self.aiCategoryGeneratedAt = aiCategoryGeneratedAt
        self.uuid = uuid
        self.deviceId = deviceId
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.ckSystemFields = ckSystemFields
        self.ckSyncState = ckSyncState
        self.ckLastSyncedAt = ckLastSyncedAt
        self.excludeFromSync = excludeFromSync
        self.isPinnedUpdatedAt = isPinnedUpdatedAt
        self.pinOrderUpdatedAt = pinOrderUpdatedAt
        self.manualOrderUpdatedAt = manualOrderUpdatedAt
        self.isDeletedUpdatedAt = isDeletedUpdatedAt
        self.nicknameUpdatedAt = nicknameUpdatedAt
        self.excludeFromSyncUpdatedAt = excludeFromSyncUpdatedAt
        self.expiresAtUpdatedAt = expiresAtUpdatedAt
        self.customShortcutUpdatedAt = customShortcutUpdatedAt
    }
}

// MARK: - GRDB TableRecord & FetchableRecord & PersistableRecord
extension Clip: TableRecord, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clips"

    // Association
    public static let clipTags = hasMany(ClipTag.self)
    public static let tags = hasMany(Tag.self, through: clipTags, using: ClipTag.tag)

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
