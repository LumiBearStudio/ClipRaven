import Foundation
import GRDB
import ClipRavenSync

/// 정기 cleanup 액터 — 6시간마다 실행되어 4가지 정리 전략을 적용한다.
///
/// ### 4가지 전략 (실행 순서)
/// 1. **만료** (`expiresAt < now`) — SmartRule TTL. 핀 고정 제외.
/// 2. **보관 기간** 초과 (`lastCopiedAt < now - maxDaysToKeep`). 핀 고정 제외.
/// 3. **개수 제한** 초과 — `maxClipCount` 를 넘는 오래된 클립부터.
/// 4. **소프트 삭제 확정분 회수** — 위 세 단계와 사용자의 삭제가 표시해 둔 행
///    중, 동기화 ack 를 받았거나 애초에 동기화 대상이 아닌 것을 실제로 지운다.
///
/// ### 삭제 방식은 동기화 상태에 달려 있다 (감사 S1)
/// - 동기화 **ON**: 1~3 단계는 soft-delete 로 **표시만** 한다. 곧바로 지우면
///   CloudKit 에 tombstone 이 남지 않아 iCloud 에 클립이 영구 잔존하고, 다른
///   기기가 그 레코드를 건드리면 부활한다. 표시된 행은 업로드 → ack 후
///   4단계가 회수한다.
/// - 동기화 **OFF**: 알릴 서버가 없으므로 즉시 hard-delete.
///
/// 각 단계는 개별 `do/catch` 로 격리되어, 하나가 실패해도 나머지는 계속 돈다
/// (감사 D1).
///
/// 의존성: `ClipRepository` (기본 주입) + `UserDefaults` (테스트 시 격리 가능).
/// `CleanupServiceTests` / `CleanupTombstoneTests` 가 격리 환경에서 검증한다.
actor CleanupService {
    private let clipRepository: ClipRepository
    private let defaults: UserDefaults
    private let defaultMaxClipCount: Int
    private let orphanSweep: OrphanSweepConfig?
    private var timer: Timer?

    /// 고아 이미지 정리 대상. **명시적으로 넘길 때만** 돈다 — 기본값이 실제 이미지
    /// 폴더면 격리된 테스트 DB 기준으로 개발 Mac 의 실제 원본을 지울 수 있다
    /// (테스트는 앱 프로세스 안에서 돈다).
    struct OrphanSweepConfig: Sendable {
        let imagesDirectory: URL
        let dbReader: DatabasePool
    }

    /// 앱이 쓰는 구성 — 실제 이미지 폴더와 DB 로 고아 정리까지 수행.
    static func production() -> CleanupService {
        CleanupService(orphanSweep: OrphanSweepConfig(
            imagesDirectory: ImageStorageService.imagesDirectory,
            dbReader: AppDatabase.shared.dbPool
        ))
    }

    static let cleanupInterval: TimeInterval = 6 * 3600 // 6 hours

    /// 프로덕션은 기본값 사용. 테스트는 격리된 ClipRepository + UserDefaults suite 주입.
    init(
        clipRepository: ClipRepository = ClipRepository(),
        defaults: UserDefaults = .standard,
        defaultMaxClipCount: Int = AppConstants.maxClipCount,
        orphanSweep: OrphanSweepConfig? = nil
    ) {
        self.clipRepository = clipRepository
        self.defaults = defaults
        self.defaultMaxClipCount = defaultMaxClipCount
        self.orphanSweep = orphanSweep
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

        // 동기화가 켜져 있으면 정리는 **표시만** 한다 (soft-delete).
        //
        // 곧바로 행을 지우면 CloudKit 에 tombstone 이 남지 않아 ① 사용자가
        // 보관 기간을 줄여도 iCloud 에는 클립이 영구 잔존하고 ② 다른 기기가
        // 그 레코드를 건드리면 다시 내려와 부활한다 (감사 S1). 표시된 행은
        // 업로드 → ack 후 아래 4단계(`deleteSoftDeleted`)가 실제로 지운다.
        //
        // 동기화가 꺼져 있으면 알릴 서버가 없으므로 즉시 hard-delete 한다 —
        // 그래야 sync 를 안 쓰는 사용자의 DB 가 불필요하게 커지지 않는다.
        let propagate = SyncFeatureFlag.isEnabled

        // 1. 만료 (SmartRule TTL). 핀 고정 제외.
        let expired = runStep("expired") {
            try clipRepository.deleteExpired(propagateToSync: propagate)
        }

        // 2. 보관 기간 ("보관 기간" / `maxDaysToKeep`). 핀 고정 제외.
        //    매 cleanup 사이클마다 평가 — 사용자가 보관 기간 줄이면 다음
        //    사이클(최대 6시간) 안에 반영.
        let aged = runStep("aged-out") {
            try clipRepository.deleteOlderThanDays(maxDays, propagateToSync: propagate)
        }

        // 3. 개수 제한
        let trimmed = runStep("over-limit") {
            try clipRepository.deleteOldest(keepCount: limit, propagateToSync: propagate)
        }

        // 4. 소프트 삭제 확정분 제거 — **마지막에** 둔다. 위 세 단계가 방금
        //    표시한 행 중 동기화 불필요한 것(sync OFF 등)은 같은 사이클에서
        //    바로 회수되고, 동기화 대상은 ack 를 기다렸다가 다음 사이클에
        //    지워진다.
        let softDeleted = runStep("soft-deleted") {
            try clipRepository.deleteSoftDeleted()
        }

        if softDeleted + expired + aged + trimmed > 0 {
            ClipRavenLog.cleanup.info("marked \(expired) expired, \(aged) aged-out (>\(maxDays)d), \(trimmed) over-limit; purged \(softDeleted) confirmed-deleted")
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

    /// 어떤 클립도 참조하지 않는 원본 파일을 회수한다. 원본을 지우는 경로는 이것
    /// 하나다 — 클립이 지워지면 다음 사이클에서 원본도 사라진다 (v1 리뷰 M6).
    private func cleanOrphanedImages() async {
        guard let orphanSweep else { return }
        do {
            _ = try await ImageOrphanSweep.run(
                imagesDirectory: orphanSweep.imagesDirectory,
                dbReader: orphanSweep.dbReader
            )
        } catch {
            ClipRavenLog.cleanup.error("orphan sweep failed: \(String(describing: error), privacy: .public)")
        }
    }
}
