import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ClipRavenSync

enum ImageStorageService {

    /// Base directory for storing original images.
    /// Exposed for BackupService — kept internal so only in-app code can read it.
    static var imagesDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("ClipRaven/images", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    // MARK: - Save

    /// Save image data to filesystem, returns relative path
    @discardableResult
    static func saveImage(_ data: Data, filename: String? = nil) -> String? {
        let name = filename ?? UUID().uuidString + ".png"
        let fileURL = imagesDirectory.appendingPathComponent(name)

        do {
            try data.write(to: fileURL)
            return name  // Return relative path
        } catch {
            ClipRavenLog.storage.error("Failed to save image: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Load

    /// Load image data from relative path
    static func loadImage(relativePath: String) -> Data? {
        let fileURL = imagesDirectory.appendingPathComponent(relativePath)
        return try? Data(contentsOf: fileURL)
    }

    /// Load image as NSImage from relative path
    static func loadNSImage(relativePath: String) -> NSImage? {
        guard let data = loadImage(relativePath: relativePath) else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Thumbnail

    /// Create JPEG thumbnail from image data — ImageIO 기반 (성능 감사 D-M5).
    ///
    /// 이전엔 `NSImage(data:) → lockFocus → draw → tiffRepresentation →
    /// NSBitmapImageRep` 체인이라 ① 풀사이즈 NSBitmapImageRep 디코드, ②
    /// off-screen window-server-backed 그래픽 컨텍스트 (lockFocus), ③ TIFF
    /// 라운드트립이 동시 일어나 4K 스크린샷 (8MB JPEG) 1장당 피크 메모리
    /// 80-120MB 도달. lockFocus 는 macOS 11 부터 thread-unsafe deprecated 경고
    /// 도 띄움.
    ///
    /// 새 흐름:
    /// 1. `CGImageSourceCreateWithData` 로 source 생성 (헤더만 파싱, 디코드 X)
    /// 2. `CGImageSourceCreateThumbnailAtIndex` 에 `kCGImageSourceThumbnailMaxPixelSize`
    ///    지정 → ImageIO 가 down-sample 디코드 (필요한 픽셀만 메모리에)
    /// 3. `CGImageDestinationCreateWithData(jpeg)` 로 JPEG encode (NSImage round-trip X)
    ///
    /// 결과: 4K 스크린샷 thumbnail 생성 시 피크 메모리 80~120MB → 5~12MB.
    /// 메인 스레드 의존성도 없어짐 (lockFocus 는 main 권장).
    static func createThumbnail(from imageData: Data, maxDimension: CGFloat = 150) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF orientation 반영
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceShouldCacheImmediately: false         // 메모리 보존
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            return nil
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.7
        ]
        CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    // MARK: - Delete

    /// Delete image file by relative path
    static func deleteImage(relativePath: String) {
        let fileURL = imagesDirectory.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Disk Usage

    /// Absolute URL for a relative path (filename) — `imagePath` 컬럼 값을
    /// 절대 경로로 변환할 때.
    static func fullURL(for relativePath: String) -> URL {
        imagesDirectory.appendingPathComponent(relativePath)
    }

    /// Calculate total disk usage of stored images in bytes
    static func diskUsage() -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: imagesDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }
}

// MARK: - ImageOriginalStore conformer

/// `ClipRavenSync.ImageOriginalStore` 어댑터.
/// 앱 시작 시 `ImageOriginalStoreRegistry.register(MacImageOriginalStore())` 호출.
struct MacImageOriginalStore: ImageOriginalStore {
    func fullURL(for relativePath: String) -> URL {
        ImageStorageService.fullURL(for: relativePath)
    }

    func saveOriginal(_ data: Data, uuid: String, preferredExt: String) -> String? {
        let filename = "\(uuid).\(preferredExt)"
        return ImageStorageService.saveImage(data, filename: filename)
    }
}
