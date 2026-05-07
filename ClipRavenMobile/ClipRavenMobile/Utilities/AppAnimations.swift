import SwiftUI

/// 앱 전역 애니메이션 on/off 정책 (iOS 사본).
///
/// 설정: Settings → 화면 → "애니메이션" Toggle (default ON).
/// UserDefault key: `clipraven.animationsEnabled` (Mac 과 동일 — 디바이스 별).
///
/// 사용 패턴:
/// ```swift
/// AppAnimations.withAnimation(.spring) { state.toggle() }
/// .animation(AppAnimations.policy(.easeInOut), value: state)
/// ```
///
/// Mac 사본 (`/ClipRaven/Utilities/AppAnimations.swift`) 과 동일 로직.
/// 두 타겟이 별개 모듈이라 ClipRavenSync 외부에서 코드 공유 어려워 복제.
enum AppAnimations {

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }

    static let key = "clipraven.animationsEnabled"

    static func policy(_ animation: Animation?) -> Animation? {
        enabled ? animation : nil
    }

    @discardableResult
    static func withAnimation<R>(
        _ animation: Animation = .default,
        _ body: () throws -> R
    ) rethrows -> R {
        if enabled {
            return try SwiftUI.withAnimation(animation, body)
        } else {
            return try body()
        }
    }
}
