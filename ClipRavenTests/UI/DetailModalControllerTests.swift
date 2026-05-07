import XCTest
@testable import ClipRaven

final class DetailModalControllerTests: XCTestCase {

    @MainActor
    func test_sharedReturnsSameInstance() {
        let a = DetailModalController.shared
        let b = DetailModalController.shared
        XCTAssertTrue(a === b, "shared accessor must be a singleton")
    }
}
