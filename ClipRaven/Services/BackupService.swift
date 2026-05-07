import Foundation
import AppKit
import GRDB
import ClipRavenSync

/// Full backup / restore for ClipRaven.
///
/// **File format:** ZIP archive (`.zip`) with the following layout:
/// ```
/// ClipRaven-Backup-2026-04-16.zip
/// ├── backup.json     ← clips, tags, clipTags, smartRules (Codable)
/// └── images/         ← ORIGINAL image files referenced by clips
///     ├── abc.png
///     └── def.png
/// ```
///
/// Thumbnails (small JPEGs in `Clip.thumbnail`) ride inside the JSON for instant display;
/// original images are copied so that a full restore on another machine rebuilds everything
/// — including image paste fidelity. This fixes the previous v1 issue where restored
/// image clips had only thumbnails, not full-resolution originals.
///
/// **Legacy:** Import also accepts plain `.json` files exported by earlier builds.
/// Those restore thumbnails only — originals are still missing but the card renders.
final class BackupService {
    static let shared = BackupService()

    private let clipRepository = ClipRepository()
    private let tagRepository = TagRepository()
    private let smartRuleRepository = SmartRuleRepository()

    private init() {}

    /// Current backup payload version. Bump on schema changes.
    static let currentVersion = 1

    // MARK: - Payload

    struct BackupPayload: Codable {
        let version: Int
        let exportedAt: Date
        let appVersion: String
        let clips: [Clip]
        let tags: [Tag]
        let clipTags: [ClipTag]
        let smartRules: [SmartRule]
    }

    // MARK: - Export

