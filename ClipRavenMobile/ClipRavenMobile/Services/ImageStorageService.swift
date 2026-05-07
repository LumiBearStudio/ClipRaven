import Foundation
import UIKit
import os.log
import ClipRavenSync

/// iOS-side 이미지 원본 저장소. App Group 컨테이너 내 `ClipRaven/images/`에
/// PNG/JPEG 원본 파일을 저장한다.
///
/// 왜 App Group:
/// - Widget/Keyboard extension도 이미지를 읽어야 함 (썸네일 외 큰 미리보기).
/// - 메인 앱이 sync로 받은 원본 binary를 extensions 와 공유.
///
/// 저장 정책:
/// - 파일명: `{uuid}.{ext}` — Mac과 동일 컨벤션.
/// - 확장자: `imagePath` 컬럼에 파일명만 (전체 경로 아님). 디렉터리는
///   런타임에 `imagesDirectory`로 결합.
/// - TTL: 30일 후 binary만 삭제 (메타/썸네일은 유지). 핀 고정 클립은 영구.
///   → 별도 `ImageStorageCleanup`에서 처리.
///
/// 이 서비스는 `Mac ImageStorageService`와 **동일 인터페이스**를 의도적으로
/// 가져가서, sync 로직(SyncRecordMapper.decode)이 양 플랫폼에서 같은 함수명
/// 으로 호출 가능하다. 단, Mac은 `~/Library/Application Support/ClipRaven/`
/// 인 반면 iOS는 App Group 컨테이너 — 차이는 internal.
enum ImageStorageService {

    private static let log = Logger(subsystem: "com.lumibear.ClipRavenMobile", category: "ImageStorage")

    /// App Group 식별자. 메인 앱/Widget/Keyboard 모두 같은 그룹.
    static let appGroupIdentifier = "group.com.lumibear.ClipRavenMobile"

    /// 원본 이미지 영구 저장 디렉터리.
    /// 앱 첫 실행/Phase C 활성 시 자동 생성.
    static var imagesDirectory: URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            // App Group 미설정 — fallback Documents (정상 빌드에서는 발생 안 함)
            log.error("App Group container missing — falling back to Documents")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dir = docs.appendingPathComponent("ClipRaven/images", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let dir = containerURL.appendingPathComponent("ClipRaven/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 절대 경로 빌더 — `imagePath` 가 파일명만 가지고 있을 때.
    static func fullURL(for relativePath: String) -> URL {
        imagesDirectory.appendingPathComponent(relativePath)
    }

    // MARK: - Save

    /// Data 를 `{uuid}.png` 파일로 저장. 이미 같은 이름이 있으면 덮어씀.
    /// 반환값: 파일명 (relative path) 또는 실패 시 nil.
    @discardableResult
    static func saveImage(_ data: Data, uuid: String, preferredExt: String = "png") -> String? {
        let filename = "\(uuid).\(preferredExt)"
        let url = imagesDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            log.error("saveImage failed uuid=\(uuid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// UIImage 를 PNG로 인코딩 후 저장.
    @discardableResult
    static func saveUIImage(_ image: UIImage, uuid: String) -> String? {
        guard let data = image.pngData() else {
            log.error("saveUIImage: pngData() returned nil for \(uuid, privacy: .public)")
            return nil
        }
        return saveImage(data, uuid: uuid, preferredExt: "png")
    }

    // MARK: - Load

    static func loadImage(relativePath: String) -> Data? {
        let url = fullURL(for: relativePath)
        return try? Data(contentsOf: url)
    }

    static func loadUIImage(relativePath: String) -> UIImage? {
        guard let data = loadImage(relativePath: relativePath) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Delete

    static func deleteImage(relativePath: String) {
        let url = fullURL(for: relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Disk Usage

    /// 모든 저장된 이미지 합계 (바이트). Settings UI 사용량 표시용.
    static func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: imagesDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - File existence

    static func exists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: fullURL(for: relativePath).path)
    }
}

// MARK: - ImageOriginalStore conformer

/// `ClipRavenSync.ImageOriginalStore` 프로토콜 어댑터.
/// 앱 시작 시점에 `ImageOriginalStoreRegistry.register(IOSImageOriginalStore())`
/// 호출 — sync 패키지가 플랫폼별 영구 저장 위치를 알게 된다.
struct IOSImageOriginalStore: ImageOriginalStore {
    func fullURL(for relativePath: String) -> URL {
        ImageStorageService.fullURL(for: relativePath)
    }

    func saveOriginal(_ data: Data, uuid: String, preferredExt: String) -> String? {
        ImageStorageService.saveImage(data, uuid: uuid, preferredExt: preferredExt)
    }
}
