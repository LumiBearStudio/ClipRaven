import SwiftUI
import ClipRavenSync

/// Mac ClipCardView 디자인 언어를 iOS에 포팅.
/// 구조: ZStack 레이어 — 컨텐츠(헤더 공간+바디+푸터) / 헤더 오버레이 / 하단 오버레이
/// 사이즈: GeometryReader로 정사각형 고정 (LazyVGrid에서 aspectRatio만으로는 height 미제어)
struct ClipCard: View {

    let clip: Clip

    @Environment(\.colorScheme) private var colorScheme

    private var headerColor: Color { clip.contentType.themeColor }

    private var displayName: String {
        if let nickname = clip.nickname, !nickname.isEmpty { return nickname }
        return clip.contentType.displayName
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width
            ZStack {
                // Layer 1: 컨텐츠
                contentLayer(size: size)
                    .allowsHitTesting(false)

                // Layer 2: 컬러 헤더 오버레이 (항상 최상단)
                VStack(spacing: 0) {
                    cardHeader
                        .clipped()
                    Spacer()
                }

                // Layer 3: 이미지·URL 하단 오버레이
                if clip.contentType == .image || clip.contentType == .url {
                    VStack {
                        Spacer()
                        bottomOverlay
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size, height: size)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(0.07)
                    : Color.black.opacity(0.04)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.08)
                            : Color(UIColor.separator).opacity(0.4),
                        lineWidth: 0.5
                    )
            )
        }
        .aspectRatio(1.0, contentMode: .fit)
    }

    // MARK: - Content Layer

    @ViewBuilder
    private func contentLayer(size: CGFloat) -> some View {
        switch clip.contentType {
        case .image:
            imageBody(size: size)
        case .url:
            urlBody(size: size)
        default:
            VStack(spacing: 0) {
                Color.clear.frame(height: 38)
                cardBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                standardFooter
            }
        }
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: clip.contentType.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 28, height: 28)

            Text(displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(clip.lastCopiedAt, style: .relative)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            Spacer()

            if let appName = clip.sourceAppName, !appName.isEmpty {
                AppNameBadge(name: appName)
            }

            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.yellow)
                    .frame(width: 20, height: 20)
            }

            if clip.excludeFromSync {
                Image(systemName: "cloud.slash")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(
            LinearGradient(
                colors: [headerColor, headerColor.opacity(0.9)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    // MARK: - Body (텍스트 계열 — image/url은 contentLayer에서 직접 처리)

    @ViewBuilder
    private var cardBody: some View {
        switch clip.contentType {
        case .text:  textBody
        case .code:  codeBody
        case .color: colorBody
        case .file:  fileBody
        default:     EmptyView()
        }
    }

    private var textBody: some View {
        Text(clip.contentText ?? "")
            .font(.system(size: 12))
            .foregroundColor(colorScheme == .dark ? .white.opacity(0.85) : .primary)
            .lineLimit(10)
            .multilineTextAlignment(.leading)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var codeBody: some View {
        Text(clip.contentText ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .primary)
            .lineLimit(12)
            .multilineTextAlignment(.leading)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                colorScheme == .dark
                    ? Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.8)
                    : Color(UIColor.tertiarySystemBackground).opacity(0.9)
            )
    }

    private func imageBody(size: CGFloat) -> some View {
        Group {
            if let data = clip.thumbnail, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        // Phase C — 원본 가용성 인디케이터.
                        // imagePath 가 있고 디스크에도 있으면 "원본 있음" (HD 배지),
                        // 없으면 "썸네일만" (cloud 아이콘으로 다른 기기 영역 암시).
                        imageOriginalIndicator
                    }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                    .frame(width: size, height: size)
            }
        }
    }

    /// 이미지 클립에만 표시. 원본 disk-resident 여부 시각화.
    @ViewBuilder
    private var imageOriginalIndicator: some View {
        if let path = clip.imagePath, ImageStorageService.exists(relativePath: path) {
            // 원본이 이 기기에 있음 — paste 시 풀 해상도
            Text("HD")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.indigo.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
        } else {
            // 썸네일만 — 원본은 다른 기기에서만 또는 옵션 OFF 라 sync 안 됨
            Image(systemName: "icloud.slash")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.gray.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
        }
    }

    private func urlBody(size: CGFloat) -> some View {
        let raw = clip.contentText ?? ""
        let host = URL(string: raw)?.host?.replacingOccurrences(of: "www.", with: "") ?? raw

        return Group {
            if let data = clip.thumbnail, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 38)
                    VStack(spacing: 6) {
                        if let url = URL(string: raw), let urlHost = url.host,
                           let faviconURL = URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(urlHost)") {
                            AsyncImage(url: faviconURL) { phase in
                                if case .success(let img) = phase {
                                    img.resizable()
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                } else {
                                    Image(systemName: "globe")
                                        .font(.system(size: 22))
                                        .foregroundColor(.secondary.opacity(0.3))
                                }
                            }
                        } else {
                            Image(systemName: "globe")
                                .font(.system(size: 22))
                                .foregroundColor(.secondary.opacity(0.3))
                        }
                        Text(host)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var colorBody: some View {
        let hex = clip.contentText ?? "#888888"
        let color = Color(hex: hex) ?? .gray

        return VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)

            Text(hex.uppercased())
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileBody: some View {
        let paths = clip.contentText?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        let isMulti = paths.count > 1
        let label = isMulti
            ? String(localized: "\(paths.count)개 항목")
            : paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "파일")

        return VStack(spacing: 6) {
            Spacer()

            if let data = clip.thumbnail, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: isMulti ? "doc.on.doc.fill" : isDirectory(paths.first) ? "folder.fill" : "doc.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(headerColor.opacity(0.5))
            }

            Text(label)
                .font(.system(size: isMulti ? 11 : 10, weight: isMulti ? .medium : .regular))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            // Mac 전용 안내 — iPhone 에는 원본 파일이 없어 paste 시 path
            // 텍스트만 들어감을 명시. 키보드 익스텐션에서는 아예 숨김 처리.
            HStack(spacing: 3) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 9))
                Text("Mac 전용")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isDirectory(_ path: String?) -> Bool {
        guard let path else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Standard Footer (text/code/color/file)

    private var standardFooter: some View {
        HStack(spacing: 6) {
            if clip.contentType == .file {
                let paths = clip.contentText?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
                if paths.count > 1 {
                    Text("\(paths.count)개")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                } else if let path = paths.first {
                    let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
                    Text(ext.isEmpty ? String(localized: "파일") : ext)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
            } else if let text = clip.contentText {
                Text("\(text.count)자")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            LinearGradient(
                stops: [
                    .init(color: headerColor.opacity(0.5), location: 0.0),
                    .init(color: headerColor.opacity(0.7), location: 0.5),
                    .init(color: headerColor.opacity(0.85), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Bottom Overlay (image/URL)

    @ViewBuilder
    private var bottomOverlay: some View {
        if clip.contentType == .image {
            imageBottomOverlay
        } else if clip.contentType == .url {
            urlBottomOverlay
        }
    }

    private var imageBottomOverlay: some View {
        HStack {
            if let ocr = clip.ocrText, !ocr.isEmpty {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                    .padding(.leading, 8)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.45), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var urlBottomOverlay: some View {
        let urlText = clip.contentText ?? ""
        let domain: String = {
            if let url = URL(string: urlText) ?? URL(string: "https://\(urlText)") {
                return url.host ?? urlText
            }
            return urlText
        }()

        return HStack(spacing: 5) {
            AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=32")) { phase in
                if case .success(let img) = phase {
                    img.resizable()
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .frame(width: 14, height: 14)

            Text(domain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.45), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - App Name Badge

/// 소스 앱 이름을 2자리 이니셜 + 색상 배지로 표시.
/// 카드 헤더 우측에 배치 — 어느 앱에서 복사한 클립인지 한눈에 구분.
/// 색상은 앱 이름 hashValue → hue 매핑으로 앱별로 일관되게 고정.
private struct AppNameBadge: View {
    let name: String

    private var initials: String {
        let words = name.components(separatedBy: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var badgeColor: Color {
        // hashValue를 360으로 나눈 나머지 → hue. 앱 이름이 바뀌지 않는 한
        // 같은 앱은 항상 같은 색을 가짐 (cross-session 일관성).
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.95)
    }

    var body: some View {
        Text(initials)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(badgeColor)
            .frame(width: 20, height: 20)
            .background(Color.white.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - ContentType theme colors (Mac DesignTokens 동일 값)

extension ContentType {
    var themeColor: Color {
        switch self {
        case .text:  return Color(red: 0.25, green: 0.52, blue: 0.95)
        case .code:  return Color(red: 0.35, green: 0.75, blue: 0.55)
        case .url:   return Color(red: 0.95, green: 0.45, blue: 0.25)
        case .image: return Color(red: 0.85, green: 0.35, blue: 0.65)
        case .color: return Color(red: 0.90, green: 0.65, blue: 0.15)
        case .file:  return Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }
}

// MARK: - Color hex helper

private extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard (s.count == 6 || s.count == 8), let v = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8)  & 0xFF) / 255
            b = Double(v         & 0xFF) / 255
            a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8)  & 0xFF) / 255
            a = Double(v         & 0xFF) / 255
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

#Preview("Light") {
    ScrollView {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ClipCard(clip: Clip(contentType: .text, contentText: "이것은 텍스트 클립 미리보기입니다. 한국어 가독성을 위해 트래킹과 줄간격을 조정했습니다.", isPinned: true, lastCopiedAt: Date().addingTimeInterval(-180), uuid: "1"))
            ClipCard(clip: Clip(contentType: .code, contentText: "func calculate() -> Int {\n    return 42\n}", sourceAppName: "Xcode", uuid: "2"))
            ClipCard(clip: Clip(contentType: .url, contentText: "https://github.com/groue/GRDB.swift", nickname: "GRDB", uuid: "3"))
            ClipCard(clip: Clip(contentType: .color, contentText: "#5E72E4", nickname: "Brand Blue", uuid: "4"))
            ClipCard(clip: Clip(contentType: .image, ocrText: "Hello World — OCR", sourceAppName: "Photos", uuid: "5"))
            ClipCard(clip: Clip(contentType: .text, contentText: "짧은 텍스트", uuid: "6", excludeFromSync: true))
        }
        .padding(12)
    }
    .background(Color(.systemGroupedBackground))
}

#Preview("Dark") {
    ScrollView {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ClipCard(clip: Clip(contentType: .text, contentText: "이것은 텍스트 클립 미리보기입니다.", isPinned: true, uuid: "1"))
            ClipCard(clip: Clip(contentType: .code, contentText: "let x = 42\nprint(x)", sourceAppName: "VS Code", uuid: "2"))
            ClipCard(clip: Clip(contentType: .url, contentText: "https://apple.com", uuid: "3"))
            ClipCard(clip: Clip(contentType: .color, contentText: "#FF6B6B", uuid: "4"))
            ClipCard(clip: Clip(contentType: .image, uuid: "5"))
            ClipCard(clip: Clip(contentType: .file, contentText: "/Documents/report.pdf", uuid: "6"))
        }
        .padding(12)
    }
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}
