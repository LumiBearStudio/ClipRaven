import SwiftUI
import ClipRavenSync

struct EditorView: View {
    let clip: Clip
    var onSave: (Clip) -> Void = { _ in }

    @State private var editedText: String = ""
    @State private var hasChanges = false

    var body: some View {
        VStack(spacing: 0) {
            // Editor
            WritableTextView(
                text: $editedText,
                font: clip.contentType == .code
                    ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                    : NSFont.systemFont(ofSize: 12)
            )
            .padding(8)
            .onChange(of: editedText) { _ in
                hasChanges = editedText != (clip.contentText ?? "")
            }

            // Save bar
            HStack {
                if hasChanges {
                    Text("변경됨")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }

                Spacer()

                Button("취소") {
                    editedText = clip.contentText ?? ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))

                Button("저장") {
                    var updatedClip = clip
                    updatedClip.contentText = editedText
                    onSave(updatedClip)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasChanges)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onAppear {
            editedText = clip.contentText ?? ""
        }
    }
}
