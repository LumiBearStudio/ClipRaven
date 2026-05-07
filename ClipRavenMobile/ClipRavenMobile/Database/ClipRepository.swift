import Foundation
import GRDB
import ClipRavenSync

enum DateRangeFilter: String, CaseIterable, Identifiable {
    // rawValue 는 ID 용 (영문 stable key) — UI 표시는 displayName 사용.
    case today
    case thisWeek
    case thisMonth

    var id: String { rawValue }

    /// 사용자 노출용 — String(localized:) 를 거쳐 ko/en 자동 선택.
    var displayName: String {
        switch self {
        case .today:     return String(localized: "오늘")
        case .thisWeek:  return String(localized: "이번 주")
        case .thisMonth: return String(localized: "이번 달")
        }
    }

    var startDate: Date {
        let cal = Calendar.current
        switch self {
        case .today:     return cal.startOfDay(for: Date())
        case .thisWeek:  return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? cal.startOfDay(for: Date())
        case .thisMonth: return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? cal.startOfDay(for: Date())
        }
    }

    var icon: String {
        switch self {
        case .today:     return "sun.max"
        case .thisWeek:  return "calendar.badge.clock"
        case .thisMonth: return "calendar"
        }
    }
}

/// iOS-specific clip repository — domain CRUD that the iOS UI needs.
///
/// Mac has a richer `ClipRepository` (Carbon hotkeys, smart-rule auto-tag,
/// AI categorization triggers, paste-stack, FTS search). iOS strips that
/// down to the operations the prototype list view uses: list, fetch one,
/// soft-delete, insert. Sync ops (`fetchByUUID`, `applyServerChanges`,
/// `applyUploadAck`) live in the package's `ClipSyncRepository` and are
/// wired into `SyncEngine` directly — this type just handles the local
/// reads/writes that the iOS UI initiates.
struct ClipRepository {

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
    }

    // MARK: - Sort order (mirrors Mac repo)

    private static let displayOrder = [
        Column("isPinned").desc,
        Column("pinOrder").asc,
        Column("manualOrder").asc,
        Column("lastCopiedAt").desc,
    ]

    // MARK: - Read

    func fetchAll(limit: Int = 200) throws -> [Clip] {
        try dbPool.read { db in
            try Clip
                .filter(Column("isDeleted") == false)
                .order(Self.displayOrder)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchOne(uuid: String) throws -> Clip? {
        try dbPool.read { db in
            try Clip.filter(Column("uuid") == uuid).fetchOne(db)
        }
    }

    func count() throws -> Int {
        try dbPool.read { db in
            try Clip.filter(Column("isDeleted") == false).fetchCount(db)
        }
    }

    func count(contentType: ContentType) throws -> Int {
        try dbPool.read { db in
            try Clip
                .filter(Column("isDeleted") == false)
                .filter(Column("contentType") == contentType.rawValue)
                .fetchCount(db)
        }
    }

    // MARK: - Live Observation (필터 포함)

    /// GRDB ValueObservation — 필터/태그 변경 시 `restartObservation()` 에서
    /// 새 cancellable로 교체. Mac MainPanelViewModel과 동일 패턴.
    func observeAll(
        contentType: ContentType? = nil,
        tagIds: Set<Int64> = [],
        sourceApp: String? = nil,
        dateRange: DateRangeFilter? = nil,
        aiCategory: String? = nil,
        onChange: @escaping ([Clip]) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db -> [Clip] in
            var request = Clip
                .filter(Column("isDeleted") == false)
                .order(Self.displayOrder)
                .limit(200)

            if !tagIds.isEmpty {
                let clipIds = try ClipTag
                    .filter(tagIds.contains(Column("tagId")))
                    .select(Column("clipId"))
                    .asRequest(of: Int64.self)
                    .fetchAll(db)
                request = request.filter(clipIds.contains(Column("id")))
            }
            if let contentType {
                request = request.filter(Column("contentType") == contentType.rawValue)
            }
            if let sourceApp {
                request = request.filter(Column("sourceAppName") == sourceApp)
            }
            if let dateRange {
                request = request.filter(Column("createdAt") >= dateRange.startDate)
            }
            if let aiCategory {
                request = request.filter(Column("aiCategory") == aiCategory)
            }
            return try request.fetchAll(db)
        }

        return observation.start(
            in: dbPool,
            onError: { _ in },
            onChange: onChange
        )
    }

    // MARK: - FTS Search

    /// FTS5 전문 검색 + contentType / tagIds 교차 필터.
    /// Mac SearchRepository의 핵심 로직을 iOS에 이식.
    func search(
        query: String,
        contentType: ContentType? = nil,
        tagIds: Set<Int64> = [],
        sourceApp: String? = nil,
        dateRange: DateRangeFilter? = nil,
        aiCategory: String? = nil,
        limit: Int = 100
    ) throws -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let ftsQuery = buildFTSQuery(trimmed)

        return try dbPool.read { db in
            var allowedIds: Set<Int64>? = nil

            if !tagIds.isEmpty {
                let ids = try ClipTag
                    .filter(tagIds.contains(Column("tagId")))
                    .select(Column("clipId"))
                    .asRequest(of: Int64.self)
                    .fetchAll(db)
                allowedIds = Set(ids)
            }

            var sql = """
                SELECT clips.*
                FROM clips
                JOIN clips_fts ON clips_fts.rowid = clips.id
                WHERE clips_fts MATCH ?
                  AND clips.isDeleted = 0
                """
            var args: [DatabaseValueConvertible] = [ftsQuery]

            if let ct = contentType {
                sql += " AND clips.contentType = ?"
                args.append(ct.rawValue)
            }
            if let ids = allowedIds {
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                sql += " AND clips.id IN (\(placeholders))"
                args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible })
            }
            if let app = sourceApp {
                sql += " AND clips.sourceAppName = ?"
                args.append(app)
            }
            if let dr = dateRange {
                sql += " AND clips.createdAt >= ?"
                args.append(dr.startDate)
            }
            if let cat = aiCategory {
                sql += " AND clips.aiCategory = ?"
                args.append(cat)
            }

            sql += " ORDER BY clips.isPinned DESC, bm25(clips_fts) ASC LIMIT ?"
            args.append(limit)

            return try Clip.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    private func buildFTSQuery(_ raw: String) -> String {
        let tokens = raw.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return tokens.map { "\($0)*" }.joined(separator: " ")
    }

    // MARK: - Chosung Search

    /// 초성 전용 검색 — contentChosung 컬럼 LIKE 매칭.
    /// Mac SearchRepository와 동일 전략.
    func searchChosung(
        query: String,
        contentType: ContentType? = nil,
        tagIds: Set<Int64> = [],
        sourceApp: String? = nil,
        dateRange: DateRangeFilter? = nil,
        aiCategory: String? = nil,
        limit: Int = 100
    ) throws -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 쿼리 자체의 초성 추출 (이미 초성이면 그대로, 한글 섞이면 초성만 추출)
        let chosungQuery = ChosungConverter.extractChosung(from: trimmed).isEmpty
            ? trimmed  // 순수 자음 쿼리 그대로
            : ChosungConverter.extractChosung(from: trimmed)

        let pattern = "%\(chosungQuery)%"

        return try dbPool.read { db in
            var allowedIds: Set<Int64>? = nil
            if !tagIds.isEmpty {
                let ids = try ClipTag
                    .filter(tagIds.contains(Column("tagId")))
                    .select(Column("clipId"))
                    .asRequest(of: Int64.self)
                    .fetchAll(db)
                allowedIds = Set(ids)
            }

            var sql = """
                SELECT * FROM clips
                WHERE isDeleted = 0
                  AND contentChosung LIKE ?
                """
            var args: [DatabaseValueConvertible] = [pattern]

            if let ct = contentType { sql += " AND contentType = ?"; args.append(ct.rawValue) }
            if let app = sourceApp  { sql += " AND sourceAppName = ?"; args.append(app) }
            if let dr = dateRange   { sql += " AND createdAt >= ?"; args.append(dr.startDate) }
            if let cat = aiCategory { sql += " AND aiCategory = ?"; args.append(cat) }
            if let ids = allowedIds {
                let ph = ids.map { _ in "?" }.joined(separator: ",")
                sql += " AND id IN (\(ph))"
                args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible })
            }

            sql += " ORDER BY isPinned DESC, lastCopiedAt DESC LIMIT ?"
            args.append(limit)

            return try Clip.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: - Insert (image)

    /// Insert a new image clip captured locally (iOS UIPasteboard).
    ///
    /// - Parameter thumbnail: ~200×200 JPEG (보통 10–50KB). 항상 저장.
    /// - Parameter imageHash: 원본 이미지의 SHA-256 hex (dedup 키).
    /// - Parameter imagePath: 원본 이미지의 App Group 상대경로(파일명).
    ///   nil 이면 thumbnail-only 모드 — 원본은 디스크에 없음.
    ///
    /// Phase C: ImageSyncSettings.full 일 때 caller (PasteboardCaptureService)
    /// 가 ImageStorageService.saveImage() 로 원본을 먼저 저장하고 그 파일명을
    /// imagePath 로 전달. SyncRecordMapper 가 이 imagePath 로부터 CKAsset을
    /// 만들어 다른 디바이스로 전송한다.
    @discardableResult
    func insertImage(
        thumbnail: Data,
        imageHash: String,
        imagePath: String? = nil
    ) throws -> Clip {
        let now = Date()
        var clip = Clip(
            contentType: .image,
            imageHash: imageHash,
            imagePath: imagePath,
            thumbnail: thumbnail,
            sourceAppName: nil,
            createdAt: now,
            lastCopiedAt: now,
            uuid: UUID().uuidString,
            deviceId: DeviceIdentity.deviceId,
            schemaVersion: 1,
            updatedAt: now,
            excludeFromSync: false  // 이미지는 캡처 단계에서 SyncFilters 적용 X
                                    // (텍스트 기반 정규식이 의미 없음)
        )
        try dbPool.write { db in
            try clip.save(db)
        }
        return clip
    }

    // MARK: - Dedup helpers (Mac ClipProcessor 와 같은 패턴)

    /// 같은 contentHash 의 클립이 있으면 copyCount + 1 후 그 클립 반환.
    /// 없으면 nil — 호출 측에서 정상 INSERT 진행.
    @discardableResult
    func incrementIfExists(contentHash: String) throws -> Clip? {
        try dbPool.write { db in
            guard let existing = try Clip
                .filter(Column("contentHash") == contentHash)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)
            else { return nil }
            try db.execute(
                sql: "UPDATE clips SET copyCount = copyCount + 1, lastCopiedAt = ? WHERE id = ?",
                arguments: [Date(), existing.id ?? -1]
            )
            return existing
        }
    }

    /// 같은 imageHash 의 이미지 클립이 있으면 copyCount + 1 후 반환.
    @discardableResult
    func incrementIfExists(imageHash: String) throws -> Clip? {
        try dbPool.write { db in
            guard let existing = try Clip
                .filter(Column("imageHash") == imageHash)
                .filter(Column("isDeleted") == false)
                .fetchOne(db)
            else { return nil }
            try db.execute(
                sql: "UPDATE clips SET copyCount = copyCount + 1, lastCopiedAt = ? WHERE id = ?",
                arguments: [Date(), existing.id ?? -1]
            )
            return existing
        }
    }

    // MARK: - Insert (text)

    /// Insert a new clip with sync metadata stamped. Used by foreground
    /// paste capture, Share Extension, and "Add" button in the prototype.
    ///
    /// Hash 통일: Mac과 iOS 모두 `TextNormalizer.normalize` 후
    /// `XXHash64Wrapper.hash` 적용. 같은 텍스트면 device 무관하게 같은
    /// contentHash → cross-device dedup이 hash 매칭으로 빠르게 잡힘.
    @discardableResult
    func insert(text: String, sourceAppBundleId: String? = nil) throws -> Clip {
        let now = Date()
        let normalized = TextNormalizer.normalize(text)
        let hash = XXHash64Wrapper.hash(normalized)

        let chosung = ChosungConverter.extractChosung(from: text)

        var clip = Clip(
            contentType: .text,
            contentText: text,
            contentHash: hash,
            sourceAppBundleId: sourceAppBundleId,
            sourceAppName: nil,
            createdAt: now,
            lastCopiedAt: now,
            uuid: UUID().uuidString,
            deviceId: DeviceIdentity.deviceId,
            schemaVersion: 1,
            updatedAt: now,
            excludeFromSync: SyncFilters.shouldExclude(
                text: text,
                sourceAppBundleId: sourceAppBundleId
            )
        )
        clip.contentChosung = chosung.isEmpty ? nil : chosung

        try dbPool.write { db in
            try clip.save(db)
        }
        return clip
    }

    // MARK: - Update

    /// Soft-delete (sets `isDeleted = 1` and bumps `updatedAt`). The sync
    /// engine will replicate this to other devices via the normal upload
    /// path — `SyncChangeCapture` sees `isDeleted` flipped → enqueueDelete.
    func softDelete(uuid: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET isDeleted = 1, updatedAt = ? WHERE uuid = ?",
                arguments: [Date(), uuid]
            )
        }
    }

    func incrementCopyCount(id: Int64) throws {
        let now = Date()
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET copyCount = copyCount + 1, lastCopiedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    func updateNickname(uuid: String, nickname: String?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET nickname = ?, updatedAt = ? WHERE uuid = ?",
                arguments: [nickname?.nilIfEmpty, Date(), uuid]
            )
        }
    }

    func updateContentTextAndNickname(uuid: String, newText: String, nickname: String?) throws {
        let normalized = TextNormalizer.normalize(newText)
        let hash = XXHash64Wrapper.hash(normalized)
        let chosung = ChosungConverter.extractChosung(from: newText)
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE clips
                    SET contentText = ?, contentHash = ?, contentChosung = ?,
                        nickname = ?, updatedAt = ?
                    WHERE uuid = ?
                    """,
                arguments: [newText, hash, chosung.isEmpty ? nil : chosung,
                            nickname?.nilIfEmpty, Date(), uuid]
            )
        }
    }

    func toggleExcludeFromSync(uuid: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET excludeFromSync = NOT excludeFromSync, updatedAt = ? WHERE uuid = ?",
                arguments: [Date(), uuid]
            )
        }
    }

    func updateContentText(uuid: String, newText: String) throws {
        let normalized = TextNormalizer.normalize(newText)
        let hash = XXHash64Wrapper.hash(normalized)
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE clips
                    SET contentText = ?, contentHash = ?, updatedAt = ?
                    WHERE uuid = ?
                    """,
                arguments: [newText, hash, Date(), uuid]
            )
        }
    }


    func fetchSourceApps() throws -> [String] {
        try dbPool.read { db in
            let rows = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT sourceAppName FROM clips
                    WHERE isDeleted = 0 AND sourceAppName IS NOT NULL AND sourceAppName != ''
                    ORDER BY sourceAppName
                    """
            )
            return rows
        }
    }

    func togglePin(uuid: String) throws {
        try dbPool.write { db in
            guard var clip = try Clip.filter(Column("uuid") == uuid).fetchOne(db) else { return }
            clip.isPinned.toggle()
            clip.updatedAt = Date()
            // pinOrder management — assign tail position when pinning,
            // clear when unpinning. iOS doesn't manage pinOrder compaction
            // (Mac does it on every toggle); for now duplicates are OK.
            if clip.isPinned {
                let max = try Int.fetchOne(db, sql:
                    "SELECT COALESCE(MAX(pinOrder), -1) FROM clips WHERE isPinned = 1 AND isDeleted = 0"
                ) ?? -1
                clip.pinOrder = max + 1
            } else {
                clip.pinOrder = nil
            }
            try clip.update(db)
        }
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
