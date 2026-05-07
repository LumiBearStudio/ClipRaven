import AppKit
import Foundation
import CryptoKit
import ClipRavenSync

private func debugLog(_ msg: String) {
    ClipRavenLog.processor.debug("\(msg, privacy: .public)")
    #if DEBUG
    // Also mirror to a file next to the .app bundle so Terminal `tail -f` works.
    let line = "\(Date()): \(msg)\n"
    let logPath = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("clipraven_debug.log").path
    let data = Data(line.utf8)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
    #endif
}

actor ClipProcessor {
    private let clipRepository = ClipRepository()
    private let ocrService = OCRService()
    private let smartRuleEngine = SmartRuleEngine.shared

    // In-memory cache to prevent rapid duplicate processing
    private var recentHashes: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 2.0  // 2 seconds

    // UC Stage-2 dedup: timestamp set when Stage 1 (com.apple.is-remote-clipboard) is skipped.
    // Stage 2 (actual image data, no UC marker) arrives after paste and must be suppressed
    // if CloudKit has already synced the iOS-captured copy.
    private var lastUCSkipTime: Date?

    func notifyUniversalClipboardSkipped() {
        lastUCSkipTime = Date()
    }

    func process(clipboardData: ClipboardData, sourceApp: SourceAppInfo) async {
        // Text takes priority over image (Xcode etc. include TIFF with text copies)
        if let string = clipboardData.text {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let contentType = classifyText(trimmed)
                await processText(trimmed, contentType: contentType, sourceApp: sourceApp)
                return
            }
        }

        // Only process as image if no text content
        if let imageData = clipboardData.imageData {
            await processImage(imageData, sourceApp: sourceApp)
            return
        }

        // File URLs (only if no text or image)
        if let fileURLs = clipboardData.fileURLs, !fileURLs.isEmpty {
            await processFileURLs(fileURLs, sourceApp: sourceApp)
        }
    }

    // MARK: - Text Processing

    private func processText(_ text: String, contentType: ContentType, sourceApp: SourceAppInfo) async {
        // Auto-cleanup: strip invisible/control characters (BOM, zero-width, nbsp) before saving.
        // Default ON — can be disabled via Privacy settings.
        let stripInvisible = UserDefaults.standard.object(forKey: "stripInvisibleChars") as? Bool ?? true
        let cleanedText = stripInvisible ? TextNormalizer.stripInvisibleCharacters(text) : text

        if stripInvisible && cleanedText != text {
            let removed = text.count - cleanedText.count
            debugLog("[ClipProc] stripInvisible ON — removed \(removed) invisible chars from text")
        } else if !stripInvisible {
            debugLog("[ClipProc] stripInvisible DISABLED by setting")
        }

        let normalized = TextNormalizer.normalize(cleanedText)
        let hash = XXHash64Wrapper.hash(normalized)

        debugLog("[ClipProc] processText type=\(contentType.rawValue) hash=\(hash.prefix(12)) text=\"\(cleanedText.prefix(60))\"")

        // In-memory dedupe check (prevents race condition)
        cleanExpiredHashes()
        if recentHashes[hash] != nil {
            debugLog("[ClipProc] DEDUP: in-memory cache hit for \(hash.prefix(12))")
            if let existing = try? clipRepository.fetchByHash(hash),
               let existingId = existing.id {
                try? clipRepository.incrementCopyCount(id: existingId)
                // Retry AI categorization if never classified before
                if existing.aiCategory == nil && (contentType == .text || contentType == .code) {
                    triggerAICategory(clipId: existingId, text: cleanedText)
                }
            }
            return
        }

        // DB duplicate check
        if let existing = try? clipRepository.fetchByHash(hash),
           let existingId = existing.id {
            debugLog("[ClipProc] DEDUP: DB hit for \(hash.prefix(12)), incrementing id=\(existingId)")
            try? clipRepository.incrementCopyCount(id: existingId)
            recentHashes[hash] = Date()
            // Retry AI categorization if never classified before
            if existing.aiCategory == nil && (contentType == .text || contentType == .code) {
                triggerAICategory(clipId: existingId, text: cleanedText)
            }
            return
        }

        // Cross-device sync race dedup — Apple Universal Clipboard mirrors
        // iOS→Mac (and Mac→iOS) automatically. Combined with our CKSyncEngine
        // pull, the same content can arrive twice within seconds.
        //
        // Mac-side hash (xxHash64 over normalized text) won't match iOS-side
        // hash (SHA-256 prefix over raw text), so the regular `fetchByHash`
        // dedup above misses cross-device clips. We do a content-text equality
        // lookup with a 30s window for clips that have ckLastSyncedAt set
        // (came from another device through sync).
        if let recent = try? clipRepository.fetchRecentSyncedClip(
            withContentText: cleanedText,
            otherThanDeviceId: DeviceIdentity.deviceId,
            window: 30
        ) {
            debugLog("[ClipProc] DEDUP: cross-device sync race for \"\(cleanedText.prefix(40))\", existing=\(recent.id ?? -1)")
            recentHashes[hash] = Date()
            return
        }

        // Mark as recently processed
        recentHashes[hash] = Date()

        let chosung = ChosungConverter.extractChosung(from: cleanedText)

        var clip = Clip(
            contentType: contentType,
            contentText: cleanedText,
            contentHash: hash,
            sourceAppBundleId: sourceApp.bundleId,
            sourceAppName: sourceApp.name,
            contentChosung: chosung,
            createdAt: Date(),
            lastCopiedAt: Date()
        )
        stampSyncMetadata(&clip, text: cleanedText)

        do {
            try clipRepository.save(&clip)
            debugLog("[ClipProc] SAVED id=\(clip.id ?? -1) hash=\(hash.prefix(12))")

            // Apply smart rules for auto-tagging
            smartRuleEngine.applyRulesAndAssignTags(to: clip)

            // Trigger AI categorization in background (macOS 26+, text only)
            if let clipId = clip.id {
                triggerAICategory(clipId: clipId, text: cleanedText)
            }
        } catch {
            debugLog("[ClipProc] SAVE ERROR: \(error)")
        }
    }

    private func triggerAICategory(clipId: Int64, text: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            Task.detached(priority: .utility) {
                await AICategoryService.shared.categorize(clipId: clipId, text: text)
            }
        }
        #endif
    }

    // MARK: - Image Processing

    private func processImage(_ imageData: Data, sourceApp: SourceAppInfo) async {
        let imageHash = SHA256Hash.compute(imageData)

        // In-memory dedupe
        cleanExpiredHashes()
        if recentHashes[imageHash] != nil {
            if let existing = try? clipRepository.fetchByImageHash(imageHash),
               let existingId = existing.id {
                try? clipRepository.incrementCopyCount(id: existingId)
            }
            return
        }

        // DB duplicate check
        if let existing = try? clipRepository.fetchByImageHash(imageHash),
           let existingId = existing.id {
            try? clipRepository.incrementCopyCount(id: existingId)
            recentHashes[imageHash] = Date()
            return
        }

        // Cross-device sync race dedup — exact imageHash match.
        if let recent = try? clipRepository.fetchRecentSyncedClip(
            withImageHash: imageHash,
            otherThanDeviceId: DeviceIdentity.deviceId,
            window: 30
        ) {
            debugLog("[ClipProc] DEDUP: cross-device image sync race (hash), existing=\(recent.id ?? -1)")
            recentHashes[imageHash] = Date()
            return
        }

        // UC Stage-2 dedup: Stage 1 (com.apple.is-remote-clipboard) was skipped by
        // ClipboardMonitor, but the actual image data arrives separately after paste
        // without the UC marker. If Stage 1 was seen within 60s AND a synced image
        // clip from another device is already in DB, this is Stage 2 — suppress it.
        if let skipTime = lastUCSkipTime,
           Date().timeIntervalSince(skipTime) < 60,
           let recent = try? clipRepository.fetchRecentSyncedImageClip(
               otherThanDeviceId: DeviceIdentity.deviceId,
               window: 90
           ) {
            debugLog("[ClipProc] DEDUP: UC Stage-2 suppressed (Stage-1 skip \(Int(Date().timeIntervalSince(skipTime)))s ago, existing=\(recent.id ?? -1))")
            recentHashes[imageHash] = Date()
            lastUCSkipTime = nil
            return
        }

        recentHashes[imageHash] = Date()

        let thumbnail = ImageStorageService.createThumbnail(from: imageData, maxDimension: 150)
        let imagePath = ImageStorageService.saveImage(imageData)
        let dHash = DHash.compute(from: imageData)

        // Universal Clipboard 2-stage dedup: if the immediately preceding clip is a
        // file clip whose path looks like an image file (single file only), upgrade it
        // in-place rather than creating a duplicate image clip.
        // Stage 1: clipboard fires with public.file-url only (lazy data provider).
        // Stage 2: paste triggers actual image fetch → another clipboard change fires.
        if let prev = try? clipRepository.fetchMostRecentNonDeleted(),
           prev.contentType == .file,
           let paths = prev.contentText,
           !paths.contains("\n"),          // single-file only
           let prevId = prev.id,
           Self.isImageFilePath(paths) {
            debugLog("[ClipProc] UC 2-stage: upgrading file clip \(prevId) → image")
            try? clipRepository.upgradeFileClipToImage(
                id: prevId,
                imageHash: imageHash,
                imageDhash: dHash,
                imagePath: imagePath,
                thumbnail: thumbnail
            )
            Task.detached(priority: .utility) { [ocrService] in
                await ocrService.performOCR(on: imageData, clipId: prevId)
            }
            return
        }

        var clip = Clip(
            contentType: .image,
            imageHash: imageHash,
            imageDhash: dHash,
            imagePath: imagePath,
            thumbnail: thumbnail,
            sourceAppBundleId: sourceApp.bundleId,
            sourceAppName: sourceApp.name,
            createdAt: Date(),
            lastCopiedAt: Date()
        )
        stampSyncMetadata(&clip, text: nil)

        try? clipRepository.save(&clip)

        // Apply smart rules for auto-tagging
        smartRuleEngine.applyRulesAndAssignTags(to: clip)

        // Trigger OCR asynchronously for image clips
        if let clipId = clip.id {
            Task.detached(priority: .utility) { [ocrService] in
                await ocrService.performOCR(on: imageData, clipId: clipId)
            }
        }
    }

    private static let imageFileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"
    ]

    private static func isImageFilePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return imageFileExtensions.contains(ext)
    }

    // MARK: - File Processing

    private func processFileURLs(_ fileURLs: [URL], sourceApp: SourceAppInfo) async {
        debugLog("[ClipProc] processFileURLs count=\(fileURLs.count) urls=\(fileURLs.map(\.path))")

        // Represent the file set as a sorted path list for hashing
        let sortedPaths = fileURLs.map(\.path).sorted()
        let combined = sortedPaths.joined(separator: "|")
        let hash = XXHash64Wrapper.hash(combined)

        debugLog("[ClipProc] fileURLs hash=\(hash.prefix(12)) paths=\(sortedPaths)")

        cleanExpiredHashes()
        if recentHashes[hash] != nil {
            if let existing = try? clipRepository.fetchByHash(hash),
               let existingId = existing.id {
                try? clipRepository.incrementCopyCount(id: existingId)
            }
            debugLog("[ClipProc] fileURLs DEDUP: in-memory")
            return
        }

        if let existing = try? clipRepository.fetchByHash(hash),
           let existingId = existing.id {
            try? clipRepository.incrementCopyCount(id: existingId)
            recentHashes[hash] = Date()
            debugLog("[ClipProc] fileURLs DEDUP: DB hit id=\(existingId)")
            return
        }

        recentHashes[hash] = Date()

        // Special case — 단일 이미지 파일 복사는 `.image` 로 자동 처리.
        // 그래야 sync 후 다른 디바이스에서 키보드/메인 앱에 사진 카드로
        // 정상 표시되고, Phase C 의 CKAsset 원본 sync 도 자동 적용됨.
        // (예: Finder 에서 .jpg 우클릭 → 복사 → iPhone 키보드에서 사진으로 보임)
        //
        // 조건: 단일 파일 + 이미지 확장자.
        // 다중 파일이거나 비-이미지 확장자(.pdf/.zip/.dmg 등)는 기존
        // .file 경로를 그대로 사용 (path 텍스트 + file icon thumbnail).
        if sortedPaths.count == 1,
           let firstPath = sortedPaths.first,
           Self.isImageFilePath(firstPath),
           let imageData = try? Data(contentsOf: URL(fileURLWithPath: firstPath))
        {
            await processImageFromFile(
                imageData: imageData,
                originalHash: hash,
                sourceApp: sourceApp
            )
            return
        }

        // Store first file path (for single file) or paths joined by newline (multi)
        let contentText = sortedPaths.joined(separator: "\n")
        debugLog("[ClipProc] fileURLs contentText=\(contentText)")

        // Generate thumbnail from file icon of first file
        let thumbnail: Data? = await MainActor.run {
            guard let firstPath = sortedPaths.first else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: firstPath)
            icon.size = NSSize(width: 60, height: 60)
            guard let tiff = icon.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return png
        }

        var clip = Clip(
            contentType: .file,
            contentText: contentText,
            contentHash: hash,
            thumbnail: thumbnail,
            sourceAppBundleId: sourceApp.bundleId,
            sourceAppName: sourceApp.name,
            createdAt: Date(),
            lastCopiedAt: Date()
        )
        stampSyncMetadata(&clip, text: contentText)

        do {
            try clipRepository.save(&clip)
            debugLog("[ClipProc] fileURLs SAVED id=\(clip.id ?? -1) contentText=\(contentText)")
        } catch {
            debugLog("[ClipProc] fileURLs SAVE ERROR: \(error)")
        }
        smartRuleEngine.applyRulesAndAssignTags(to: clip)
    }

    /// Finder 에서 단일 이미지 파일을 복사한 경우 — image 데이터를 직접
    /// 캡처해 `.image` 로 처리. 일반 image 캡처(processImageData) 와 동일한
    /// 결과: thumbnail + imagePath + imageHash + dHash 채워서 저장.
    private func processImageFromFile(
        imageData: Data,
        originalHash: String,
        sourceApp: SourceAppInfo
    ) async {
        // 이미지 데이터로 hash 재계산 — file path 기반 hash 와 다른 이미지
        // 콘텐츠 hash 가 필요. dedup 도 콘텐츠 기준이 더 정확.
        // CryptoKit SHA256 직접 사용 (ClipboardMonitor 와 동일 패턴).
        let imageHash: String = {
            let digest = SHA256.hash(data: imageData)
            return digest.map { String(format: "%02x", $0) }.joined()
        }()

        // 콘텐츠 기준 dedup — 같은 이미지를 다른 path 에서 또 복사 시
        if let existing = try? clipRepository.fetchByImageHash(imageHash),
           let existingId = existing.id {
            try? clipRepository.incrementCopyCount(id: existingId)
            debugLog("[ClipProc] file→image DEDUP: imageHash hit id=\(existingId)")
            return
        }

        let thumbnail = ImageStorageService.createThumbnail(from: imageData, maxDimension: 150)
        let imagePath = ImageStorageService.saveImage(imageData)
        let dHash = DHash.compute(from: imageData)

        var clip = Clip(
            contentType: .image,
            contentHash: originalHash,  // file-list hash (dedup 용)
            imageHash: imageHash,
            imageDhash: dHash,
            imagePath: imagePath,
            thumbnail: thumbnail,
            sourceAppBundleId: sourceApp.bundleId,
            sourceAppName: sourceApp.name,
            createdAt: Date(),
            lastCopiedAt: Date()
        )
        stampSyncMetadata(&clip, text: nil)

        do {
            try clipRepository.save(&clip)
            debugLog("[ClipProc] file→image SAVED id=\(clip.id ?? -1) imageHash=\(imageHash.prefix(12))")
        } catch {
            debugLog("[ClipProc] file→image SAVE ERROR: \(error)")
        }

        smartRuleEngine.applyRulesAndAssignTags(to: clip)

        // 백그라운드 OCR
        if let clipId = clip.id {
            Task.detached(priority: .utility) { [ocrService] in
                await ocrService.performOCR(on: imageData, clipId: clipId)
            }
        }
    }

    // MARK: - Classification

    private func classifyText(_ text: String) -> ContentType {
        if URLNormalizer.isURL(text) {
            return .url
        }
        if CodeLanguageDetector.isCode(text) {
            return .code
        }
        return .text
    }

    // MARK: - Cache Cleanup

    private func cleanExpiredHashes() {
        let now = Date()
        recentHashes = recentHashes.filter { now.timeIntervalSince($0.value) < dedupeWindow }
    }

    // MARK: - Sync Metadata

    /// Stamp sync metadata onto a freshly-built clip before save.
    ///
    /// Must be called on every code path that builds a new `Clip` (text,
    /// image, file). Without this:
    /// - `uuid` stays nil → SyncRecordMapper.encode returns nil → row is
    ///   silently dropped from the upload queue.
    /// - `excludeFromSync` stays false → credentials leak to iCloud.
    ///
    /// The `text` argument is what `SyncFilters.shouldExclude` scans. Pass
    /// the text content for text/code/file clips, nil for image clips
    /// (SyncFilters text-pattern matching is a no-op on nil).
    private func stampSyncMetadata(_ clip: inout Clip, text: String?) {
        let now = Date()
        clip.uuid = UUID().uuidString
        clip.deviceId = DeviceIdentity.deviceId
        clip.updatedAt = now
        clip.schemaVersion = 1
        clip.excludeFromSync = SyncFilters.shouldExclude(
            text: text,
            sourceAppBundleId: clip.sourceAppBundleId,
            userAppBlacklist: Self.userExcludedAppBundleIds()
        )
    }

    /// PrivacySettingsView 의 "앱별 제외 목록"(UserDefaults `excludedApps`,
    /// 줄바꿈 구분 String) 을 Set 으로 파싱. 캡처마다 호출되므로 가볍게 유지.
    /// SyncFilters 가 substring match (`bundleId.contains($0.lowercased())`)
    /// 하므로 lowercase 캐시는 SyncFilters 측에서 처리.
    private static func userExcludedAppBundleIds() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: "excludedApps") ?? ""
        guard !raw.isEmpty else { return [] }
        return Set(
            raw.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}
