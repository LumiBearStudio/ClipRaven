import Foundation
import ClipRavenSync

// iOS-specific display helpers on the shared `Clip` model.

extension Clip {

    /// Title the iOS list row shows. Nickname → contentText → bracketed
    /// type fallback for non-text clips we can't render inline.
    var displayTitle: String {
        if let nick = nickname, !nick.isEmpty { return nick }
        if let text = contentText, !text.isEmpty {
            return String(text.prefix(120))
        }
        return "[\(contentType.displayName)]"
    }

    /// Origin badge — only shown for clips created on a DIFFERENT device.
    /// Returns the actual platform name from the iOS device registry, with
    /// "Mac" / "iPad" / "iPhone" as the typical values. Falls back to nil
    /// when this is our own device's clip (no badge needed).
    ///
    /// Currently we don't query the device_registry table from views, so
    /// this returns nil for own-device clips and a small `cloud.and.arrow.down`
    /// hint for foreign-device clips. The actual device name will be wired
    /// in once we expose a per-clip lookup.
    var isFromOtherDevice: Bool {
        guard let deviceId, !deviceId.isEmpty else { return false }
        return deviceId != DeviceIdentity.deviceId
    }

    /// AI category to display — filters out the "other" / empty placeholder
    /// values that don't add user-facing information.
    var displayableAiCategory: String? {
        guard let category = aiCategory,
              !category.isEmpty,
              category.lowercased() != "other"
        else { return nil }
        return category
    }
}
