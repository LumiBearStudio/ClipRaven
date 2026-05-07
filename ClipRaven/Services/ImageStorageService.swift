import AppKit
import Foundation
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

    /// Create JPEG thumbnail from image data
    /// Returns compressed thumbnail data (typically 5-30KB)
    static func createThumbnail(from imageData: Data, maxDimension: CGFloat = 150) -> Data? {
        guard let image = NSImage(data: imageData) else { return nil }

        let originalSize = image.size
        guard originalSize.width > 0 && originalSize.height > 0 else { return nil }

        // Calculate thumbnail size maintaining aspect ratio
        let scale: CGFloat
        if originalSize.width > originalSize.height {
            scale = maxDimension / originalSize.width
        } else {
            scale = maxDimension / originalSize.height
        }

        // Don't upscale
        let finalScale = min(scale, 1.0)
        let newSize = NSSize(
            width: originalSize.width * finalScale,
            height: originalSize.height * finalScale
        )

        // Draw thumbnail
        let thumbnailImage = NSImage(size: newSize)
        thumbnailImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        thumbnailImage.unlockFocus()

        // Convert to JPEG data
        guard let tiffData = thumbnailImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
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
