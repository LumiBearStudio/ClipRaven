import XCTest
import GRDB
@testable import ClipRaven
import ClipRavenSync

/// `PreviewViewModel` 은 단순 상태 머신 + ClipRepository 호출. DI 후 검증.
@MainActor
final class PreviewViewModelTests: XCTestCase {

    private var testDB: TestDatabase!
    private var clipRepository: ClipRepository!
    private var vm: PreviewViewModel!

    override func setUpWithError() throws {
        testDB = try TestDatabase()
        clipRepository = ClipRepository(dbPool: testDB.dbPool)
        vm = PreviewViewModel(clipRepository: clipRepository)
    }

    override func tearDownWithError() throws {
        testDB.cleanup()
        testDB = nil
        clipRepository = nil
        vm = nil
    }

    private func makeClip(text: String = "test") throws -> Clip {
        var clip = Clip(contentType: .text, contentText: text)
        return try clipRepository.save(&clip)
    }

    // MARK: - showPreview / hidePreview

    func test_showPreview_setsClipAndFlag() throws {
        let clip = try makeClip(text: "hello")
        vm.showPreview(for: clip)
        XCTAssertTrue(vm.isShowingPreview)
        XCTAssertEqual(vm.selectedClip?.id, clip.id)
    }

    func test_hidePreview_clearsClipAndFlag() throws {
        let clip = try makeClip()
        vm.showPreview(for: clip)
        vm.hidePreview()
        XCTAssertFalse(vm.isShowingPreview)
        XCTAssertNil(vm.selectedClip)
    }

    // MARK: - togglePreview

    func test_togglePreview_opensWhenNotShowing() throws {
        let clip = try makeClip()
        vm.togglePreview(for: clip)
        XCTAssertTrue(vm.isShowingPreview)
        XCTAssertEqual(vm.selectedClip?.id, clip.id)
    }

    func test_togglePreview_closesWhenSameClipShowing() throws {
        let clip = try makeClip()
        vm.showPreview(for: clip)
        vm.togglePreview(for: clip)
        XCTAssertFalse(vm.isShowingPreview)
        XCTAssertNil(vm.selectedClip)
    }

    func test_togglePreview_switchesToOtherClip() throws {
        let a = try makeClip(text: "A")
        let b = try makeClip(text: "B")
        vm.showPreview(for: a)
        vm.togglePreview(for: b)
        XCTAssertTrue(vm.isShowingPreview)
        XCTAssertEqual(vm.selectedClip?.id, b.id)
    }

    // MARK: - togglePin

    func test_togglePin_flipsSelectedClipPinState() throws {
        let clip = try makeClip()
        vm.showPreview(for: clip)
        XCTAssertFalse(vm.selectedClip?.isPinned ?? true)

        vm.togglePin()

        XCTAssertTrue(vm.selectedClip?.isPinned ?? false)
        // DB 도 반영되었는지
        let fromDB = try clipRepository.fetchOne(id: XCTUnwrap(clip.id))
        XCTAssertEqual(fromDB?.isPinned, true)
    }
}
