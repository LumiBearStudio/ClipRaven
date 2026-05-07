import Foundation
import GRDB

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
        excludeFromSync: Bool = false
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
