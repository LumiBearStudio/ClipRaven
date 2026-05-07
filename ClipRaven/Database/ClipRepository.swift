import Foundation
import CloudKit
import GRDB
import ClipRavenSync

struct ClipRepository {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
    }

    // MARK: - Sort order (pinned by pinOrder, normal by manualOrder then lastCopiedAt)

    private static let displayOrder = [
        Column("isPinned").desc,
        Column("pinOrder").asc,
        Column("manualOrder").asc,
        Column("lastCopiedAt").desc,
    ]

    // MARK: - Create

    @discardableResult
    func save(_ clip: inout Clip) throws -> Clip {
        try dbPool.write { db in
            try clip.save(db)
        }
        return clip
    }

    // MARK: - Read

    func fetchAll(
        contentType: ContentType? = nil,
        isPinned: Bool? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) throws -> [Clip] {
        try dbPool.read { db in
            var request = Clip
                .filter(Column("isDeleted") == false)
                .order(Self.displayOrder)

            if let contentType {
                request = request.filter(Column("contentType") == contentType.rawValue)
            }
            if let isPinned {
                request = request.filter(Column("isPinned") == isPinned)
            }

            return try request
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func fetchOne(id: Int64) throws -> Clip? {
        try dbPool.read { db in
            try Clip.fetchOne(db, id: id)
        }
    }

    /// Fetch every live (non-deleted) clip with no limit — used by BackupService.
    func fetchAllForExport() throws -> [Clip] {
        try dbPool.read { db in
            try Clip
                .filter(Column("isDeleted") == false)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    /// Fetch every clip↔tag join row for a full data export.
    func fetchAllClipTagsForExport() throws -> [ClipTag] {
        try dbPool.read { db in
            try ClipTag.fetchAll(db)
        }
    }

    func fetchById(_ id: Int64) throws -> Clip? {
        try dbPool.read { db in
            try Clip.fetchOne(db, key: id)
        }
    }

    func fetchByHash(_ hash: String) throws -> Clip? {
        try dbPool.read { db in
            try Clip
                .filter(Column("contentHash") == hash)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)
        }
    }

    func fetchByImageHash(_ hash: String) throws -> Clip? {
        try dbPool.read { db in
            try Clip
                .filter(Column("imageHash") == hash)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)
        }
    }

    func count(contentType: ContentType? = nil) throws -> Int {
        try dbPool.read { db in
            var request = Clip.filter(Column("isDeleted") == false)
            if let contentType {
                request = request.filter(Column("contentType") == contentType.rawValue)
            }
            return try request.fetchCount(db)
        }
    }

    // MARK: - Update

    func update(_ clip: Clip) throws {
        var mutable = clip
        mutable.updatedAt = Date()  // LWW basis for sync
        try dbPool.write { db in
            try mutable.update(db)
        }
    }

    func incrementCopyCount(id: Int64) throws {
        let now = Date()
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE clips SET copyCount = copyCount + 1, lastCopiedAt = ?, updatedAt = ?
                    WHERE id = ?
                """,
                arguments: [now, now, id]
            )
        }
    }

    /// Universal Clipboard 2-stage dedup: the most recently created non-deleted clip,
    /// regardless of sort order (by id DESC, not lastCopiedAt).
    func fetchMostRecentNonDeleted() throws -> Clip? {
        try dbPool.read { db in
            try Clip
                .filter(Column("isDeleted") == false)
                .order(Column("id").desc)
                .fetchOne(db)
        }
    }

    /// Upgrade a file clip to an image clip in-place. Used when Universal Clipboard
    /// delivers the actual image bytes after stage-1 saved only the file-url reference.
    func upgradeFileClipToImage(
        id: Int64,
        imageHash: String,
        imageDhash: Int64?,
        imagePath: String?,
        thumbnail: Data?
    ) throws {
        let now = Date()
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE clips
                    SET contentType = 'image',
                        contentText = NULL,
                        contentHash = NULL,
                        imageHash   = ?,
                        imageDhash  = ?,
                        imagePath   = ?,
                        thumbnail   = ?,
                        lastCopiedAt = ?,
                        updatedAt   = ?
                    WHERE id = ?
                """,
                arguments: [imageHash, imageDhash, imagePath, thumbnail, now, now, id]
            )
        }
    }

    // MARK: - Custom shortcuts (v10)

    /// Assign or replace a custom global hotkey on a clip.
    /// Pass nil for both args to clear the shortcut.
    func updateCustomShortcut(
        id: Int64,
        keyCode: UInt32?,
        modifiers: UInt32?
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE clips
                       SET customShortcutKeyCode = ?,
                           customShortcutModifiers = ?,
                           updatedAt = ?
                     WHERE id = ?
                """,
                arguments: [keyCode, modifiers, Date(), id]
            )
        }
    }

    /// Fetch every live clip that has a custom shortcut assigned.
    /// Used at app launch to re-register per-clip hotkeys.
    func fetchClipsWithShortcuts() throws -> [Clip] {
        try dbPool.read { db in
            try Clip
                .filter(Column("isDeleted") == false)
                .filter(Column("customShortcutKeyCode") != nil)
                .fetchAll(db)
        }
    }

    /// Look up any live clip using the given (keyCode, modifiers) combo.
    /// Used by the shortcut recorder to detect in-app conflicts before attempting Carbon registration.
    func fetchClipByShortcut(keyCode: UInt32, modifiers: UInt32) throws -> Clip? {
        try dbPool.read { db in
            try Clip
                .filter(Column("isDeleted") == false)
                .filter(Column("customShortcutKeyCode") == Int(keyCode))
                .filter(Column("customShortcutModifiers") == Int(modifiers))
                .fetchOne(db)
        }
    }

    func togglePin(id: Int64) throws {
        try dbPool.write { db in
            guard var clip = try Clip.fetchOne(db, id: id) else { return }
            clip.updatedAt = Date()

            if clip.isPinned {
                // Unpin: clear pinOrder
                clip.isPinned = false
                clip.pinOrder = nil
                try clip.update(db)
                // Recompact remaining pinned clips
                try Self.recompactPinOrder(db)
            } else {
                // Pin: assign to end
                let maxOrder = try Int.fetchOne(db, sql:
                    "SELECT COALESCE(MAX(pinOrder), -1) FROM clips WHERE isPinned = 1 AND isDeleted = 0"
                ) ?? -1
                clip.isPinned = true
                clip.pinOrder = maxOrder + 1
                clip.manualOrder = nil
                try clip.update(db)
            }
        }
    }

    // MARK: - Delete (soft)

    func updateNickname(id: Int64, nickname: String?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET nickname = ?, updatedAt = ? WHERE id = ?",
                arguments: [nickname, Date(), id]
            )
        }
    }

    func softDelete(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET isDeleted = 1, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    func softDeleteBatch(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [Date()]
            args.append(contentsOf: ids)
            try db.execute(
                sql: "UPDATE clips SET isDeleted = 1, updatedAt = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    func hardDelete(id: Int64) throws {
        try dbPool.write { db in
            _ = try Clip.deleteOne(db, id: id)
        }
    }

    // MARK: - Cleanup

    func deleteExpired() throws -> Int {
        try dbPool.write { db in
            try Clip
                .filter(Column("expiresAt") != nil && Column("expiresAt") < Date())
                .deleteAll(db)
        }
    }

    /// 보관 기간 자동 정리 — `lastCopiedAt < now - days` 인 클립을 hard-delete.
    /// 핀 고정(`isPinned = 1`) 은 영구 보관이므로 제외.
    /// SmartRule 의 명시적 `expiresAt` 과 별개로 글로벌 retention 적용.
    /// `days <= 0` 또는 비합리적으로 큰 값(>365) 은 no-op (defensive).
    func deleteOlderThanDays(_ days: Int) throws -> Int {
        guard days > 0, days <= 365 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return try dbPool.write { db in
            try Clip
                .filter(Column("isDeleted") == false)
                .filter(Column("isPinned") == false)
                .filter(Column("lastCopiedAt") < cutoff)
                .deleteAll(db)
        }
    }

    func deleteSoftDeleted() throws -> Int {
        try dbPool.write { db in
            // Only hard-delete clips whose deletion has been confirmed synced
            // (ckLastSyncedAt >= updatedAt, set by applyDeleteAck after
            // CloudKit acknowledges the deleteRecord). Un-synced soft-deletes
            // are preserved so the engine can still upload them.
            //
            // Fallback: also delete clips that are older than 30 days — these
            // are either excludeFromSync=1 (never synced) or the sync engine
            // has been persistently broken for a month, both acceptable to purge.
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            try db.execute(sql: """
                DELETE FROM clips
                WHERE isDeleted = 1
                  AND (
                    (ckLastSyncedAt IS NOT NULL AND ckLastSyncedAt >= updatedAt)
                    OR excludeFromSync = 1
                    OR updatedAt IS NULL
                    OR updatedAt < ?
                  )
            """, arguments: [cutoff])
            return db.changesCount
        }
    }

    func deleteOldest(keepCount: Int) throws -> Int {
        try dbPool.write { db in
            let totalCount = try Clip
                .filter(Column("isDeleted") == false)
                .filter(Column("isPinned") == false)
                .fetchCount(db)

            guard totalCount > keepCount else { return 0 }
            let deleteCount = totalCount - keepCount

            let oldestIds = try Clip
                .filter(Column("isDeleted") == false)
                .filter(Column("isPinned") == false)
                .order(Column("lastCopiedAt").asc)
                .limit(deleteCount)
                .select(Column("id"))
                .asRequest(of: Int64.self)
                .fetchAll(db)

            return try Clip
                .filter(oldestIds.contains(Column("id")))
                .deleteAll(db)
        }
    }

    // MARK: - Source App

    /// 현재 저장된 클립에서 고유한 소스 앱 목록을 반환
    func fetchUniqueSourceApps() throws -> [(bundleId: String, name: String)] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT sourceAppBundleId, sourceAppName
                FROM clips
                WHERE isDeleted = 0
                  AND sourceAppBundleId IS NOT NULL
                  AND sourceAppName IS NOT NULL
                ORDER BY sourceAppName ASC
            """)
            return rows.compactMap { row in
                guard let bundleId = row["sourceAppBundleId"] as String?,
                      let name = row["sourceAppName"] as String? else { return nil }
                return (bundleId: bundleId, name: name)
            }
        }
    }

    // MARK: - Observation

    func observeAll(
        contentType: ContentType? = nil,
        tagIds: Set<Int64> = [],
        sourceAppBundleId: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        aiCategory: String? = nil,
        onUpdate: @escaping ([Clip]) -> Void
    ) -> DatabaseCancellable {
        let observation = ValueObservation.tracking { db -> [Clip] in
            // If filtering by tags, fetch clip IDs from clipTags first
            if !tagIds.isEmpty {
                let clipIds = try ClipTag
                    .filter(tagIds.contains(Column("tagId")))
                    .select(Column("clipId"))
                    .asRequest(of: Int64.self)
                    .fetchAll(db)

                var request = Clip
                    .filter(clipIds.contains(Column("id")))
                    .filter(Column("isDeleted") == false)
                    .order(Self.displayOrder)
                    .limit(200)

                if let contentType {
                    request = request.filter(Column("contentType") == contentType.rawValue)
                }
                if let sourceAppBundleId {
                    request = request.filter(Column("sourceAppBundleId") == sourceAppBundleId)
                }
                if let dateFrom {
                    request = request.filter(Column("createdAt") >= dateFrom)
                }
                if let dateTo {
                    request = request.filter(Column("createdAt") <= dateTo)
                }
                if let aiCategory {
                    request = request.filter(Column("aiCategory") == aiCategory)
                }

                return try request.fetchAll(db)
            }

            var request = Clip
                .filter(Column("isDeleted") == false)
                .order(Self.displayOrder)
                .limit(200)

            if let contentType {
                request = request.filter(Column("contentType") == contentType.rawValue)
            }
            if let sourceAppBundleId {
                request = request.filter(Column("sourceAppBundleId") == sourceAppBundleId)
            }
            if let dateFrom {
                request = request.filter(Column("createdAt") >= dateFrom)
            }
            if let dateTo {
                request = request.filter(Column("createdAt") <= dateTo)
            }
            if let aiCategory {
                request = request.filter(Column("aiCategory") == aiCategory)
            }

            return try request.fetchAll(db)
        }

        return observation.start(
            in: dbPool,
            onError: { error in ClipRavenLog.database.error("observation error: \(String(describing: error), privacy: .public)") },
            onChange: onUpdate
        )
    }

    // MARK: - Drag & Drop Reordering

    /// Reorder a pinned clip to a new position among pinned clips
    func reorderPinnedClip(clipId: Int64, newIndex: Int) throws {
        let now = Date()
        try dbPool.write { db in
            // Get all pinned clips in current order
            var pinnedIds = try Int64.fetchAll(db, sql: """
                SELECT id FROM clips
                WHERE isPinned = 1 AND isDeleted = 0
                ORDER BY pinOrder ASC, lastCopiedAt DESC
            """)

            // Remove the clip from its current position
            pinnedIds.removeAll { $0 == clipId }

            // Insert at the new position
            let insertAt = min(newIndex, pinnedIds.count)
            pinnedIds.insert(clipId, at: insertAt)

            // Reassign sequential pinOrder
            for (index, id) in pinnedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE clips SET pinOrder = ?, updatedAt = ? WHERE id = ?",
                    arguments: [index, now, id]
                )
            }
        }
    }

    /// Reorder a normal clip to a new position among normal clips
    func reorderNormalClip(clipId: Int64, newIndex: Int) throws {
        let now = Date()
        try dbPool.write { db in
            // Get all normal (non-pinned) clips in current display order
            var normalIds = try Int64.fetchAll(db, sql: """
                SELECT id FROM clips
                WHERE isPinned = 0 AND isDeleted = 0
                ORDER BY manualOrder ASC NULLS LAST, lastCopiedAt DESC
                LIMIT 200
            """)

            // Remove the clip from its current position
            normalIds.removeAll { $0 == clipId }

            // Insert at the new position
            let insertAt = min(newIndex, normalIds.count)
            normalIds.insert(clipId, at: insertAt)

            // Assign manualOrder to all visible normal clips
            for (index, id) in normalIds.enumerated() {
                try db.execute(
                    sql: "UPDATE clips SET manualOrder = ?, updatedAt = ? WHERE id = ?",
                    arguments: [index, now, id]
                )
            }
        }
    }

    /// Pin a clip and insert at a specific position among pinned clips
    func pinClipAtPosition(clipId: Int64, position: Int) throws {
        let now = Date()
        try dbPool.write { db in
            // Get current pinned clip IDs
            var pinnedIds = try Int64.fetchAll(db, sql: """
                SELECT id FROM clips
                WHERE isPinned = 1 AND isDeleted = 0
                ORDER BY pinOrder ASC, lastCopiedAt DESC
            """)

            // Insert at position
            let insertAt = min(position, pinnedIds.count)
            pinnedIds.insert(clipId, at: insertAt)

            // Mark the clip as pinned, clear manualOrder
            try db.execute(
                sql: "UPDATE clips SET isPinned = 1, manualOrder = NULL, updatedAt = ? WHERE id = ?",
                arguments: [now, clipId]
            )

            // Reassign all pinOrder values
            for (index, id) in pinnedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE clips SET pinOrder = ?, updatedAt = ? WHERE id = ?",
                    arguments: [index, now, id]
                )
            }
        }
    }

    /// Unpin a clip and insert at a specific position among normal clips
    func unpinClipAtPosition(clipId: Int64, position: Int) throws {
        let now = Date()
        try dbPool.write { db in
            // Unpin and clear pinOrder
            try db.execute(
                sql: "UPDATE clips SET isPinned = 0, pinOrder = NULL, updatedAt = ? WHERE id = ?",
                arguments: [now, clipId]
            )

            // Recompact remaining pinned clips
            try Self.recompactPinOrder(db)

            // Get all normal clips in current order
            var normalIds = try Int64.fetchAll(db, sql: """
                SELECT id FROM clips
                WHERE isPinned = 0 AND isDeleted = 0
                ORDER BY manualOrder ASC NULLS LAST, lastCopiedAt DESC
                LIMIT 200
            """)

            // Remove if already present (just unpinned)
            normalIds.removeAll { $0 == clipId }

            // Insert at position
            let insertAt = min(position, normalIds.count)
            normalIds.insert(clipId, at: insertAt)

            // Assign manualOrder to all
            for (index, id) in normalIds.enumerated() {
                try db.execute(
                    sql: "UPDATE clips SET manualOrder = ?, updatedAt = ? WHERE id = ?",
                    arguments: [index, now, id]
                )
            }
        }
    }

    // MARK: - AI Category (v11)

    func updateAICategory(id: Int64, category: String, generatedAt: Date) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET aiCategory = ?, aiCategoryGeneratedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [category, generatedAt, Date(), id]
            )
        }
    }

    /// Clips eligible for AI classification without aiCategory yet.
    /// Includes text/code with contentText, plus image clips whose OCR produced text.
    func fetchUnclassifiedTextClips() throws -> [Clip] {
        try dbPool.read { db in
            try Clip.fetchAll(db, sql: """
                SELECT * FROM clips
                WHERE isDeleted = 0
                  AND aiCategory IS NULL
                  AND (
                    ((contentType = 'text' OR contentType = 'code') AND contentText IS NOT NULL)
                    OR (contentType = 'image' AND ocrText IS NOT NULL AND LENGTH(TRIM(ocrText)) >= 5)
                  )
                ORDER BY createdAt DESC
            """)
        }
    }

    /// All clips eligible for AI classification, regardless of existing aiCategory. For force re-classify.
    func fetchAllTextClips() throws -> [Clip] {
        try dbPool.read { db in
            try Clip.fetchAll(db, sql: """
                SELECT * FROM clips
                WHERE isDeleted = 0
                  AND (
                    ((contentType = 'text' OR contentType = 'code') AND contentText IS NOT NULL)
                    OR (contentType = 'image' AND ocrText IS NOT NULL AND LENGTH(TRIM(ocrText)) >= 5)
                  )
                ORDER BY createdAt DESC
            """)
        }
    }

    /// Clear aiCategory for all clips. Used before a full re-classify.
    func clearAllAICategories() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE clips SET aiCategory = NULL, aiCategoryGeneratedAt = NULL")
        }
    }

    // MARK: - OG Metadata

    func updateOGMetadata(clipId: Int64, title: String?, thumbnailData: Data?, fetchedAt: Date) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET ogTitle = ?, thumbnail = ?, ogFetchedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [title, thumbnailData, fetchedAt, Date(), clipId]
            )
        }
    }

    // MARK: - Private Helpers

    private static func recompactPinOrder(_ db: Database) throws {
        let pinnedIds = try Int64.fetchAll(db, sql: """
            SELECT id FROM clips
            WHERE isPinned = 1 AND isDeleted = 0
            ORDER BY pinOrder ASC, lastCopiedAt DESC
        """)

        let now = Date()
        for (index, id) in pinnedIds.enumerated() {
            try db.execute(
                sql: "UPDATE clips SET pinOrder = ?, updatedAt = ? WHERE id = ?",
                arguments: [index, now, id]
            )
        }
    }

    // MARK: - Cross-device dedup
    //
    // Apple Universal Clipboard와 우리 CKSyncEngine sync가 같은 콘텐츠를
    // 두 경로로 가져오면 중복 클립이 생긴다. Mac↔iOS hash 알고리즘이 다르고
    // (xxHash64 vs SHA-256 prefix), Universal Clipboard가 이미지를 재인코딩
    // 하면 raw byte hash도 안 맞는다. 그래서 cross-device dedup은:
    //   - 텍스트: contentText 완전 일치
    //   - 이미지: imageHash 일치
    // 30초 윈도우로 Universal Clipboard latency 커버 + 사용자가 같은 콘텐츠
    // 의도적으로 다시 복사하는 케이스는 윈도우 밖에서 정상 저장.

    /// 다른 device에서 최근 N초 안에 sync로 들어온 동일 텍스트 클립 조회.
    func fetchRecentSyncedClip(
        withContentText text: String,
        otherThanDeviceId myDeviceId: String,
        window: TimeInterval
    ) throws -> Clip? {
        let cutoff = Date().addingTimeInterval(-window)
        return try dbPool.read { db in
            try Clip
                .filter(Column("contentText") == text)
                .filter(Column("deviceId") != myDeviceId)
                .filter(Column("ckLastSyncedAt") != nil)
                .filter(Column("ckLastSyncedAt") > cutoff)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)
        }
    }

    /// 다른 device에서 최근 N초 안에 sync로 들어온 동일 이미지 클립 조회.
    func fetchRecentSyncedClip(
        withImageHash hash: String,
        otherThanDeviceId myDeviceId: String,
        window: TimeInterval
    ) throws -> Clip? {
        let cutoff = Date().addingTimeInterval(-window)
        return try dbPool.read { db in
            try Clip
                .filter(Column("imageHash") == hash)
                .filter(Column("deviceId") != myDeviceId)
                .filter(Column("ckLastSyncedAt") != nil)
                .filter(Column("ckLastSyncedAt") > cutoff)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)
        }
    }

    /// 다른 device에서 최근 N초 안에 sync로 들어온 이미지 클립 (hash 무관).
    /// UC Stage-2 dedup용 — 플랫폼별 코덱 차이로 imageHash가 달라도 잡을 수 있음.
    func fetchRecentSyncedImageClip(
        otherThanDeviceId myDeviceId: String,
        window: TimeInterval
    ) throws -> Clip? {
        let cutoff = Date().addingTimeInterval(-window)
        return try dbPool.read { db in
            try Clip
                .filter(Column("contentType") == "image")
                .filter(Column("deviceId") != myDeviceId)
                .filter(Column("ckLastSyncedAt") != nil)
                .filter(Column("ckLastSyncedAt") > cutoff)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)
        }
    }

    // MARK: - Sync (delegated to ClipRavenSync.ClipSyncRepository)
    //
    // Sync-related DB ops live in the package so the iOS app can use them
    // verbatim. Mac keeps these wrappers for backward-compat with existing
    // callers (tests, AppDelegate plumbing) — they just construct a
    // `ClipSyncRepository(dbPool:)` and forward.

    private var syncRepo: ClipSyncRepository {
        ClipSyncRepository(dbPool: dbPool)
    }

    func fetchByUUID(_ uuid: String) throws -> Clip? {
        try syncRepo.fetchByUUID(uuid)
    }

    func applyUploadAck(records: [CKRecord]) async throws {
        try await syncRepo.applyUploadAck(records: records)
    }

    @discardableResult
    func applyServerChanges(
        modifications: [CKRecord],
        deletions: [CKRecord.ID]
    ) throws -> (inserted: Int, updated: Int, deleted: Int) {
        try syncRepo.applyServerChanges(modifications: modifications, deletions: deletions)
    }

    @discardableResult
    func applyServerChanges(
        modifications: [CKRecord],
        deletions: [CKRecord.ID]
    ) async throws -> (inserted: Int, updated: Int, deleted: Int) {
        try await syncRepo.applyServerChanges(modifications: modifications, deletions: deletions)
    }
}
