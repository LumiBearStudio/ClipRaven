import Foundation
import os.log

/// 키보드 익스텐션이 main DB 에 직접 write 하지 않고 임시 파일에 저장 →
/// 메인 앱이 깨어날 때 처리하는 패턴.
///
/// 왜 이 패턴:
/// - 키보드가 main SQLite write 하면 0xDEAD10CC crash 위험 (process suspend
///   중 lock 보유 → iOS 강제 종료)
/// - JSON 단순 파일 IO 는 lock 없어 안전
/// - NSFileCoordinator 로 atomic write/read 보장
///
/// 위치: App Group `pending-captures.json`
public enum KeyboardCaptureBuffer {

    private static let log = Logger(
        subsystem: "com.lumibear.ClipRaven",
        category: "CaptureBuffer"
    )

    /// 키보드가 캡처한 단일 클립. 메인 앱 ClipRepository.insert 와 호환되는
    /// minimal 정보만.
    public struct PendingCapture: Codable {
        /// 'text' / 'url' / 'image' — ContentType.rawValue
        public let contentType: String
        /// 텍스트 클립이면 본문, 이미지 클립이면 nil
        public let contentText: String?
        /// 이미지 클립이면 thumbnail (Base64 PNG/JPEG), 텍스트면 nil
        /// 키보드는 원본 저장 위치 모르므로 thumbnail 만 동봉
        public let thumbnailBase64: String?
        /// imageHash (SHA-256 hex) — 이미지 dedup
        public let imageHash: String?
        /// 캡처 시각
        public let capturedAt: Date
        /// 키보드가 클립을 잡은 시점의 host 앱 정보 (선택)
        public let sourceHostBundleId: String?

        public init(
            contentType: String,
            contentText: String?,
            thumbnailBase64: String?,
            imageHash: String?,
            capturedAt: Date,
            sourceHostBundleId: String?
        ) {
            self.contentType = contentType
            self.contentText = contentText
            self.thumbnailBase64 = thumbnailBase64
            self.imageHash = imageHash
            self.capturedAt = capturedAt
            self.sourceHostBundleId = sourceHostBundleId
        }
    }

    /// App Group 의 pending JSON 파일 URL.
    public static func fileURL(appGroupIdentifier: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        return containerURL.appendingPathComponent("pending-captures.json")
    }

    // MARK: - Append (키보드 측)

    /// 새 capture 를 pending 파일에 append. atomic.
    /// - 기존 파일이 있으면 array 에 push
    /// - 없으면 새 array 로 생성
    public static func append(_ capture: PendingCapture, appGroupIdentifier: String) {
        guard let url = fileURL(appGroupIdentifier: appGroupIdentifier) else {
            log.error("App Group container missing — cannot buffer capture")
            return
        }

        let coordinator = NSFileCoordinator()
        var coordError: NSError?

        coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { writeURL in
            do {
                var captures: [PendingCapture] = []
                if let data = try? Data(contentsOf: writeURL) {
                    captures = (try? JSONDecoder().decode([PendingCapture].self, from: data)) ?? []
                }
                // 너무 많이 누적되면 (메인 앱이 오랫동안 안 깨어남) cap. 가장
                // 오래된 것부터 삭제.
                let cap = 200
                captures.append(capture)
                if captures.count > cap {
                    captures.removeFirst(captures.count - cap)
                }
                let encoded = try JSONEncoder().encode(captures)
                try encoded.write(to: writeURL, options: .atomic)
            } catch {
                Self.log.error("append failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let coordError {
            log.error("file coordinator error: \(coordError.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Peek (키보드 측 — read-only, 안 비움)

    /// pending captures 를 읽기만 함 (drain 과 달리 파일 안 비움).
    /// 키보드가 자기 표시용 — 메인 앱이 아직 처리 안 한 capture 도 카드에
    /// 즉시 보이도록 loadClips merge 시 사용.
    public static func peekAll(appGroupIdentifier: String) -> [PendingCapture] {
        guard let url = fileURL(appGroupIdentifier: appGroupIdentifier) else {
            return []
        }
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: [PendingCapture] = []

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            result = (try? JSONDecoder().decode([PendingCapture].self, from: data)) ?? []
        }
        return result
    }

    // MARK: - Drain (메인 앱 측)

    /// 모든 pending capture 를 읽고 파일 비움. 메인 앱이 launch / 활성화
    /// 시 호출.
    @discardableResult
    public static func drainAll(appGroupIdentifier: String) -> [PendingCapture] {
        guard let url = fileURL(appGroupIdentifier: appGroupIdentifier) else {
            return []
        }

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: [PendingCapture] = []

        coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { drainURL in
            guard let data = try? Data(contentsOf: drainURL) else { return }
            result = (try? JSONDecoder().decode([PendingCapture].self, from: data)) ?? []
            // 비움 — 다시 빈 array 로 atomic write (또는 파일 자체 삭제)
            try? FileManager.default.removeItem(at: drainURL)
        }
        if let coordError {
            log.error("drainAll coordinator error: \(coordError.localizedDescription, privacy: .public)")
        }

        if !result.isEmpty {
            log.info("drained \(result.count, privacy: .public) pending capture(s)")
        }
        return result
    }
}
