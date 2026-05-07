import Foundation
import UIKit
import GRDB
import WidgetKit
import os.log
import ClipRavenSync

/// Foreground 클립보드 캡처 — 앱이 활성 상태일 때 `UIPasteboard.general`을
/// 폴링해서 새 텍스트를 로컬 DB에 저장한다.
///
/// 왜 폴링?
/// iOS는 macOS의 NSPasteboard.changeCount 폴링과 달리 **앱이 백그라운드일
/// 때 클립보드 접근을 차단**한다 (iOS 14+ 토스트 알림, iOS 16+ 명시 권한).
/// 따라서:
/// - 백그라운드 자동 캡처 불가 → 앱이 foreground일 때만
/// - `pasteboardChangedNotification` (iOS 자체 NotificationCenter 이벤트)
///   가 동작하지만 실제로는 same-app 변경에만 fire 함 — 외부 앱에서 복사한
///   변경은 알림되지 않음. 그래서 앱 활성화 시 1회 + 짧은 폴링 루프로 보완.
///
/// 권한 토스트:
/// `UIPasteboard.string` 또는 `.hasStrings` 둘 중 하나만 호출해도 사용자에게
/// "ClipRaven에서 클립보드에 접근했습니다" 토스트가 표시됨. 빈도를 줄이려고:
/// - `hasStrings`로 먼저 비싼지 확인 (toast trigger 동일하지만 명시적)
/// - changeCount 비교로 같은 클립을 여러 번 저장하지 않음
///
/// 정책:
/// - `SyncFeatureFlag.isEnabled` 가 OFF여도 캡처는 함 (로컬 저장은 동기화와
///   별개 기능). 동기화는 SyncChangeCapture가 ON일 때만 enqueue.
/// - `SyncFilters.shouldExclude` 결과가 true면 `excludeFromSync = 1`로
///   저장. Mac과 동일.
@MainActor
final class PasteboardCaptureService {

    private let repository: ClipRepository
    private let dbPool: DatabasePool
    private let log = Logger(subsystem: "com.lumibear.ClipRavenMobile", category: "Capture")

    /// 마지막으로 처리한 changeCount. 같은 클립이 여러 활성 사이클에 걸쳐
    /// 중복 저장되지 않도록 추적.
    private var lastChangeCount: Int = -1

    /// 같은 텍스트의 contentHash를 잠시 기억해 더블-탭 같은 빠른 중복을 막는다.
    /// 더 강한 dedup은 DB의 `idx_clips_contentHash` + UNIQUE uuid가 처리.
    private var recentHashes: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 2.0

    /// Cross-device sync 윈도우. Universal Clipboard와 우리 CKSyncEngine
    /// 둘 다 같은 콘텐츠를 가져오는 race condition 방지용.
    /// Universal Clipboard latency는 보통 1–10초, 안전하게 30초 잡는다.
    private let crossDeviceWindow: TimeInterval = 30

    init(repository: ClipRepository = ClipRepository()) {
        self.repository = repository
        self.dbPool = AppDatabase.shared.dbPool
        // Seed with current value so the very first capture-on-launch
        // doesn't double-save a clipboard that's been there since reboot.
        self.lastChangeCount = UIPasteboard.general.changeCount
    }

    /// 우리가 직접 UIPasteboard에 write 한 후 호출 — 다음 capture cycle이
    /// 그 write를 자기 변경으로 잘못 인식해 echo-back 클립을 만드는 걸 방지.
    ///
    /// 예: ClipListView의 "복사" context menu가 `UIPasteboard.general.string =
    /// clip.contentText` 호출 → changeCount 증가 → 사용자가 앱을 background
    /// → foreground 하면 captureCurrentClipboard가 그 변경을 캡처하려 함.
    /// 이 함수를 write 직후 부르면 lastChangeCount를 갱신해서 다음 사이클이
    /// no-op이 됨.
    func markIntentionalWrite() {
        lastChangeCount = UIPasteboard.general.changeCount
    }

