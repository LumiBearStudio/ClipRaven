import SwiftUI

struct StackBarView: View {
    @ObservedObject var engine: PasteStackEngine

    var body: some View {
        if !engine.items.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)

                Text("스택: \(engine.items.count)개")
                    .font(.system(size: 11))

                if engine.isActive {
                    // Progress
                    ProgressView(value: engine.progress)
                        .frame(width: 60)

                    Text("\(engine.remainingCount)개 남음")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if engine.isActive {
                    Button("중지") { engine.finish() }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                } else {
                    Button("시작") { engine.start() }
                        .font(.system(size: 10))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)

                    Button(action: { engine.clear() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }
}
