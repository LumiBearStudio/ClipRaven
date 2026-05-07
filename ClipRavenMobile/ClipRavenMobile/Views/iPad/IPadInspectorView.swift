import SwiftUI
import ClipRavenSync

/// iPad Inspector 패널 (우측). NavigationSplitView detail 영역에 붙는
/// `.inspector()` modifier의 content로 사용.
///
/// 클립이 선택되면 ClipDetailView를 렌더링하고, 없으면 빈 안내 화면을 표시.
/// ClipDetailView의 "완료" 버튼은 onDismiss 클로저로 selectedClip을 nil로 설정.
struct IPadInspectorView: View {

    let clip: Clip?
    let onDismiss: () -> Void

    var body: some View {
        if let clip {
            ClipDetailView(clip: clip, onDismiss: onDismiss)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text("클립을 선택하면\n상세 정보가 표시됩니다")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
