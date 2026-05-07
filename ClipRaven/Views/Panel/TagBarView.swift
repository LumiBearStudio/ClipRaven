import SwiftUI
import ClipRavenSync

struct TagBarView: View {
    let tags: [Tag]
    @Binding var selectedTagIds: Set<Int64>
    var onCreateTag: (String, String) -> Void = { _, _ in }
    var onDeleteTag: (Int64) -> Void = { _ in }

    @State private var isCreating = false
    @State private var newTagName = ""
    @State private var selectedColor: TagColor = .blue

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Existing tags as toggle chips
                ForEach(tags, id: \.id) { tag in
                    tagChip(tag)
                }

                // "+" button to add new tag
                if isCreating {
                    createForm
                } else {
                    Button(action: { withAnimation(.easeOut(duration: 0.15)) { isCreating = true } }) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("태그 추가")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(height: 30)
    }

    // MARK: - Tag Chip (toggle style)
    private func tagChip(_ tag: Tag) -> some View {
        let isSelected = selectedTagIds.contains(tag.id ?? -1)

        return Button {
            if let id = tag.id {
                withAnimation(.easeOut(duration: 0.1)) {
                    if selectedTagIds.contains(id) {
                        selectedTagIds.remove(id)
                    } else {
                        selectedTagIds.insert(id)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(hex: tag.colorHex) ?? .gray)
                    .frame(width: 8, height: 8)

                Text(tag.name)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? (Color(hex: tag.colorHex) ?? .gray).opacity(0.2)
                          : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected
                            ? (Color(hex: tag.colorHex) ?? .gray).opacity(0.5)
                            : Color.clear,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                if let id = tag.id {
                    onDeleteTag(id)
                }
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
    }

    // MARK: - Inline Create Form
    private var createForm: some View {
        HStack(spacing: 4) {
            // Color dot selector
            Circle()
                .fill(selectedColor.color)
                .frame(width: 10, height: 10)
                .onTapGesture {
                    // Cycle to next color
                    let allColors = TagColor.allCases
                    if let idx = allColors.firstIndex(of: selectedColor) {
                        selectedColor = allColors[(idx + 1) % allColors.count]
                    }
                }

            TextField("태그 이름", text: $newTagName)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 70)
                .onSubmit {
                    commitCreate()
                }

            Button(action: commitCreate) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(newTagName.isEmpty ? Color.accentColor.opacity(0.4) : Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .disabled(newTagName.isEmpty)

            Button(action: cancelCreate) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func commitCreate() {
        guard !newTagName.isEmpty else { return }
        onCreateTag(newTagName, selectedColor.hex)
        newTagName = ""
        withAnimation(.easeOut(duration: 0.15)) { isCreating = false }
    }

    private func cancelCreate() {
        newTagName = ""
        withAnimation(.easeOut(duration: 0.15)) { isCreating = false }
    }
}
