import XCTest
import SwiftUI
@testable import ClipRaven

final class CanReorderTests: XCTestCase {

    @MainActor
    func test_canReorder_falseWhenSearchTextIsNonEmpty() {
        let vm = MainPanelViewModel()
        vm.searchText = "swift"
        XCTAssertFalse(vm.canReorder,
                       "Reorder must be disabled while a search query is active")
    }
}
