import Foundation

/// 앱 잠금 상태. Mac + iOS 공유.
public enum LockState: Equatable, Sendable {
    /// 체험 기간 중. daysLeft ≥ 1.
    case trial(daysLeft: Int)
    /// 구매 완료 — 영구 잠금 해제.
    case paid
    /// 체험 만료, 미결제.
    case expired

    public var isAccessible: Bool {
        switch self {
        case .trial, .paid: return true
        case .expired:      return false
        }
    }
}
