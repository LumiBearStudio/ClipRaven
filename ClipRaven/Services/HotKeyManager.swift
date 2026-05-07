import Carbon
import AppKit

/// Manages ClipRaven's global hotkeys via Carbon.
///
/// **Two classes of hotkeys coexist:**
/// 1. The *global toggle* (opens/closes the main panel). Single, user-configurable.
/// 2. *Per-clip shortcuts* (v10 feature). The user assigns a shortcut to a specific
///    clip so pressing the combo pastes that clip into the frontmost app without
///    opening the panel. Any number can be registered.
///
/// Both categories share the app-wide Carbon event handler — we dispatch by
/// `EventHotKeyID.id` to the right callback.
///
/// **ID convention** (fits in OSType + UInt32):
/// - Global toggle: signature `"CRVN"`, id `1`
/// - Per-clip: signature `"CRVN"`, id `Int32(100 + clipId)`
final class HotKeyManager {
    typealias HotKeyHandler = () -> Void

    // Global toggle
    private var hotKeyRef: EventHotKeyRef?

    // Per-clip hotkeys (clipId → Carbon ref)
    private var clipHotkeys: [Int64: EventHotKeyRef] = [:]

    // Shared Carbon event handler (installed once; dispatches all hotkey events)
    private var eventHandler: EventHandlerRef?

    // Callbacks keyed by EventHotKeyID.id (1 = global, 100+clipId = per-clip)
    fileprivate static var handlers: [UInt32: HotKeyHandler] = [:]

    private static let signature = OSType(0x4352_564E)  // "CRVN"
    private static let globalToggleID: UInt32 = 1
    private static let clipHotkeyIDBase: UInt32 = 100

    /// Turn a clipId into its EventHotKeyID.id value.
    private static func clipHotkeyID(clipId: Int64) -> UInt32 {
        // Positive clipIds only (auto-increment primary key starts at 1).
        return clipHotkeyIDBase + UInt32(clipId)
    }

    deinit {
        unregister()
    }

    // MARK: - Shared event handler

    /// Install the shared Carbon event handler if not already installed.
    /// Safe to call multiple times.
    private func ensureHandlerInstalled() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if status != noErr {
            ClipRavenLog.hotkey.error("Failed to install event handler: \(status, privacy: .public)")
        }
    }

    // MARK: - Global toggle

    /// Register the global panel-toggle hotkey. Default: ⌘\ (Cmd+Backslash)
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_Backslash),
        modifiers: UInt32 = UInt32(cmdKey),
        handler: @escaping HotKeyHandler
    ) {
        ensureHandlerInstalled()

        // Unregister any existing global toggle first (e.g. after user changes key)
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        HotKeyManager.handlers[Self.globalToggleID] = handler

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.globalToggleID)
        var registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        // Carbon returns -9868 (eventHotKeyExistsErr) when another process already owns
        // the combo. The most common culprit is an old copy of ourselves that was
        // killed before Carbon released the registration, so retry briefly before giving up.
        if registerStatus == -9868 {
            for attempt in 1...5 {
                Thread.sleep(forTimeInterval: 0.2)
                registerStatus = RegisterEventHotKey(
                    keyCode,
                    modifiers,
                    hotKeyID,
                    GetApplicationEventTarget(),
                    0,
                    &hotKeyRef
                )
                if registerStatus == noErr {
                    ClipRavenLog.hotkey.info("Global hotkey registered on retry \(attempt, privacy: .public)")
                    break
                }
            }
        }

        if registerStatus != noErr {
            ClipRavenLog.hotkey.error("Failed to register global hotkey keyCode=\(keyCode, privacy: .public) modifiers=\(modifiers, privacy: .public): \(registerStatus, privacy: .public)")
        } else {
            ClipRavenLog.hotkey.info("Global hotkey registered keyCode=\(keyCode, privacy: .public) modifiers=\(modifiers, privacy: .public)")
        }
    }

    /// Unregister the global toggle hotkey and remove the shared event handler.
    /// Also clears all per-clip hotkeys.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        unregisterAllClipHotkeys()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        HotKeyManager.handlers.removeAll()
    }

    // MARK: - Per-clip hotkeys

    /// Register a global hotkey bound to a specific clip.
    /// - Returns: `true` on success. `false` if the OS rejects the combo
    ///   (already used system-wide, etc.). Silent no-op if identical hotkey is
    ///   already registered for this clip.
    @discardableResult
    func registerClipHotkey(
        clipId: Int64,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping HotKeyHandler
    ) -> Bool {
        ensureHandlerInstalled()

        // Replace any existing registration for this clip
        if let existing = clipHotkeys[clipId] {
            UnregisterEventHotKey(existing)
            clipHotkeys.removeValue(forKey: clipId)
        }

        let idValue = Self.clipHotkeyID(clipId: clipId)
        HotKeyManager.handlers[idValue] = handler

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: idValue)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            clipHotkeys[clipId] = ref
            return true
        } else {
            // Carbon returned an error (typically `eventHotKeyExistsErr` = -9878).
            // Common causes: combo already registered by system / another app.
            HotKeyManager.handlers.removeValue(forKey: idValue)
            ClipRavenLog.hotkey.error("Failed to register clip \(clipId) hotkey (keyCode=\(keyCode), modifiers=\(modifiers)): \(status, privacy: .public)")
            return false
        }
    }

    /// Unregister the per-clip hotkey (if any) associated with `clipId`.
    func unregisterClipHotkey(clipId: Int64) {
        if let ref = clipHotkeys[clipId] {
            UnregisterEventHotKey(ref)
            clipHotkeys.removeValue(forKey: clipId)
        }
        HotKeyManager.handlers.removeValue(forKey: Self.clipHotkeyID(clipId: clipId))
    }

    /// Unregister every per-clip hotkey. Called during full teardown.
    func unregisterAllClipHotkeys() {
        for (_, ref) in clipHotkeys {
            UnregisterEventHotKey(ref)
        }
        clipHotkeys.removeAll()
        // Remove all per-clip handler entries while keeping the global one intact
        HotKeyManager.handlers = HotKeyManager.handlers.filter { key, _ in
            key == Self.globalToggleID
        }
    }

    /// Returns true if a per-clip hotkey is currently registered for the given clip.
    func hasClipHotkey(clipId: Int64) -> Bool {
        clipHotkeys[clipId] != nil
    }
}

// MARK: - Carbon event dispatch

/// Single C-function callback shared by all hotkey registrations.
/// Reads the fired `EventHotKeyID` and routes to the matching handler.
private func hotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    if status == noErr {
        if let handler = HotKeyManager.handlers[hotKeyID.id] {
            ClipRavenLog.hotkey.info("Carbon event fired, dispatching handler id=\(hotKeyID.id, privacy: .public)")
            handler()
        } else {
            ClipRavenLog.hotkey.error("Carbon event fired but no handler for id=\(hotKeyID.id, privacy: .public) (registered ids=\(HotKeyManager.handlers.keys.sorted(), privacy: .public))")
        }
    } else {
        // Fallback: fire the global handler (prior behavior)
        ClipRavenLog.hotkey.error("GetEventParameter failed status=\(status, privacy: .public), firing global fallback")
        HotKeyManager.handlers[1]?()
    }
    return noErr
}
