import AppKit
import LinkPresentation
import Foundation
import ClipRavenSync

/// LPMetadataProvider를 사용해 URL 클립의 OG 메타데이터(타이틀, 썸네일)를 fetch하고
/// DB에 저장한다. 이미 fetch 시도한 클립(ogFetchedAt != nil)은 재요청하지 않는다.
actor OGMetadataService {
    static let shared = OGMetadataService()

    private var inFlight: Set<Int64> = []
    private let clipRepository = ClipRepository()

    // MARK: - Public

    /// 클립이 URL 타입이고 아직 미시도인 경우 fetch를 시작한다.
    func fetchIfNeeded(clip: Clip) async {
        guard clip.contentType == .url,
              let clipId = clip.id,
              clip.ogFetchedAt == nil,
              !inFlight.contains(clipId),
              let urlString = clip.contentText,
              let url = URL(string: urlString) ?? URL(string: "https://\(urlString)")
        else { return }

        inFlight.insert(clipId)

        await fetchAndPersist(url: url, clipId: clipId)

        inFlight.remove(clipId)
    }

    // MARK: - Private

    private func fetchAndPersist(url: URL, clipId: Int64) async {
        // LPMetadataProvider는 반드시 메인 스레드에서 호출
        let metadata: LPLinkMetadata? = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                let provider = LPMetadataProvider()
                provider.timeout = 8
                provider.startFetchingMetadata(for: url) { metadata, _ in
                    cont.resume(returning: metadata)
                }
            }
        }

        let title = metadata?.title

        // OG 이미지 로드 (imageProvider → NSImage → PNG Data)
        var thumbnailData: Data? = nil
        if let imageProvider = metadata?.imageProvider {
            thumbnailData = await loadImageData(from: imageProvider)
        }

        // DB 저장
        do {
            try clipRepository.updateOGMetadata(
                clipId: clipId,
                title: title,
                thumbnailData: thumbnailData,
                fetchedAt: Date()
            )
        } catch {
            // fetch 자체는 성공했지만 저장 실패 — 로그만 남기고 계속
        }

        // MainPanelViewModel / URLCardViewModel에게 갱신 알림
        await MainActor.run {
            NotificationCenter.default.post(
                name: .clipRavenOGMetadataUpdated,
                object: clipId
            )
        }
    }

    private func loadImageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let image = obj as? NSImage,
                      let tiff   = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png    = bitmap.representation(using: .png, properties: [:])
                else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: png)
            }
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let clipRavenOGMetadataUpdated = Notification.Name("clipRavenOGMetadataUpdated")
}
