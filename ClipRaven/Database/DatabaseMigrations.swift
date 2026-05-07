import GRDB
import Foundation
import ClipRavenSync

enum DatabaseMigrations {
    static func registerAll(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            // --- clips table ---
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contentType", .text).notNull()
                t.column("contentText", .text)
                t.column("contentHash", .text)
                t.column("imageHash", .text)
                t.column("imageDhash", .integer)
                t.column("imagePath", .text)
                t.column("thumbnail", .blob)
                t.column("ocrText", .text)
                t.column("ocrConfidence", .double)
                t.column("sourceAppBundleId", .text)
                t.column("sourceAppName", .text)
                t.column("sourceUrl", .text)
                t.column("tagsText", .text).defaults(to: "")
                t.column("contentChosung", .text)
                t.column("copyCount", .integer).notNull().defaults(to: 1)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("expiresAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("lastCopiedAt", .datetime).notNull()
            }

            // --- tags table ---
            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("colorHex", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // --- clip_tags junction table ---
            try db.create(table: "clipTags") { t in
                t.column("clipId", .integer).notNull().references("clips", onDelete: .cascade)
                t.column("tagId", .integer).notNull().references("tags", onDelete: .cascade)
                t.primaryKey(["clipId", "tagId"])
            }

            // --- paste_stack table ---
            try db.create(table: "pasteStack") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("clipId", .integer).notNull().references("clips")
                t.column("sortOrder", .integer).notNull()
                t.column("isPasted", .boolean).notNull().defaults(to: false)
                t.column("addedAt", .datetime).notNull()
            }

            // --- Indexes ---
            try db.create(index: "idx_clips_contentHash", on: "clips", columns: ["contentHash"])
            try db.create(index: "idx_clips_imageHash", on: "clips", columns: ["imageHash"])
            try db.create(index: "idx_clips_createdAt", on: "clips", columns: ["createdAt"])
            try db.create(index: "idx_clips_contentType", on: "clips", columns: ["contentType"])
            try db.create(index: "idx_clips_isDeleted", on: "clips", columns: ["isDeleted"])
            try db.create(index: "idx_clips_isPinned", on: "clips", columns: ["isPinned"])
            try db.create(index: "idx_clips_chosung", on: "clips", columns: ["contentChosung"])
            try db.create(index: "idx_clips_expiresAt", on: "clips", columns: ["expiresAt"])

            // --- FTS5 Virtual Table (external content) ---
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

            // --- FTS5 Sync Triggers ---
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

            // --- Tag sync triggers (update denormalized tagsText in clips) ---
            try db.execute(sql: """
                CREATE TRIGGER clip_tags_ai AFTER INSERT ON clipTags BEGIN
                    UPDATE clips SET tagsText = (
                        SELECT COALESCE(GROUP_CONCAT(t.name, ' '), '')
                        FROM clipTags ct JOIN tags t ON ct.tagId = t.id
                        WHERE ct.clipId = new.clipId
                    ), lastCopiedAt = datetime('now')
                    WHERE id = new.clipId;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clip_tags_ad AFTER DELETE ON clipTags BEGIN
                    UPDATE clips SET tagsText = (
                        SELECT COALESCE(GROUP_CONCAT(t.name, ' '), '')
                        FROM clipTags ct JOIN tags t ON ct.tagId = t.id
                        WHERE ct.clipId = old.clipId
                    ), lastCopiedAt = datetime('now')
                    WHERE id = old.clipId;
                END
                """)
        }

