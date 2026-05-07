import UIKit
import UniformTypeIdentifiers
import GRDB
import os.log
import CryptoKit
import ClipRavenSync

class ShareViewController: UIViewController {

    private let log = Logger(subsystem: "com.lumibear.ClipRavenMobile.share", category: "ShareExt")

    private lazy var dbPool: DatabasePool? = {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
        ) else {
            log.error("App Group container missing — check entitlements")
            return nil
        }
        let dbURL = containerURL
            .appendingPathComponent("ClipRaven", isDirectory: true)
            .appendingPathComponent("clipraven.sqlite")
        do {
            var config = Configuration()
            config.foreignKeysEnabled = true
            return try DatabasePool(path: dbURL.path, configuration: config)
        } catch {
            log.error("dbPool init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "ClipRaven에 저장 중…")
        label.textAlignment = .center
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        Task { await processSharedItem() }
    }

    private func processSharedItem() async {
        guard let extensionContext else { return }
        guard let dbPool else {
            await complete(error: String(localized: "데이터베이스 접근 실패 (App Group 미설정)"))
            return
        }

        let items = extensionContext.inputItems.compactMap { $0 as? NSExtensionItem }
        guard let item = items.first,
              let providers = item.attachments,
              let provider = providers.first
        else {
            await complete(error: String(localized: "공유할 콘텐츠를 찾을 수 없음"))
            return
        }

        // 1) 이미지 우선 시도 — Photos/Safari image share 등 image extension
        //    먼저 검사. 메인앱 PasteboardCaptureService 의 우선순위와 동일.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            do {
                try await processImageItem(provider)
            } catch {
                log.error("image insert failed: \(error.localizedDescription, privacy: .public)")
                await complete(error: String(localized: "저장 실패: \(error.localizedDescription)"))
            }
            return
        }

        // 2) 텍스트/URL — 기존 흐름
        var text: String?
        var contentType: ContentType = .text

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil)
            text = (value as? URL)?.absoluteString ?? (value as? String)
            contentType = .url
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil)
            text = value as? String
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            let value = try? await provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil)
            text = value as? String
        }

        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            await complete(error: String(localized: "공유 가능한 텍스트 없음"))
            return
        }

        // If text looks like a URL but provider didn't declare URL type, override.
        if contentType == .text, let url = URL(string: trimmed), url.scheme != nil {
            contentType = .url
        }

        do {
            try await insertClip(text: trimmed, contentType: contentType)
            await complete(error: nil)
        } catch {
            log.error("insert failed: \(error.localizedDescription, privacy: .public)")
            await complete(error: String(localized: "저장 실패: \(error.localizedDescription)"))
        }
    }

    /// 이미지 attachment 처리 — UIImage 추출 → 썸네일 생성 → 원본 파일을
    /// App Group images/ 디렉토리에 저장 → Clip insert.
    ///
    /// 메인앱 ImageThumbnailMaker / ImageStorageService 와 같은 동작이지만
    /// 그 두 서비스가 ClipRavenMobile 메인 타겟에 있어 직접 import 불가.
    /// ShareExtension 은 ClipRavenSync 만 의존하므로 최소 로직 인라인.
    private func processImageItem(_ provider: NSItemProvider) async throws {
        let value = try await provider.loadItem(
            forTypeIdentifier: UTType.image.identifier, options: nil
        )

        // NSItemProvider 가 줄 수 있는 형태: UIImage / Data / URL (디스크 파일)
        let image: UIImage? = {
            if let img = value as? UIImage { return img }
            if let data = value as? Data, let img = UIImage(data: data) { return img }
            if let url = value as? URL,
               let data = try? Data(contentsOf: url),
               let img = UIImage(data: data) { return img }
            return nil
        }()
        guard let image else {
            await complete(error: String(localized: "공유 가능한 텍스트 없음"))
            return
        }

        // 썸네일 (max 200px JPEG q0.7) — 메인앱 ImageThumbnailMaker 와 동일 정책
        guard let thumbnail = Self.makeThumbnail(image),
              let thumbData = thumbnail.jpegData(compressionQuality: 0.7) else {
            await complete(error: String(localized: "저장 실패: \(NSLocalizedString("이미지를 불러올 수 없습니다", comment: ""))"))
            return
        }

        // SHA-256 hash — Mac/iOS 간 dedup 키
        let sourceData: Data = image.pngData() ?? image.jpegData(compressionQuality: 1.0) ?? thumbData
        let digest = SHA256.hash(data: sourceData)
        let imageHash = digest.map { String(format: "%02x", $0) }.joined()

        // 원본을 App Group/ClipRaven/images/<uuid>.png 로 저장 (sync 시 CKAsset 으로 첨부)
        let uuid = UUID().uuidString
        let fullData = image.pngData() ?? image.jpegData(compressionQuality: 0.95) ?? sourceData
        let imagePath = saveImageToAppGroup(data: fullData, uuid: uuid, ext: "png")

        let now = Date()
        let clip = Clip(
            contentType: .image,
            imageHash: imageHash,
            imagePath: imagePath,
            thumbnail: thumbData,
            sourceAppName: "Share Extension",
            createdAt: now,
            lastCopiedAt: now,
            uuid: uuid,
            deviceId: DeviceIdentity.deviceId,
            schemaVersion: 1,
            updatedAt: now,
            excludeFromSync: SyncFilters.shouldExclude(
                text: nil, sourceAppBundleId: nil
            )
        )
        try await dbPool?.write { db in
            var c = clip
            try c.save(db)
        }
        log.info("share-saved image uuid=\(uuid, privacy: .public) imagePath=\(imagePath ?? "nil", privacy: .public)")
        await complete(error: nil)
    }

    /// 이미지 데이터를 App Group images/ 폴더에 저장. 메인앱
    /// ImageStorageService.saveImage 와 동일 — 폴더 경로 일치 필수
    /// (메인앱의 cleanOrphanedImages 가 같은 폴더 enumerate).
    private func saveImageToAppGroup(data: Data, uuid: String, ext: String) -> String? {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
        ) else { return nil }
        let dir = groupURL.appendingPathComponent("ClipRaven/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(uuid).\(ext)"
        let url = dir.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            log.error("share-save image failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func makeThumbnail(_ image: UIImage, maxDim: CGFloat = 200) -> UIImage? {
        let originalSize = image.size
        let longSide = max(originalSize.width, originalSize.height)
        guard longSide > 0 else { return nil }
        if longSide <= maxDim { return image }
        let scale = maxDim / longSide
        let newSize = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func insertClip(text: String, contentType: ContentType) async throws {
        let now = Date()
        let normalized = TextNormalizer.normalize(text)
        let hash = XXHash64Wrapper.hash(normalized)
        var clip = Clip(
            contentType: contentType,
            contentText: text,
            contentHash: hash,
            sourceAppName: "Share Extension",
            createdAt: now,
            lastCopiedAt: now,
            uuid: UUID().uuidString,
            deviceId: DeviceIdentity.deviceId,
            schemaVersion: 1,
            updatedAt: now,
            excludeFromSync: SyncFilters.shouldExclude(text: text, sourceAppBundleId: nil)
        )
        try await dbPool?.write { db in
            try clip.save(db)
        }
        log.info("share-saved uuid=\(clip.uuid ?? "?", privacy: .public) type=\(contentType.rawValue, privacy: .public)")
    }

    @MainActor
    private func complete(error: String?) async {
        if let error {
            view.subviews.forEach { ($0 as? UILabel)?.text = error }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        } else {
            view.subviews.forEach { ($0 as? UILabel)?.text = String(localized: "✅ 저장됨") }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
