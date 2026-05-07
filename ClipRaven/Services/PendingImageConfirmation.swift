import Foundation

/// Carries a pending image clip that needs user confirmation before being saved.
/// Passed as `object` in `clipRavenImageNeedsConfirmation` notifications.
final class PendingImageConfirmation: @unchecked Sendable {
    let id: String
    let thumbnail: Data?
    let sourceAppName: String?
    let onConfirm: @Sendable () -> Void
    let onDiscard: @Sendable () -> Void

    init(
        id: String,
        thumbnail: Data?,
        sourceAppName: String?,
        onConfirm: @escaping @Sendable () -> Void,
        onDiscard: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.thumbnail = thumbnail
        self.sourceAppName = sourceAppName
        self.onConfirm = onConfirm
        self.onDiscard = onDiscard
    }
}
