import Foundation

/// 민감 데이터 (패스워드, 2FA 코드, API 키, JWT, 신용카드, SSN 등) 휴리스틱 필터.
///
/// macOS / iOS 양쪽 캡처 단계에서 호출되어 **DB 저장 자체를 막는다** (SyncFilters
/// 와 다름 — SyncFilters 는 sync 업로드만 막을 뿐 로컬 DB 에는 저장됨).
///
/// 사용 흐름:
/// 1. 캡처 진입점 (ClipboardMonitor / KeyboardViewController / ShareViewController) 에서
///    `UserDefaults` 의 `blockSensitive` 토글 확인
/// 2. 토글 ON 이면:
///    - 플랫폼 pasteboard 의 type identifiers → `isSensitivePasteboardType(types:)`
///    - 텍스트 → `isSensitiveWithContext(_:sourceAppBundleId:filter2FAEnabled:)`
/// 3. 둘 중 하나라도 true 이면 캡처 중단
///
/// 이전엔 macOS 의 `ClipRaven/Services/SensitiveDataFilter.swift` 단독 존재 →
/// iOS 측에 동일 보호 부재 (보안 감사 A-C1). 본 패키지 이전으로 양쪽 일관 보장.
public enum SensitiveDataFilter {

    // MARK: - Pasteboard type check