        // MARK: - v2: Fix tag triggers + backfill chosung
        migrator.registerMigration("v2") { db in
            // 1) Fix tag triggers: remove lastCopiedAt update so tag assignment
            //    doesn't cause cards to jump to the front
            try db.execute(sql: "DROP TRIGGER IF EXISTS clip_tags_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clip_tags_ad")

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

            // 2) Backfill contentChosung for existing clips that have text but no chosung
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, contentText FROM clips
                WHERE contentText IS NOT NULL
                  AND (contentChosung IS NULL OR contentChosung = '')
                  AND isDeleted = 0
            """)

            for row in rows {
                let id: Int64 = row["id"]
                let text: String = row["contentText"]
                let chosung = ChosungConverter.extractChosung(from: text)
                if !chosung.isEmpty {
                    try db.execute(
                        sql: "UPDATE clips SET contentChosung = ? WHERE id = ?",
                        arguments: [chosung, id]
                    )
                }
            }
        }

        // MARK: - v3: Add pinOrder + manualOrder for drag-and-drop reordering
        migrator.registerMigration("v3") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "pinOrder", .integer)
                t.add(column: "manualOrder", .integer)
            }

            try db.create(
                index: "idx_clips_pinOrder",
                on: "clips",
                columns: ["pinOrder"]
            )

            // Backfill pinOrder for existing pinned clips (ordered by lastCopiedAt DESC)
            let pinnedRows = try Row.fetchAll(db, sql: """
                SELECT id FROM clips
                WHERE isPinned = 1 AND isDeleted = 0
                ORDER BY lastCopiedAt DESC
            """)

            for (index, row) in pinnedRows.enumerated() {
                let id: Int64 = row["id"]
                try db.execute(
                    sql: "UPDATE clips SET pinOrder = ? WHERE id = ?",
                    arguments: [index, id]
                )
            }
        }

        // MARK: - v4: Add nickname column for custom clip titles
        migrator.registerMigration("v4") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "nickname", .text)
            }
        }

        // MARK: - v5: Smart Rules (auto-tagging)
        migrator.registerMigration("v5") { db in
            try db.create(table: "smartRules") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("conditionJson", .blob).notNull()
                t.column("actionTagId", .integer).notNull()
                    .references("tags", onDelete: .cascade)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // MARK: - v7: OG Metadata columns for URL clips
        // ogTitle: 페이지 타이틀 (LPMetadataProvider)
        // ogFetchedAt: 마지막 fetch 시각 (nil = 미시도)
        // thumbnail(기존 BLOB): URL clips의 OG 이미지를 여기에 저장
        migrator.registerMigration("v7") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "ogTitle",     .text)
                t.add(column: "ogFetchedAt", .datetime)
            }
        }

        // MARK: - v8: SmartRule multi-action support
        migrator.registerMigration("v8_smartRuleMultiAction") { db in
            try db.alter(table: "smartRules") { t in
                t.add(column: "actionsJson", .blob)
            }
        }

        // MARK: - v9: Drop NOT NULL + FK constraint on actionTagId
        // v5에서 actionTagId NOT NULL로 생성했으나 새 multi-action 코드가
        // actionsJson만 쓰고 actionTagId를 설정 안 함 → INSERT 실패 방지
        migrator.registerMigration("v9_dropActionTagIdConstraint") { db in
            try db.execute(sql: """
                CREATE TABLE smartRules_temp (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    isEnabled BOOLEAN NOT NULL DEFAULT 1,
                    conditionJson BLOB NOT NULL,
                    actionTagId INTEGER,
                    actionsJson BLOB,
                    createdAt DATETIME NOT NULL
                )
            """)
            try db.execute(sql: """
                INSERT INTO smartRules_temp
                SELECT id, name, isEnabled, conditionJson, actionTagId, actionsJson, createdAt
                FROM smartRules
            """)
            try db.execute(sql: "DROP TABLE smartRules")
            try db.execute(sql: "ALTER TABLE smartRules_temp RENAME TO smartRules")
        }

        // MARK: - v6: Backfill imageDhash for existing image clips
        // Previous builds stored NULL for all images due to a bug where
        // NSBitmapImageRep(cgImage:) did not expose pixels to colorAt(x:y:),
        // and cgImage(forProposedRect:nil,...) returned nil for TIFF-backed images
        // on background threads. The fixed DHash implementation uses CGImageSource +
        // pure CGContext pixel reads. This migration recomputes the hash for every
        // image clip that has a saved imagePath but no imageDhash.
        migrator.registerMigration("v6") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, imagePath FROM clips
                WHERE contentType = 'image'
                  AND imageDhash IS NULL
                  AND imagePath IS NOT NULL
                  AND isDeleted = 0
            """)