    /// Collect all user data, bundle the referenced image originals, and write a ZIP to `url`.
    /// Returns the number of clips exported (for the user-facing success toast).
    /// Called from a background Task — sync internally; GRDB's DatabasePool is thread-safe.
    @discardableResult
    func exportBackup(to url: URL) throws -> Int {
        let fm = FileManager.default

        // 1) Stage output in a fresh temp directory
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("clipraven-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        // 2) Gather records
        let clips = try clipRepository.fetchAllForExport()
        let tags = try tagRepository.fetchAll()
        let clipTags = try clipRepository.fetchAllClipTagsForExport()
        let rules = try smartRuleRepository.fetchAll()

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

        // 3) Write backup.json
        let payload = BackupPayload(
            version: Self.currentVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            clips: clips,
            tags: tags,
            clipTags: clipTags,
            smartRules: rules
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonURL = stagingDir.appendingPathComponent("backup.json")
        try encoder.encode(payload).write(to: jsonURL, options: .atomic)

        // 4) Copy referenced image files (originals) into images/
        let stagedImagesDir = stagingDir.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: stagedImagesDir, withIntermediateDirectories: true)
        let sourceImagesDir = ImageStorageService.imagesDirectory

        for clip in clips where clip.contentType == .image {
            guard let rel = clip.imagePath else { continue }
            let srcURL = sourceImagesDir.appendingPathComponent(rel)
            let dstURL = stagedImagesDir.appendingPathComponent(rel)
            if fm.fileExists(atPath: srcURL.path) {
                try? fm.copyItem(at: srcURL, to: dstURL)
            }
        }

        // 5) Zip the staging folder with NSFileCoordinator.forUploading.
        //    This creates a standard PKZip archive that macOS Finder can open inline.
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var innerError: Error?
        coordinator.coordinate(readingItemAt: stagingDir, options: [.forUploading], error: &coordError) { zippedURL in
            do {
                // Move into place — ensure destination is clear
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                try fm.copyItem(at: zippedURL, to: url)
            } catch {
                innerError = error
            }
        }
        if let err = coordError as Error? ?? innerError {
            throw err
        }

        return clips.count
    }

    // MARK: - Import

    enum ImportStrategy {
        /// Skip clips/tags that already exist (by hash / name). Keeps user's current data.
        case merge
        /// Wipe the database first, then restore everything from the backup.
        case overwrite
    }

    struct ImportResult {
        let clipsImported: Int
        let clipsSkipped: Int
        let tagsImported: Int
        let tagsSkipped: Int
        let rulesImported: Int
        let imagesRestored: Int
    }

    /// Read a backup (.zip or legacy .json) and restore its contents.
    /// - Parameters:
    ///   - url: backup file
    ///   - strategy: `.merge` or `.overwrite`
    /// Called from a background Task — sync internally.
    @discardableResult
    func importBackup(from url: URL, strategy: ImportStrategy) throws -> ImportResult {
        let fm = FileManager.default
        let ext = url.pathExtension.lowercased()

        // 1) Resolve the JSON payload + optional images directory
        let jsonData: Data
        let importedImagesDir: URL?
        var extractDir: URL?

        if ext == "zip" {
            // Extract ZIP to a temp folder via /usr/bin/ditto (always available on macOS, handles PKZip reliably)
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("clipraven-import-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            extractDir = tempDir

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            task.arguments = ["-x", "-k", url.path, tempDir.path]
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                throw BackupError.zipExtractionFailed(status: task.terminationStatus)
            }

            // Find backup.json at the root (NSFileCoordinator wraps the directory
            // name inside the zip, so also look one level deep).
            let rootJSON = tempDir.appendingPathComponent("backup.json")
            var jsonURL = rootJSON
            var imagesDir = tempDir.appendingPathComponent("images", isDirectory: true)
            if !fm.fileExists(atPath: rootJSON.path) {
                // Look for a single subdirectory wrapping our content
                let entries = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
                if let wrapper = entries.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) {
                    jsonURL = wrapper.appendingPathComponent("backup.json")
                    imagesDir = wrapper.appendingPathComponent("images", isDirectory: true)
                }
            }
            guard fm.fileExists(atPath: jsonURL.path) else {
                throw BackupError.missingBackupJSON
            }
            jsonData = try Data(contentsOf: jsonURL)
            importedImagesDir = fm.fileExists(atPath: imagesDir.path) ? imagesDir : nil
        } else {
            // Legacy plain-JSON import: no originals available
            jsonData = try Data(contentsOf: url)
            importedImagesDir = nil
        }
        defer { if let d = extractDir { try? fm.removeItem(at: d) } }

        // 2) Decode
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(BackupPayload.self, from: jsonData)
        guard payload.version <= Self.currentVersion else {
            throw BackupError.unsupportedVersion(payload.version)
        }

        // 3) DB restore (tag/clip ID remap for .merge)
        var tagIdMap: [Int64: Int64] = [:]
        var clipIdMap: [Int64: Int64] = [:]
        var clipsImported = 0
        var clipsSkipped = 0
        var tagsImported = 0
        var tagsSkipped = 0
        var rulesImported = 0

        try AppDatabase.shared.dbPool.write { db in
            if strategy == .overwrite {
                try db.execute(sql: "DELETE FROM clipTags")
                try db.execute(sql: "DELETE FROM clips")
                try db.execute(sql: "DELETE FROM tags")
                try db.execute(sql: "DELETE FROM smartRules")
            }

            // Tags — dedupe by unique name
            for importedTag in payload.tags {
                var tag = importedTag
                let oldId = tag.id ?? -1
                if strategy == .merge,
                   let existing = try Tag.filter(Column("name") == tag.name).fetchOne(db),
                   let existingId = existing.id {
                    tagIdMap[oldId] = existingId
                    tagsSkipped += 1
                    continue
                }
                tag.id = nil
                try tag.insert(db)
                if let newId = tag.id { tagIdMap[oldId] = newId }
                tagsImported += 1
            }

            // Clips — dedupe by contentHash (text/code/url/color),
            // imageHash (image), or contentText+contentType (file/other).
            for importedClip in payload.clips {
                var clip = importedClip
                let oldId = clip.id ?? -1
                if strategy == .merge,
                   let existingId = try Self.findExistingClipId(matching: clip, in: db) {
                    clipIdMap[oldId] = existingId
                    clipsSkipped += 1
                    continue
                }
                clip.id = nil
                try clip.insert(db)
                if let newId = clip.id { clipIdMap[oldId] = newId }
                clipsImported += 1
            }

            // Clip↔Tag joins — rewrite with remapped IDs
            for link in payload.clipTags {
                guard let newClipId = clipIdMap[link.clipId],
                      let newTagId = tagIdMap[link.tagId] else { continue }
                let remapped = ClipTag(clipId: newClipId, tagId: newTagId)
                _ = try? remapped.insert(db)
            }

            // Smart rules — dedupe by name, rewrite tagId in actions
            for importedRule in payload.smartRules {
                var rule = importedRule
                if strategy == .merge,
                   try SmartRule.filter(Column("name") == rule.name).fetchOne(db) != nil {
                    continue
                }
                rule.id = nil
                rule.actions = rule.actions.map { action in
                    switch action {
                    case .assignTag(let oldTagId):
                        return .assignTag(tagId: tagIdMap[oldTagId] ?? oldTagId)
                    default:
                        return action
                    }
                }
                try rule.insert(db)
                rulesImported += 1
            }
        }

        SmartRuleEngine.shared.reloadRules()

        // 4) Restore original image files (if backup contained images/)
        var imagesRestored = 0
        if let importedImagesDir {
            let destDir = ImageStorageService.imagesDirectory
            let entries = (try? fm.contentsOfDirectory(at: importedImagesDir, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let dstURL = destDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: dstURL.path) {
                    // Skip existing — user may want to keep their current copy
                    continue
                }
                do {
                    try fm.copyItem(at: entry, to: dstURL)
                    imagesRestored += 1
                } catch {
                    // Non-fatal — skip and continue
                    continue
                }
            }
        }

        return ImportResult(
            clipsImported: clipsImported,
            clipsSkipped: clipsSkipped,
            tagsImported: tagsImported,
            tagsSkipped: tagsSkipped,
            rulesImported: rulesImported,
            imagesRestored: imagesRestored
        )
    }

