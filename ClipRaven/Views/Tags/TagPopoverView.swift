import SwiftUI
import ClipRavenSync

struct TagPopoverView: View {
    let clipId: Int64
    @StateObject private var viewModel = TagViewModel()
    @State private var isCreating = false
    @State private var newTagName = ""
    @State private var selectedColor = TagColor.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("태그")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: { isCreating.toggle() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Tag list
            if viewModel.allTags.isEmpty && !isCreating {
                Text("태그가 없습니다")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.allTags, id: \.id) { tag in
                    tagRow(tag)
                }
            }

            // Create new tag
            if isCreating {
                Divider()
                createTagSection
            }
        }
        .padding(12)
        .frame(width: 200)
        .onAppear {
            viewModel.loadTags(forClipId: clipId)
        }
    }

    private func tagRow(_ tag: Tag) -> some View {
        Button(action: {
            viewModel.toggleTag(tag, forClipId: clipId)
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: tag.colorHex) ?? .gray)
                    .frame(width: 10, height: 10)

                Text(tag.name)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)

                Spacer()

                if viewModel.assignedTagIds.contains(tag.id ?? -1) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private var createTagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("태그 이름", text: $newTagName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            // Color palette
            TagColorPalette(selectedColor: $selectedColor)

            HStack {
                Spacer()
                Button("생성") {
                    viewModel.createTag(name: newTagName, colorHex: selectedColor.hex)
                    newTagName = ""
                    isCreating = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newTagName.isEmpty)
            }
        }
    }
}
