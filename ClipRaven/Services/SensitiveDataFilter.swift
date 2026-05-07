import AppKit

enum SensitiveDataFilter {
    /// Check if pasteboard contains concealed/sensitive content
    static func isSensitive(pasteboard: NSPasteboard) -> Bool {
        // System-marked sensitive (password managers)
        let concealedType = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.ConcealedType")
        if pasteboard.types?.contains(concealedType) == true {
            return true
        }
        return false
    }

    /// Check if text matches sensitive patterns
    static func containsSensitivePattern(_ text: String) -> Bool {
        let patterns = [
            // API keys (long alphanumeric strings)
            "^[a-zA-Z0-9_\\-]{32,}$",
            // Credit card numbers (13-19 digits)
            "^\\d{13,19}$",
            // SSN pattern
            "^\\d{3}-\\d{2}-\\d{4}$",
            // Korean resident registration number
            "^\\d{6}-[1-4]\\d{6}$",
            // JWT tokens (header.payload.signature)
            "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$",
            // GitHub personal access tokens (ghp_, gho_, etc.)
            "^gh[pousr]_[A-Za-z0-9]{36,}$",
            // OpenAI API keys
            "^sk-[A-Za-z0-9]{32,}$",
            // Private key blocks
            "-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----",
            // Slack tokens
            "^xox[baprs]-[A-Za-z0-9\\-]{10,}$",
        ]

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Check if text looks like a 2FA/OTP code (4-8 digits only)
    static func isLikelyTwoFactorCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^\\d{4,8}$", options: .regularExpression) != nil
    }

    /// Keywords that indicate the text is a 2FA/OTP message (case-insensitive).
    /// If any keyword is present AND the text contains a 4-8 digit number,
    /// the whole message is treated as a 2FA code.
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

    /// Check if a message contains a 2FA keyword alongside a 4-8 digit number.
    /// Catches phrases like "인증번호는 [14145] 입니다" or "Your code is 123456".
    static func containsTwoFactorPhrase(_ text: String) -> Bool {
        let lower = text.lowercased()
        let hasKeyword = twoFactorKeywords.contains { lower.contains($0.lowercased()) }
        guard hasKeyword else { return false }
        // Any 4-8 digit run inside the text (not anchored)
        return text.range(of: "\\b\\d{4,8}\\b", options: .regularExpression) != nil
    }

    /// Bundle-ID fragments that indicate a messaging/mail app where 2FA codes typically arrive.
    /// Matched via case-insensitive `contains` against the source app bundle identifier.
    private static let twoFactorSourceHints: [String] = [
        "mail",         // com.apple.mail, com.microsoft.Outlook, com.readdle.smartemail-Mac
        "message",      // com.apple.iChat, naver.messenger
        "mobilesms",    // com.apple.MobileSMS (iMessage on macOS) — 소문자 기준
        "sms",          // generic SMS apps
        "imessage",     // any iMessage variant
        "kakao",        // com.kakao.KakaoTalkMac
        "telegram",     // ru.keepcoder.Telegram, org.telegram.desktop
        "slack",        // com.tinyspeck.slackmacgap
        "whatsapp",     // net.whatsapp.WhatsApp
        "line"          // com.linecorp.LINE
    ]

    /// Context-aware sensitivity check — combines pattern matching with source-app heuristics.
    /// Use this in place of `containsSensitivePattern` when a source app is known.
    static func isSensitiveWithContext(_ text: String, sourceApp: SourceAppInfo?) -> Bool {
        // All existing static patterns (API keys, SSN, JWT, etc.)
        if containsSensitivePattern(text) {
            return true
        }

        // 2FA filter — only enabled if user opted in (default ON)
        let filter2FAEnabled = UserDefaults.standard.object(forKey: "filter2FA") as? Bool ?? true
        guard filter2FAEnabled else { return false }

        let bundleIdLower = sourceApp?.bundleId?.lowercased() ?? ""
        let fromMessagingApp = !bundleIdLower.isEmpty &&
            twoFactorSourceHints.contains(where: { bundleIdLower.contains($0) })

        // Case A: bare code (e.g., "14145") copied from messaging/mail app
        if fromMessagingApp && isLikelyTwoFactorCode(text) {
            return true
        }

        // Case B: full SMS/mail text with "인증번호", "verification code" + number
        // (source app agnostic — catches forwarded messages, emails, chat apps we missed)
        if containsTwoFactorPhrase(text) {
            return true
        }

        return false
    }

    /// Mask sensitive text for display
    static func mask(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 8 {
            let prefix = String(trimmed.prefix(4))
            let suffix = String(trimmed.suffix(4))
            return prefix + String(repeating: "•", count: trimmed.count - 8) + suffix
        }
        return String(repeating: "•", count: trimmed.count)
    }
}