    // MARK: - Dedup helper

    /// Look for an existing live clip that corresponds to the imported one.
    /// Order: contentHash → imageHash → (contentText + contentType) fallback.
    private static func findExistingClipId(matching clip: Clip, in db: Database) throws -> Int64? {
        if let hash = clip.contentHash, !hash.isEmpty,
           let existing = try Clip
               .filter(Column("contentHash") == hash)
               .filter(Column("isDeleted") == false)
               .fetchOne(db) {
            return existing.id
        }
        if let imgHash = clip.imageHash, !imgHash.isEmpty,
           let existing = try Clip
               .filter(Column("imageHash") == imgHash)
               .filter(Column("isDeleted") == false)
               .fetchOne(db) {
            return existing.id
        }
        if let text = clip.contentText, !text.isEmpty,
           let existing = try Clip
               .filter(Column("contentText") == text)
               .filter(Column("contentType") == clip.contentType.rawValue)
               .filter(Column("isDeleted") == false)
               .fetchOne(db) {
            return existing.id
        }
        return nil
    }

    // MARK: - Errors

    enum BackupError: LocalizedError {
        case unsupportedVersion(Int)
        case zipExtractionFailed(status: Int32)
        case missingBackupJSON

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "이 백업 파일은 더 새로운 버전(v\(v))의 ClipRaven에서 생성되었습니다. 앱을 업데이트한 뒤 다시 시도하세요."
            case .zipExtractionFailed(let status):
                return "ZIP 압축 해제에 실패했습니다. (status: \(status))"
            case .missingBackupJSON:
                return "백업 파일에 backup.json이 없습니다. 올바른 ClipRaven 백업 파일이 맞는지 확인해주세요."
            }
        }
    }
}
