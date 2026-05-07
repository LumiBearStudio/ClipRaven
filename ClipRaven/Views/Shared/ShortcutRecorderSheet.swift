import SwiftUI
import Carbon
import AppKit
import ClipRavenSync

/// Modal sheet for assigning a global hotkey to a specific clip.
///
/// Behaviour:
/// - Shows the current shortcut (if any), a recorder field, and Save/Cancel/Clear.
/// - ESC cancels recording.
/// - "저장" attempts Carbon registration; on failure (combo already in use) shows an inline error.
/// - Prevents ⌘V/⌘C/⌘X/⌘A etc. — these are common paste targets and blocking them makes paste useless.
struct ShortcutRecorderSheet: View {
    /// Initial shortcut to show (existing assignment, if any).
    let initialKeyCode: UInt32?
    let initialModifiers: UInt32?
    /// Clip ID — used to detect "same as currently assigned" in conflict check.
    let clipId: Int64?
    /// Called with the chosen (keyCode, modifiers) when the user presses Save.
    let onSave: (UInt32, UInt32) -> Void
    /// Called when the user clears the current shortcut.
    let onClear: () -> Void
    /// Called when the user cancels without saving.
    let onCancel: () -> Void

    @State private var isRecording = true
    @State private var pendingKeyCode: UInt32?
    @State private var pendingModifiers: UInt32?
    @State private var errorMessage: String?

    private let clipRepository = ClipRepository()

    private var displayString: String {
        if let kc = pendingKeyCode, let mods = pendingModifiers {
            return HotKeyFormatter.format(keyCode: kc, modifiers: mods)
        }
        if let kc = initialKeyCode, let mods = initialModifiers {
            return HotKeyFormatter.format(keyCode: kc, modifiers: mods)
        }
        return ""
    }

    private var hasPending: Bool { pendingKeyCode != nil && pendingModifiers != nil }
    private var hasExisting: Bool { initialKeyCode != nil && initialModifiers != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("클립 단축키 할당")
                    .font(.headline)
                Text("이 클립에 전역 단축키를 지정하면, 어느 앱에서든 그 키 조합으로 바로 붙여넣을 수 있어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Recorder
            HStack(spacing: 12) {
                KeyRecorderView(
                    isRecording: $isRecording,
                    displayString: displayString,
                    onRecorded: { keyCode, modifiers in
                        pendingKeyCode = keyCode
                        pendingModifiers = modifiers
                        errorMessage = validate(keyCode: keyCode, modifiers: modifiers)
                        // Stay in recording mode so user can retry if combo is invalid
                        isRecording = errorMessage != nil
                    },
                    onCancel: {
                        // ESC from within the recorder — discard pending and leave the sheet
                        pendingKeyCode = nil
                        pendingModifiers = nil
                        onCancel()
                    }
                )
                .frame(width: 140, height: 28)

                if isRecording {
                    Text("단축키를 입력하세요…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if hasPending {
                    Button("다시 입력") {
                        pendingKeyCode = nil
                        pendingModifiers = nil
                        errorMessage = nil
                        isRecording = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            // Inline validation error
            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Footer buttons
            HStack {
                if hasExisting {
                    Button(role: .destructive) {
                        onClear()
                    } label: {
                        Label("단축키 제거", systemImage: "minus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button("취소") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("저장") {
                    if let kc = pendingKeyCode, let mods = pendingModifiers {
                        onSave(kc, mods)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasPending || errorMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Validation

    /// Reject obvious conflicts before we waste a Carbon registration round-trip.
    /// Returns a Korean-language error string or nil if the combo looks acceptable.
    private func validate(keyCode: UInt32, modifiers: UInt32) -> String? {
        // Require at least one non-shift modifier — plain ⇧X types a capital letter everywhere.
        let meaningfulModifiers = modifiers & UInt32(cmdKey | controlKey | optionKey)
        if meaningfulModifiers == 0 {
            return "⌘ / ⌃ / ⌥ 중 하나 이상을 포함해야 합니다."
        }

        // Block the V key combined with just ⌘ — that IS paste; hijacking it breaks the paste action itself.
        if keyCode == UInt32(kVK_ANSI_V), modifiers == UInt32(cmdKey) {
            return "⌘V는 붙여넣기 단축키라 사용할 수 없습니다."
        }

        // Warn if another clip already uses this exact combo
        if let existing = try? clipRepository.fetchClipByShortcut(keyCode: keyCode, modifiers: modifiers),
           existing.id != clipId {
            let preview = (existing.contentText ?? "").prefix(30)
            return "이미 다른 클립(\"\(preview)…\")에 할당된 단축키입니다."
        }

        return nil
    }
}
