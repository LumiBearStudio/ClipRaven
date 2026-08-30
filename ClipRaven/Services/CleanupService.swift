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

    /// Run all cleanup tasks.
    ///
    /// 각 전략은 **독립적으로** 실패한다. 이전에는 4단계가 하나의 `do/catch`
    /// 안에 직렬로 있어서 1단계가 throw 하면 만료·보관기간·개수제한 정리가
    /// 아예 실행되지 않았고, 6시간마다 같은 실패만 반복하며 DB 가 무한히
    /// 커졌다 (감사 D1 — 원인이던 pasteStack FK 는 v15 에서 해결했지만,
    /// 한 전략의 실패가 나머지를 멈추는 구조 자체가 위험하다).
    func runCleanup() async {
        let maxDays = defaults.integer(forKey: "maxDaysToKeep")
        let maxCount = defaults.integer(forKey: "maxClipCount")
        let limit = maxCount > 0 ? maxCount : defaultMaxClipCount

        // 1. Remove soft-deleted items
        let softDeleted = runStep("soft-deleted") {
            try clipRepository.deleteSoftDeleted()
        }

        // 2. Remove items past their explicit expiresAt (SmartRule TTL)
        let expired = runStep("expired") {
            try clipRepository.deleteExpired()
        }

        // 3. Apply global retention policy ("보관 기간" / `maxDaysToKeep`).
        //    SmartRule 의 per-clip expiresAt 과 별개. 핀 고정은 제외.
        //    매 cleanup 사이클마다 평가 — 사용자가 보관 기간 줄이면 다음
        //    사이클(최대 6시간) 안에 반영.
        let aged = runStep("aged-out") {
            try clipRepository.deleteOlderThanDays(maxDays)
        }

        // 4. Enforce max item count
        let trimmed = runStep("over-limit") {
            try clipRepository.deleteOldest(keepCount: limit)
        }

        if softDeleted + expired + aged + trimmed > 0 {
            ClipRavenLog.cleanup.info("removed \(softDeleted) soft-deleted, \(expired) expired, \(aged) aged-out (>\(maxDays)d), \(trimmed) over-limit")
        }

        // 5. Clean up orphaned image files
        await cleanOrphanedImages()
    }

    /// 정리 단계 하나를 실행하고, 실패하면 로그만 남긴 뒤 0 을 반환한다.
    /// 한 전략의 실패가 다음 전략을 막지 않게 하는 격리 지점.
    private func runStep(_ name: String, _ body: () throws -> Int) -> Int {
        do {
            return try body()
        } catch {
            ClipRavenLog.cleanup.error("cleanup step '\(name, privacy: .public)' failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    private func cleanOrphanedImages() async {
        // Future: scan images/ directory vs imagePath values in DB
    }
}
