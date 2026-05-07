import Foundation
import CloudKit
import os.log

/// 플랫폼별 이미지 영구 저장소 추상화.
///
/// `SyncRecordMapper` 는 패키지(ClipRavenSync)에 살고, 두 플랫폼에서 공유된다.
/// Mac은 `~/Library/Application Support/ClipRaven/images/`, iOS는 App Group
/// 컨테이너 — 디렉터리 경로가 다르므로 mapper에서 직접 알 수 없다.
///
/// 각 플랫폼 메인 앱이 시작 시 `ImageOriginalStoreRegistry.register(...)` 로
/// 자기 구현을 등록하면, mapper가 encode/decode 시 lookup 한다.
public protocol ImageOriginalStore: Sendable {
    /// 상대 경로(파일명) 를 절대 URL 로.
    func fullURL(for relativePath: String) -> URL

    /// 다운로드한 원본 binary를 저장. uuid 기반 파일명 권장.
    /// 반환: 저장된 파일명 (relativePath) 또는 실패 시 nil.
    func saveOriginal(_ data: Data, uuid: String, preferredExt: String) -> String?
}

/// 글로벌 registry — 각 플랫폼 앱 launch 시 1회 등록.
public enum ImageOriginalStoreRegistry {
    /// nonisolated(unsafe) 사용 사유: Sendable 프로토콜 제약 + register 가
    /// 앱 시작 시점 1회만 호출되는 단순 참조 저장. 실제 race는 발생할 수 없음.
    nonisolated(unsafe) public private(set) static var current: ImageOriginalStore?

    public static func register(_ store: ImageOriginalStore) {
        current = store
    }
}

/// CKAsset upload/download용 임시 디렉터리 관리자.
///
/// CKAsset(fileURL:) 의 계약:
/// - 업로드 시 CloudKit이 파일을 백그라운드 캐시로 옮길 수 있음.
/// - **원본 파일을 그대로 넘기면 안 됨** — CloudKit이 이동/삭제할 수 있어
///   로컬 imagePath가 깨짐. 항상 사본을 만들어 staging 디렉터리에 두고
///   그 URL을 CKAsset에 전달.
/// - 업로드 ack 후 staging 파일은 우리가 정리.
///
/// 다운로드 시:
/// - CloudKit이 다운로드한 asset 파일은 `temporaryFileURL` 또는
///   `~/Library/Caches/...`에 임시로 살아있음. **즉시 우리 영구 디렉터리로
///   복사**해야 안전 (CloudKit이 캐시 비울 수 있음).
///
/// 동시성:
/// - 모든 메서드는 file I/O. 호출 측이 main thread 가급적 회피하도록 설계.
/// - 디렉터리 생성은 idempotent.
public final class AssetStaging {

    public static let shared = AssetStaging()

    private static let log = Logger(subsystem: "com.lumibear.ClipRaven", category: "AssetStaging")

    private init() {
        try? ensureDir(stagingDir)
    }

    // MARK: - Locations

    /// CKAsset 업로드 직전 사본을 두는 임시 디렉터리.
    /// `~/Library/Caches/` 하위 — OS가 압박 시 비울 수 있는 영역으로 의도적
    /// 선택 (영구 보관은 ImageStorageService가 담당).
    public var stagingDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("ClipRaven/CKStaging", isDirectory: true)
    }

    // MARK: - Stage (upload prep)

    /// 썸네일 Data를 임시 파일로 만들어 CKAsset 으로 포장.
    /// thumbnail은 inline Data field로도 보낼 수 있지만 CKAsset 경로를 쓰면
    /// 1MB 한도에서 자유롭고 CloudKit의 background transfer 사용 가능.
    /// 현 시점에선 inline (mapper에서 200KB 컷)을 유지하고 이 메서드는 미사용 —
    /// 향후 thumbnail이 더 커질 경우를 위해 보존.
    public func stageThumbnail(uuid: String, data: Data) -> CKAsset? {
        do {
            let url = thumbnailStagingURL(for: uuid)
            try ensureDir(url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            return CKAsset(fileURL: url)
        } catch {
            Self.log.error("stageThumbnail failed uuid=\(uuid, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 원본 파일(`sourcePath`)을 staging 으로 복사 후 CKAsset 으로 포장.
    /// `sizeCapBytes` 초과면 nil 반환 — 호출 측은 record 에 `assetExceeded`
    /// 플래그를 세워 다른 디바이스가 이 사실을 인지하게 한다.
    ///
    /// - Parameters:
    ///   - uuid: 클립 uuid (staging 파일명에 사용)
    ///   - sourcePath: 로컬 영구 저장된 원본 파일 URL
    ///   - sizeCapBytes: 0 이하 또는 .max 면 cap 없음
    /// - Returns: CKAsset 또는 nil
    public func stageOriginal(uuid: String, sourcePath: URL, sizeCapBytes: Int) -> CKAsset? {
        // 파일 존재/크기 체크
        guard FileManager.default.fileExists(atPath: sourcePath.path) else {
            Self.log.info("stageOriginal: source missing \(sourcePath.path, privacy: .public)")
            return nil
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: sourcePath.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if sizeCapBytes > 0 && sizeCapBytes != .max && size > sizeCapBytes {
            Self.log.info("stageOriginal: \(uuid, privacy: .public) size \(size) > cap \(sizeCapBytes) — skip")
            return nil
        }

        do {
            let stagingURL = originalStagingURL(for: uuid, ext: sourcePath.pathExtension)
            try ensureDir(stagingURL.deletingLastPathComponent())
            // 기존 staging 파일이 있으면 제거
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.copyItem(at: sourcePath, to: stagingURL)
            return CKAsset(fileURL: stagingURL)
        } catch {
            Self.log.error("stageOriginal failed uuid=\(uuid, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Cleanup

    /// 업로드 ack 후 또는 retry 포기 후 staging 파일 정리.
    /// idempotent — 파일이 없어도 에러 없음.
    public func cleanup(uuid: String) {
        let urls = [
            thumbnailStagingURL(for: uuid),
            // 알 수 없는 확장자도 시도 — glob 대신 단순 enum
            originalStagingURL(for: uuid, ext: "png"),
            originalStagingURL(for: uuid, ext: "jpg"),
            originalStagingURL(for: uuid, ext: "jpeg"),
            originalStagingURL(for: uuid, ext: "heic"),
        ]
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 앱 시작 시 호출 — N일 이상 된 staging 파일은 retry 큐에서 잊혀진
    /// 고아일 가능성이 높음. 7일 기본.
    public func purgeStaleStaging(olderThan days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let enumerator = FileManager.default.enumerator(
            at: stagingDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var purged = 0
        for case let url as URL in enumerator {
            guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if mod < cutoff {
                try? FileManager.default.removeItem(at: url)
                purged += 1
            }
        }
        if purged > 0 {
            Self.log.info("purged \(purged) stale staging files older than \(days) days")
        }
    }

    // MARK: - Asset Read (download path)

    /// 다운로드된 CKAsset의 fileURL 에서 Data 로드.
    /// CloudKit 캐시 영역에서 즉시 읽어 우리 영구 저장소로 옮기기 위함.
    public static func dataFromAsset(_ asset: CKAsset) -> Data? {
        guard let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Private

    private func thumbnailStagingURL(for uuid: String) -> URL {
        stagingDir.appendingPathComponent("\(uuid)_thumb.jpg")
    }

    private func originalStagingURL(for uuid: String, ext: String) -> URL {
        let safeExt = ext.isEmpty ? "bin" : ext
        return stagingDir.appendingPathComponent("\(uuid)_full.\(safeExt)")
    }

    private func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
