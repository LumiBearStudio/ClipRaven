import Carbon
import XCTest
@testable import ClipRaven

/// `HotKeyFormatter` 는 외부 의존성 없는 순수 함수라 단독 테스트 가능.
/// `format(keyCode:modifiers:)` 는 Carbon modifier 플래그 → 심볼 문자열,
/// `keyToString(_:)` 는 키코드 → 표시 문자열로 변환한다.
final class HotKeyFormatterTests: XCTestCase {

    // MARK: - format() modifier 조합

    func test_format_cmdShiftV_default() {
        let s = HotKeyFormatter.format(
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey | shiftKey)
        )
        XCTAssertEqual(s, "⇧⌘V")
    }

    func test_format_singleCmd() {
        let s = HotKeyFormatter.format(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey)
        )
        XCTAssertEqual(s, "⌘C")
    }

    func test_format_singleShift() {
        let s = HotKeyFormatter.format(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(shiftKey)
        )
        XCTAssertEqual(s, "⇧A")
    }

    func test_format_singleOption() {
        let s = HotKeyFormatter.format(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(optionKey)
        )
        XCTAssertEqual(s, "⌥B")
    }

    func test_format_singleControl() {
        let s = HotKeyFormatter.format(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey)
        )
        XCTAssertEqual(s, "⌃D")
    }

    func test_format_cmdOptionShiftControl_orderIsCtrlOptShiftCmd() {
        // 구현 순서: control → option → shift → cmd
        let s = HotKeyFormatter.format(
            keyCode: UInt32(kVK_ANSI_X),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        XCTAssertEqual(s, "⌃⌥⇧⌘X")
    }

    func test_format_noModifiers_onlyKey() {
        let s = HotKeyFormatter.format(keyCode: UInt32(kVK_ANSI_Z), modifiers: 0)
        XCTAssertEqual(s, "Z")
    }

    func test_format_cmdOption() {
        let s = HotKeyFormatter.format(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | optionKey)
        )
        XCTAssertEqual(s, "⌥⌘Space")
    }

    func test_format_functionKey_withCmd() {
        let s = HotKeyFormatter.format(
            keyCode: UInt32(kVK_F5),
            modifiers: UInt32(cmdKey)
        )
        XCTAssertEqual(s, "⌘F5")
    }

    func test_format_unknownKeyCode_returnsQuestionMark() {
        let s = HotKeyFormatter.format(keyCode: 9999, modifiers: 0)
        XCTAssertEqual(s, "?")
    }

    // MARK: - keyToString() — 키코드별 표시 문자열

    func test_keyToString_alphabet() {
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_A)), "A")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_M)), "M")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_Z)), "Z")
    }

    func test_keyToString_digits() {
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_0)), "0")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_5)), "5")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_9)), "9")
    }

    func test_keyToString_functionKeys() {
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_F1)),  "F1")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_F6)),  "F6")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_F12)), "F12")
    }

    func test_keyToString_special() {
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_Space)),  "Space")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_Return)), "↩")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_Tab)),    "⇥")
    }

    func test_keyToString_arrows() {
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_UpArrow)),    "↑")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_DownArrow)),  "↓")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_LeftArrow)),  "←")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_RightArrow)), "→")
    }

    func test_keyToString_punctuation() {
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_Slash)),     "/")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_Backslash)), "\\")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_Comma)),     ",")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_Period)),    ".")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_Semicolon)), ";")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_Minus)),     "-")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_ANSI_Equal)),     "=")
    }

    func test_keyToString_navigation() {
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_PageUp)),   "⇞")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_PageDown)), "⇟")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_Home)),     "↖")
        XCTAssertEqual(HotKeyFormatter.keyToString(UInt32(kVK_End)),      "↘")
    }

    func test_keyToString_unknown_returnsQuestionMark() {
        XCTAssertEqual(HotKeyFormatter.keyToString(0xDEADBEEF), "?")
    }
}
