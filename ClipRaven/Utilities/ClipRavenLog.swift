import Foundation
import OSLog

/// Centralized os.Logger factory. Use `ClipRavenLog.X.info("...")` etc.
/// All logs become visible via `log show --predicate 'subsystem == "com.lumibear.ClipRaven"'`.
enum ClipRavenLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.lumibear.ClipRaven"

    static let app        = Logger(subsystem: subsystem, category: "app")
    static let clipboard  = Logger(subsystem: subsystem, category: "clipboard")
    static let processor  = Logger(subsystem: subsystem, category: "processor")
    static let database   = Logger(subsystem: subsystem, category: "database")
    static let ui         = Logger(subsystem: subsystem, category: "ui")
    static let ai         = Logger(subsystem: subsystem, category: "ai")
    static let ocr        = Logger(subsystem: subsystem, category: "ocr")
    static let hotkey     = Logger(subsystem: subsystem, category: "hotkey")
    static let paste      = Logger(subsystem: subsystem, category: "paste")
    static let cleanup    = Logger(subsystem: subsystem, category: "cleanup")
    static let smartRule  = Logger(subsystem: subsystem, category: "smartRule")
    static let storage    = Logger(subsystem: subsystem, category: "storage")
    static let search     = Logger(subsystem: subsystem, category: "search")
    static let general    = Logger(subsystem: subsystem, category: "general")
}
