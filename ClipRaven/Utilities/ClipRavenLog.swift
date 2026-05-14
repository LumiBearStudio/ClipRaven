import Foundation
import OSLog

/// 중앙 집중식 `os.Logger` 팩토리 + DEBUG 빌드 시 파일 로그 mirror.
///
/// - 일반 사용:
///   ```
///   ClipRavenLog.processor.debug("captured: \(text, privacy: .public)")
///   ```
///   `log show --predicate 'subsystem == "com.lumibear.ClipRaven"'` 로 조회.
///
/// - DEBUG 빌드 동안 Terminal 에서 `tail -f` 로 보고 싶을 때:
///   ```
///   ClipRavenLog.write(.processor, "captured: \(text)")
///   ```
///   `clipraven_debug.log` 파일(.app 번들과 같은 폴더)에 mirror 된다.
///
/// 이전엔 각 서비스마다 로컬 `debugLog` private 함수를 4중복 정의했으나
/// 모두 이 단일 진입점으로 통합되었다.
enum ClipRavenLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.lumibear.ClipRaven"

    // MARK: - Loggers (카테고리별)

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

    // MARK: - File mirror (DEBUG only)

    /// 메시지 카테고리. `write(_:_:)` 의 첫 인자.
    /// 카테고리는 os.Logger 와 동일한 이름 + 추가 prefix 가 파일 로그 라인에 붙는다.
    enum Category: String {
        case app, clipboard, processor, database, ui, ai, ocr, hotkey
        case paste, cleanup, smartRule, storage, search, general

        fileprivate var logger: Logger {
            switch self {
            case .app: return ClipRavenLog.app
            case .clipboard: return ClipRavenLog.clipboard
            case .processor: return ClipRavenLog.processor
            case .database: return ClipRavenLog.database
            case .ui: return ClipRavenLog.ui
            case .ai: return ClipRavenLog.ai
            case .ocr: return ClipRavenLog.ocr
            case .hotkey: return ClipRavenLog.hotkey
            case .paste: return ClipRavenLog.paste
            case .cleanup: return ClipRavenLog.cleanup
            case .smartRule: return ClipRavenLog.smartRule
            case .storage: return ClipRavenLog.storage
            case .search: return ClipRavenLog.search
            case .general: return ClipRavenLog.general
            }
        }
    }

    /// 로그 한 줄을 기록한다.
    ///
    /// 항상 `os.Logger` 에 기록되며, DEBUG 빌드에선 `.app` 번들 옆의
    /// `clipraven_debug.log` 파일에도 append 된다. RELEASE 빌드에선 파일 mirror 가
    /// 일어나지 않아 디스크 부담이 없다.
    ///
    /// - Parameters:
    ///   - category: 로그 카테고리 (subsystem 안의 부분).
    ///   - message: 한 줄 메시지. 멀티라인은 호출자가 줄바꿈 처리.
    static func write(_ category: Category, _ message: String) {
        category.logger.debug("\(message, privacy: .public)")
        #if DEBUG
        appendToFile(category: category.rawValue, message: message)
        #endif
    }

    #if DEBUG
    /// DEBUG 빌드에서만 사용되는 파일 mirror 구현. 동시 호출이 잦지 않다는 가정으로
    /// 단순 FileHandle/append 방식 사용 — 별도 lock 없이도 한 줄 단위 write 는
    /// 거의 atomic 하다 (한국어 multibyte 가 잘릴 가능성은 극도로 낮음).
    private static func appendToFile(category: String, message: String) {
        let logPath = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("clipraven_debug.log").path
        let line = "\(Date()): [\(category)] \(message)\n"
        let data = Data(line.utf8)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
    #endif
}
