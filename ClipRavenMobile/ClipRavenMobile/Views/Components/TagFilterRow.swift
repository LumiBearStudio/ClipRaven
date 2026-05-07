import SwiftUI
import ClipRavenSync

/// 태그 필터 칩 행 + 태그 생성 버튼.
/// 태그가 없으면 숨겨지고 "+" 버튼만 노출해 첫 태그 생성을 유도.
struct TagFilterRow: View {

    let tags: [Tag]
    @Binding var selectedTagIds: Set<Int64>
    var onCreateTag: (String, String) async -> Void
    var onDeleteTag: (Int64) async -> Void

    @State private var showCreateSheet = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags) { tag in
                    TagChip(
                        tag: tag,
                        isSelected: selectedTagIds.contains(tag.id ?? -1)
                    ) {
                        if let id = tag.id {
                            AppAnimations.withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                if selectedTagIds.contains(id) {
                                    selectedTagIds.remove(id)
                                } else {
                                    selectedTagIds.insert(id)
                                }
                            }
                        }
                    } onDelete: {
                        if let id = tag.id {
                            Task { await onDeleteTag(id) }
                        }
                    }
                }

                // 태그 생성 버튼
                Button {
                    showCreateSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("태그")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showCreateSheet) {
            TagCreateSheet { name, colorHex in
                await onCreateTag(name, colorHex)
            }
        }
    }
}

// MARK: - Tag Chip

private struct TagChip: View {
    let tag: Tag
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    private var tagColor: Color {
        Color(hex: tag.colorHex) ?? .blue
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tagColor)
                    .frame(width: 8, height: 8)

                Text(tag.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? tagColor : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected
                          ? tagColor.opacity(0.15)
                          : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? tagColor.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("태그 삭제", systemImage: "trash")
            }
        }
    }
}

// MARK: - Tag Create Sheet

struct TagCreateSheet: View {
    let onCreate: (String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedColorHex = TagColor.blue.hex
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("이름") {
                    TextField("태그 이름", text: $name)
                        .focused($nameFocused)
                }

                Section("색상") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible()), count: 6),
                        spacing: 12
                    ) {
                        ForEach(TagColor.allCases, id: \.self) { tc in
                            Circle()
                                .fill(tc.color)
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            selectedColorHex == tc.hex
                                                ? Color.primary : Color.clear,
                                            lineWidth: 2.5
                                        )
                                        .padding(2)
                                )
                                .onTapGesture { selectedColorHex = tc.hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("새 태그")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            await onCreate(trimmed, selectedColorHex)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
    }
}

// MARK: - TagColor palette (Mac DesignTokens 동일 값)

enum TagColor: String, CaseIterable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray

    var hex: String {
        switch self {
        case .red:    return "FF3B30"
        case .orange: return "FF9500"
        case .yellow: return "FFCC00"
        case .green:  return "34C759"
        case .mint:   return "00C7BE"
        case .teal:   return "30B0C7"
        case .blue:   return "007AFF"
        case .indigo: return "5856D6"
        case .purple: return "AF52DE"
        case .pink:   return "FF2D55"
        case .brown:  return "A2845E"
        case .gray:   return "8E8E93"
        }
    }

    var color: Color { Color(hex: hex) ?? .gray }
}

// MARK: - Color hex helper (local, Tag 색상 파싱용)

private extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard (s.count == 6 || s.count == 8), let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8)  & 0xFF) / 255
        let b = Double(v         & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension Color {
    init?(tagHex hex: String) { self.init(hex: hex) }
}

#Preview {
    TagFilterRow(
        tags: [
            Tag(name: "업무", colorHex: "007AFF", createdAt: Date()),
            Tag(name: "개인", colorHex: "FF2D55", createdAt: Date()),
            Tag(name: "중요", colorHex: "FFCC00", createdAt: Date()),
        ],
        selectedTagIds: .constant([]),
        onCreateTag: { _, _ in },
        onDeleteTag: { _ in }
    )
    .background(Color(.systemGroupedBackground))
}
