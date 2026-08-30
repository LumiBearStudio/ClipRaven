import AppKit
import Combine
import CryptoKit
import os.log

// 로컬 `debugLog` 함수는 ClipRavenLog 으로 통합됨 (Utilities/ClipRavenLog.swift).

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
        ClipRavenLog.write(.clipboard, "[ClipMon] START changeCount=\(lastChangeCount) initialHash=\(lastContentHash.prefix(12))")

        // App Nap 방지 — **유휴 절전은 막지 않는다.**
        //
        // 이전 값은 `[.userInitiated, .idleSystemSleepDisabled]` 였는데,
        // `.userInitiated` 자체가 이미 `.idleSystemSleepDisabled` 를 포함한다.
        // 이 assertion 은 stop()(= 앱 종료) 전까지 해제되지 않으므로, 앱이 떠
        // 있는 동안 맥이 유휴 절전에 들어가지 못했다 (`pmset -g assertions` 에
        // PreventUserIdleSystemSleep 상시 표시). 자리를 비운 사이 배터리가
        // 소진되는 문제로 이어진다 (감사 F1).
        //
        // 클립보드 폴링은 화면이 꺼진 뒤까지 계속될 이유가 없다. App Nap 만
        // 피하면 되므로 절전을 허용하는 옵션을 쓴다.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Clipboard monitoring"
        )

        // 품질 감사 B-R4: force unwrap 정책 위반. Timer.scheduledTimer 반환은
        // 실패 안 하지만 Optional 시그니처 존중.
        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        timer = newTimer
        RunLoop.current.add(newTimer, forMode: .common)
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

    /// 클립보드 변경 검사 entry point. 품질 감사 B-CS5 권고에 따라 4단계로 분해:
    /// 1. changeCount + pause 확인
    /// 2. `shouldSkip(types:sourceApp:)` — early-skip 분기 (self / UC / concealed /
    ///    excluded app / sensitive)
    /// 3. `dedupOrAdvance(data:hash:sourceApp:)` — content hash dedup + selective
    ///    모드 더블카피 확인
    /// 4. `route(data:sourceApp:hash:)` — selective 모드 큐잉 또는 normal 처리
    private func checkClipboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        let prevCount = lastChangeCount
        lastChangeCount = currentCount
        guard !isPaused else { return }

        let types = pasteboard.types?.map { $0.rawValue } ?? []
        ClipRavenLog.write(.clipboard, "[ClipMon] CHANGE \(prevCount)→\(currentCount) types=[\(types.joined(separator: ", "))]")

        let sourceApp = SourceAppTracker.currentApp()
        if shouldSkip(pasteboardTypes: pasteboard.types ?? [], sourceApp: sourceApp) {
            return
        }

        let clipboardData = readPasteboardData()
        let hasImage = clipboardData.imageData != nil
        ClipRavenLog.write(.clipboard, "[ClipMon] READ text=\(ClipRavenLog.redacted(clipboardData.text)) hasImage=\(hasImage) source=\(sourceApp.name ?? "?")")

        let contentHash = computeContentHash(clipboardData)
        guard handleContentDedup(data: clipboardData, hash: contentHash) else {
            return
        }

        guard clipboardData.text != nil || clipboardData.imageData != nil || clipboardData.fileURLs != nil else {
            ClipRavenLog.write(.clipboard, "[ClipMon] SKIP: empty clipboard")
            return
        }

        route(data: clipboardData, sourceApp: sourceApp, hash: contentHash)
    }

    // MARK: - checkClipboard helpers (B-CS5 분해)

    /// Pasteboard type / source app / sensitive content 검사로 early-skip 결정.
    /// 한 분기라도 skip 매치되면 true 반환 (caller 는 return).
    private func shouldSkip(
        pasteboardTypes: [NSPasteboard.PasteboardType],
        sourceApp: SourceAppInfo
    ) -> Bool {
        // 1. Self-detection marker (우리 paste 의 echo)
        if pasteboardTypes.contains(ClipboardMarker.selfType) {
            ClipRavenLog.write(.clipboard, "[ClipMon] SKIP: self-detection marker")
            return true
        }

        // 2. Universal Clipboard — 다른 device 에서 캡처해 sync 로 어차피 받음
        if pasteboardTypes.contains(.init(rawValue: "com.apple.is-remote-clipboard")) {
            ClipRavenLog.write(.clipboard, "[ClipMon] SKIP: Universal Clipboard remote item")
            Task { await clipProcessor.notifyUniversalClipboardSkipped() }
            return true
        }

        // 3. Concealed / transient / auto-generated 타입
        let skipTypes: [NSPasteboard.PasteboardType] = [
            .init(rawValue: "org.nspasteboard.ConcealedType"),
            .init(rawValue: "org.nspasteboard.TransientType"),
            .init(rawValue: "org.nspasteboard.AutoGeneratedType"),
            .init(rawValue: "de.petermaurer.TransientPasteboardType"),
            .init(rawValue: "com.agilebits.onepassword"),
            .init(rawValue: "com.typeit4me.clipping"),
        ]
        if pasteboardTypes.contains(where: { skipTypes.contains($0) }) {
            ClipRavenLog.write(.clipboard, "[ClipMon] SKIP: transient/concealed type")
            return true
        }

        // 4. 사용자 제외 앱
        if let bundleId = sourceApp.bundleId, excludedApps.contains(bundleId) {
            ClipRavenLog.write(.clipboard, "[ClipMon] SKIP: excluded app \(bundleId)")
            return true
        }

        // 5. 민감 데이터 (보안 감사 A-C2 default true)
        let blockSensitiveOn = UserDefaults.standard.object(forKey: "blockSensitive") as? Bool ?? true
        ClipRavenLog.write(.clipboard, "[ClipMon] sensitive check: blockSensitive=\(blockSensitiveOn) source=\(sourceApp.bundleId ?? "?") name=\(sourceApp.name ?? "?")")
        if blockSensitiveOn {
            if SensitiveDataFilter.isSensitive(pasteboard: pasteboard) {
                ClipRavenLog.write(.clipboard, "[ClipMon] SKIP: sensitive data detected (pasteboard ConcealedType)")
                return true
            }
            if let text = pasteboard.string(forType: .string) {
                let is2FA = SensitiveDataFilter.isLikelyTwoFactorCode(text)
                let hasPhrase = SensitiveDataFilter.containsTwoFactorPhrase(text)
                let filter2FAOn = UserDefaults.standard.object(forKey: "filter2FA") as? Bool ?? true
                // 이 줄은 "저장하지 않겠다" 고 판정하기 직전에 찍힌다. 본문을
                // 그대로 남기면 차단하려던 2FA 코드·비밀번호가 로그로 새어나가
                // 필터 자체가 무의미해진다 (보안 감사 P1).
                ClipRavenLog.write(.clipboard, "[ClipMon] text=\(ClipRavenLog.redacted(text)) is2FACandidate=\(is2FA) hasPhrase=\(hasPhrase) filter2FAOn=\(filter2FAOn)")
                if SensitiveDataFilter.isSensitiveWithContext(text, sourceApp: sourceApp) {
                    ClipRavenLog.write(.clipboard, "[ClipMon] SKIP: sensitive/2FA pattern detected (source=\(sourceApp.bundleId ?? "?"))")
                    return true
                }
            }
        }

        return false
    }

    /// Content hash 기반 dedup. 같은 hash 면 false 반환 (caller skip).
    /// 단 selective mode 의 double-copy 확정 케이스는 confirmPendingText 후 false.
    /// 새 hash 면 lastContentHash 갱신 후 true.
    private func handleContentDedup(data: ClipboardData, hash: String) -> Bool {
        if hash == lastContentHash {
            if selectiveModeEnabled, let pending = pendingSelectiveText, pending.hash == hash {
                let elapsed = Date().timeIntervalSince(pending.capturedAt) * 1000
                if elapsed >= 80 && elapsed <= doubleCopyWindowMs && !doubleCopyConfirmLock {
                    ClipRavenLog.write(.clipboard, "[ClipMon] SELECTIVE: double-copy confirmed elapsed=\(Int(elapsed))ms")
                    confirmPendingText(pending)
                    return false
                }
            }
            ClipRavenLog.write(.clipboard, "[ClipMon] SKIP: same content hash \(hash.prefix(16))")
            return false
        }
        ClipRavenLog.write(.clipboard, "[ClipMon] NEW hash=\(hash.prefix(16)) prev=\(lastContentHash.prefix(16))")
        lastContentHash = hash
        return true
    }

    /// 통과한 데이터를 selective mode 큐 또는 normal processing 으로 분기.
    private func route(data: ClipboardData, sourceApp: SourceAppInfo, hash: String) {
        if selectiveModeEnabled {
            if data.text != nil || data.fileURLs != nil {
                pendingSelectiveText = PendingTextCapture(
                    data: data,
                    sourceApp: sourceApp,
                    hash: hash,
                    capturedAt: Date()
                )
                ClipRavenLog.write(.clipboard, "[ClipMon] SELECTIVE: text queued, waiting for double-copy")
                return
            } else if let imageData = data.imageData {
                queueSelectiveImage(imageData: imageData, sourceApp: sourceApp)
                return
            }
        }

        // Normal mode
        ClipRavenLog.write(.clipboard, "[ClipMon] → PROCESSING")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let processor = self?.clipProcessor else { return }
            await processor.process(clipboardData: data, sourceApp: sourceApp)
            await MainActor.run {
                NotificationCenter.default.post(name: .clipRavenNewClipCaptured, object: nil)
            }
        }
    }

    /// Selective mode 의 이미지 캡처 큐잉 + popup 표시 요청.
    private func queueSelectiveImage(imageData: Data, sourceApp: SourceAppInfo) {
        let captureId = UUID().uuidString
        pendingImageCaptures[captureId] = PendingImageCapture(
            imageData: imageData,
            sourceApp: sourceApp
        )
        ClipRavenLog.write(.clipboard, "[ClipMon] SELECTIVE: image queued id=\(captureId)")
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

        // B-R5: processor 가 nil 이면 notification 도 발사 안 함 (가짜 피드백 방지).
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let processor = self?.clipProcessor else { return }
            await processor.process(
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
            guard let processor = self?.clipProcessor else { return }
            await processor.process(
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
        ClipRavenLog.write(.clipboard, "[ClipMon] SELECTIVE: image discarded id=\(id)")
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
