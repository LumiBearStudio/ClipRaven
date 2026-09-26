import AppKit
import Foundation
import CryptoKit
import ClipRavenSync

// 이전엔 로컬 `debugLog` private 함수를 정의했으나, `ClipRavenLog.write(.processor, …)`
// 단일 진입점으로 통합 (Utilities/ClipRavenLog.swift 참고).

actor ClipProcessor {
    private let clipRepository: ClipRepository
    private let ocrService: OCRService
    private let smartRuleEngine: SmartRuleEngine
    private let defaults: UserDefaults

    /// 프로덕션 기본값 사용. 테스트는 모든 의존성을 격리해 주입.
    init(
        clipRepository: ClipRepository = ClipRepository(),
        ocrService: OCRService = OCRService(),
        smartRuleEngine: SmartRuleEngine = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.clipRepository = clipRepository
        self.ocrService = ocrService
        self.smartRuleEngine = smartRuleEngine
        self.defaults = defaults
    }

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
        let stripInvisible = defaults.object(forKey: "stripInvisibleChars") as? Bool ?? true
        let cleanedText = stripInvisible ? TextNormalizer.stripInvisibleCharacters(text) : text

        if stripInvisible && cleanedText != text {
            let removed = text.count - cleanedText.count
            ClipRavenLog.write(.processor, "[ClipProc] stripInvisible ON — removed \(removed) invisible chars from text")
        } else if !stripInvisible {
            ClipRavenLog.write(.processor, "[ClipProc] stripInvisible DISABLED by setting")
        }

        let normalized = TextNormalizer.normalize(cleanedText)
        let hash = XXHash64Wrapper.hash(normalized)

        ClipRavenLog.write(.processor, "[ClipProc] processText type=\(contentType.rawValue) hash=\(hash.prefix(12)) text=\(ClipRavenLog.redacted(cleanedText))")

        // In-memory dedupe check (prevents race condition)
        cleanExpiredHashes()
        if recentHashes[hash] != nil {
            ClipRavenLog.write(.processor, "[ClipProc] DEDUP: in-memory cache hit for \(hash.prefix(12))")
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
            ClipRavenLog.write(.processor, "[ClipProc] DEDUP: DB hit for \(hash.prefix(12)), incrementing id=\(existingId)")
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
            ClipRavenLog.write(.processor, "[ClipProc] DEDUP: cross-device sync race for \(ClipRavenLog.redacted(cleanedText)), existing=\(recent.id ?? -1)")
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
            ClipRavenLog.write(.processor, "[ClipProc] SAVED id=\(clip.id ?? -1) hash=\(hash.prefix(12))")

            // Apply smart rules for auto-tagging
            await smartRuleEngine.applyRulesAndAssignTags(to: clip)

            // Trigger AI categorization in background (macOS 26+, text only)
            if let clipId = clip.id {
                triggerAICategory(clipId: clipId, text: cleanedText)
            }
        } catch {
            ClipRavenLog.write(.processor, "[ClipProc] SAVE ERROR: \(error)")
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

    /// 이미지 캡처 진입점. 품질 감사 B-CS6 권고에 따라 dedup 단계 + save 분해.
    /// 각 단계가 "이미 dedup 됐다 (skip)" 이면 true 반환, false 면 다음 단계 진행.
    private func processImage(_ imageData: Data, sourceApp: SourceAppInfo) async {
        let imageHash = SHA256Hash.compute(imageData)

        cleanExpiredHashes()

        // 1. In-memory 2초 윈도우 dedup (SHA-256)
        if dedupInMemoryImage(imageHash: imageHash) { return }
        // 2. DB 해시 dedup (SHA-256) — 같은 byte 의 재복사는 여기서 끝남.
        //    dHash 계산 (~3-10ms DCT) 을 SHA-256 dedup 뒤로 미뤄 hot path 단축
        //    (성능 감사 D-O3 lazy compute).
        if dedupByImageHashDB(imageHash: imageHash) { return }

        // dHash 는 시각적 perceptual hash (64-bit). 같은 visual 이미지면 byte 가
        // 달라도 일치. Chrome 등 브라우저의 multi-stage clipboard write 회귀
        // (SHA-256 다른 캡처 2건) 방어용. SHA-256 dedup 통과 시점에만 계산.
        let dHash = DHash.compute(from: imageData)

        // 3. dHash 기반 perceptual dedup (5초 윈도우) — 같은 visual 이미지의 multi-stage
        //    pasteboard write 또는 미세한 byte 차이 (compression metadata 등) 방어.
        if dedupByPerceptualHash(imageHash: imageHash, dHash: dHash) { return }
        // 4. Cross-device sync race dedup (30초 윈도우)
        if dedupCrossDeviceImage(imageHash: imageHash) { return }
        // 5. UC Stage-2 dedup (Stage-1 marker 60초 이내)
        if dedupUCStage2(imageHash: imageHash) { return }

        recentHashes[imageHash] = Date()

        // 6. thumbnail 생성 + 원본 저장 — 둘 다 imageData 만 읽고 결과가 독립이라
        //    Task.detached 로 병렬 실행. 4K 스크린샷 기준 thumbnail 5~15ms,
        //    disk write 5~20ms → 직렬 25ms → 병렬 ~max(15,20)=20ms.
        //    성능 감사 D-O3 image pipeline parallelization.
        async let thumbnailTask = Task.detached(priority: .userInitiated) {
            ImageStorageService.createThumbnail(from: imageData, maxDimension: 150)
        }.value
        async let imagePathTask = Task.detached(priority: .userInitiated) {
            ImageStorageService.saveImage(imageData)
        }.value
        let (thumbnail, imagePath) = await (thumbnailTask, imagePathTask)

        // 7. UC 2-stage upgrade — 직전 file clip 이 같은 이미지 파일 경로면 in-place 업그레이드
        if upgradeRecentFileClipToImage(
            imageHash: imageHash, imageDhash: dHash,
            imagePath: imagePath, thumbnail: thumbnail, imageData: imageData
        ) { return }

        // 8. 새 image clip 저장 + smart rule + OCR
        await saveNewImageClip(
            imageHash: imageHash, dHash: dHash, imagePath: imagePath,
            thumbnail: thumbnail, imageData: imageData, sourceApp: sourceApp
        )
    }

    // MARK: - processImage dedup helpers (B-CS6 분해)

    /// In-memory 2초 윈도우 dedup. recentHashes 에 같은 hash 가 있으면 copyCount++ 후 true.
    private func dedupInMemoryImage(imageHash: String) -> Bool {
        guard recentHashes[imageHash] != nil else { return false }
        if let existing = try? clipRepository.fetchByImageHash(imageHash),
           let existingId = existing.id {
            try? clipRepository.incrementCopyCount(id: existingId)
        }
        return true
    }

    /// DB 의 imageHash 컬럼에 같은 값이 있으면 copyCount++ 후 true.
    private func dedupByImageHashDB(imageHash: String) -> Bool {
        guard let existing = try? clipRepository.fetchByImageHash(imageHash),
              let existingId = existing.id else {
            return false
        }
        try? clipRepository.incrementCopyCount(id: existingId)
        recentHashes[imageHash] = Date()
        return true
    }

    /// dHash (perceptual hash) 기반 dedup — 같은 visual 이미지가 byte 차이로 SHA-256
    /// 다른 결과를 낼 때 회귀 방지.
    /// 시나리오: Chrome 등 브라우저가 이미지를 클립보드에 multi-stage 로 쓰면서
    /// 두 번째 stage 의 metadata 가 살짝 달라져 SHA-256 이 다름 → 시각적으로 동일한
    /// 이미지가 2개 row 생성되던 버그.
    /// 5초 윈도우 + 같은 dHash → 사용자가 의도한 다른 이미지일 가능성이 무시할
    /// 만큼 낮으므로 (64-bit dHash 충돌 확률 + 시간 제약) dedup 안전.
    private func dedupByPerceptualHash(imageHash: String, dHash: Int64?) -> Bool {
        guard let dHash else { return false }
        guard let existing = try? clipRepository.fetchRecentImageClip(
            withDhash: dHash,
            withinSeconds: 5
        ), let existingId = existing.id else { return false }
        ClipRavenLog.write(.processor, "[ClipProc] DEDUP: perceptual hash match (dHash=\(dHash)), existing=\(existingId)")
        try? clipRepository.incrementCopyCount(id: existingId)
        recentHashes[imageHash] = Date()
        return true
    }

    /// Cross-device sync race: 다른 device 가 30초 이내에 같은 이미지를 sync 로 보낸 케이스.
    private func dedupCrossDeviceImage(imageHash: String) -> Bool {
        guard let recent = try? clipRepository.fetchRecentSyncedClip(
            withImageHash: imageHash,
            otherThanDeviceId: DeviceIdentity.deviceId,
            window: 30
        ) else { return false }
        ClipRavenLog.write(.processor, "[ClipProc] DEDUP: cross-device image sync race (hash), existing=\(recent.id ?? -1)")
        recentHashes[imageHash] = Date()
        return true
    }

    /// UC Stage-2: Stage 1 marker 가 60초 이내에 있었고, 다른 device 가 90초 이내에
    /// 동일 이미지를 sync 로 보낸 경우 (Universal Clipboard 의 지연 Stage 2 image arrival).
    private func dedupUCStage2(imageHash: String) -> Bool {
        guard let skipTime = lastUCSkipTime,
              Date().timeIntervalSince(skipTime) < 60,
              let recent = try? clipRepository.fetchRecentSyncedImageClip(
                  otherThanDeviceId: DeviceIdentity.deviceId,
                  window: 90
              ) else { return false }
        ClipRavenLog.write(.processor, "[ClipProc] DEDUP: UC Stage-2 suppressed (Stage-1 skip \(Int(Date().timeIntervalSince(skipTime)))s ago, existing=\(recent.id ?? -1))")
        recentHashes[imageHash] = Date()
        lastUCSkipTime = nil
        return true
    }

    /// UC 2-stage upgrade: 직전 클립이 단일 이미지 파일 path 인 file clip 이면
    /// 새 row 만들지 않고 in-place 로 image 로 승격. 사용자에게 같은 클립이 두 장 보이는
    /// 시각 중복 방지. 처리됐으면 true.
    private func upgradeRecentFileClipToImage(
        imageHash: String, imageDhash: Int64?,
        imagePath: String?, thumbnail: Data?, imageData: Data
    ) -> Bool {
        guard let prev = try? clipRepository.fetchMostRecentNonDeleted(),
              prev.contentType == .file,
              let paths = prev.contentText,
              !paths.contains("\n"),          // single-file only
              let prevId = prev.id,
              Self.isImageFilePath(paths) else { return false }
        ClipRavenLog.write(.processor, "[ClipProc] UC 2-stage: upgrading file clip \(prevId) → image")
        try? clipRepository.upgradeFileClipToImage(
            id: prevId,
            imageHash: imageHash,
            imageDhash: imageDhash,
            imagePath: imagePath,
            thumbnail: thumbnail
        )
        Task.detached(priority: .utility) { [ocrService] in
            await ocrService.performOCR(on: imageData, clipId: prevId)
        }
        return true
    }

    /// 모든 dedup 통과한 새 이미지를 DB 에 저장 + smart rule + 백그라운드 OCR.
    private func saveNewImageClip(
        imageHash: String, dHash: Int64?, imagePath: String?,
        thumbnail: Data?, imageData: Data, sourceApp: SourceAppInfo
    ) async {
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

        // try? 의 Void? 결과는 의도적으로 무시 (실패 시 ClipRavenLog 도 안 남기는
        // 기존 동작 유지) — `_ =` 로 unused warning 만 silence.
        _ = try? clipRepository.save(&clip)

        await smartRuleEngine.applyRulesAndAssignTags(to: clip)

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
        ClipRavenLog.write(.processor, "[ClipProc] processFileURLs count=\(fileURLs.count) paths=\(ClipRavenLog.redacted(fileURLs.map(\.path).joined(separator: "\n")))")

        // Represent the file set as a sorted path list for hashing
        let sortedPaths = fileURLs.map(\.path).sorted()
        let combined = sortedPaths.joined(separator: "|")
        let hash = XXHash64Wrapper.hash(combined)

        // 파일 경로는 사용자명·문서명을 담는다 — P1 에서 이 두 줄을 놓쳤다 (v1 리뷰 G7).
        ClipRavenLog.write(.processor, "[ClipProc] fileURLs hash=\(hash.prefix(12)) count=\(sortedPaths.count)")

        cleanExpiredHashes()
        if recentHashes[hash] != nil {
            if let existing = try? clipRepository.fetchByHash(hash),
               let existingId = existing.id {
                try? clipRepository.incrementCopyCount(id: existingId)
            }
            ClipRavenLog.write(.processor, "[ClipProc] fileURLs DEDUP: in-memory")
            return
        }

        if let existing = try? clipRepository.fetchByHash(hash),
           let existingId = existing.id {
            try? clipRepository.incrementCopyCount(id: existingId)
            recentHashes[hash] = Date()
            ClipRavenLog.write(.processor, "[ClipProc] fileURLs DEDUP: DB hit id=\(existingId)")
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
        // 파일 경로는 사용자명·프로젝트명·문서명을 그대로 담는다 — 개수만 남긴다.
        ClipRavenLog.write(.processor, "[ClipProc] fileURLs count=\(sortedPaths.count) paths=\(ClipRavenLog.redacted(contentText))")

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
            ClipRavenLog.write(.processor, "[ClipProc] fileURLs SAVED id=\(clip.id ?? -1) paths=\(ClipRavenLog.redacted(contentText))")
        } catch {
            ClipRavenLog.write(.processor, "[ClipProc] fileURLs SAVE ERROR: \(error)")
        }
        await smartRuleEngine.applyRulesAndAssignTags(to: clip)
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
            ClipRavenLog.write(.processor, "[ClipProc] file→image DEDUP: imageHash hit id=\(existingId)")
            return
        }

        // thumbnail + 원본 저장 + dHash 모두 독립 — 병렬 실행 (D-O3).
        async let thumbnailTask = Task.detached(priority: .userInitiated) {
            ImageStorageService.createThumbnail(from: imageData, maxDimension: 150)
        }.value
        async let imagePathTask = Task.detached(priority: .userInitiated) {
            ImageStorageService.saveImage(imageData)
        }.value
        async let dHashTask = Task.detached(priority: .userInitiated) {
            DHash.compute(from: imageData)
        }.value
        let (thumbnail, imagePath, dHash) = await (thumbnailTask, imagePathTask, dHashTask)

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
            ClipRavenLog.write(.processor, "[ClipProc] file→image SAVED id=\(clip.id ?? -1) imageHash=\(imageHash.prefix(12))")
        } catch {
            ClipRavenLog.write(.processor, "[ClipProc] file→image SAVE ERROR: \(error)")
        }

        await smartRuleEngine.applyRulesAndAssignTags(to: clip)

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
            userAppBlacklist: userExcludedAppBundleIds()
        )
    }

    /// PrivacySettingsView 의 "앱별 제외 목록"(UserDefaults `excludedApps`,
    /// 줄바꿈 구분 String) 을 Set 으로 파싱. 캡처마다 호출되므로 가볍게 유지.
    /// SyncFilters 가 substring match (`bundleId.contains($0.lowercased())`)
    /// 하므로 lowercase 캐시는 SyncFilters 측에서 처리.
    private func userExcludedAppBundleIds() -> Set<String> {
        let raw = defaults.string(forKey: "excludedApps") ?? ""
        guard !raw.isEmpty else { return [] }
        return Set(
            raw.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}
