import Foundation
import GRDB
import ClipRavenSync

/// SmartRule (조건 + 액션) 평가 엔진 — actor 격리.
///
/// 이전엔 `final class @unchecked Sendable + DispatchQueue.sync` 직렬화 패턴.
/// 같은 디렉토리의 다른 서비스 (ClipProcessor, CleanupService, OCRService) 가
/// 모두 actor 라 컨벤션 불일치 + DispatchQueue 의 deadlock 위험. actor 로 통일.
///
/// 캐싱 전략: enabled rule 목록을 `cachedRules` 로 메모리 보유.
/// SmartRule CRUD (Settings UI) 또는 백업 import 후 `reloadRules()` 호출 필요.
actor SmartRuleEngine {
    static let shared = SmartRuleEngine()

    private let dbPool: DatabasePool
    private var cachedRules: [SmartRule] = []
    private let tagRepository: TagRepository

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
        self.tagRepository = TagRepository(dbPool: dbPool)
        // actor init 안에서 self.method 호출은 isolated context 라 safe.
        // 단, 동기 reloadRules 가 dbPool.read 를 호출 — actor init 동안 blocking 허용.
        Task { await self.reloadRules() }
    }

    /// DB 에서 enabled rule 목록 재로드. SmartRule CRUD 또는 백업 import 후 호출.
    func reloadRules() {
        do {
            cachedRules = try dbPool.read { db in
                try SmartRule
                    .filter(Column("isEnabled") == true)
                    .fetchAll(db)
            }
        } catch {
            ClipRavenLog.smartRule.error("Failed to load rules: \(String(describing: error), privacy: .public)")
            cachedRules = []
        }
    }

    /// 클립에 매치되는 모든 rule 의 assignTag 액션 → 태그 ID 배열 (중복 제거).
    /// TTL 액션은 무시 — UI 표시용 dry-run.
    func applyRules(to clip: Clip) -> [Int64] {
        var tagIds: [Int64] = []
        for rule in cachedRules where rule.condition.matches(clip) {
            for action in rule.actions {
                if case .assignTag(let tagId) = action {
                    tagIds.append(tagId)
                }
            }
        }
        return Array(Set(tagIds))
    }

    /// 클립에 매치되는 rule 을 실제 적용 — 태그 부여 + TTL 갱신.
    /// 캡처 직후 ClipProcessor 가 호출하는 메인 진입점.
    func applyRulesAndAssignTags(to clip: Clip) {
        guard let clipId = clip.id else { return }

        var updatedClip = clip
        var needsClipUpdate = false

        for rule in cachedRules where rule.condition.matches(clip) {
            for action in rule.actions {
                switch action {
                case .assignTag(let tagId):
                    do {
                        try tagRepository.assignTag(clipId: clipId, tagId: tagId)
                    } catch {
                        ClipRavenLog.smartRule.error("Failed to assign tag \(tagId) to clip \(clipId): \(String(describing: error), privacy: .public)")
                    }
                case .setTTL(let days):
                    if days == 0 {
                        updatedClip.expiresAt = nil
                    } else {
                        updatedClip.expiresAt = Calendar.current.date(
                            byAdding: .day, value: days, to: Date()
                        )
                    }
                    needsClipUpdate = true
                }
            }
        }

        if needsClipUpdate {
            do {
                try dbPool.write { db in
                    try updatedClip.update(db)
                }
            } catch {
                ClipRavenLog.smartRule.error("Failed to update TTL for clip \(clipId): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
