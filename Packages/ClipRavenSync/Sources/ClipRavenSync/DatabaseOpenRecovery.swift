import Foundation
import GRDB

/// DB 열기·마이그레이션이 실패했을 때 무엇을 할지 정한다. macOS·iOS 앱이 같은
/// 규칙을 쓴다.
///
/// ## 왜 필요한가 (v1 리뷰 M5)
/// 이전에는 **어떤 오류든** 손상으로 보고 히스토리 파일을 `.corrupted-*` 로 옮긴 뒤
/// 빈 DB 로 시작했다. 실제로 밟히는 경로는 손상이 아니었다:
///
/// - 기존 인스턴스가 잠금을 쥔 상태에서 마이그레이션 → `SQLITE_BUSY`
/// - GRDB 마이그레이터는 끝에 **DB 전체**에 `PRAGMA foreign_key_check` 를 돌린다.
///   어느 테이블이든 고아 행 하나가 있으면 모든 마이그레이션이 실패한다.
/// - 디스크 가득 참(`SQLITE_FULL`), I/O 오류, 잠금 해제 전 백그라운드 실행
///
/// 이런 경우 파일은 멀쩡한데 사용자는 빈 히스토리를 보고, 복구 플래그는 기록만
/// 되고 아무도 읽지 않아 이유조차 알 수 없었다. 클립보드 기록은 유일한 사본인
/// 경우가 많으므로 **격리는 손상이 확인됐을 때만** 한다.
public enum DatabaseOpenRecovery {

    public enum Action: Equatable {
        /// 다른 프로세스가 잠금을 쥐고 있다 — 잠시 뒤 다시 시도.
        case retry
        /// 파일이 실제로 손상됐다 — 격리하고 새로 시작.
        case quarantine
        /// 그 밖의 모든 경우 — 데이터를 건드리지 말고 사용자에게 알린다.
        case abort
    }

    /// 오류를 분류한다.
    ///
    /// - Parameter isFileHealthy: 파일 무결성 검사. true = 정상, false = 손상,
    ///   nil = 판단 불가. 손상 보고(`SQLITE_CORRUPT`)가 틀릴 수 있어 격리 전에 한 번
    ///   더 확인하는 데 쓴다.
    public static func action(for error: Error, isFileHealthy: () -> Bool?) -> Action {
        guard let dbError = error as? DatabaseError else { return .abort }
        switch dbError.resultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED:
            return .retry
        case .SQLITE_NOTADB:
            return .quarantine
        case .SQLITE_CORRUPT:
            // FTS 가상 테이블 손상은 검색 인덱스 문제다. 본 데이터는 멀쩡하므로
            // 히스토리 전체를 격리하면 안 된다.
            if dbError.extendedResultCode == .SQLITE_CORRUPT_VTAB { return .abort }
            return isFileHealthy() == false ? .quarantine : .abort
        default:
            return .abort
        }
    }

    /// 읽기 전용으로 열어 `PRAGMA quick_check` 를 돌린다.
    /// true = "ok", false = 손상 또는 DB 파일이 아님, nil = 열 수 없어 판단 불가.
    public static func quickCheck(at url: URL) -> Bool? {
        var config = Configuration()
        config.readonly = true
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            let result = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
            return result == "ok"
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            return false
        } catch {
            return nil
        }
    }

    /// 손상된 DB 를 `Quarantine/<시각>/` 로 옮긴다. sqlite·wal·shm 을 **이름 그대로**
    /// 함께 옮겨 나중에 그 폴더에서 그대로 열어볼 수 있게 한다.
    ///
    /// - Returns: 옮긴 폴더. 본 파일을 옮기지 못하면 nil — 이때 새 DB 를 만들면 남은
    ///   `-wal` 이 새 파일에 재생될 수 있으므로 호출자는 새로 시작하면 안 된다.
    public static func quarantine(databaseAt dbURL: URL) -> URL? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let folder = dbURL.deletingLastPathComponent()
            .appendingPathComponent("Quarantine", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: dbURL.path + suffix)
                guard fm.fileExists(atPath: src.path) else { continue }
                try fm.moveItem(at: src, to: folder.appendingPathComponent(src.lastPathComponent))
            }
            return folder
        } catch {
            NSLog("⚠️ ClipRaven: quarantine failed: \(error)")
            return nil
        }
    }
}
