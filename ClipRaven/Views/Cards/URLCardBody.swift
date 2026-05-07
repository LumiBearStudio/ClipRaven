import SwiftUI
import LinkPresentation
import ClipRavenSync

// MARK: - URL Card Body

struct URLCardBody: View {
    let clip: Clip
    @StateObject private var viewModel = URLCardViewModel()

    private var domain: String {
        let text = clip.contentText ?? ""
        if let url = URL(string: text) ?? URL(string: "https://\(text)") {
            return url.host ?? text
        }
        return text
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // 배경: OG 썸네일 or 플레이스홀더
                if let image = viewModel.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                    // 하단 gradient overlay (타이틀 가독성)
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.65)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(width: geo.size.width, height: geo.size.height)

                    // OG 타이틀
                    if let title = viewModel.ogTitle {
                        Text(title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }

                } else {
                    // 로딩 or 실패 플레이스홀더
                    Color.clear

                    VStack(spacing: 6) {
                        if viewModel.isLoading {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            FaviconView(domain: domain)
                                .frame(width: 20, height: 20)
                            Image(systemName: "globe")
                                .font(.system(size: 22))
                                .foregroundColor(.secondary.opacity(0.3))
                        }

                        Text(domain)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            viewModel.load(clip: clip)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class URLCardViewModel: ObservableObject {
    @Published var thumbnail: NSImage?
    @Published var ogTitle: String?
    @Published var isLoading = false

    private var observerToken: NSObjectProtocol?
    private var loadedClipId: Int64?

    func load(clip: Clip) {
        guard let clipId = clip.id else { return }

        // 동일 clip 재로드 방지
        if loadedClipId == clipId { return }
        loadedClipId = clipId

        // 1. DB 캐시 즉시 반영
        if let data = clip.thumbnail {
            thumbnail = NSImage(data: data)
        }
        ogTitle = clip.ogTitle

        // 2. 아직 fetch 안 된 경우 → OGMetadataService에 요청
        if clip.ogFetchedAt == nil {
            isLoading = thumbnail == nil
            Task {
                await OGMetadataService.shared.fetchIfNeeded(clip: clip)
            }
        }

        // 3. OG 갱신 알림 구독
        observerToken = NotificationCenter.default.addObserver(
            forName: .clipRavenOGMetadataUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let updatedId = notification.object as? Int64,
                  updatedId == clipId
            else { return }
            self.reloadFromDB(clipId: clipId)
        }
    }

    private func reloadFromDB(clipId: Int64) {
        Task { @MainActor in
            let repo = ClipRepository()
            guard let clip = try? repo.fetchById(clipId) else { return }
            if let data = clip.thumbnail {
                self.thumbnail = NSImage(data: data)
            }
            self.ogTitle = clip.ogTitle
            self.isLoading = false
        }
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - Favicon View

private struct FaviconView: View {
    let domain: String
    @State private var image: NSImage?

    private var faviconURL: URL? {
        URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=32")
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
            }
        }
        .onAppear { loadFavicon() }
    }

    private func loadFavicon() {
        guard let url = faviconURL else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let nsImage = NSImage(data: data) {
                DispatchQueue.main.async { self.image = nsImage }
            }
        }.resume()
    }
}
