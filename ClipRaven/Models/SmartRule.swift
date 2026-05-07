import Foundation
import GRDB
import ClipRavenSync

enum RuleAction: Codable, Equatable {
    case assignTag(tagId: Int64)
    case setTTL(days: Int)    // 0 = never expire

    var displayName: String {
        switch self {
        case .assignTag: return "태그 지정"
        case .setTTL(let days): return days == 0 ? "TTL: 영구 보관" : "TTL: \(days)일"
        }
    }
}

struct SmartRule: Codable, Identifiable, Equatable {
    var id: Int64?
    var name: String
    var isEnabled: Bool
    var condition: RuleCondition  // JSON-encoded in DB
    var actions: [RuleAction]
    var createdAt: Date

    static func == (lhs: SmartRule, rhs: SmartRule) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.isEnabled == rhs.isEnabled &&
        lhs.actions == rhs.actions
    }
}

extension SmartRule: TableRecord, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "smartRules"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let isEnabled = Column(CodingKeys.isEnabled)
        static let actionsJson = Column("actionsJson")
        static let createdAt = Column(CodingKeys.createdAt)
    }

    // Custom encode: store condition and actions as JSON in DB columns
    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["isEnabled"] = isEnabled
        container["conditionJson"] = try JSONEncoder().encode(condition)
        container["actionsJson"] = try JSONEncoder().encode(actions)
        container["createdAt"] = createdAt
    }

    // Custom decode: read conditionJson and actionsJson columns
    init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        isEnabled = row["isEnabled"]
        createdAt = row["createdAt"]

        if let jsonData = row["conditionJson"] as? Data {
            condition = try JSONDecoder().decode(RuleCondition.self, from: jsonData)
        } else if let jsonString = row["conditionJson"] as? String,
                  let data = jsonString.data(using: .utf8) {
            condition = try JSONDecoder().decode(RuleCondition.self, from: data)
        } else {
            condition = .textContains("")
        }

        if let jsonData = row["actionsJson"] as? Data {
            actions = (try? JSONDecoder().decode([RuleAction].self, from: jsonData)) ?? []
        } else if let jsonString = row["actionsJson"] as? String,
                  let data = jsonString.data(using: .utf8) {
            actions = (try? JSONDecoder().decode([RuleAction].self, from: data)) ?? []
        } else if let tagId = row["actionTagId"] as? Int64 {
            // Migrate from old single-action format
            actions = [.assignTag(tagId: tagId)]
        } else {
            actions = []
        }
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum RuleCondition: Codable, Equatable {
    case sourceApp(bundleId: String)    // From specific app
    case contentType(String)            // text, code, url, image, color
    case textContains(String)           // Content contains keyword
    case urlDomain(String)              // URL from specific domain

    var displayType: String {
        switch self {
        case .sourceApp: return "앱"
        case .contentType: return "콘텐츠 유형"
        case .textContains: return "텍스트 포함"
        case .urlDomain: return "URL 도메인"
        }
    }

    var displayValue: String {
        switch self {
        case .sourceApp(let bundleId): return bundleId
        case .contentType(let type): return type
        case .textContains(let keyword): return keyword
        case .urlDomain(let domain): return domain
        }
    }

    /// Check if this condition matches a given clip
    func matches(_ clip: Clip) -> Bool {
        switch self {
        case .sourceApp(let bundleId):
            return clip.sourceAppBundleId == bundleId

        case .contentType(let type):
            return clip.contentType.rawValue == type

        case .textContains(let keyword):
            guard !keyword.isEmpty else { return false }
            let text = clip.contentText ?? ""
            return text.localizedCaseInsensitiveContains(keyword)

        case .urlDomain(let domain):
            guard !domain.isEmpty,
                  clip.contentType == .url,
                  let urlString = clip.contentText,
                  let url = URL(string: urlString),
                  let host = url.host else { return false }
            return host.localizedCaseInsensitiveContains(domain)
        }
    }
}
