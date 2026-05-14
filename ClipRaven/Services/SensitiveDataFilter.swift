import AppKit
import ClipRavenSync

/// macOS 전용 wrapper — 패키지의 `ClipRavenSync.SensitiveDataFilter` 위에
/// `NSPasteboard` / `SourceAppInfo` 형식의 macOS 호출 컨벤션을 얹어준다.
///
/// 핵심 로직 (regex 패턴, 2FA 키워드, masking) 은 모두 패키지 측. macOS 와 iOS 가
/// 동일 보호 규칙을 공유.
///
/// 기존 호출처 (`ClipboardMonitor.swift:188-206` 등) 의 시그니처를 깨지 않기 위해
/// 동일 이름의 enum 을 유지하고 패키지 메서드로 forward.
enum SensitiveDataFilter {

    /// NSPasteboard 의 concealed type 검사 — macOS 전용 진입점.
    static func isSensitive(pasteboard: NSPasteboard) -> Bool {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        return ClipRavenSync.SensitiveDataFilter.isSensitivePasteboardType(types)
    }

    /// 패턴 매칭 — 패키지 메서드 forward.
    static func containsSensitivePattern(_ text: String) -> Bool {
        ClipRavenSync.SensitiveDataFilter.containsSensitivePattern(text)
    }

    static func isLikelyTwoFactorCode(_ text: String) -> Bool {
        ClipRavenSync.SensitiveDataFilter.isLikelyTwoFactorCode(text)
    }

    static func containsTwoFactorPhrase(_ text: String) -> Bool {
        ClipRavenSync.SensitiveDataFilter.containsTwoFactorPhrase(text)
    }

    /// 소스 앱 컨텍스트 기반 판정. macOS `SourceAppInfo` 를 패키지의 String 으로 변환.
    static func isSensitiveWithContext(_ text: String, sourceApp: SourceAppInfo?) -> Bool {
        let filter2FAEnabled = UserDefaults.standard.object(forKey: "filter2FA") as? Bool ?? true
        return ClipRavenSync.SensitiveDataFilter.isSensitiveWithContext(
            text,
            sourceAppBundleId: sourceApp?.bundleId,
            filter2FAEnabled: filter2FAEnabled
        )
    }

    static func mask(_ text: String) -> String {
        ClipRavenSync.SensitiveDataFilter.mask(text)
    }
}
