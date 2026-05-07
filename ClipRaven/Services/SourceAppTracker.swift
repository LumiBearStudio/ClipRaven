import AppKit

struct SourceAppInfo {
    let bundleId: String?
    let name: String?
    let icon: NSImage?
}

enum SourceAppTracker {
    static func currentApp() -> SourceAppInfo {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return SourceAppInfo(bundleId: nil, name: nil, icon: nil)
        }

        return SourceAppInfo(
            bundleId: frontApp.bundleIdentifier,
            name: frontApp.localizedName,
            icon: frontApp.icon
        )
    }

    /// Retrieve app icon from bundle identifier (for display in cards)
    static func icon(forBundleId bundleId: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}
