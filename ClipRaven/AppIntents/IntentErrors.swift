import AppIntents
import Foundation

/// Error types thrown from ClipRaven App Intents.
/// Conforms to `CustomLocalizedStringResourceConvertible` so Shortcuts/Siri show
/// readable Korean-localized reasons when the intent fails.
enum ClipRavenIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noClips
    case clipNotFound
    case tagNotFound
    case accessibilityRequired
    case cannotPasteIntoShortcutsEditor
    case processingFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noClips:
            return "저장된 클립이 없습니다."
        case .clipNotFound:
            return "지정한 클립을 찾을 수 없습니다. 이미 삭제되었을 수 있습니다."
        case .tagNotFound:
            return "지정한 태그를 찾을 수 없습니다."
        case .accessibilityRequired:
            return "ClipRaven에 손쉬운 사용 권한이 필요합니다. 시스템 설정 → 개인정보 보호 → 손쉬운 사용에서 허용해주세요."
        case .cannotPasteIntoShortcutsEditor:
            return "Shortcuts 편집기에서는 붙여넣기를 실행할 수 없습니다. Spotlight(⌘Space), Siri, 또는 자동화(Automation)에서 호출해주세요."
        case .processingFailed:
            return "클립 처리에 실패했습니다."
        }
    }
}
