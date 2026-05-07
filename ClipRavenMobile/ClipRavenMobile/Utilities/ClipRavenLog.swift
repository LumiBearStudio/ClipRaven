import Foundation
import OSLog

/// iOS 용 중앙 os.Logger 팩토리.
/// `log show --predicate 'subsystem == "com.lumibear.ClipRavenMobile"'` 로 조회.
enum ClipRavenLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.lumibear.ClipRavenMobile"

    static let app       = Logger(subsystem: subsystem, category: "app")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let database  = Logger(subsystem: subsystem, category: "database")
    static let sync      = Logger(subsystem: subsystem, category: "sync")
    static let drain     = Logger(subsystem: subsystem, category: "drain")
    static let ocr       = Logger(subsystem: subsystem, category: "ocr")
    static let storage   = Logger(subsystem: subsystem, category: "storage")
    static let cleanup   = Logger(subsystem: subsystem, category: "cleanup")
    static let general   = Logger(subsystem: subsystem, category: "general")
}
