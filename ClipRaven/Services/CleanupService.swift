import Foundation

/// 정기 cleanup 액터 — 6시간마다 실행되어 4가지 정리 전략을 적용한다.
///
/// ### 4가지 전략
/// 1. **소프트 삭제** 확정된 클립 (`isDeleted = 1` 이고 sync 확인됨) hard-delete.
/// 2. **만료** 클립 (`expiresAt < now`) hard-delete — SmartRule TTL.
/// 3. **보관 기간** 초과 (`lastCopiedAt < now - maxDaysToKeep`) hard-delete.
///    핀 고정 (`isPinned`) 은 제외 (영구 보관).
/// 4. **개수 제한** 초과 — `maxClipCount` 를 넘는 오래된 클립부터 삭제.
///
/// 의존성: `ClipRepository` (기본 주입) + `UserDefaults` (테스트 시 격리 가능).
/// `CleanupServiceTests` 가 격리된 환경에서 각 전략을 검증한다.
actor CleanupService {
    private let clipRepository: ClipRepository
    private let defaults: UserDefaults
    private let defaultMaxClipCount: Int
    private var timer: Timer?

    static let cleanupInterval: TimeInterval = 6 * 3600 // 6 hours

    /// 프로덕션은 기본값 사용. 테스트는 격리된 ClipRepository + UserDefaults suite 주입.
    init(
        clipRepository: ClipRepository = ClipRepository(),
        defaults: UserDefaults = .standard,
        defaultMaxClipCount: Int = AppConstants.maxClipCount
    ) {
        self.clipRepository = clipRepository
        self.defaults = defaults
        self.defaultMaxClipCount = defaultMaxClipCount
    }

    /// Run cleanup on app startup and schedule periodic cleanup
    func startSchedule() {
        Task {
            await runCleanup()
        }

        // Schedule periodic cleanup
        Task { @MainActor in
            Timer.scheduledTimer(withTimeInterval: Self.cleanupInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.runCleanup()
                }
            }
        }
    }

    /// Run all cleanup tasks
    func runCleanup() async {
        do {
            // 1. Remove soft-deleted items
            let softDeleted = try clipRepository.deleteSoftDeleted()

            // 2. Remove items past their explicit expiresAt (SmartRule TTL)
            let expired = try clipRepository.deleteExpired()

            // 3. Apply global retention policy ("보관 기간" / `maxDaysToKeep`).
            //    SmartRule 의 per-clip expiresAt 과 별개. 핀 고정은 제외.
            //    매 cleanup 사이클마다 평가 — 사용자가 보관 기간 줄이면 다음
            //    사이클(최대 6시간) 안에 반영.
            let maxDays = defaults.integer(forKey: "maxDaysToKeep")
            let aged = try clipRepository.deleteOlderThanDays(maxDays)

            // 4. Enforce max item count
            let maxCount = defaults.integer(forKey: "maxClipCount")
            let limit = maxCount > 0 ? maxCount : defaultMaxClipCount
            let trimmed = try clipRepository.deleteOldest(keepCount: limit)

            if softDeleted + expired + aged + trimmed > 0 {
                ClipRavenLog.cleanup.info("removed \(softDeleted) soft-deleted, \(expired) expired, \(aged) aged-out (>\(maxDays)d), \(trimmed) over-limit")
            }

            // 5. Clean up orphaned image files
            await cleanOrphanedImages()
        } catch {
            ClipRavenLog.cleanup.error("error during cleanup: \(String(describing: error), privacy: .public)")
        }
    }

    private func cleanOrphanedImages() async {
        // Future: scan images/ directory vs imagePath values in DB
    }
}
