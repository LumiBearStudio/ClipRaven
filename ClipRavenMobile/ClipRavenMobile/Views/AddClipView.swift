import SwiftUI

/// 새 클립 추가 시트. 내용 + 별명(선택).
///
/// UX 결정:
/// - 내용 필드를 주역으로 (큰 TextEditor). 별명은 부수 필드로 작게.
/// - 빈 상태에서 자동 포커스 → 시트 열자마자 입력 가능.
/// - 저장 버튼은 trim 후 빈 문자열이면 비활성화.
/// - "테스트 자동 채우기" 같은 dev 편의 기능은 제거 — 프로덕션에선 사용자가
///   직접 입력하지 자동 채우기 안 좋음.
struct AddClipView: View {

    let onSave: (_ text: String, _ nickname: String?) -> Void

    @State private var text: String = ""
    @State private var nickname: String = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field { case content, nickname }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedText.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body)
                        .lineSpacing(2)
                        .tracking(-0.2)
                        .frame(minHeight: 180, maxHeight: 320)
                        .focused($focusedField, equals: .content)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("내용")
                } footer: {
                    HStack {
                        Spacer()
                        Text("\(trimmedText.count)자")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Section {
                    TextField("선택 사항", text: $nickname)
                        .focused($focusedField, equals: .nickname)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("별명")
                } footer: {
                    Text("리스트와 디테일 화면에서 내용 대신 우선 표시됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("새 클립")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let trimmedNick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmedText, trimmedNick.isEmpty ? nil : trimmedNick)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .onAppear {
                focusedField = .content
            }
        }
    }
}

#Preview {
    AddClipView { _, _ in }
}
