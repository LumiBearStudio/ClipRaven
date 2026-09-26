import XCTest
import GRDB
@testable import ClipRavenSync

/// DB 열기 실패 시 격리 여부 판단 (v1 리뷰 M5).
/// 이전에는 모든 오류를 손상으로 보고 히스토리를 격리했다.
final class DatabaseOpenRecoveryTests: XCTestCase {

    private func error(_ code: ResultCode) -> DatabaseError { DatabaseError(resultCode: code) }

    func test_busyAndLocked_retry_neverQuarantine() {
        XCTAssertEqual(DatabaseOpenRecovery.action(for: error(.SQLITE_BUSY), isFileHealthy: { false }), .retry)
        XCTAssertEqual(DatabaseOpenRecovery.action(for: error(.SQLITE_LOCKED), isFileHealthy: { false }), .retry)
    }

    func test_environmentalErrors_abort_withoutTouchingData() {
        for code in [ResultCode.SQLITE_FULL, .SQLITE_IOERR, .SQLITE_CANTOPEN, .SQLITE_READONLY, .SQLITE_PERM] {
            XCTAssertEqual(DatabaseOpenRecovery.action(for: error(code), isFileHealthy: { nil }), .abort, "\(code)")
        }
    }

    /// GRDB 마이그레이터의 전역 FK 검사 실패는 손상이 아니다 — 파일은 그대로 두어야 한다.
    func test_foreignKeyCheckFailure_aborts() {
        XCTAssertEqual(
            DatabaseOpenRecovery.action(for: error(.SQLITE_CONSTRAINT_FOREIGNKEY), isFileHealthy: { true }),
            .abort
        )
    }

    func test_notADatabase_quarantines() {
        XCTAssertEqual(DatabaseOpenRecovery.action(for: error(.SQLITE_NOTADB), isFileHealthy: { nil }), .quarantine)
    }

    func test_corrupt_quarantinesOnlyWhenIntegrityCheckFails() {
        XCTAssertEqual(DatabaseOpenRecovery.action(for: error(.SQLITE_CORRUPT), isFileHealthy: { false }), .quarantine)
        XCTAssertEqual(DatabaseOpenRecovery.action(for: error(.SQLITE_CORRUPT), isFileHealthy: { true }), .abort,
                       "무결성 검사가 통과하면 손상 보고를 믿지 않는다")
        XCTAssertEqual(DatabaseOpenRecovery.action(for: error(.SQLITE_CORRUPT), isFileHealthy: { nil }), .abort,
                       "판단할 수 없으면 격리하지 않는다")
    }

    /// FTS 인덱스 손상은 본 데이터가 멀쩡하다.
    func test_ftsVirtualTableCorruption_doesNotQuarantine() {
        XCTAssertEqual(DatabaseOpenRecovery.action(for: error(.SQLITE_CORRUPT_VTAB), isFileHealthy: { false }), .abort)
    }

    func test_nonDatabaseError_aborts() {
        struct Other: Error {}
        XCTAssertEqual(DatabaseOpenRecovery.action(for: Other(), isFileHealthy: { false }), .abort)
    }

    // MARK: - 실제 파일

    func test_quickCheck_healthyFile_isTrue_andGarbageFile_isFalse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = dir.appendingPathComponent("good.sqlite")
        try DatabaseQueue(path: good.path).write { try $0.execute(sql: "CREATE TABLE t(x)") }
        XCTAssertEqual(DatabaseOpenRecovery.quickCheck(at: good), true)

        let bad = dir.appendingPathComponent("bad.sqlite")
        try Data(repeating: 0x41, count: 8192).write(to: bad)
        XCTAssertEqual(DatabaseOpenRecovery.quickCheck(at: bad), false)
    }

    func test_quarantine_movesAllFilesTogether_keepingNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("clipraven.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: db.path + suffix))
        }

        let folder = try XCTUnwrap(DatabaseOpenRecovery.quarantine(databaseAt: db))

        for name in ["clipraven.sqlite", "clipraven.sqlite-wal", "clipraven.sqlite-shm"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
    }
}
