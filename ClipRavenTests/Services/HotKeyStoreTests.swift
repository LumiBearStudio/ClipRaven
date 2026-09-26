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

    /// 기본값은 ⇧⌘V. 이전 기본값 ⇧V(Shift 단독)는 모든 앱의 대문자 V 입력을
    /// 가로챘다 (v1 리뷰 M2).
    func test_keyCode_returnsDefaultV_whenNotSet() {
        XCTAssertEqual(store.keyCode, UInt32(kVK_ANSI_V))
    }

    func test_modifiers_returnsDefaultShiftCommand_whenNotSet() {
        XCTAssertEqual(store.modifiers, UInt32(cmdKey | shiftKey))
    }

    func test_displayString_default() {
        XCTAssertEqual(store.displayString, "⇧⌘V")
    }

    /// 예전 기본값을 명시적으로 저장한 사용자(⇧V)는 새 기본값으로 넘어가야 한다.
    /// 그대로 두면 글자 입력을 가로채거나 macOS 15 에서 등록에 실패한다.
    func test_legacyShiftOnlyCombo_fallsBackToDefault() {
        defaults.set(Int(kVK_ANSI_V), forKey: "hotkey.keyCode")
        defaults.set(Int(shiftKey), forKey: "hotkey.modifiers")
        XCTAssertEqual(store.displayString, "⇧⌘V")
    }

    /// A 키의 키코드는 0 이다. 이전에는 0 을 "미설정" 으로 봐서 A 로 녹화한
    /// 단축키가 V 로 바뀌어 등록됐다 (⌃⌥A → ⌃⌥V).
    func test_keyA_isNotTreatedAsUnset() {
        store.update(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey))
        XCTAssertEqual(store.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(store.displayString, "⌃⌥A")
    }

    // MARK: - HotKeyRules

    func test_rules_global_rejectsShiftOrOptionOnly() {
        XCTAssertNotNil(HotKeyRules.problem(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey), scope: .global))
        XCTAssertNotNil(HotKeyRules.problem(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey), scope: .global))
        XCTAssertNotNil(HotKeyRules.problem(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey | optionKey), scope: .global))
    }

    func test_rules_global_acceptsCommandOrControlCombos() {
        XCTAssertNil(HotKeyRules.problem(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), scope: .global))
        XCTAssertNil(HotKeyRules.problem(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey), scope: .global))
    }

    func test_rules_rejectReservedCommandShortcuts_inBothScopes() {
        for key in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q] {
            XCTAssertNotNil(HotKeyRules.problem(keyCode: UInt32(key), modifiers: UInt32(cmdKey), scope: .global))
            XCTAssertNotNil(HotKeyRules.problem(keyCode: UInt32(key), modifiers: UInt32(cmdKey), scope: .perClip))
        }
    }

    func test_rules_perClip_allowsOptionCombos_butNotBareShift() {
        XCTAssertNil(HotKeyRules.problem(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey), scope: .perClip))
        XCTAssertNotNil(HotKeyRules.problem(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(shiftKey), scope: .perClip))
    }

    // MARK: - Update

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