    /// 앱 foreground 진입, ClipListView .task, 또는 명시적 사용자 액션
    /// (예: "지금 캡처" 버튼) 에서 호출. 토스트 알림이 한 번 뜬다.
    ///
    /// 우선순위:
    /// 1. 텍스트가 있으면 텍스트 클립으로 저장 (Mac 동작과 동일 — 텍스트
    ///    + 이미지가 같이 있는 경우 텍스트 우선)
    /// 2. 텍스트 없고 이미지만 있으면 이미지 클립으로 저장 (썸네일 추출)
    /// 3. 둘 다 없으면 no-op
    func captureCurrentClipboard() async {
        let pasteboard = UIPasteboard.general

        // No change since last check — skip without touching pasteboard
        // accessors (avoids the iOS toast for a no-op).
        let currentChange = pasteboard.changeCount
        guard currentChange != lastChangeCount else { return }
        lastChangeCount = currentChange

        // Skip Universal Clipboard items that originated on another device.
        // The originating device captured and will upload to CloudKit; we
        // receive it via SyncEngine instead of creating a duplicate here.
        if pasteboard.contains(pasteboardTypes: ["com.apple.is-remote-clipboard"]) {
            log.info("skip capture — Universal Clipboard remote item")
            return
        }

        // Text takes priority (matches Mac ClipProcessor behavior).
        if pasteboard.hasStrings, let text = pasteboard.string {
            await captureText(text)
            return
        }

        // No text → check for image. UIPasteboard.image extracts UIImage
        // from PNG/JPEG/HEIC etc. that copy from Photos / Safari supplies.
        if pasteboard.hasImages, let image = pasteboard.image {
            await captureImage(image)
            return
        }
    }

    private func captureText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // In-memory dedupe — same text within 2s shouldn't double-save.
        cleanExpiredHashes()
        let hash = stableHash(of: trimmed)
        if recentHashes[hash] != nil { return }
        recentHashes[hash] = Date()

        // Cross-device dedup — Apple Universal Clipboard mirrors Mac→iOS
        // clipboard automatically + our CKSyncEngine also delivers the
        // clip. If the same content arrived from another device within
        // the recent window, suppress the local capture (it'd be a
        // duplicate UUID for the same content).
        if await wasJustSyncedFromOtherDevice(text: trimmed) {
            log.info("skip capture — cross-device sync race detected")
            return
        }

