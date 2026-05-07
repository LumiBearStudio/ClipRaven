import Foundation

/// Decides whether a clip should be excluded from iCloud sync, independent of
/// whether it was captured. Runs at the sync boundary.
///
/// `SensitiveDataFilter` runs earlier and blocks *capture* (password manager
/// concealed types, 2FA codes). SyncFilters is broader and softer: the clip is
/// allowed into the local DB so the user can paste it on this Mac, but the
/// `excludeFromSync` flag is set so it never leaves.
///
/// The goal is to fail safe on credentials and financial data even when the
/// user forgot to pause capture — losing a copy-paste convenience on one
/// device is acceptable; leaking a credit card across devices is not.
public enum SyncFilters {
    /// Evaluate a freshly-captured clip. `true` → insert with `excludeFromSync = 1`.
    ///
    /// - Parameters:
    ///   - text: captured text (nil for non-text clips).
    ///   - sourceAppBundleId: bundle ID of the app the copy came from.
    ///   - userAppBlacklist: additional bundle-ID fragments the user added in
    ///     Settings → Privacy. Matched case-insensitively via `contains`.
    public static func shouldExclude(
        text: String?,
        sourceAppBundleId: String?,
        userAppBlacklist: Set<String> = []
    ) -> Bool {
        if let bundleId = sourceAppBundleId?.lowercased(), !bundleId.isEmpty {
            if defaultAppBlacklist.contains(where: { bundleId.contains($0) }) {
                return true
            }
            if userAppBlacklist.contains(where: { bundleId.contains($0.lowercased()) }) {
                return true
            }
        }

        if let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            // DoS guard: regex scans and digit-filters are O(n). A multi-MB
            // hex dump or CSV paste should not freeze the clipboard monitor.
            // 16 KiB is larger than any legitimate credential payload yet
            // small enough that `NSRegularExpression` costs are bounded.
            guard raw.count <= scanLengthCap else {
                return false
            }
            if matchesSyncExclusionPattern(raw) { return true }
            if looksLikeCreditCard(raw) { return true }
        }

        return false
    }

    /// Max clip text size (chars) that we bother scanning for secrets. Beyond
    /// this we skip and let the sync go through — if the user pastes a 50MB
    /// log file they almost certainly don't want it blocked anyway.
    private static let scanLengthCap = 16 * 1024

    // MARK: - Regex patterns (sync-exclusion only)
    //
    // Categories (plan §9 Layer 2):
    //   - AWS access keys
    //   - GitHub personal / OAuth / server / user / refresh tokens
    //   - Stripe secret / restricted keys (live + test)
    //   - Slack tokens (xoxa/xoxb/xoxp/xoxr/xoxs)
    //   - Google API keys (AIza… 39 chars total)
    //   - OpenAI / Anthropic prefixed keys (sk-…)
    //   - Google OAuth access tokens (ya29.…)
    //   - JWTs (three base64 segments separated by dots)
    //   - Private key PEM headers
    //   - URL basic-auth
    //   - App-specific passwords (Apple ID format)
    //   - IBAN (full-string match; length + prefix differentiate from long uppercase strings)
    //   - Korean SSN pattern (주민등록번호 13자리)
    //   - npm access tokens (npm_…)
    //   - Hugging Face tokens (hf_…)
    //
    // Each pattern is anchored by a recognisable prefix/format so false
    // positives on normal prose are rare. We accept false negatives over
    // false positives — a detected secret is dropped from sync, which hurts
    // the user if it's not really a secret.
    private static let syncExclusionPatterns: [String] = [
        "(?i)\\bAKIA[0-9A-Z]{16}\\b",
        "\\bgh[pousr]_[A-Za-z0-9]{36}\\b",
        "\\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}\\b",
        "\\bxox[abprs]-[A-Za-z0-9-]{10,}\\b",
        "\\bAIza[0-9A-Za-z_\\-]{35}\\b",
        "\\bsk-[A-Za-z0-9_\\-]{20,}\\b",
        "\\bya29\\.[A-Za-z0-9_\\-]{20,}\\b",
        "\\beyJ[A-Za-z0-9_\\-]+\\.eyJ[A-Za-z0-9_\\-]+\\.[A-Za-z0-9_\\-]*",
        "-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----",
        "https?://[^:/\\s]+:[^@\\s]+@",
        "(?i)^[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}$",
        "^[A-Z]{2}\\d{2}[A-Z0-9]{11,30}$",
        "\\b\\d{6}-[1-4]\\d{6}\\b",
        "\\bnpm_[A-Za-z0-9]{36,}\\b",
        "\\bhf_[A-Za-z0-9]{30,}\\b",
    ]

    private static func matchesSyncExclusionPattern(_ text: String) -> Bool {
        for pattern in syncExclusionPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Luhn-validated credit card detection. Pure digit run of 13–19 is common
    /// enough that we require the checksum to match to avoid tagging random IDs.
    /// Caller has already enforced the `scanLengthCap`.
    private static func looksLikeCreditCard(_ raw: String) -> Bool {
        let digits = raw.filter { $0.isNumber }
        guard (13...19).contains(digits.count) else { return false }

        var sum = 0
        var alternate = false
        for ch in digits.reversed() {
            guard let digit = ch.wholeNumberValue else { return false }
            if alternate {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: - App blacklist

    /// Bundle-ID fragments (case-insensitive `contains`) that indicate a
    /// password manager, authenticator, or secrets vault. Clipboard flowing
    /// from these apps should never reach iCloud, full stop.
    private static let defaultAppBlacklist: Set<String> = [
        "1password",
        "onepassword",  // 1Password 7 MAS bundle id is com.agilebits.onepassword7
        "agilebits",    // older 1Password vendor prefix
        "bitwarden",
        "dashlane",
        "lastpass",
        "keychain",
        "keepass",
        "nordpass",
        "roboform",
        "authy",
        "enpass",
    ]
}
