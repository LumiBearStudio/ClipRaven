import Foundation

/// Kill switch for the entire iCloud sync subsystem.
///
/// Design intent:
/// - Default **off**. No CloudKit code path should execute unless this is true.
/// - Read cheaply and synchronously — it gates engine init, observer attach,
///   and every enqueue call. Keep it `UserDefaults.bool(forKey:)` level, no
///   network, no I/O.
/// - Toggleable without rebuilding the app. For emergencies a user or
///   developer can run:
///     defaults write com.lumibear.ClipRaven clipraven.sync.enabled -bool NO
///   and next launch will bring up no engine at all.
/// - The settings UI is deferred. Until it ships this flag is only set by
///   hand. Shipped binaries keep sync dormant by default.
///
/// Rollback criteria (from icloud-sync.plan.md):
/// - Engine crash, observable CRUD regression (>100ms added latency),
///   unexpected data loss, or account leakage → flip to false immediately,
///   quit the app, investigate before re-enabling.
public enum SyncFeatureFlag {
    private static let enabledKey = "clipraven.sync.enabled"

    /// Master switch. Engine is built only when this returns true AND
    /// `CKContainer.accountStatus` reports `.available`.
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Reserved for the future Settings UI. Writing this takes effect on
    /// next launch — hot reload of the engine is intentionally not supported
    /// to keep the lifecycle single-owner and predictable.
    public static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }
}
