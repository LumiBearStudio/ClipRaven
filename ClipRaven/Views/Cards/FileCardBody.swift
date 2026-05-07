import SwiftUI
import AppKit
import ClipRavenSync

struct FileCardBody: View {
    let clip: Clip

    @State private var icons: [NSImage] = []
    @State private var primarySize: String?
    @Environment(\.colorScheme) var colorScheme

    private var paths: [String] {
        guard let text = clip.contentText else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private var isMultiple: Bool { paths.count > 1 }

    var body: some View {
        if isMultiple {
            multiView
        } else {
            singleView
        }
    }

    // MARK: - Single file / folder

    private var singleView: some View {
        let path = paths.first ?? ""
        let name = URL(fileURLWithPath: path).lastPathComponent

        return VStack(spacing: 8) {
            Group {
                if let icon = icons.first {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    fallbackIcon(for: path)
                }
            }
            .frame(width: 52, height: 52)

            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(colorScheme == .dark ? .white.opacity(0.95) : Color(NSColor.labelColor))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            HStack(spacing: 4) {
                if let size = primarySize {
                    Text(size)
                        .font(.system(size: 10))
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.55) : Color(NSColor.secondaryLabelColor))
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 9))
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.35) : Color(NSColor.tertiaryLabelColor))
                } else {
                    Text("파일 없음")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 10)
        .onAppear { loadIcons() }
    }

    // MARK: - Multiple files / folders

    private var multiView: some View {
        VStack(spacing: 8) {
            // Up to 4 icons in a 2×2 grid
            let displayPaths = Array(paths.prefix(4))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2),
                spacing: 4
            ) {
                ForEach(Array(displayPaths.enumerated()), id: \.offset) { idx, path in
                    Group {
                        if idx < icons.count {
                            Image(nsImage: icons[idx])
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            fallbackIcon(for: path)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
            }
            .frame(width: 56, height: 56)

            Text("\(paths.count)개 항목")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(colorScheme == .dark ? .white.opacity(0.95) : Color(NSColor.labelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 10)
        .onAppear { loadIcons() }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func fallbackIcon(for path: String) -> some View {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let name = exists && isDir.boolValue ? "folder" : "doc"
        Image(systemName: name)
            .font(.system(size: exists && isDir.boolValue ? 28 : 24))
            .foregroundColor(colorScheme == .dark ? .white.opacity(0.6) : Color(NSColor.secondaryLabelColor))
    }

    private func loadIcons() {
        let loadPaths = Array(paths.prefix(4))
        DispatchQueue.global(qos: .utility).async {
            var loaded: [NSImage] = []
            for path in loadPaths {
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 52, height: 52)
                loaded.append(icon)
            }

            var sizeStr: String? = nil
            if let first = loadPaths.first,
               let attrs = try? FileManager.default.attributesOfItem(atPath: first),
               let bytes = attrs[.size] as? Int64 {
                sizeStr = Self.formatFileSize(bytes)
            }

            DispatchQueue.main.async {
                icons = loaded
                primarySize = sizeStr
            }
        }
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}
