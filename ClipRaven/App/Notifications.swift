import Foundation

extension Notification.Name {
    static let clipRavenHidePanel = Notification.Name("clipRavenHidePanel")
    static let clipRavenNewClipCaptured = Notification.Name("clipRavenNewClipCaptured")
    static let clipRavenTogglePause = Notification.Name("clipRavenTogglePause")
    static let clipRavenOpenSettings = Notification.Name("clipRavenOpenSettings")
    static let clipRavenTogglePreview = Notification.Name("clipRavenTogglePreview")
    static let clipRavenDeleteSelected = Notification.Name("clipRavenDeleteSelected")
    static let clipRavenQuickPaste = Notification.Name("clipRavenQuickPaste")
    static let clipRavenPlainTextPaste = Notification.Name("clipRavenPlainTextPaste")
    static let clipRavenPanelHeightChanged = Notification.Name("clipRavenPanelHeightChanged")
    static let clipRavenPanelShown        = Notification.Name("clipRavenPanelShown")
    static let clipRavenPanelHidden       = Notification.Name("clipRavenPanelHidden")
    static let clipRavenSearchOpened      = Notification.Name("clipRavenSearchOpened")
    static let clipRavenSearchClosed      = Notification.Name("clipRavenSearchClosed")
    static let clipRavenHotKeyChanged     = Notification.Name("clipRavenHotKeyChanged")
    /// Posted when the user starts dragging a clip to an external app.
    /// MainPanelController observes this to suppress auto-hide during drag.
    static let clipRavenExternalDragStarted = Notification.Name("clipRavenExternalDragStarted")
    /// Posted in selective mode when an image needs user confirmation before saving.
    /// object: PendingImageConfirmation
    static let clipRavenImageNeedsConfirmation = Notification.Name("clipRavenImageNeedsConfirmation")
    /// Posted when selective mode setting changes.
    static let clipRavenSelectiveModeChanged = Notification.Name("clipRavenSelectiveModeChanged")
    /// Posted to navigate Settings window to the About tab.
    static let clipRavenOpenAboutSection = Notification.Name("clipRavenOpenAboutSection")
    /// Posted when pause state actually changes. userInfo: ["isPaused": Bool]
    static let clipRavenPauseStateChanged = Notification.Name("clipRavenPauseStateChanged")
    /// Posted whenever the Option key is pressed/released while the panel is key.
    /// userInfo: ["pressed": Bool]. Used to overlay ⌥1..⌥0 hint badges on cards.
    static let clipRavenOptionKeyChanged = Notification.Name("clipRavenOptionKeyChanged")
    /// Posted when a user-assigned per-clip hotkey fires (or when AppDelegate needs to
    /// paste a specific clip by ID). userInfo: ["clipId": Int64].
    /// MainPanelViewModel observes this and invokes the full pasteClip flow.
    static let clipRavenPasteClipById = Notification.Name("clipRavenPasteClipById")
    /// Posted after MainPanelViewModel assigns/changes/removes a clip shortcut so
    /// AppDelegate can re-register Carbon. userInfo: ["clipId": Int64].
    static let clipRavenClipShortcutChanged = Notification.Name("clipRavenClipShortcutChanged")
    /// Posted when the user changes theme or color preset. AppKit windows observe this to update visual effect materials.
    static let clipRavenThemeChanged = Notification.Name("clipRavenThemeChanged")
    /// Posted when a drag session ends without completing a drop (cancelled or released outside drop zone).
    static let clipRavenDragSessionEnded = Notification.Name("clipRavenDragSessionEnded")
    /// 우리 코드가 직접 NSPasteboard에 write 한 직후 fire — AppDelegate가 listen해서
    /// ClipboardMonitor.markIntentionalWrite()를 호출, 다음 polling cycle이 그 변경을
    /// echo-back으로 잘못 캡처하는 걸 방지. (iOS의 동일 패턴과 같은 이름.)
    static let clipRavenIntentionalPasteboardWrite = Notification.Name("clipRavenIntentionalPasteboardWrite")
}
