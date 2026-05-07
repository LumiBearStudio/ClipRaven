import SwiftUI

/// 앱의 최상위 뷰.
///
/// iPhone / iPad 모두 `ClipListView` 단독 사용. 태그 필터는 ClipListView
/// 내부의 칩 row 에서 즉시 처리된다 (별도 "보드" 탭/사이드바 없음).
///
/// OnboardingView fullScreenCover 는 `ClipRavenMobileApp` 에서 이 RootView
/// 위에 덮어씌운다.
struct RootView: View {
    var body: some View {
        ClipListView()
    }
}

#Preview {
    RootView()
}
