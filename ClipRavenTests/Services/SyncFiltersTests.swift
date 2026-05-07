import XCTest
import ClipRavenSync
@testable import ClipRaven

/// Exercises the sync-exclusion heuristics — app blacklist, secret-shaped
/// regex detection, Luhn credit-card detection, and the DoS length cap.
///
/// The filter biases toward false negatives (a real secret slips through)
/// rather than false positives (a legitimate paste is silently dropped from
/// sync). Tests reflect that: we only assert detection on clearly-shaped
/// credentials and explicitly verify that ordinary prose / code is NOT
/// flagged.
final class SyncFiltersTests: XCTestCase {

    private func exclude(
        _ text: String?,
        app: String? = nil,
        userBlacklist: Set<String> = []
    ) -> Bool {
        SyncFilters.shouldExclude(
            text: text,
            sourceAppBundleId: app,
            userAppBlacklist: userBlacklist
        )
    }

    // MARK: - App blacklist

    func test_defaultBlacklistMatchesKnownPasswordManagers() {
        XCTAssertTrue(exclude("anything", app: "com.agilebits.onepassword7"))
        XCTAssertTrue(exclude("anything", app: "com.bitwarden.desktop"))
        XCTAssertTrue(exclude("anything", app: "com.apple.keychainaccess"))
        XCTAssertTrue(exclude("anything", app: "com.dashlane.dashlanephonefinal"))
        XCTAssertTrue(exclude("anything", app: "com.authy.desktop"))
    }

    func test_blacklistIsCaseInsensitive() {
        XCTAssertTrue(exclude("anything", app: "COM.1PASSWORD.1password7"))
        XCTAssertTrue(exclude("anything", app: "Com.Bitwarden.Desktop"))
    }

    func test_unknownAppPassesThroughToTextScan() {
        XCTAssertFalse(exclude("just some text", app: "com.apple.Safari"))
    }

    func test_userBlacklistSupplementsDefault() {
        XCTAssertTrue(exclude("x", app: "com.example.myvault", userBlacklist: ["myvault"]))
    }

    // MARK: - API-key / secret regex coverage

    func test_detectsAwsAccessKey() {
        XCTAssertTrue(exclude("AKIAIOSFODNN7EXAMPLE"))
    }

    func test_detectsAwsAccessKey_caseInsensitive() {
        // Real-world: `export aws_access_key_id=akiaiosfodnn7example` after
        // someone lowercased the env block.
        XCTAssertTrue(exclude("akiaiosfodnn7example"))
    }

    func test_detectsGitHubPersonalAccessToken() {
        XCTAssertTrue(exclude("ghp_abcdef0123456789abcdef0123456789abcd"))
    }

    func test_detectsGitHubOAuthAndServerTokens() {
        XCTAssertTrue(exclude("gho_abcdef0123456789abcdef0123456789abcd"))
        XCTAssertTrue(exclude("ghs_abcdef0123456789abcdef0123456789abcd"))
        XCTAssertTrue(exclude("ghu_abcdef0123456789abcdef0123456789abcd"))
        XCTAssertTrue(exclude("ghr_abcdef0123456789abcdef0123456789abcd"))
    }

    func test_detectsStripeSecretKeys() {
        XCTAssertTrue(exclude("sk_live_" + "PLACEHOLDER_xxxxxxxxxxxxxxxxxxx"))
        XCTAssertTrue(exclude("sk_test_" + "PLACEHOLDER_xxxxxxxxxxxxxxxxxxx"))
        XCTAssertTrue(exclude("rk_live_" + "PLACEHOLDER_xxxxxxxxxxxxxxxxxxx"))
    }

    func test_detectsSlackTokens() {
        XCTAssertTrue(exclude("xoxb-1234567890-abcdefgHIJKL"))
        XCTAssertTrue(exclude("xoxp-1234567890-abcdefgHIJKL"))
        XCTAssertTrue(exclude("xoxa-1234567890-abcdefgHIJKL"))
    }

    func test_detectsGoogleApiKey() {
        // Google API keys are exactly 39 chars: `AIza` + 35 alphanumerics/_/-.
        XCTAssertTrue(exclude("AIzaSyD-abc123DEF456ghi789JKL012mno345P"))
    }

    func test_detectsOpenAIStyleKey() {
        XCTAssertTrue(exclude("sk-abc123defghijklmnopqrstu"))
    }

    func test_detectsGoogleOAuthAccessToken() {
        XCTAssertTrue(exclude("ya29.a0AfH6SMAbc123defGhi456jKl"))
    }