            for row in rows {
                let id: Int64 = row["id"]
                let relativePath: String = row["imagePath"]

                guard let imageData = ImageStorageService.loadImage(relativePath: relativePath),
                      let dHash = DHash.compute(from: imageData)
                else { continue }

                try db.execute(
                    sql: "UPDATE clips SET imageDhash = ? WHERE id = ?",
                    arguments: [dHash, id]
                )
            }
        }

        // MARK: - v10: Per-clip custom global hotkeys
        // Lets a user assign a global shortcut (e.g. ⌘⇧E) to any clip so the clip
        // pastes directly into the frontmost app without opening the panel.
        //   customShortcutKeyCode  — Carbon virtual key code (nil if no shortcut)
        //   customShortcutModifiers — Carbon modifier bitmask (cmdKey | shiftKey | ...)
        migrator.registerMigration("v10_customShortcuts") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "customShortcutKeyCode", .integer)
                t.add(column: "customShortcutModifiers", .integer)
            }
        }

        // MARK: - v11: AI category fields (Foundation Models, macOS 26+)
        //   aiCategory            — e.g. "receipt", "meeting", "code", "email", nil = uncategorized
        //   aiCategoryGeneratedAt — timestamp when the category was last assigned by the model
        migrator.registerMigration("v11_aiCategory") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "aiCategory", .text)
                t.add(column: "aiCategoryGeneratedAt", .datetime)
            }
        }

        // MARK: - v12: iCloud sync metadata
        //
        // Adds the columns every row needs to participate in CloudKit sync.
        // This migration only ensures the schema is ready and existing rows
        // are backfilled with a stable uuid + origin deviceId so nothing
        // needs to be touched later.
        //
        // Column rationale:
        //   uuid             — CKRecord.recordName. Globally unique across devices.
        //                      Nullable in DB (backfilled below) so we don't fail on
        //                      pre-existing rows; new inserts are expected to supply one.
        //   deviceId         — Origin device. Needed for "iPhone에서 복사" UI and to
        //                      ignore our own changes echoing back through CloudKit.
        //   schemaVersion    — Per-record schema version. Forward-compat for future
        //                      field additions (CloudKit schema is additive-only).
        //   updatedAt        — Server LWW basis for mutable fields.
        //   ckSystemFields   — encodeSystemFields() blob. Required to preserve
        //                      server change tags across local edits; without it the
        //                      next upload becomes a "first save" and clobbers.
        //   ckSyncState      — 0 synced / 1 pendingUpload / 2 pendingDelete / 3 conflict.
        //   ckLastSyncedAt   — Last successful server round-trip (debugging/UX).
        //   excludeFromSync  — Set by SyncFilters + user blacklist. Capture stays
        //                      local on this device only.
        migrator.registerMigration("v12_syncMeta") { db in
            // Column shape, defaults, and indexes live in `ClipRavenSync.SyncSchema`
            // so iOS can replicate them verbatim. Backfill is Mac-only because
            // iOS has no legacy rows.
            try db.alter(table: "clips") { t in
                SyncSchema.addClipSyncColumns(t)
            }
            try db.alter(table: "tags") { t in
                SyncSchema.addTagSyncColumns(t)
            }

            try SyncSchema.backfillExistingRows(db, deviceId: DeviceIdentity.deviceId)
            try SyncSchema.createSyncIndexes(db)
        }

        // MARK: - v13: Sync engine state + device registry (Phase A scaffolding)
        //
        // `sync_engine_state` persists `CKSyncEngine.State.Serialization` blobs
        // and zone-level change tokens. Keeping it inside the same SQLite file
        // (rather than a separate plist) lets `ChangeCapture` enqueue pending
        // uploads in the *same* GRDB transaction as the local insert — so a
        // crash can never leave a row persisted without its sync intent.
        //
        // `device_registry` is populated from every peer's DeviceMeta CKRecord
        // so Settings → Sync can list "Mac Studio · 마지막 동기화: 3분 전".
        migrator.registerMigration("v13_syncEngineState") { db in
            try SyncSchema.createSyncEngineTables(db)
            try SyncSchema.seedThisDevice(db)
        }
    }
}
