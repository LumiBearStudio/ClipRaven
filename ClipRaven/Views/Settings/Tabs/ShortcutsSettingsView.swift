import AppKit
import Carbon
import SwiftUI

/// 단축키 설정 탭 + KeyRecorder NSViewRepresentable.
struct ShortcutsSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var displayString = HotKeyStore.shared.displayString
    /// 저장하려던 조합이 거부된 이유 (없으면 nil).
    @State private var recordError: String?
    @State private var isRecording = false
    @State private var pendingKeyCode: UInt32?
    @State private var pendingModifiers: UInt32?

    var body: some View {
        Form {
            Section {
                Group {
                    LabeledContent("글로벌 단축키") {
                        HStack(spacing: 10) {
                            KeyRecorderView(
                                isRecording: $isRecording,
                                displayString: displayString,
                                onRecorded: { keyCode, modifiers in
                                    pendingKeyCode = keyCode
                                    pendingModifiers = modifiers
                                    displayString = HotKeyFormatter.format(keyCode: keyCode, modifiers: modifiers)
                                },
                                onCancel: {
                                    isRecording = false
                                    displayString = HotKeyStore.shared.displayString
                                }
                            )
                            .frame(width: 110, height: 28)

                            if !isRecording {
                                Button("변경") {
                                    isRecording = true
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(themeManager.colorPreset.accentColor)
                            } else {
                                Button("취소") {
                                    isRecording = false
                                    displayString = HotKeyStore.shared.displayString
                                    pendingKeyCode = nil
                                    pendingModifiers = nil
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            }

                            if let kc = pendingKeyCode, let mods = pendingModifiers {
                                Button("저장") {
                                    // 글자 입력을 가로채거나 시스템 단축키를 덮는 조합은
                                    // 저장하지 않는다 (v1 리뷰 M2).
                                    if let problem = HotKeyRules.problem(keyCode: kc, modifiers: mods, scope: .global) {
                                        recordError = problem
                                        return
                                    }
                                    recordError = nil
                                    HotKeyStore.shared.update(keyCode: kc, modifiers: mods)
                                    pendingKeyCode = nil
                                    pendingModifiers = nil
                                    displayString = HotKeyStore.shared.displayString
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }

                    Text("이 단축키로 ClipRaven 패널을 열고 닫습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let recordError {
                        Text(verbatim: recordError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if isRecording {
                        Text("키 조합을 입력하세요. ESC로 취소합니다.")
                            .font(.caption)
                            .foregroundStyle(themeManager.colorPreset.accentColor)
                    }
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.clipboardPanel")
            }
        }
        .darkFormStyle()
    }
}

// MARK: - Key Recorder (NSViewRepresentable)

struct KeyRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var displayString: String
    var onRecorded: (UInt32, UInt32) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyRecorderField {
        let field = KeyRecorderField()
        field.onRecorded = { kc, mods in
            DispatchQueue.main.async { onRecorded(kc, mods) }
        }
        field.onCancel = {
            DispatchQueue.main.async { onCancel() }
        }
        return field
    }

    func updateNSView(_ nsView: KeyRecorderField, context: Context) {
        nsView.displayString = displayString
        if nsView.isRecording != isRecording {
            nsView.isRecording = isRecording
            if isRecording {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

// MARK: - KeyRecorderField (NSView)

final class KeyRecorderField: NSView {
    var isRecording = false  { didSet { needsDisplay = true } }
    var displayString = ""   { didSet { needsDisplay = true } }
    var onRecorded: ((UInt32, UInt32) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 28) }

    // Key codes for pure modifier keys
    private let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),       UInt16(kVK_RightCommand),
        UInt16(kVK_Shift),         UInt16(kVK_RightShift),
        UInt16(kVK_Option),        UInt16(kVK_RightOption),
        UInt16(kVK_Control),       UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock),      UInt16(kVK_Function)
    ]

    override func draw(_ dirtyRect: NSRect) {
        // Background
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            (NSColor.separatorColor).setStroke()
        }
        path.fill()
        path.lineWidth = isRecording ? 1.5 : 1.0
        path.stroke()

        // Label
        let label = isRecording ? String(localized: "입력 중...") : displayString
        let color: NSColor = isRecording ? .controlAccentColor : .labelColor
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attrStr = NSAttributedString(string: label, attributes: attrs)
        let size = attrStr.size()
        let pt = NSPoint(
            x: max(8, (bounds.width  - size.width)  / 2),
            y: (bounds.height - size.height) / 2
        )
        attrStr.draw(at: pt)
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // ESC cancels
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            onCancel?()
            return
        }

        // Ignore pure modifier keys
        if modifierKeyCodes.contains(event.keyCode) { return }

        let mods = carbonModifiers(from: event.modifierFlags)
        onRecorded?(UInt32(event.keyCode), mods)
        isRecording = false
    }

    override func flagsChanged(with event: NSEvent) {
        // Redraw to show current modifier state while recording
        if isRecording { needsDisplay = true }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            onCancel?()
        }
        return super.resignFirstResponder()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey)     }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey)   }
        if flags.contains(.option)  { mods |= UInt32(optionKey)  }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}

