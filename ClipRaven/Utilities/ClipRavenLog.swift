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
    ///   - sensitive: true 면 DEBUG 파일 mirror 에서 메시지가 **redact** 된다
    ///     (`os.Logger` 에는 그대로 기록 — `privacy: .public` 마킹은 `os.Logger` 의 책임).
    ///     기본 false. 클립 내용 prefix 같은 사용자 데이터를 파일에 평문 보존하지 않기 위함
    ///     (보안 감사 A-L3).
    static func write(
        _ category: Category,
        _ message: String,
        sensitive: Bool = false
    ) {
        category.logger.debug("\(message, privacy: .public)")
        #if DEBUG
        // 파일 mirror 는 SHA-256 prefix 또는 length-only 로 redact.
        let safeMessage = sensitive ? Self.redactedSummary(of: message) : message
        Self.fileWriteQueue.async {
            Self.appendToFile(category: category.rawValue, message: safeMessage)
        }
        #endif
    }

    #if DEBUG
    /// DEBUG 파일 mirror 의 동시성 안전 보장 — serial queue.
    /// 이전엔 lock 없이 `FileHandle.write` 직접 호출이라 동시 호출 시
    /// 라인이 인터리브 될 수 있었다 (품질 감사 B-CS7). 한 명령씩 직렬 실행.
    private static let fileWriteQueue = DispatchQueue(
        label: "com.lumibear.ClipRaven.fileLog",
        qos: .utility
    )

    /// 민감 메시지의 파일 mirror 용 summary — 평문 노출 방지.
    /// 길이 + SHA-256 prefix 8 char.
    private static func redactedSummary(of message: String) -> String {
        let bytes = Data(message.utf8)
        let hashHex = bytes.sha256Hex().prefix(8)
        return "[redacted, len=\(message.count), sha=\(hashHex)]"
    }

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

#if DEBUG
import CryptoKit

private extension Data {
    /// SHA-256 hex string (redact 용 — cryptographic 보안 보장 필요 없음).
    func sha256Hex() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
