import AppKit
import Combine
import CryptoKit
import os.log

private func debugLog(_ msg: String) {
    ClipRavenLog.clipboard.debug("\(msg, privacy: .public)")
    #if DEBUG
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

// MARK: - Selective Mode Pending State

private struct PendingTextCapture {
    let data: ClipboardData
    let sourceApp: SourceAppInfo
    let hash: String
    let capturedAt: Date
}

private struct PendingImageCapture {
    let imageData: Data
    let sourceApp: SourceAppInfo
}

// MARK: - ClipboardMonitor

final class ClipboardMonitor: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var isPaused = false

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general
    private let clipProcessor = ClipProcessor()
    private var activity: NSObjectProtocol?

    /// Content-based dedup: hash of the last processed clipboard content.
    private var lastContentHash: String = ""

    // Excluded app bundle IDs
    private var excludedApps: Set<String> = []
    private var pauseObserver: Any?

    // MARK: Selective Mode State
    private var pendingSelectiveText: PendingTextCapture?
    private var pendingImageCaptures: [String: PendingImageCapture] = [:]
    private var doubleCopyConfirmLock = false
    private var confirmLockTimer: Timer?

    private var selectiveModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "selectiveMode")
    }
    private var doubleCopyWindowMs: Double {
        let stored = UserDefaults.standard.integer(forKey: "doubleCopyWindowMs")
        let value = stored > 0 ? stored : 500
        return Double(max(300, min(1000, value)))
    }

    /// 우리 코드가 직접 NSPasteboard에 write 한 직후 호출. 다음 polling
    /// cycle이 그 변경을 자기 변경으로 잘못 인식해서 ClipProcessor에
    /// 다시 보내는 echo-back 방지. iOS의 PasteboardCaptureService.markIntentionalWrite
    /// 와 동일 패턴.
    func markIntentionalWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard !isMonitoring else { return }
        lastChangeCount = pasteboard.changeCount
        isMonitoring = true

        // Load excluded apps from UserDefaults
        loadExcludedApps()

        // Listen for pause toggle
        pauseObserver = NotificationCenter.default.addObserver(
            forName: .clipRavenTogglePause,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isPaused { self.resume() } else { self.pause() }
        }

        // Capture current clipboard content hash to avoid processing existing content on launch
        let initialData = readPasteboardData()
        lastContentHash = computeContentHash(initialData)
        debugLog("[ClipMon] START changeCount=\(lastChangeCount) initialHash=\(lastContentHash.prefix(12))")

        // Prevent App Nap
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Clipboard monitoring"
        )

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if let pauseObserver {
            NotificationCenter.default.removeObserver(pauseObserver)
            self.pauseObserver = nil
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        NotificationCenter.default.post(
            name: .clipRavenPauseStateChanged,
            object: nil,
            userInfo: ["isPaused": true]
        )
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        NotificationCenter.default.post(
            name: .clipRavenPauseStateChanged,
            object: nil,
            userInfo: ["isPaused": false]
        )
    }

    func setExcludedApps(_ apps: Set<String>) {
        excludedApps = apps
    }

    private func checkClipboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }

        let prevCount = lastChangeCount
        lastChangeCount = currentCount

        guard !isPaused else { return }

        // Log all pasteboard types for debugging
        let types = pasteboard.types?.map { $0.rawValue } ?? []
        debugLog("[ClipMon] CHANGE \(prevCount)→\(currentCount) types=[\(types.joined(separator: ", "))]")

        // Skip ClipRaven's own pastes (self-detection)
        if pasteboard.types?.contains(ClipboardMarker.selfType) == true {
            debugLog("[ClipMon] SKIP: self-detection marker")
            return
        }

        // Skip Universal Clipboard items from another device — the originating
        // device already captured this clip and will upload it to CloudKit.
        // We'll receive it via SyncEngine, avoiding the duplicate.
        // Also notify ClipProcessor so Stage-2 (actual image data arriving after
        // paste, without the UC marker) can be suppressed as well.
        if pasteboard.types?.contains(.init(rawValue: "com.apple.is-remote-clipboard")) == true {
            debugLog("[ClipMon] SKIP: Universal Clipboard remote item")
            Task { await clipProcessor.notifyUniversalClipboardSkipped() }
            return
        }

        // Skip concealed/transient/auto-generated types
        let skipTypes: [NSPasteboard.PasteboardType] = [
            .init(rawValue: "org.nspasteboard.ConcealedType"),
            .init(rawValue: "org.nspasteboard.TransientType"),
            .init(rawValue: "org.nspasteboard.AutoGeneratedType"),
            .init(rawValue: "de.petermaurer.TransientPasteboardType"),
            .init(rawValue: "com.agilebits.onepassword"),
            .init(rawValue: "com.typeit4me.clipping"),
        ]
        if let pbTypes = pasteboard.types, pbTypes.contains(where: { skipTypes.contains($0) }) {
            debugLog("[ClipMon] SKIP: transient/concealed type")
            return
        }

        // Check excluded apps
        let sourceApp = SourceAppTracker.currentApp()
        if let bundleId = sourceApp.bundleId, excludedApps.contains(bundleId) {
            debugLog("[ClipMon] SKIP: excluded app \(bundleId)")
            return
        }

        // Check sensitive data (ConcealedType already handled above via skipTypes)
        let blockSensitiveOn = UserDefaults.standard.bool(forKey: "blockSensitive")
        debugLog("[ClipMon] sensitive check: blockSensitive=\(blockSensitiveOn) source=\(sourceApp.bundleId ?? "?") name=\(sourceApp.name ?? "?")")
        if blockSensitiveOn {
            if SensitiveDataFilter.isSensitive(pasteboard: pasteboard) {
                debugLog("[ClipMon] SKIP: sensitive data detected (pasteboard ConcealedType)")
                return
            }
            if let text = pasteboard.string(forType: .string) {
                let is2FA = SensitiveDataFilter.isLikelyTwoFactorCode(text)
                let hasPhrase = SensitiveDataFilter.containsTwoFactorPhrase(text)
                let filter2FAOn = UserDefaults.standard.object(forKey: "filter2FA") as? Bool ?? true
                debugLog("[ClipMon] text=\"\(text.prefix(50))\" is2FACandidate=\(is2FA) hasPhrase=\(hasPhrase) filter2FAOn=\(filter2FAOn)")
                if SensitiveDataFilter.isSensitiveWithContext(text, sourceApp: sourceApp) {
                    debugLog("[ClipMon] SKIP: sensitive/2FA pattern detected (source=\(sourceApp.bundleId ?? "?"))")
                    return
                }
            }
        }

        // Read pasteboard data on main thread
        let clipboardData = readPasteboardData()

        let textPreview = String(clipboardData.text?.prefix(80) ?? "nil")
        let hasImage = clipboardData.imageData != nil
        debugLog("[ClipMon] READ text=\"\(textPreview)\" hasImage=\(hasImage) source=\(sourceApp.name ?? "?")")

        // Content-based dedup
        let contentHash = computeContentHash(clipboardData)
        if contentHash == lastContentHash {
            // Selective mode: same content within window = double-copy confirmation
            if selectiveModeEnabled, let pending = pendingSelectiveText, pending.hash == contentHash {
                let elapsed = Date().timeIntervalSince(pending.capturedAt) * 1000
                if elapsed >= 80 && elapsed <= doubleCopyWindowMs && !doubleCopyConfirmLock {
                    debugLog("[ClipMon] SELECTIVE: double-copy confirmed elapsed=\(Int(elapsed))ms")
                    confirmPendingText(pending)
                    return
                }
            }
            debugLog("[ClipMon] SKIP: same content hash \(contentHash.prefix(16))")
            return
        }
        debugLog("[ClipMon] NEW hash=\(contentHash.prefix(16)) prev=\(lastContentHash.prefix(16))")
        lastContentHash = contentHash

        // Guard against empty clipboard
        guard clipboardData.text != nil || clipboardData.imageData != nil || clipboardData.fileURLs != nil else {
            debugLog("[ClipMon] SKIP: empty clipboard")
            return
        }

        // Selective mode routing
        if selectiveModeEnabled {
            if clipboardData.text != nil || clipboardData.fileURLs != nil {
                // Queue for double-copy confirmation (in memory only)
                pendingSelectiveText = PendingTextCapture(
                    data: clipboardData,
                    sourceApp: sourceApp,
                    hash: contentHash,
                    capturedAt: Date()
                )
                debugLog("[ClipMon] SELECTIVE: text queued, waiting for double-copy")
                return
            } else if let imageData = clipboardData.imageData {
                // Queue image for popup confirmation
                let captureId = UUID().uuidString
                pendingImageCaptures[captureId] = PendingImageCapture(
                    imageData: imageData,
                    sourceApp: sourceApp
                )
                debugLog("[ClipMon] SELECTIVE: image queued id=\(captureId)")
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    let thumbnail = ImageStorageService.createThumbnail(from: imageData, maxDimension: 150)
                    let pending = PendingImageConfirmation(
                        id: captureId,
                        thumbnail: thumbnail,
                        sourceAppName: sourceApp.name,
                        onConfirm: { [weak self] in
                            DispatchQueue.main.async { self?.confirmPendingImage(id: captureId) }
                        },
                        onDiscard: { [weak self] in
                            DispatchQueue.main.async { self?.discardPendingImage(id: captureId) }
                        }
                    )
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .clipRavenImageNeedsConfirmation,
                            object: pending
                        )
                    }
                }
                return
            }
        }

        // Normal mode: process asynchronously
        debugLog("[ClipMon] → PROCESSING")
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.clipProcessor.process(
                clipboardData: clipboardData,
                sourceApp: sourceApp
            )

            // Notify for icon flash
            await MainActor.run {
                NotificationCenter.default.post(name: .clipRavenNewClipCaptured, object: nil)
            }
        }
    }

    private func loadExcludedApps() {
        let raw = UserDefaults.standard.string(forKey: "excludedApps") ?? ""
        let apps = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        excludedApps = Set(apps)
    }

    /// Read all pasteboard data on the main thread
    private func readPasteboardData() -> ClipboardData {
        let pb = NSPasteboard.general
        let pbTypes = pb.types ?? []

        // File URLs take priority over text — Finder copies include filename as plain text too.
        // Exception: Universal Clipboard photo copies have BOTH file-url AND image data on the pasteboard.
        // In that case skip file-URL handling so the photo is captured as an image clip, not a file clip.
        let imageDataTypes: [NSPasteboard.PasteboardType] = [
            .tiff, .png, .init(rawValue: "public.jpeg"), .init(rawValue: "public.heic")
        ]
        let hasImageDataAlongside = imageDataTypes.contains(where: { pbTypes.contains($0) })

        let fileURLType = NSPasteboard.PasteboardType("public.file-url")
        let hasFileURLType = pbTypes.contains(fileURLType)
            || pbTypes.contains(.init(rawValue: "NSFilenamesPboardType"))

        if hasFileURLType && !hasImageDataAlongside {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
               !urls.isEmpty {
                return ClipboardData(text: nil, imageData: nil, fileURLs: urls)
            }
        }

        // Text
        let text = pb.string(forType: .string)
        let hasText = text != nil && !text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Image (only if no text)
        var imageData: Data?
        if !hasText {
            let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
            for type in imageTypes {
                if let data = pb.data(forType: type) {
                    if type == .tiff, let image = NSImage(data: data),
                       let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        imageData = pngData
                    } else {
                        imageData = data
                    }
                    break
                }
            }
        }

        return ClipboardData(text: hasText ? text : nil, imageData: imageData, fileURLs: nil)
    }

    // MARK: - Selective Mode Helpers

    private func confirmPendingText(_ pending: PendingTextCapture) {
        pendingSelectiveText = nil
        doubleCopyConfirmLock = true
        startConfirmLockTimer()

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.clipProcessor.process(
                clipboardData: pending.data,
                sourceApp: pending.sourceApp
            )
            await MainActor.run {
                NotificationCenter.default.post(name: .clipRavenNewClipCaptured, object: nil)
            }
        }
    }

    private func confirmPendingImage(id: String) {
        guard let pending = pendingImageCaptures.removeValue(forKey: id) else { return }
        let data = ClipboardData(text: nil, imageData: pending.imageData, fileURLs: nil)

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.clipProcessor.process(
                clipboardData: data,
                sourceApp: pending.sourceApp
            )
            await MainActor.run {
                NotificationCenter.default.post(name: .clipRavenNewClipCaptured, object: nil)
            }
        }
    }

    private func discardPendingImage(id: String) {
        pendingImageCaptures.removeValue(forKey: id)
        debugLog("[ClipMon] SELECTIVE: image discarded id=\(id)")
    }

    private func startConfirmLockTimer() {
        confirmLockTimer?.invalidate()
        let lockInterval = (doubleCopyWindowMs + 200) / 1000
        confirmLockTimer = Timer.scheduledTimer(withTimeInterval: lockInterval, repeats: false) { [weak self] _ in
            self?.doubleCopyConfirmLock = false
        }
    }

    /// Fast SHA-256 hash of clipboard content for dedup comparison.
    private func computeContentHash(_ data: ClipboardData) -> String {
        if let text = data.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let digest = SHA256.hash(data: Data(text.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        if let imageData = data.imageData {
            let digest = SHA256.hash(data: imageData)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        if let fileURLs = data.fileURLs, !fileURLs.isEmpty {
            let combined = fileURLs.map(\.absoluteString).joined(separator: "|")
            let digest = SHA256.hash(data: Data(combined.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        return ""
    }
}
