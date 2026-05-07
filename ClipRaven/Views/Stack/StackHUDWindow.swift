import SwiftUI

struct StackHUDView: View {
    @ObservedObject var engine: PasteStackEngine

    var body: some View {
        if engine.isActive {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundColor(.accentColor)
                    Text("Paste Stack")
                        .font(.system(size: 12, weight: .semibold))
                }

                ProgressView(value: engine.progress)

                Text("\(engine.currentIndex)/\(engine.items.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    keyHint("⌘\\", "다음")
                    keyHint("ESC", "취소")
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(width: 200)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 10)
        }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }
}

// ViewModel for Paste Stack
@MainActor
final class PasteStackViewModel: ObservableObject {
    @Published var showHUD = false
    let engine = PasteStackEngine()
}
