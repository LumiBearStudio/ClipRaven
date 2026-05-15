import Foundation

/// 날짜 범위 필터 — macOS 와 iOS 양쪽이 공유하는 단일 정의.
///
/// 이전엔 macOS (`MainPanelViewModel.swift` 안 `DateRangeFilter` enum, 5 cases)
/// 와 iOS (`ClipRepository.swift` 안 `DateRangeFilter` enum, 3 cases) 가 **다른
/// 케이스**를 가졌다 (보안/아키텍처 감사 C 트랙 Inconsistency 항목). sync 후 다른
/// 디바이스에서 같은 "이번 주" 가 다른 결과를 내는 위험.
///
/// 본 단일 정의는 두 플랫폼이 쓰는 모든 case 를 포함하며, 각 플랫폼은 UI 표시
/// 컨벤션(LocalizedStringKey vs String) 만 본인 쪽에서 결정한다.
///
/// ### Case 의미
/// - `today` — 오늘 자정부터 현재까지
/// - `yesterday` — 어제 자정부터 오늘 자정까지 (macOS 만 사용)
/// - `lastWeek` — 최근 7일 (이동 윈도우)
/// - `lastMonth` — 최근 30일 (이동 윈도우)
/// - `thisWeek` — 이번 주 시작 (월/일 기준 캘린더) 부터 현재까지
/// - `thisMonth` — 이번 달 1일부터 현재까지
/// - `custom(from:to:)` — 임의 구간
public enum ClipDateRange: Equatable, Sendable, Identifiable {
    /// `id` 는 `stableKey` 와 동일. SwiftUI List/Picker 가 case 별 view 를
    /// stable 하게 식별. (이전엔 iOS 측 retroactive conformance 였는데
    /// "imported type to imported protocol" 경고 막기 위해 정의 자체로 이동.)
    public var id: String { stableKey }

    case today
    case yesterday
    case lastWeek
    case lastMonth
    case thisWeek
    case thisMonth
    case custom(from: Date, to: Date)

    /// 사용자가 흔히 선택하는 프리셋 case 목록 (`custom` 제외).
    /// `CaseIterable` 자동 합성이 associated value 때문에 불가하므로 수동 제공.
    public static let presetCases: [ClipDateRange] = [
        .today, .yesterday, .lastWeek, .lastMonth, .thisWeek, .thisMonth
    ]

    /// 캘린더 기반 from/to 계산. 호스트 앱이 DB 쿼리에 이 튜플을 그대로 사용.
    /// 계산 실패 (극단적 캘린더 케이스) 시 fallback 으로 `(startOfDay, now)` 반환.
    public var range: (from: Date, to: Date) {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return (calendar.startOfDay(for: now), now)
        case .yesterday:
            let todayStart = calendar.startOfDay(for: now)
            let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return (yesterdayStart, todayStart)
        case .lastWeek:
            let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return (start, now)
        case .lastMonth:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return (start, now)
        case .thisWeek:
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let start = calendar.date(from: comps) ?? calendar.startOfDay(for: now)
            return (start, now)
        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: comps) ?? calendar.startOfDay(for: now)
            return (start, now)
        case .custom(let from, let to):
            return (from, to)
        }
    }

    /// Identifiable / preference 저장을 위한 안정적 stable key.
    /// `custom(...)` 은 from/to timestamp 가 포함되어 매번 다른 키를 만든다.
    public var stableKey: String {
        switch self {
        case .today:      return "today"
        case .yesterday:  return "yesterday"
        case .lastWeek:   return "lastWeek"
        case .lastMonth:  return "lastMonth"
        case .thisWeek:   return "thisWeek"
        case .thisMonth:  return "thisMonth"
        case .custom(let from, let to):
            return "custom_\(Int(from.timeIntervalSince1970))_\(Int(to.timeIntervalSince1970))"
        }
    }
}
