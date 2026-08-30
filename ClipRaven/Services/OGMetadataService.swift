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
    ///
    /// 사용자 동의: `DefaultsKey.linkPreviewEnabled` 가 ON 일 때만 동작하며
    /// **기본값은 OFF** 다 (보안 감사 P3-b). 이 fetch 는 사용자가 복사한 URL 로
    /// 앱이 직접 HTTP 요청을 보내는 것이라, 비밀번호 재설정 링크나 1회용
    /// 매직링크를 복사했을 때 ClipRaven 이 그 토큰을 대신 소진하거나 비공개
    /// URL 의 존재를 대상 서버에 알릴 수 있다. 게이트를 서비스 진입점에 두어
    /// 향후 호출자가 늘어도 동의 없이는 네트워크가 발생하지 않게 한다.
    ///
    /// 보안: SSRF 방어 — http(s) scheme 만 허용하고 private/loopback/link-local
    /// 주소 (192.168.*, 10.*, 127.*, 169.254.*, ::1 등) 는 fetch 차단.
    func fetchIfNeeded(clip: Clip) async {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.linkPreviewEnabled) else { return }
        guard clip.contentType == .url,
              let clipId = clip.id,
              clip.ogFetchedAt == nil,
              !inFlight.contains(clipId),
              let urlString = clip.contentText,
              let url = URL(string: urlString) ?? URL(string: "https://\(urlString)"),
              Self.isPubliclyRoutable(url)
        else { return }

        inFlight.insert(clipId)

        await fetchAndPersist(url: url, clipId: clipId)

        inFlight.remove(clipId)
    }

    /// SSRF 가드 — public 인터넷 hostname 만 허용.
    /// 보안 감사 A-H3: 사용자가 무심코 복사한 내부 IP (`192.168.1.1`,
    /// `169.254.169.254` AWS metadata 등) 가 자동으로 fetch 되어 OG 메타가
    /// CloudKit 으로 전파되던 위험.
    ///
    /// 차단:
    /// - 비-http(s) scheme (`file:`, `data:`, `javascript:`, etc.)
    /// - hostname 이 `localhost` / `*.local` / `*.internal`
    /// - IPv4 literal: 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16
    /// - IPv6 literal: `::1`, `fe80::/10` (link-local), `fc00::/7` (ULA)
    nonisolated static func isPubliclyRoutable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { return false }

        // hostname 식별자 차단
        if host == "localhost" { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }

        // IPv4 literal 검사
        let octets = host.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ Int($0) != nil }) {
            let parts = octets.compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            switch parts[0] {
            case 10, 127: return false                                  // 10/8, loopback
            case 169 where parts[1] == 254: return false                // link-local
            case 172 where (16...31).contains(parts[1]): return false   // 172.16/12
            case 192 where parts[1] == 168: return false                // 192.168/16
            case 0: return false                                         // 0.0.0.0/8
            default: break
            }
        }

        // IPv6 literal — bracketed: [::1], [fe80::...]
        if host.hasPrefix("[") {
            let inner = host.dropFirst().split(separator: "]").first.map(String.init) ?? ""
            let lower = inner.lowercased()
            if lower == "::1" { return false }
            if lower.hasPrefix("fe80:") || lower.hasPrefix("fe9") ||
               lower.hasPrefix("fea") || lower.hasPrefix("feb") {
                return false  // fe80::/10 link-local
            }
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") {
                return false  // fc00::/7 ULA
            }
        }

        return true
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
