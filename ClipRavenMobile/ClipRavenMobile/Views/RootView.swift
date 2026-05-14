import SwiftUI
import ClipRavenSync

/// 앱의 최상위 뷰.
///
/// iPhone / iPad 모두 `ClipListView` 단독 사용. 태그 필터는 ClipListView
/// 내부의 칩 row 에서 즉시 처리된다 (별도 "보드" 탭/사이드바 없음).
///
/// OnboardingView fullScreenCover 는 `ClipRavenMobileApp` 에서 이 RootView
/// 위에 덮어씌운다.
struct RootView: View {
    @ObservedObject private var pm = PurchaseManager.shared

    /// XCUITest 런처가 주입하는 인수. 테스트 중에는 페이월 fullScreenCover를
    /// 표시하지 않아 설정/추가 시트 등 UI 흐름 테스트가 정상 동작하도록 한다.
    private static let isUITesting =
        ProcessInfo.processInfo.arguments.contains("UI_TESTING")

    var body: some View {
        ClipListView()
            .fullScreenCover(
                isPresented: .constant(!Self.isUITesting && pm.lockState == .expired)
            ) {
                PaywallView()
            }
            .task { await pm.refresh() }
    }
}

#Preview {
    RootView()
}
