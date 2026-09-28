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
///   앱 컨테이너의 `Library/Logs/clipraven_debug.log` 에 mirror 된다
///   (`debugLogFileURL` — 예: `~/Library/Containers/com.lumibear.ClipRaven/Data/Library/Logs/`).
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
    /// 항상 `os.Logger` 에 기록되며, DEBUG 빌드에선 `debugLogFileURL` 파일에도
    /// append 된다. RELEASE 빌드에선 파일 mirror 가 일어나지 않아 디스크 부담이 없다.
    ///
    /// - Important: **사용자 콘텐츠(클립 본문, 파일 경로 등)를 message 에 그대로
    ///   보간하지 말 것.** `redacted(_:)` 로 감싸거나 `sensitive: true` 를 쓴다.
    ///   이유는 `redacted(_:)` 문서 참고.
    ///
    /// - Parameters:
    ///   - category: 로그 카테고리 (subsystem 안의 부분).
    ///   - message: 한 줄 메시지. 멀티라인은 호출자가 줄바꿈 처리.
    ///   - sensitive: true 면 메시지 전체가 `os.Logger` 와 DEBUG 파일 mirror
    ///     **양쪽에서** redact 된다. 이전 구현은 파일 mirror 만 가리고 os_log 에는
    ///     평문을 그대로 넘겨(`privacy: .public`) 방어 장치가 사실상 무력했다
    ///     (보안 감사 P1).
    static func write(
        _ category: Category,
        _ message: String,
        sensitive: Bool = false
    ) {
        // redact 는 os_log 로 넘기기 **전에** 적용해야 한다. 메시지가 이미 하나의
        // String 으로 조립된 뒤라 `privacy: .private` 마킹으로는 줄 전체가
        // `<private>` 이 되어 운영 로그로서 쓸모가 없어진다.
        let emitted = sensitive ? Self.redactedSummary(of: message) : message

        category.logger.debug("\(emitted, privacy: .public)")
        #if DEBUG
        Self.fileWriteQueue.async {
            Self.appendToFile(category: category.rawValue, message: emitted)
        }
        #endif
    }

    // MARK: - 사용자 콘텐츠 redaction

    /// 사용자 콘텐츠를 로그에 남길 때 쓰는 안전 요약 — 길이 + SHA-256 prefix.
    ///
    /// 평문은 남지 않지만 같은 값은 같은 해시가 나오므로, 로그 상에서 동일
    /// 클립이 파이프라인을 따라 흐르는 것을 그대로 추적할 수 있다.
    ///
    /// **왜 필요한가**: `logger.debug` 도 `log stream --level debug` 로 실시간
    /// 열람되고, debug 레벨이 켜진 환경에서는 `/var/db/diagnostics` 에 영속화되어
    /// sysdiagnose·logarchive 로 기기 밖으로 나간다. 클립보드 매니저의 로그에
    /// 본문이 남으면 비밀번호·2FA 코드가 그 경로로 새어나간다.
    static func redacted(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "<empty>" }
        return redactedSummary(of: text)
    }

    /// 길이 + SHA-256 prefix 8자. 암호학적 보안이 아니라 상관관계 추적용.
    private static func redactedSummary(of message: String) -> String {
        let hashHex = Data(message.utf8).sha256Hex().prefix(8)
        return "[len=\(message.count) sha=\(hashHex)]"
    }

    #if DEBUG
    /// DEBUG 파일 mirror 의 동시성 안전 보장 — serial queue.
    /// 이전엔 lock 없이 `FileHandle.write` 직접 호출이라 동시 호출 시
    /// 라인이 인터리브 될 수 있었다 (품질 감사 B-CS7). 한 명령씩 직렬 실행.
    private static let fileWriteQueue = DispatchQueue(
        label: "com.lumibear.ClipRaven.fileLog",
        qos: .utility
    )

    /// DEBUG 파일 로그 위치. 샌드박스 앱이 쓸 수 있는 컨테이너의 `Library/Logs`.
    /// 이전에는 `.app` 번들 옆에 썼는데, 샌드박스가 그 쓰기를 막아 로그를 남길 때마다
    /// 위반이 기록됐고 파일도 생기지 않았다 (테스트 계획 A6).
    static let debugLogFileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("clipraven_debug.log")
    }()

    private static func appendToFile(category: String, message: String) {
        let logPath = debugLogFileURL.path
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

import CryptoKit

private extension Data {
    /// SHA-256 hex string (redact 용 — cryptographic 보안 보장 필요 없음).
    /// RELEASE 빌드에서도 필요하다: redaction 은 DEBUG 파일 mirror 만이 아니라
    /// os_log 경로에도 적용된다.
    func sha256Hex() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
