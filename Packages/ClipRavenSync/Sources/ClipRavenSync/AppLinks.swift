import Foundation

/// 앱 밖으로 나가는 고정 링크. App Store Connect 의 개인정보 처리방침 URL·지원 URL 과
/// 같은 주소여야 하므로 macOS·iOS 가 여기 한 곳을 본다.
///
/// 이전에는 두 앱이 주소를 각자 적었고, iOS 는 `github.com/yourorg/…` 자리표시자가
/// 남아 404 였다. macOS 는 GitHub 의 `PRIVACY.md` 를 열었는데 그 문서는 "크래시
/// 리포트·동기화 없음" 이라는 옛 내용이었다 (v1 리뷰).
///
/// 두 페이지 모두 GitHub Pages 가 `main` 브랜치 루트의 `privacy-policy.md`,
/// `support.md` 로 만든다.
public enum AppLinks {
    public static let privacyPolicy = URL(string: "https://lumibearstudio.github.io/ClipRaven/privacy-policy")!
    public static let support = URL(string: "https://lumibearstudio.github.io/ClipRaven/support")!
}
