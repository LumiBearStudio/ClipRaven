import Carbon
import Foundation

/// Persists the global hotkey configuration (Carbon keyCode + modifiers).
/// Provides a formatted display string and atomic save + notification.
///
/// 기본 동작은 `UserDefaults.standard` + `NotificationCenter.default` 를 쓰지만,
/// 테스트에서는 `init(defaults:notificationCenter:)` 로 격리된 인스턴스를 주입한다.
final class HotKeyStore {
    static let shared = HotKeyStore()

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    // MARK: - Defaults

    /// 기본 전역 단축키 ⇧⌘V — 클립보드 매니저의 사실상 표준 조합.
    ///
    /// 이전 기본값은 **Shift+V 단독**이었다. 전역 단축키는 모든 앱의 입력보다
    /// 먼저 가로채므로 등록에 성공하면 어느 앱에서도 대문자 V 를 칠 수 없고,
    /// macOS 15 의 샌드박스 앱은 ⇧·⌥ 만의 조합을 아예 등록하지 못한다(-9868)
    /// (v1 리뷰 M2).
    static let defaultKeyCode = UInt32(kVK_ANSI_V)
    static let defaultModifiers = UInt32(cmdKey | shiftKey)

    // MARK: - Persisted Values

    /// 저장된 조합이 전역 단축키로 쓸 수 있는 것인가. 예전 기본값(⇧V)처럼 ⌘·⌃ 가
    /// 없는 저장값은 버리고 기본값을 쓴다 — 그대로 두면 글자 입력을 가로채거나
    /// 등록에 실패해 패널을 열 방법이 없어진다.
    private var storedCombo: (keyCode: UInt32, modifiers: UInt32)? {
        // 미설정은 "값이 없음(nil)" 으로 판정한다. 이전에는 0 을 미설정으로 봤는데
        // A 키의 키코드(kVK_ANSI_A)가 0 이라, A 로 녹화한 단축키가 V 로 바뀌어
        // 등록됐다 — ⌘A 를 녹화하면 실제로는 ⌘V(붙여넣기)가 전역으로 가로채였다.
        guard let kc = defaults.object(forKey: "hotkey.keyCode") as? Int,
              let mods = defaults.object(forKey: "hotkey.modifiers") as? Int
        else { return nil }
        let combo = (keyCode: UInt32(kc), modifiers: UInt32(mods))
        guard HotKeyRules.problem(keyCode: combo.keyCode, modifiers: combo.modifiers, scope: .global) == nil
        else { return nil }
        return combo
    }

    var keyCode: UInt32 { storedCombo?.keyCode ?? Self.defaultKeyCode }

    var modifiers: UInt32 { storedCombo?.modifiers ?? Self.defaultModifiers }

    var displayString: String {
        HotKeyFormatter.format(keyCode: keyCode, modifiers: modifiers)
    }

    /// Atomically saves new keyCode + modifiers and notifies AppDelegate to re-register.
    func update(keyCode: UInt32, modifiers: UInt32) {
        defaults.set(Int(keyCode), forKey: "hotkey.keyCode")
        defaults.set(Int(modifiers), forKey: "hotkey.modifiers")
        // Keep legacy display string key in sync
        defaults.set(
            HotKeyFormatter.format(keyCode: keyCode, modifiers: modifiers),
            forKey: "hotkey"
        )
        notificationCenter.post(name: .clipRavenHotKeyChanged, object: nil)
    }
}

// MARK: - HotKeyRules

/// 전역 단축키로 등록하면 안 되는 조합을 거른다. 전역 단축키와 클립별 단축키가
/// 같은 규칙을 쓴다 (v1 리뷰 M2 — 이전에는 전역 녹화기에 검증이 아예 없었다).
enum HotKeyRules {
    enum Scope {
        /// 패널 열기 단축키 — ⌘ 또는 ⌃ 필수.
        case global
        /// 클립별 단축키 — ⌥ 조합도 허용 (기존 동작 유지).
        case perClip
    }

    /// ⌘ 하나만 붙은 시스템·편집 단축키. 전역으로 가로채면 모든 앱에서 해당
    /// 기능이 사라진다.
    private static let reservedCommandKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z,
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_S, kVK_ANSI_N, kVK_ANSI_T,
        kVK_ANSI_F, kVK_ANSI_P, kVK_ANSI_O, kVK_ANSI_H, kVK_ANSI_M,
        kVK_Tab, kVK_Space,
    ]

    /// 문제가 있으면 사용자에게 보여줄 설명, 없으면 nil.
    static func problem(keyCode: UInt32, modifiers: UInt32, scope: Scope) -> String? {
        let hasCommandOrControl = modifiers & UInt32(cmdKey | controlKey) != 0
        let hasOption = modifiers & UInt32(optionKey) != 0

        switch scope {
        case .global where !hasCommandOrControl:
            return String(localized: "⌘ 또는 ⌃를 포함한 조합을 사용하세요. ⇧나 ⌥만 쓰면 글자 입력을 가로챕니다.")
        case .perClip where !hasCommandOrControl && !hasOption:
            return String(localized: "⌘ / ⌃ / ⌥ 중 하나 이상을 포함해야 합니다.")
        default:
            break
        }

        if modifiers == UInt32(cmdKey), reservedCommandKeys.contains(Int(keyCode)) {
            return String(localized: "시스템 단축키(\(HotKeyFormatter.format(keyCode: keyCode, modifiers: modifiers)))는 사용할 수 없습니다.")
        }
        return nil
    }
}

// MARK: - HotKeyFormatter

enum HotKeyFormatter {
    static func format(keyCode: UInt32, modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { result += "⌘" }
        result += keyToString(keyCode)
        return result
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    static func keyToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space:              return "Space"
        case kVK_Return:             return "↩"
        case kVK_Tab:                return "⇥"
        case kVK_ANSI_Backslash:     return "\\"
        case kVK_ANSI_Slash:         return "/"
        case kVK_ANSI_Comma:         return ","
        case kVK_ANSI_Period:        return "."
        case kVK_ANSI_Semicolon:     return ";"
        case kVK_ANSI_Quote:         return "'"
        case kVK_ANSI_Grave:         return "`"
        case kVK_ANSI_Minus:         return "-"
        case kVK_ANSI_Equal:         return "="
        case kVK_ANSI_LeftBracket:   return "["
        case kVK_ANSI_RightBracket:  return "]"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_PageUp:     return "⇞"
        case kVK_PageDown:   return "⇟"
        case kVK_Home:       return "↖"
        case kVK_End:        return "↘"
        default: return "?"
        }
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}
