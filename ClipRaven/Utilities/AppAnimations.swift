import SwiftUI

/// 앱 전역 애니메이션 on/off 정책.
///
/// 설정: Settings → 외관 → "애니메이션" Toggle (default ON).
/// UserDefault key: `clipraven.animationsEnabled`.
///
/// 사용 패턴:
/// ```swift
/// // withAnimation 대체:
/// AppAnimations.withAnimation(.spring) { state.toggle() }
///
/// // .animation modifier 대체:
/// .animation(AppAnimations.policy(.easeInOut), value: someState)
///
/// // SwiftUI View 안에서 @AppStorage 직접:
/// @AppStorage("clipraven.animationsEnabled") private var animationsEnabled = true
/// .animation(animationsEnabled ? .easeInOut : nil, value: state)
/// ```
///
/// 미적용 위치 (의도적):
/// - 시스템 컨트롤 (Picker / sheet presentation transition) — OS 가 관리
/// - SF Symbol effects (.symbolEffect 등) — Reduce Motion 자동 존중
enum AppAnimations {

    /// 현재 사용자 설정 — UserDefaults 직접 read (View 밖에서도 호출 가능).
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }

    static let key = "clipraven.animationsEnabled"

    /// `.animation(_:value:)` modifier 에 넘길 값.
    /// 설정 ON → 입력 animation, OFF → nil (즉시 변경).
    static func policy(_ animation: Animation?) -> Animation? {
        enabled ? animation : nil
    }

    /// `withAnimation` 대체. 설정 OFF 시 애니메이션 없이 즉시 적용.
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