    /// 1Password 등 패스워드 매니저가 마킹하는 "concealed" 타입 ID.
    /// macOS UTI / iOS UTI 모두 `org.nspasteboard.ConcealedType` 가 통용.
    /// (iOS 의 UIPasteboard.PasteboardType 도 raw string 으로 사용 가능.)
    public static let concealedTypeIdentifiers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "com.agilebits.onepassword",      // 1Password 일부 버전
        "com.apple.security.concealed-data" // 시스템 keychain 자동완성 (iOS)
    ]

    /// pasteboard 의 type identifier 목록에 concealed 마커가 포함되어 있는지 확인.
    /// - Parameter types: `pasteboard.types.map(\.rawValue)` 로 얻은 raw string 배열.
    public static func isSensitivePasteboardType(_ types: [String]) -> Bool {
        for t in types where concealedTypeIdentifiers.contains(t) {
            return true
        }
        return false
    }

    // MARK: - Pattern match

    /// 잘 알려진 secret 형식 (전체 문자열이 패턴과 일치) 의 정규식 모음.
    /// 보수적 매칭 — `^...$` 앵커로 부분 매칭 false positive 회피.
    private static let patterns: [String] = [
        // API keys (long alphanumeric strings) — 보수적 (32자+)
        "^[a-zA-Z0-9_\\-]{32,}$",
        // Credit card numbers (13-19 digits)
        "^\\d{13,19}$",
        // SSN pattern
        "^\\d{3}-\\d{2}-\\d{4}$",
        // 한국 주민등록번호
        "^\\d{6}-[1-4]\\d{6}$",
        // 한국 외국인등록번호
        "^[5-8]\\d{5}-[1-4]\\d{6}$",
        // 한국 사업자등록번호
        "^\\d{3}-\\d{2}-\\d{5}$",
        // JWT tokens
        "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$",
        // GitHub personal access tokens
        "^gh[pousr]_[A-Za-z0-9]{36,}$",
        // OpenAI API keys
        "^sk-[A-Za-z0-9]{32,}$",
        // Private key blocks (부분 매칭 허용 — 앵커 없음)
        "-----BEGIN (RSA |EC |OPENSSH |ENCRYPTED |DSA |PGP )?PRIVATE KEY-----",
        // Slack tokens
        "^xox[baprs]-[A-Za-z0-9\\-]{10,}$",
        // AWS Access Key ID
        "^AKIA[0-9A-Z]{16}$",
        // Telegram bot token
        "^\\d{8,10}:[A-Za-z0-9_-]{35}$",
        // SendGrid API key
        "^SG\\.[A-Za-z0-9_-]{22}\\.[A-Za-z0-9_-]{43}$",
        // Twilio Account SID
        "^AC[a-f0-9]{32}$"
    ]

    /// 텍스트가 등록된 sensitive 패턴 중 하나에 매치되는지.
    /// trim 후 zero-width 문자 제거하여 우회 시도 (BOM/ZWSP 삽입) 방어.
    public static func containsSensitivePattern(_ text: String) -> Bool {
        let cleaned = stripZeroWidth(text.trimmingCharacters(in: .whitespacesAndNewlines))
        for pattern in patterns {
            if cleaned.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// BOM / ZWSP / ZWNJ / ZWJ / Word joiner 제거 — regex 우회 시도 차단.
    private static func stripZeroWidth(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0xFEFF, 0x200B, 0x200C, 0x200D, 0x2060:
                continue  // skip zero-width
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - 2FA detection

    /// 텍스트가 4~8자리 숫자만으로 구성된 OTP 코드처럼 보이는지.
    public static func isLikelyTwoFactorCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^\\d{4,8}$", options: .regularExpression) != nil
    }

    /// 2FA 메시지를 식별하는 키워드 (한국어 + 영어).
    /// 텍스트에 키워드 + 4~8 자리 숫자가 모두 있으면 2FA 로 판정.
    private static let twoFactorKeywords: [String] = [
        // Korean
        "인증번호", "인증 번호", "인증코드", "인증 코드",
        "본인확인", "본인 확인", "본인인증",
        "보안코드", "보안 코드",
        "검증코드", "검증 코드", "확인코드", "확인 코드",
        "일회용", "패스코드",
        // English
        "verification code", "verify code", "security code",
        "otp", "one-time", "one time",
        "passcode", "access code", "auth code", "authentication code",
        "2fa", "two-factor", "two factor",
        "confirmation code"
    ]

    /// 키워드 + 4~8 자리 숫자가 동반된 "전체 메시지" 형식 검사.
    /// "인증번호는 [14145] 입니다" / "Your code is 123456" 같은 케이스.
    public static func containsTwoFactorPhrase(_ text: String) -> Bool {
        let lower = text.lowercased()
        let hasKeyword = twoFactorKeywords.contains { lower.contains($0.lowercased()) }
        guard hasKeyword else { return false }
        return text.range(of: "\\b\\d{4,8}\\b", options: .regularExpression) != nil
    }

    /// 2FA 코드가 자주 도착하는 메시지/메일 앱의 bundle ID fragment.
    /// 대소문자 무시 contains 매칭.
    private static let twoFactorSourceHints: [String] = [
        "mail",
        "message",
        "mobilesms",
        "sms",
        "imessage",
        "kakao",
        "telegram",
        "slack",
        "whatsapp",
        "line"
    ]

    /// 컨텍스트 기반 민감도 판정 — 패턴 매칭 + 소스 앱 휴리스틱 결합.
    ///
    /// - Parameters:
    ///   - text: 검사할 텍스트.
    ///   - sourceAppBundleId: 캡처가 일어난 앱의 bundle identifier. nil 이면 소스앱
    ///     관련 휴리스틱 (Case A) 생략.
    ///   - filter2FAEnabled: 사용자가 2FA 필터 ON 으로 설정했는지. false 면 패턴 매칭만 수행.
    /// - Returns: 민감 데이터로 판정되면 true (캡처 차단해야 함).
    public static func isSensitiveWithContext(
        _ text: String,
        sourceAppBundleId: String?,
        filter2FAEnabled: Bool = true
    ) -> Bool {
        if containsSensitivePattern(text) {
            return true
        }
        guard filter2FAEnabled else { return false }

        let bundleLower = sourceAppBundleId?.lowercased() ?? ""
        let fromMessagingApp = !bundleLower.isEmpty &&
            twoFactorSourceHints.contains(where: { bundleLower.contains($0) })

        // Case A: bare code (e.g., "14145") copied from messaging/mail app
        if fromMessagingApp && isLikelyTwoFactorCode(text) {
            return true
        }

        // Case B: 키워드 + 숫자 풀텍스트 (소스앱 무관, 포워드/이메일 cover)
        if containsTwoFactorPhrase(text) {
            return true
        }

        return false
    }

    // MARK: - Display

    /// 민감 텍스트를 UI 표시용으로 마스킹 — 앞 4 + bullet * (count-8) + 뒤 4.
    public static func mask(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 8 {
            let prefix = String(trimmed.prefix(4))
            let suffix = String(trimmed.suffix(4))
            return prefix + String(repeating: "•", count: trimmed.count - 8) + suffix
        }
        return String(repeating: "•", count: trimmed.count)
    }
}
