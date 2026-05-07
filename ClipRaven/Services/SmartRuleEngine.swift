import Foundation
import GRDB
import ClipRavenSync

final class SmartRuleEngine: @unchecked Sendable {
    static let shared = SmartRuleEngine()

    private let dbPool: DatabasePool
    private var cachedRules: [SmartRule] = []
    private let tagRepository = TagRepository()
    private let queue = DispatchQueue(label: "com.clipraven.smartrules")

    init(dbPool: DatabasePool = AppDatabase.shared.dbPool) {
        self.dbPool = dbPool
        reloadRules()
    }

    /// Reload enabled rules from the database
    func reloadRules() {
        queue.sync {
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
    }

    /// Evaluate all enabled rules against a clip and return matching tag IDs
    func applyRules(to clip: Clip) -> [Int64] {
        queue.sync {
            var tagIds: [Int64] = []
            for rule in cachedRules where rule.condition.matches(clip) {
                for action in rule.actions {
                    if case .assignTag(let tagId) = action {
                        tagIds.append(tagId)
                    }
                }
            }
            // Deduplicate
            return Array(Set(tagIds))
        }
    }

    /// Evaluate rules and assign tags / apply TTL to the clip
    func applyRulesAndAssignTags(to clip: Clip) {
        guard let clipId = clip.id else { return }

        var updatedClip = clip
        var needsClipUpdate = false

        queue.sync {
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