    func test_detectsJwt() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abc123SigPart"
        XCTAssertTrue(exclude(jwt))
    }

    func test_detectsPemPrivateKey() {
        XCTAssertTrue(exclude("-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END..."))
        XCTAssertTrue(exclude("-----BEGIN EC PRIVATE KEY-----\nMHQC..."))
        XCTAssertTrue(exclude("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(exclude("-----BEGIN PRIVATE KEY-----"))
        XCTAssertTrue(exclude("-----BEGIN ENCRYPTED PRIVATE KEY-----"))
    }

    func test_detectsUrlBasicAuth() {
        XCTAssertTrue(exclude("https://user:s3cret@example.com/api"))
        XCTAssertTrue(exclude("http://admin:pass@10.0.0.1:8080/"))
    }

    func test_detectsAppleAppSpecificPassword() {
        XCTAssertTrue(exclude("abcd-efgh-ijkl-mnop"))
        XCTAssertTrue(exclude("ABCD-EFGH-IJKL-MNOP"))
    }

    func test_detectsIban() {
        XCTAssertTrue(exclude("DE89370400440532013000"))
        XCTAssertTrue(exclude("GB82WEST12345698765432"))
    }

    func test_detectsKoreanSSN() {
        // 13자리 주민등록번호 포맷 (XXXXXX-YXXXXXX, Y ∈ 1…4).
        XCTAssertTrue(exclude("900101-1234567"))
    }

    // MARK: - False-positive guards on normal text

    func test_doesNotFlagOrdinaryProse() {
        XCTAssertFalse(exclude("Meeting notes — discuss Q4 roadmap with team"))
        XCTAssertFalse(exclude("https://example.com/article/123"))
        XCTAssertFalse(exclude("이것은 평범한 한글 텍스트입니다"))
        XCTAssertFalse(exclude("func main() { print(\"hello\") }"))
    }

    func test_doesNotFlagShortNumericIds() {
        XCTAssertFalse(exclude("Order #12345"))
        XCTAssertFalse(exclude("Phone: 010-1234-5678"))
    }

    // MARK: - Luhn credit card detection

    func test_detectsKnownTestCreditCardNumbers() {
        // Visa test
        XCTAssertTrue(exclude("4111 1111 1111 1111"))
        // Mastercard test
        XCTAssertTrue(exclude("5555 5555 5555 4444"))
        // Amex test (15 digits)
        XCTAssertTrue(exclude("3782 822463 10005"))
    }

    func test_doesNotFlagRandomDigitsFailingLuhn() {
        // Same length but intentionally fails checksum.
        XCTAssertFalse(exclude("1234 5678 9012 3456"))
    }

    // MARK: - DoS / length cap

    func test_doesNotScanMultiMegabyteInputs() {
        // 1 MB of "A" — would otherwise force a regex scan + digit filter.
        // We measure only that shouldExclude returns false quickly; timing
        // is validated by XCTest's default timeout (60s).
        let huge = String(repeating: "A", count: 1_000_000)
        XCTAssertFalse(exclude(huge))
    }

    func test_hugeDigitBlobDoesNotFreeze() {
        // 500 KB of digits that would Luhn-match if scanned.
        let hugeDigits = String(repeating: "4111111111111111", count: 30_000)
        XCTAssertFalse(
            exclude(hugeDigits),
            "length cap must skip secret scan on oversized payloads"
        )
    }

    func test_scanRunsOnModerateSizeInputs() {
        // Exactly at the cap — allow the scan.
        let padded = String(repeating: " ", count: 16 * 1024 - 20)
            + "AKIAIOSFODNN7EXAMPLE"
        XCTAssertTrue(
            exclude(padded),
            "inputs at or below the cap should still trigger detection"
        )
    }

    // MARK: - Edge cases

    func test_handlesNilAndEmptyText() {
        XCTAssertFalse(exclude(nil))
        XCTAssertFalse(exclude(""))
        XCTAssertFalse(exclude("    \n\t  "))
    }

    // MARK: - 최신 secret 패턴 (2024–2025 추가분)

    func test_detectsAnthropicApiKey() {
        // sk-ant-api03-... 형식 (Anthropic Claude API key)
        XCTAssertTrue(exclude("sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890ABCDEF"))
    }

    func test_detectsNpmToken() {
        // npm_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx (40자)
        XCTAssertTrue(exclude("npm_abcdef1234567890ABCDEF1234567890abcd12"))
    }

    func test_detectsHuggingFaceToken() {
        // hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        XCTAssertTrue(exclude("hf_abcdefghijklmnopqrstuvwxyz12345678ABCD"))
    }

    func test_detectsGcpServiceAccountKey() {
        // "type": "service_account" JSON 스니펫
        XCTAssertTrue(exclude("""
        {
          "type": "service_account",
          "project_id": "my-project",
          "private_key": "-----BEGIN RSA PRIVATE KEY-----\\nMIIE..."
        }
        """))
    }

    // MARK: - 경계 케이스 (false-positive 방지)

    func test_doesNotFlagGitCommitHash() {
        // 40자 hex — SHA-1 git hash. 단독으로는 비밀이 아님
        XCTAssertFalse(exclude("a3f5b1c2d4e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0"))
    }

    func test_doesNotFlagUUID() {
        XCTAssertFalse(exclude("550e8400-e29b-41d4-a716-446655440000"))
    }

    func test_doesNotFlagKoreanPhoneNumber() {
        // 010-xxxx-xxxx 는 공개 정보 (연락처 공유 등)
        XCTAssertFalse(exclude("010-1234-5678"))
    }

    func test_doesNotFlagMarkdownCodeBlock() {
        let md = """
        ```python
        def hello():
            print("Hello, World!")
        ```
        """
        XCTAssertFalse(exclude(md))
    }
}
