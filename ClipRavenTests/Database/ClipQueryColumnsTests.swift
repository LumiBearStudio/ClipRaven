import XCTest
import GRDB
import ClipRavenSync
@testable import ClipRaven

/// `ClipQueryColumns.list` 를 **실제 프로덕션 스키마**로 검증 (감사 X2).
///
/// 이 빌더는 iOS 키보드 익스텐션과 위젯이 목록을 가져올 때 본문을 잘라오도록
/// 만드는 SQL 을 생성한다. 익스텐션 자체는 iOS 전용이라 여기서 돌릴 수 없지만,
/// 빌더는 공유 패키지에 있고 clips 스키마는 양 플랫폼이 같은 컬럼 집합을
/// 쓰므로, 마이그레이션 전체를 적용한 실제 DB 로 여기서 검증한다.
///
/// 핵심 회귀 위험은 두 가지다:
/// 1. 컬럼이 빠져 `Clip` 디코딩이 깨지거나 값이 조용히 nil 이 되는 것
/// 2. 본문이 안 잘려 메모리 절감 효과가 없어지는 것
final class ClipQueryColumnsTests: XCTestCase {

    private var testDB: TestDatabase!
    private var clipRepo: ClipRepository!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        clipRepo = ClipRepository(dbPool: testDB.dbPool)
    }

    override func tearDown() {
        testDB?.cleanup()
        testDB = nil; clipRepo = nil
        super.tearDown()
    }

    /// 스키마의 **모든** 컬럼이 목록에 들어가야 한다. 하드코딩된 목록이었다면
    /// 새 마이그레이션이 컬럼을 추가할 때마다 조용히 어긋났을 지점.
    func test_list_includesEveryColumnOfProductionSchema() throws {
        try testDB.dbPool.read { db in
            let schemaColumns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('clips')")
            XCTAssertGreaterThan(schemaColumns.count, 30, "실제 스키마를 읽고 있는지 확인")

            let sql = try ClipQueryColumns.list(db)

            for column in schemaColumns {
                if column == "contentText" {
                    XCTAssertTrue(
                        sql.contains("AS contentText"),
                        "contentText 는 별칭으로 유지되어야 Clip 디코딩이 동작한다"
                    )
                } else {
                    XCTAssertTrue(
                        sql.contains("clips.\(column)"),
                        "컬럼 '\(column)' 이 SELECT 목록에서 빠졌다"
                    )
                }
            }
        }
    }

    /// 생성된 SQL 로 실제 조회했을 때 본문만 잘리고 나머지 필드는 온전해야 한다.
    func test_list_truncatesContentText_andKeepsOtherFieldsIntact() throws {
        let long = String(repeating: "가", count: 5_000)
        var clip = Clip(
            contentType: .text,
            contentText: long,
            contentHash: XXHash64Wrapper.hash(long)
        )
        clip.nickname = "별명"
        clip.isPinned = true
        clip.copyCount = 7
        try clipRepo.save(&clip)

        let fetched: Clip = try testDB.dbPool.read { db in
            let cols = try ClipQueryColumns.list(db, previewLimit: 300)
            return try XCTUnwrap(
                Clip.fetchOne(db, sql: "SELECT \(cols) FROM clips LIMIT 1")
            )
        }

        XCTAssertEqual(fetched.contentText?.count, 300, "본문이 미리보기 길이로 잘려야 한다")
        XCTAssertEqual(fetched.id, clip.id)
        XCTAssertEqual(fetched.nickname, "별명")
        XCTAssertEqual(fetched.isPinned, true)
        XCTAssertEqual(fetched.copyCount, 7)
        XCTAssertEqual(fetched.contentType, .text)
        XCTAssertNotNil(fetched.createdAt)
    }

    /// 원본은 DB 에 그대로 남아 있어야 한다 — 붙여넣기·복사 경로가 id 로 다시
    /// 읽어 전체 내용을 쓴다. (잘린 값을 저장해 버리면 데이터 손실이다.)
    func test_originalContentRemainsFullInDatabase() throws {
        let long = String(repeating: "x", count: 5_000)
        var clip = Clip(
            contentType: .text,
            contentText: long,
            contentHash: XXHash64Wrapper.hash(long)
        )
        try clipRepo.save(&clip)

        let full: String? = try testDB.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT contentText FROM clips WHERE id = ?", arguments: [clip.id])
        }
        XCTAssertEqual(full?.count, 5_000, "저장된 원본은 절대 잘리면 안 된다")
    }

    /// JOIN 쿼리에서 컬럼 모호성이 생기지 않아야 한다 (키보드의 태그 필터 /
    /// FTS 검색이 JOIN 을 쓴다).
    func test_list_worksInJoinQuery() throws {
        let text = "joined"
        var clip = Clip(
            contentType: .text,
            contentText: text,
            contentHash: XXHash64Wrapper.hash(text)
        )
        try clipRepo.save(&clip)

        let fetched: [Clip] = try testDB.dbPool.read { db in
            let cols = try ClipQueryColumns.list(db)
            return try Clip.fetchAll(db, sql: """
                SELECT \(cols)
                FROM clips
                JOIN clips_fts ON clips_fts.rowid = clips.id
                WHERE clips_fts MATCH ?
                """, arguments: ["joined"])
        }

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.contentText, text)
    }
}
