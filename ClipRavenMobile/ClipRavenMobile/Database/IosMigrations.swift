import GRDB
import Foundation
import ClipRavenSync

/// iOS-only 통합 마이그레이션. Mac의 v1~v13 누적 결과와 컬럼/인덱스가
/// 동일한 최종 스키마를 한 번에 만든다. `Clip`/`Tag`/`ClipTag` 모델이
/// 패키지에서 공유되므로 컬럼 정의는 정확히 일치해야 한다.
///
/// 새 sync 메타 컬럼은 `ClipRavenSync.SyncSchema.defineClipSyncColumns/
/// defineTagSyncColumns` 헬퍼로 정의 — Mac alter-column 경로와 정확히
/// 같은 정의를 공유함으로써 drift 방지.
///
/// 비-sync 컬럼은 Mac의 v1+v3+v5+v6+v10+v11 결과를 인라인으로 펼쳤다.
/// 이 부분은 패키지로 추출할 가치가 있지만(Mac과 lockstep), 지금은
/// iOS 전용 로컬 정의로 두고 향후 `SyncSchema.defineCoreClipColumns`
/// 같은 헬퍼가 생기면 이쪽도 거기로 옮긴다.
enum IosMigrations {
    static func registerAll(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_iosInitial") { db in
            // --- clips table (Mac v1~v11 누적 결과 + sync 컬럼) ---
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contentType", .text).notNull()
                t.column("contentText", .text)
                t.column("contentHash", .text)
                t.column("imageHash", .text)
                t.column("imageDhash", .integer)
                t.column("imagePath", .text)              // Mac-only field
                t.column("thumbnail", .blob)              // Mac-only field
                t.column("ocrText", .text)
                t.column("ocrConfidence", .double)
                t.column("sourceAppBundleId", .text)
                t.column("sourceAppName", .text)
                t.column("sourceUrl", .text)
                t.column("tagsText", .text).defaults(to: "")
                t.column("contentChosung", .text)         // Mac-only field
                t.column("pinOrder", .integer)
                t.column("manualOrder", .integer)
                t.column("copyCount", .integer).notNull().defaults(to: 1)
                t.column("nickname", .text)
                t.column("ogTitle", .text)
                t.column("ogFetchedAt", .datetime)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("expiresAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("lastCopiedAt", .datetime).notNull()
                // Mac-only: per-clip global hotkey (iOS doesn't register
                // Carbon hotkeys, but column exists so Clip struct decodes).
                t.column("customShortcutKeyCode", .integer)
                t.column("customShortcutModifiers", .integer)
                // AI categorization (works on iOS 18+ Apple Intelligence).
                t.column("aiCategory", .text)
                t.column("aiCategoryGeneratedAt", .datetime)
                // Sync metadata — same shape as Mac v12.
                SyncSchema.defineClipSyncColumns(t)
            }

            // --- tags table (Mac v1 + sync columns from v12) ---
            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("colorHex", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                SyncSchema.defineTagSyncColumns(t)
            }

            // --- clip_tags junction table ---
            try db.create(table: "clipTags") { t in
                t.column("clipId", .integer).notNull().references("clips", onDelete: .cascade)
                t.column("tagId", .integer).notNull().references("tags", onDelete: .cascade)
                t.primaryKey(["clipId", "tagId"])
            }

            // --- Indexes (Mac v1) ---
            try db.create(index: "idx_clips_contentHash", on: "clips", columns: ["contentHash"])
            try db.create(index: "idx_clips_imageHash", on: "clips", columns: ["imageHash"])
            try db.create(index: "idx_clips_createdAt", on: "clips", columns: ["createdAt"])
            try db.create(index: "idx_clips_contentType", on: "clips", columns: ["contentType"])
            try db.create(index: "idx_clips_isDeleted", on: "clips", columns: ["isDeleted"])
            try db.create(index: "idx_clips_isPinned", on: "clips", columns: ["isPinned"])
            try db.create(index: "idx_clips_chosung", on: "clips", columns: ["contentChosung"])
            try db.create(index: "idx_clips_expiresAt", on: "clips", columns: ["expiresAt"])

            // --- FTS5 (text search). Same shape as Mac so query syntax
            //     transfers verbatim if we eventually share search code. ---
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    contentText,
                    sourceAppName,
                    sourceUrl,
                    tagsText,
                    ocrText,
                    content='clips',
                    content_rowid='id',
                    tokenize='unicode61'
                )
                """)

            // FTS sync triggers
            try db.execute(sql: """
                CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, contentText, sourceAppName, sourceUrl, tagsText, ocrText)
                    VALUES (new.id, new.contentText, new.sourceAppName, new.sourceUrl, new.tagsText, new.ocrText);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, contentText, sourceAppName, sourceUrl, tagsText, ocrText)
                    VALUES('delete', old.id, old.contentText, old.sourceAppName, old.sourceUrl, old.tagsText, old.ocrText);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, contentText, sourceAppName, sourceUrl, tagsText, ocrText)
                    VALUES('delete', old.id, old.contentText, old.sourceAppName, old.sourceUrl, old.tagsText, old.ocrText);
                    INSERT INTO clips_fts(rowid, contentText, sourceAppName, sourceUrl, tagsText, ocrText)
                    VALUES (new.id, new.contentText, new.sourceAppName, new.sourceUrl, new.tagsText, new.ocrText);
                END
                """)

            // --- Tag triggers (denormalized tagsText on clips, fix from Mac v2) ---
            try db.execute(sql: """
                CREATE TRIGGER clip_tags_ai AFTER INSERT ON clipTags BEGIN
                    UPDATE clips SET tagsText = (
                        SELECT COALESCE(GROUP_CONCAT(t.name, ' '), '')
                        FROM clipTags ct JOIN tags t ON ct.tagId = t.id
                        WHERE ct.clipId = new.clipId
                    )
                    WHERE id = new.clipId;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clip_tags_ad AFTER DELETE ON clipTags BEGIN
                    UPDATE clips SET tagsText = (
                        SELECT COALESCE(GROUP_CONCAT(t.name, ' '), '')
                        FROM clipTags ct JOIN tags t ON ct.tagId = t.id
                        WHERE ct.clipId = old.clipId
                    )
                    WHERE id = old.clipId;
                END
                """)

            // --- Sync metadata indexes (uuid unique + ckSyncState) ---
            try SyncSchema.createSyncIndexes(db)

            // --- Sync engine state + device registry (Mac v13 equivalent) ---
            try SyncSchema.createSyncEngineTables(db)
            try SyncSchema.seedThisDevice(db)
        }
    }
}
