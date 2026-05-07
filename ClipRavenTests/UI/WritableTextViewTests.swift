import XCTest
import AppKit
import SwiftUI
@testable import ClipRaven

final class WritableTextViewTests: XCTestCase {

    func test_coordinatorSyncsBindingOnTextViewChange() {
        var text = "초기값"
        let binding = Binding(get: { text }, set: { text = $0 })
        let writableView = WritableTextView(text: binding)
        let coordinator = writableView.makeCoordinator()

        let textView = NSTextView()
        textView.string = "변경된값"
        let notification = Notification(name: NSText.didChangeNotification, object: textView)
        coordinator.textDidChange(notification)

        XCTAssertEqual(text, "변경된값")
    }
}
