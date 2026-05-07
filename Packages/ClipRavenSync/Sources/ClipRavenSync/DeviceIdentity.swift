import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Stable identifier for this installation of ClipRaven.
///
/// Generated on first access, persisted to UserDefaults, and stamped on every
/// clip this device creates. Other devices use it to attribute origin
/// ("이 클립은 iPhone에서 복사됨" 같은 UI 배지) and to reconcile self-authored
/// events returning through CloudKit.
///
/// Scope: per-installation. Reinstalling the app or resetting the sandbox
/// produces a fresh ID by design — the local DB is also fresh in that case.
public enum DeviceIdentity {
    private static let deviceIdKey = "clipraven.sync.deviceId"

    /// This installation's UUID. Side-effect on first call: writes to UserDefaults.
    public static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIdKey)
        return fresh
    }

    /// Human-readable name shown in "devices syncing" lists.
    /// - macOS: System Settings → General → Sharing → Computer Name (`Host.current().localizedName`).
    /// - iOS:   `UIDevice.current.name` — since iOS 16 this returns the model name (e.g. "iPhone")
    ///          unless the app has the `com.apple.developer.device-information.user-assigned-device-name`
    ///          entitlement, which is fine for our use (badges read "iPhone" / "iPad").
    public static var displayName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return "Unknown"
        #endif
    }

    /// Stored in CKRecord.platformCreatedOn so peer devices can render
    /// "iPhone에서 복사됨" / "Mac에서 복사됨" style badges.
    public static let platform: String = {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }()
}
