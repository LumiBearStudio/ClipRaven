import XCTest
import ClipRavenSync
@testable import ClipRaven

final class ClipTests: XCTestCase {

    func test_expiresAt_defaultsToNil() {
        let clip = Clip(contentType: .text, contentText: "test")
        XCTAssertNil(clip.expiresAt)
    }

    func test_expiresAt_setToFutureDate() {
        var clip = Clip(contentType: .text, contentText: "test")
        let sevenDaysLater = Date().addingTimeInterval(86400 * 7)
        clip.expiresAt = sevenDaysLater

        XCTAssertNotNil(clip.expiresAt)
        XCTAssertEqual(
            clip.expiresAt!.timeIntervalSince1970,
            sevenDaysLater.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func test_defaultInitialState() {
        let clip = Clip(contentType: .text, contentText: "hello")
        XCTAssertFalse(clip.isPinned)
        XCTAssertFalse(clip.isDeleted)
        XCTAssertEqual(clip.copyCount, 1)
        XCTAssertEqual(clip.tagsText, "")
        XCTAssertNil(clip.nickname)
        XCTAssertNil(clip.aiCategory)
    }
}
