import Carbon
import XCTest
@testable import ClipRaven

/// `HotKeyStore` 는 UserDefaults + NotificationCenter 를 사용. DI 적용 후
/// 격리된 suite/NC 로 검증한다.
final class HotKeyStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var notificationCenter: NotificationCenter!
    private var store: HotKeyStore!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "HotKeyStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        try XCTUnwrap(defaults)
        defaults.removePersistentDomain(forName: suiteName)
        notificationCenter = NotificationCenter()
        store = HotKeyStore(defaults: defaults, notificationCenter: notificationCenter)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        notificationCenter = nil
        store = nil
        suiteName = nil
    }

    // MARK: - Defaults

    func test_keyCode_returnsDefaultV_whenNotSet() {
        XCTAssertEqual(store.keyCode, UInt32(kVK_ANSI_V))
    }

    func test_modifiers_returnsDefaultShift_whenNotSet() {
        XCTAssertEqual(store.modifiers, UInt32(shiftKey))
    }

    func test_displayString_default() {
        // 기본값: ⇧V
        XCTAssertEqual(store.displayString, "⇧V")
    }

    // MARK: - update() Persistence

    func test_update_persistsKeyCodeAndModifiers() {
        store.update(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey))

        XCTAssertEqual(store.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertEqual(store.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(store.displayString, "⇧⌘C")
    }

    func test_update_persistsLegacyDisplayStringKey() {
        store.update(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))
        XCTAssertEqual(defaults.string(forKey: "hotkey"), "⌘A")
    }

    // MARK: - Notification

    func test_update_postsClipRavenHotKeyChangedNotification() {
        let exp = expectation(forNotification: .clipRavenHotKeyChanged,
                              object: nil,
                              notificationCenter: notificationCenter)
        store.update(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey))
        wait(for: [exp], timeout: 1.0)
    }
}
