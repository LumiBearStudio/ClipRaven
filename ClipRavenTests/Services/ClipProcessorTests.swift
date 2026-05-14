import XCTest
import GRDB
@testable import ClipRaven
import ClipRavenSync

/// `ClipProcessor` 의 텍스트/파일 파이프라인 검증.
///
/// 검증 범위 (외부 의존성 격리 가능한 부분):
/// - 빈 텍스트 무시
/// - 같은 텍스트 두 번 → copyCount 증가, 새 row 생성 안 됨
/// - 새 텍스트 → 저장
/// - invisible char strip on/off
/// - 다중 파일 URL → .file 클립으로 저장
///
/// 이미지 처리는 ImageStorageService 정적 호출 (디스크 I/O)이 있어 본 단위 테스트
/// 범위 밖. OCR / AI 카테고리는 외부 시스템 의존성으로 제외.
final class ClipProcessorTests: XCTestCase {

    private var testDB: TestDatabase!
    private var clipRepository: ClipRepository!
    private var smartRuleEngine: SmartRuleEngine!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sut: ClipProcessor!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        clipRepository = ClipRepository(dbPool: testDB.dbPool)
        smartRuleEngine = SmartRuleEngine(dbPool: testDB.dbPool)
        suiteName = "ClipProcessorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        sut = ClipProcessor(
            clipRepository: clipRepository,
            ocrService: OCRService(),  // 텍스트 테스트만 → OCR 미호출
            smartRuleEngine: smartRuleEngine,
            defaults: defaults
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        testDB.cleanup()
        sut = nil
        defaults = nil
        smartRuleEngine = nil
        clipRepository = nil
        testDB = nil
    }

    // MARK: - Helpers

    private func makeData(text: String? = nil, imageData: Data? = nil, fileURLs: [URL]? = nil) -> ClipboardData {
        ClipboardData(text: text, imageData: imageData, fileURLs: fileURLs)
    }

    private var dummyApp: SourceAppInfo {
        SourceAppInfo(bundleId: "com.test.app", name: "TestApp", icon: nil)
    }

    private func clipCount() async throws -> Int {
        try await testDB.dbPool.read { db in
            try Clip.fetchCount(db)
        }
    }

    private func allClips() async throws -> [Clip] {
        try await testDB.dbPool.read { db in
            try Clip.fetchAll(db)
        }
    }

    // MARK: - 텍스트: 빈 입력 무시

    func test_process_emptyText_doesNotSave() async throws {
        await sut.process(clipboardData: makeData(text: ""), sourceApp: dummyApp)
        let count = try await clipCount()
        XCTAssertEqual(count, 0)
    }

    func test_process_whitespaceOnly_doesNotSave() async throws {
        await sut.process(clipboardData: makeData(text: "   \n\t  "), sourceApp: dummyApp)
        let count = try await clipCount()
        XCTAssertEqual(count, 0)
    }

    func test_process_nilEverything_noop() async throws {
        await sut.process(clipboardData: makeData(), sourceApp: dummyApp)
        let count = try await clipCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - 텍스트: 정상 저장

    func test_process_newText_savesClip() async throws {
        await sut.process(clipboardData: makeData(text: "hello world"), sourceApp: dummyApp)
        let clips = try await allClips()
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.contentText, "hello world")
        XCTAssertEqual(clips.first?.contentType, .text)
    }

    func test_process_url_classifiedAsURL() async throws {
        await sut.process(
            clipboardData: makeData(text: "https://example.com"),
            sourceApp: dummyApp
        )
        let clips = try await allClips()
        XCTAssertEqual(clips.first?.contentType, .url)
    }

    // MARK: - 텍스트: 중복 (in-memory + DB dedup)

    func test_process_sameTextTwice_incrementsCopyCount_noNewRow() async throws {
        await sut.process(clipboardData: makeData(text: "duplicate"), sourceApp: dummyApp)
        await sut.process(clipboardData: makeData(text: "duplicate"), sourceApp: dummyApp)

        let clips = try await allClips()
        XCTAssertEqual(clips.count, 1)
        // copyCount 는 in-memory cache hit 시에도 증가
        XCTAssertGreaterThanOrEqual(clips.first?.copyCount ?? 0, 2)
    }

    func test_process_normalizedDuplicate_dedupes() async throws {
        // TextNormalizer 가 공백 정규화 → 같은 hash → dedup
        await sut.process(clipboardData: makeData(text: "hello world"), sourceApp: dummyApp)
        await sut.process(clipboardData: makeData(text: "hello   world"), sourceApp: dummyApp)

        let clips = try await allClips()
        XCTAssertEqual(clips.count, 1)
    }

    // MARK: - 텍스트: invisible char strip

    func test_process_stripInvisibleOn_removesBOM() async throws {
        defaults.set(true, forKey: "stripInvisibleChars")
        // \u{FEFF} 는 BOM (invisible)
        await sut.process(clipboardData: makeData(text: "\u{FEFF}clean"), sourceApp: dummyApp)
        let clips = try await allClips()
        XCTAssertEqual(clips.first?.contentText, "clean", "BOM 이 제거되어야 함")
    }

    func test_process_stripInvisibleOff_keepsBOM() async throws {
        defaults.set(false, forKey: "stripInvisibleChars")
        await sut.process(clipboardData: makeData(text: "\u{FEFF}withbom"), sourceApp: dummyApp)
        let clips = try await allClips()
        XCTAssertEqual(clips.first?.contentText, "\u{FEFF}withbom")
    }

    // MARK: - 파일: 다중 파일

    func test_process_multipleFileURLs_savesAsFileClip() async throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.docx")
        ]
        await sut.process(clipboardData: makeData(fileURLs: urls), sourceApp: dummyApp)

        let clips = try await allClips()
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.contentType, .file)
        // 정렬되어 newline 으로 join
        XCTAssertTrue(clips.first?.contentText?.contains("/tmp/a.pdf") ?? false)
        XCTAssertTrue(clips.first?.contentText?.contains("/tmp/b.docx") ?? false)
    }

    func test_process_sameFileURLsTwice_dedupes() async throws {
        let urls = [URL(fileURLWithPath: "/tmp/x.zip")]

        await sut.process(clipboardData: makeData(fileURLs: urls), sourceApp: dummyApp)
        await sut.process(clipboardData: makeData(fileURLs: urls), sourceApp: dummyApp)

        let count = try await clipCount()
        XCTAssertEqual(count, 1)
    }

    func test_process_emptyFileURLs_noop() async throws {
        await sut.process(clipboardData: makeData(fileURLs: []), sourceApp: dummyApp)
        let count = try await clipCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - 우선순위

    func test_process_textTakesPriorityOverFileURLs() async throws {
        let urls = [URL(fileURLWithPath: "/tmp/foo.txt")]
        await sut.process(
            clipboardData: makeData(text: "priority", fileURLs: urls),
            sourceApp: dummyApp
        )

        let clips = try await allClips()
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.contentType, .text)
        XCTAssertEqual(clips.first?.contentText, "priority")
    }
}
