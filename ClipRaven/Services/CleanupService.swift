import Foundation

actor CleanupService {
    private let clipRepository = ClipRepository()
    private var timer: Timer?

    static let cleanupInterval: TimeInterval = 6 * 3600 // 6 hours

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
            let maxDays = UserDefaults.standard.integer(forKey: "maxDaysToKeep")
            let aged = try clipRepository.deleteOlderThanDays(maxDays)

            // 4. Enforce max item count
            let maxCount = UserDefaults.standard.integer(forKey: "maxClipCount")
            let limit = maxCount > 0 ? maxCount : AppConstants.maxClipCount
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
