import Foundation

enum URLNormalizer {
    // Common tracking parameters to strip.
    // Used both by `normalize()` (for dedup hashing) and `stripTracking()` (display/paste).
    private static let trackingParams: Set<String> = [
        // Google Analytics / UTM
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        // Ad click IDs
        "fbclid", "gclid", "gclsrc", "msclkid", "dclid", "yclid", "twclid",
        // Referral
        "ref", "ref_src", "ref_url", "referrer",
        // HubSpot
        "_hsenc", "_hsmi", "__hstc", "__hssc", "__hsfp", "hsCtaTracking",
        // Mailchimp
        "mc_cid", "mc_eid",
        // Oracle / Eloqua
        "oly_anon_id", "oly_enc_id", "elqTrackId", "elqTrack",
        // Salesforce / Marketo
        "mkt_tok",
        // Misc
        "source", "campaign_id", "spm", "share_source"
    ]

    static func isURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n") else { return false }
        guard let url = URL(string: trimmed) else { return false }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp"].contains(scheme)
    }

    /// Normalize URL for duplicate detection (aggressive — lowercase host, remove fragment/slash).
    /// Used only for hashing; do NOT show this result to the user.
    static func normalize(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return urlString
        }

        // Lowercase host
        components.host = components.host?.lowercased()

        // Remove tracking parameters
        if let queryItems = components.queryItems {
            let filtered = queryItems.filter { !trackingParams.contains($0.name.lowercased()) }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }

        // Remove fragment
        components.fragment = nil

        // Remove trailing slash
        if components.path.hasSuffix("/") && components.path != "/" {
            components.path = String(components.path.dropLast())
        }

        return components.string ?? urlString
    }

    /// Strip only tracking parameters — preserves host casing, fragment, trailing slash.
    /// Safe for display/paste: user sees the same URL minus the tracking noise.
    static func stripTracking(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return urlString
        }
        guard let queryItems = components.queryItems, !queryItems.isEmpty else {
            return urlString
        }
        let filtered = queryItems.filter { !trackingParams.contains($0.name.lowercased()) }
        // No change? return original string verbatim (preserves unusual encodings)
        if filtered.count == queryItems.count {
            return urlString
        }
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string ?? urlString
    }
}