        do {
            // contentHash dedup — 키보드 익스텐션이 같은 텍스트를 pending 으로
            // 잡고 메인 앱 active 시점에 captureCurrentClipboard 도 같이 잡아
            // 두 경로로 중복 INSERT 되는 케이스 방지.
            let normalized = TextNormalizer.normalize(trimmed)
            let hash = XXHash64Wrapper.hash(normalized)
            if (try repository.incrementIfExists(contentHash: hash)) != nil {
                log.info("captured text — dedup skip (hash exists)")
                return
            }
            let clip = try repository.insert(text: trimmed)
            log.info("captured text uuid=\(clip.uuid ?? "?", privacy: .public) excluded=\(clip.excludeFromSync, privacy: .public)")
            // 새 클립 캡처 시 위젯 즉시 갱신
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            log.error("capture text failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 같은 텍스트의 클립이 다른 device에서 최근 N초 내에 sync되어 들어왔는지 확인.
    /// Universal Clipboard race 방지의 핵심. DB-driven이라 sync 이벤트와의
    /// in-memory 동기화 불필요.
    ///
    /// 매칭 기준:
    /// - `contentText` 완전 일치 (TextNormalizer 미적용 — Mac과 iOS의 정규화가
    ///   다를 수 있어서, 정확한 byte-equal로 안전하게)
    /// - `deviceId` 가 이 device 가 아닌 것 (다른 device에서 만든 거)
    /// - `ckLastSyncedAt` 이 N초 이내
    private func wasJustSyncedFromOtherDevice(text: String) async -> Bool {
        let cutoff = Date().addingTimeInterval(-crossDeviceWindow)
        let myDeviceId = DeviceIdentity.deviceId
        do {
            return try await dbPool.read { db in
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM clips
                    WHERE contentText = ?
                      AND (deviceId IS NULL OR deviceId != ?)
                      AND ckLastSyncedAt IS NOT NULL
                      AND ckLastSyncedAt > ?
                      AND isDeleted = 0
                """, arguments: [text, myDeviceId, cutoff]) ?? 0
                return count > 0
            }
        } catch {
            log.error("dedup query failed: \(error.localizedDescription, privacy: .public)")
            return false  // fail-open — better duplicate than silent drop
        }
    }

    private func captureImage(_ image: UIImage) async {
        guard let processed = ImageThumbnailMaker.process(image) else {
            log.error("failed to process pasteboard image")
            return
        }

        cleanExpiredHashes()
        if recentHashes[processed.hash] != nil { return }
        recentHashes[processed.hash] = Date()

        // Cross-device dedup — two strategies, either can short-circuit:
        //
        // 1. Hash match: works when both platforms produce identical hashes.
        //    Mac converts TIFF→PNG then SHA-256; iOS re-encodes UIImage→PNG
        //    then SHA-256. Same pixel data but different codec → hash mismatch
        //    is common.  Keep this check for the cases where it does match.
        //
        // 2. Time window: if ANY image clip was created by another device
        //    within the last 30 seconds, assume it's the same Universal
        //    Clipboard change and skip.  When Mac is awake it always captures
        //    first via its 0.5s polling; when Mac is off no such record
        //    exists and iOS captures normally.
        if await wasJustCapturedImageFromOtherDevice(hash: processed.hash) {
            log.info("skip image capture — cross-device duplicate detected")
            return
        }

        // Phase C — 옵션이 .full 일 때만 원본 PNG를 App Group에 저장.
        // 저장된 파일명을 imagePath 컬럼에 기록 → SyncRecordMapper 가 다음
        // 업로드 사이클에 CKAsset 으로 전송.
        // .thumbnailOnly / .off 모드면 imagePath 미설정 (썸네일만 sync).
        let savedPath: String? = {
            guard ImageSyncSettings.current().mode == .full,
                  let pngData = image.pngData()
            else { return nil }
            // uuid 가 아직 결정 안 됐으므로 임시 uuid 로 저장 후 필요 시 rename.
            // 단순화: 새 uuid 생성 → 동일 uuid 를 insertImage 에 전달했으면
            // 좋겠지만 repository.insertImage 내부에서 uuid 생성 → 약간의
            // 불일치. 향후 insertImage 가 uuid 매개변수를 받도록 리팩토링.
            // 현재로선 임시 uuid 사용 → DB 저장 후 imagePath 만 의미가 있고
            // 파일명은 어차피 그 imagePath 를 그대로 따라가므로 문제 없음.
            let tempUuid = UUID().uuidString
            return ImageStorageService.saveImage(pngData, uuid: tempUuid, preferredExt: "png")
        }()

        do {
            // imageHash dedup — 키보드 pending 과 메인 앱 capture 양쪽이
            // 같은 이미지를 잡아 중복 INSERT 되는 거 방지.
            if (try repository.incrementIfExists(imageHash: processed.hash)) != nil {
                log.info("captured image — dedup skip (hash exists)")
                return
            }
            let clip = try repository.insertImage(
                thumbnail: processed.thumbnail,
                imageHash: processed.hash,
                imagePath: savedPath
            )
            log.info("captured image uuid=\(clip.uuid ?? "?", privacy: .public) thumbBytes=\(processed.thumbnail.count, privacy: .public)")
            WidgetCenter.shared.reloadAllTimelines()

            // Background OCR — don't block capture path.
            if let clipId = clip.id {
                Task.detached(priority: .utility) { [dbPool] in
                    await ImageOCRService.runAndStore(
                        clipId: clipId,
                        imageData: processed.thumbnail,
                        dbPool: dbPool
                    )
                }
            }
        } catch {
            log.error("capture image failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns true if another device captured an image clip that is likely
    /// the same Universal Clipboard event.  Two-tier check:
    /// - Tier 1: exact imageHash match within the sync window (fast path)
    /// - Tier 2: any image from another device created within 30 s (covers
    ///   hash-mismatch cases caused by platform codec differences)
    private func wasJustCapturedImageFromOtherDevice(hash: String) async -> Bool {
        let syncCutoff = Date().addingTimeInterval(-crossDeviceWindow)
        let ucCutoff   = Date().addingTimeInterval(-30) // Universal Clipboard latency
        let myDeviceId = DeviceIdentity.deviceId
        do {
            return try await dbPool.read { db in
                // Tier 1: hash match
                let byHash = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM clips
                    WHERE imageHash = ?
                      AND (deviceId IS NULL OR deviceId != ?)
                      AND ckLastSyncedAt IS NOT NULL
                      AND ckLastSyncedAt > ?
                      AND isDeleted = 0
                """, arguments: [hash, myDeviceId, syncCutoff]) ?? 0
                if byHash > 0 { return true }

                // Tier 2: time-window match (handles platform codec divergence)
                let byTime = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM clips
                    WHERE contentType = 'image'
                      AND (deviceId IS NULL OR deviceId != ?)
                      AND createdAt > ?
                      AND isDeleted = 0
                """, arguments: [myDeviceId, ucCutoff]) ?? 0
                return byTime > 0
            }
        } catch { return false }
    }

    private func cleanExpiredHashes() {
        let now = Date()
        recentHashes = recentHashes.filter { now.timeIntervalSince($0.value) < dedupeWindow }
    }

    private func stableHash(of text: String) -> String {
        // Lightweight checksum — only needs to be unique enough for the
        // 2-second dedupe window. The DB-level dedup uses the proper
        // contentHash from ClipRepository.insert.
        var hasher = Hasher()
        hasher.combine(text)
        return String(hasher.finalize())
    }
}
