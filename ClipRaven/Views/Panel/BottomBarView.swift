import SwiftUI

struct BottomBarView: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            HStack(spacing: 16) {
                keyHint("↵", "붙여넣기")
                keyHint("⌫", "삭제")
                keyHint("Space", "미리보기")
                keyHint("⌥↵", "텍스트 붙여넣기")
                keyHint("⇧↵", "스택 추가")
                keyHint("⌥1-9", "빠른 붙여넣기")

                keyHint("⌘+Click", "다중 선택")

                Spacer()

                keyHint("⌘/", "검색")
                keyHint("ESC", "닫기")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.7))
        }
    }

    private func keyHint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .fontWeight(.medium)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }
}
