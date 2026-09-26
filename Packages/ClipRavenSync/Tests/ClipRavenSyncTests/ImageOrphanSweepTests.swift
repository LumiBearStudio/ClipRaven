import XCTest
import GRDB
@testable import ClipRavenSync

/// 원본 수명 = 클립 수명 (v1 리뷰 M6). 이전에는 30일이 지나면 살아 있는 클립의
/// 원본도 지웠고, 클립을 지워도 원본 파일은 영원히 남았다.
final class ImageOrphanSweepTests: XCTestCase {

    private var dir: URL!
    private var db: DatabaseQueue!
    private let now = Date()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try DatabaseQueue()
        try db.write { db in
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("imagePath", .text)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func file(_ name: String, ageDays: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ageDays * 86400)], ofItemAtPath: url.path)
        return url
    }

    private func reference(_ path: String, deleted: Bool = false) throws {
        try db.write { try $0.execute(sql: "INSERT INTO clips (imagePath, isDeleted) VALUES (?, ?)", arguments: [path, deleted]) }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 핵심 보장 — 살아 있는 클립의 원본은 아무리 오래돼도 지우지 않는다.
    func test_oldOriginalOfLiveClip_isKept() async throws {
        let name = "\(UUID().uuidString).png"
        let url = try file(name, ageDays: 200)
        try reference(name)

        let result = try await ImageOrphanSweep.run(imagesDirectory: dir, dbReader: db, now: now)

        XCTAssertTrue(exists(url))
        XCTAssertEqual(result.removed, 0)
    }

    /// 소프트 삭제된 행도 회수 전까지는 참조로 본다 (동기화 tombstone 업로드 대기 중).
    func test_originalOfSoftDeletedClip_isKeptUntilRowIsPurged() async throws {
        let name = "\(UUID().uuidString).jpg"
        let url = try file(name, ageDays: 10)
        try reference(name, deleted: true)

        _ = try await ImageOrphanSweep.run(imagesDirectory: dir, dbReader: db, now: now)
        XCTAssertTrue(exists(url))
    }

    func test_oldUnreferencedFile_isRemoved() async throws {
        let url = try file("\(UUID().uuidString).png", ageDays: 2)

        let result = try await ImageOrphanSweep.run(imagesDirectory: dir, dbReader: db, now: now)

        XCTAssertFalse(exists(url))
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.bytesFreed, 4)
    }

    /// 방금 저장됐지만 아직 행이 커밋되지 않은 캡처·가져오기를 보호한다.
    func test_recentUnreferencedFile_isKeptDuringGracePeriod() async throws {
        let url = try file("\(UUID().uuidString).png", ageDays: 0.1)
        _ = try await ImageOrphanSweep.run(imagesDirectory: dir, dbReader: db, now: now)
        XCTAssertTrue(exists(url))
    }

    /// 앱이 만들지 않은 이름의 파일은 건드리지 않는다.
    func test_nonUUIDNames_areNeverTouched() async throws {
        let a = try file("notes.txt", ageDays: 30)
        let b = try file("clipraven.sqlite", ageDays: 30)
        _ = try await ImageOrphanSweep.run(imagesDirectory: dir, dbReader: db, now: now)
        XCTAssertTrue(exists(a)); XCTAssertTrue(exists(b))
    }

    /// DB 의 imagePath 에 경로가 섞여 있어도 폴더 밖을 가리키지 못한다.
    func test_sanitizedFileName_stripsDirectoriesAndDotDot() {
        XCTAssertEqual(ImageOrphanSweep.sanitizedFileName("../clipraven.sqlite"), "clipraven.sqlite")
        XCTAssertEqual(ImageOrphanSweep.sanitizedFileName("/etc/passwd"), "passwd")
        XCTAssertEqual(ImageOrphanSweep.sanitizedFileName(".."), "invalid-image-path")
        XCTAssertEqual(ImageOrphanSweep.sanitizedFileName(""), "invalid-image-path")
        XCTAssertEqual(ImageOrphanSweep.sanitizedFileName("ABC.png"), "ABC.png")
    }

    func test_referenceWithTraversalPath_stillProtectsTheRealFile() async throws {
        let name = "\(UUID().uuidString).png"
        let url = try file(name, ageDays: 5)
        try reference("subdir/../\(name)")
        _ = try await ImageOrphanSweep.run(imagesDirectory: dir, dbReader: db, now: now)
        XCTAssertTrue(exists(url), "정규화한 이름으로 비교해야 한다")
    }
}
