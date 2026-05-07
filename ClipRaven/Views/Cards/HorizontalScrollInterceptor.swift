import AppKit

private func debugLog(_ msg: String) {
    ClipRavenLog.ui.debug("\(msg, privacy: .public)")
    #if DEBUG
    let line = "\(Date()): \(msg)\n"
    let logPath = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("clipraven_debug.log").path
    let data = Data(line.utf8)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
    #endif
}

/// NSPanel subclass that intercepts vertical scroll wheel events and converts
/// them to horizontal scrolling. Used as the panel class in MainPanelController
/// so that a normal mouse wheel (vertical) scrolls the horizontal card strip.
final class ScrollConvertingPanel: NSPanel {
    // Allow panel to become key window so TextField can receive keyboard input
    // and onTapGesture works properly, even with .nonactivatingPanel style
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // 검색창 열림 여부 추적 — FilterBarView에서 노티피케이션으로 동기화
    private var isSearchActive = false
    private var searchObservers: [Any] = []

    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        searchObservers.append(
            NotificationCenter.default.addObserver(
                forName: .clipRavenSearchOpened, object: nil, queue: .main
            ) { [weak self] _ in self?.isSearchActive = true }
        )
        searchObservers.append(
            NotificationCenter.default.addObserver(
                forName: .clipRavenSearchClosed, object: nil, queue: .main
            ) { [weak self] _ in self?.isSearchActive = false }
        )
        searchObservers.append(
            NotificationCenter.default.addObserver(
                forName: .clipRavenPanelHidden, object: nil, queue: .main
            ) { [weak self] _ in self?.isSearchActive = false }
        )
    }

    // Number key codes (1-9, 0) on main keyboard.
    // Value = logical slot (1..10), where 10 is the ⌥0 = 10th card shortcut.
    private static let numberKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10
    ]

    override func sendEvent(_ event: NSEvent) {
        // Detect Option key press/release so the UI can overlay ⌥1..⌥0 hint badges on cards.
        if event.type == .flagsChanged {
            let optionDown = event.modifierFlags.contains(.option)
            NotificationCenter.default.post(
                name: .clipRavenOptionKeyChanged,
                object: nil,
                userInfo: ["pressed": optionDown]
            )
            super.sendEvent(event)
            return
        }

        if event.type == .keyDown {
            // Check if a text field is focused
            let isTextFieldFocused = (self.firstResponder is NSTextView)

            // Debug: log every keydown reaching the panel
            let modsRaw = event.modifierFlags.rawValue
            let hasCmd = event.modifierFlags.contains(.command)
            let hasCtrl = event.modifierFlags.contains(.control)
            let hasOpt = event.modifierFlags.contains(.option)
            debugLog("[Panel.sendEvent] keyDown keyCode=\(event.keyCode) mods=0x\(String(modsRaw, radix: 16)) cmd=\(hasCmd) ctrl=\(hasCtrl) opt=\(hasOpt) textFieldFocused=\(isTextFieldFocused)")

            // ESC key handling
            if event.keyCode == 53 {
                // 검색창이 열려 있으면 (포커스 여부 무관) SwiftUI에게 넘겨 검색 닫기
                if isTextFieldFocused || isSearchActive {
                    super.sendEvent(event)
                    // 검색창이 열려있었다면 닫기 처리 — onExitCommand가 이미 처리하지만
                    // 포커스가 없는 경우를 위해 직접 닫기 알림도 발송
                    if isSearchActive && !isTextFieldFocused {
                        NotificationCenter.default.post(name: .clipRavenSearchClosed, object: nil)
                        isSearchActive = false
                    }
                    return
                }
                NotificationCenter.default.post(name: .clipRavenHidePanel, object: nil)
                return
            }

            // Skip keyboard shortcuts when text field is focused (allow normal typing)
            if isTextFieldFocused {
                super.sendEvent(event)
                return
            }

            // Delete/Backspace key (keyCode 51) — delete selected clip
            if event.keyCode == 51 {
                NotificationCenter.default.post(name: .clipRavenDeleteSelected, object: nil)
                return
            }

            // Forward Delete key (keyCode 117) — also delete selected clip
            if event.keyCode == 117 {
                NotificationCenter.default.post(name: .clipRavenDeleteSelected, object: nil)
                return
            }

            // Option+Enter — plain text paste
            if event.keyCode == 36 && event.modifierFlags.contains(.option) {
                NotificationCenter.default.post(name: .clipRavenPlainTextPaste, object: nil)
                return
            }

            // Space is handled by SwiftUI's .keyboardShortcut(" ") in MainPanelView
            // → opens DetailModalController (centered large preview). Do NOT intercept here.

            // Option+1~9 — quick paste.
            // We deliberately avoid ⌘ so there's no modifier-state conflict with the
            // synthesized ⌘V that simulatePaste() posts into the frontmost app.
            let isOption = event.modifierFlags.contains(.option)
            let notCmd = !event.modifierFlags.contains(.command)
            let notCtrl = !event.modifierFlags.contains(.control)
            if isOption && notCmd && notCtrl,
               let index = Self.numberKeyCodes[event.keyCode] {
                debugLog("[Panel.sendEvent] OPT+\(index) → post clipRavenQuickPaste index=\(index - 1)")
                NotificationCenter.default.post(
                    name: .clipRavenQuickPaste,
                    object: nil,
                    userInfo: ["index": index - 1]  // 0-based
                )
                return
            }
        }

        guard event.type == .scrollWheel else {
            super.sendEvent(event)
            return
        }

        // If already scrolling horizontally, pass through unchanged
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.sendEvent(event)
            return
        }

        // No meaningful vertical delta — pass through
        if abs(event.scrollingDeltaY) < 0.001 && event.deltaY == 0 {
            super.sendEvent(event)
            return
        }

        // Build a synthetic CGEvent with vertical and horizontal axes swapped
        guard let cgEvent = event.cgEvent?.copy() else {
            super.sendEvent(event)
            return
        }

        // Mouse wheel (non-precise) sends tiny line deltas (±1, ±2).
        // Amplify them so horizontal scrolling feels smooth.
        let amplify: Int64 = event.hasPreciseScrollingDeltas ? 1 : 2

        // CGEvent scroll wheel field constants:
        //   scrollWheelEventDeltaAxis1  (11)  — line delta vertical
        //   scrollWheelEventDeltaAxis2  (12)  — line delta horizontal
        //   scrollWheelEventFixedPtDeltaAxis1 (93) — fixed-point delta vertical
        //   scrollWheelEventFixedPtDeltaAxis2 (94) — fixed-point delta horizontal
        //   scrollWheelEventPointDeltaAxis1   (96) — pixel delta vertical
        //   scrollWheelEventPointDeltaAxis2   (97) — pixel delta horizontal
        let axisPairs: [(vertical: CGEventField, horizontal: CGEventField)] = [
            (.init(rawValue: 11)!, .init(rawValue: 12)!),
            (.init(rawValue: 93)!, .init(rawValue: 94)!),
            (.init(rawValue: 96)!, .init(rawValue: 97)!),
        ]

        for (v, h) in axisPairs {
            let verticalValue = cgEvent.getIntegerValueField(v) * amplify
            cgEvent.setIntegerValueField(h, value: verticalValue)
            cgEvent.setIntegerValueField(v, value: 0)
        }

        if let converted = NSEvent(cgEvent: cgEvent) {
            super.sendEvent(converted)
        } else {
            super.sendEvent(event)
        }
    }
}
