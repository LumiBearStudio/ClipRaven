import XCTest
@testable import ClipRaven

final class SensitiveDataFilterTests: XCTestCase {

    // MARK: - containsSensitivePattern

    func test_detects_JWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdef123"
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern(jwt))
    }

    func test_detects_OpenAIKey() {
        let key = "sk-proj1234567890abcdefghijklmnopqrstuvwxyz12"
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern(key))
    }

    func test_detects_GitHubToken() {
        let token = "ghp_" + String(repeating: "a", count: 36)
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern(token))
    }

    func test_detects_SlackBotToken() {
        let slack = "xoxb-1234567890-abcdefghij"
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern(slack))
    }

    func test_detects_CreditCardNumber() {
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern("4532123456788910"))
    }

    func test_detects_KoreanRRN() {
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern("901201-1234567"))
    }

    func test_detects_USSocialSecurity() {
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern("123-45-6789"))
    }

    func test_detects_RSAPrivateKeyHeader() {
        let key = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA...
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern(key))
    }

    func test_detects_LongApiKeyAlphanumeric() {
        // 32+ char alphanumeric
        let key = String(repeating: "a1B2c3D4", count: 4)  // 32 chars
        XCTAssertTrue(SensitiveDataFilter.containsSensitivePattern(key))
    }

    func test_rejects_NormalText() {
        XCTAssertFalse(SensitiveDataFilter.containsSensitivePattern("Hello, world!"))
    }

    func test_rejects_ShortText() {
        XCTAssertFalse(SensitiveDataFilter.containsSensitivePattern("abc123"))
    }

    // MARK: - isLikelyTwoFactorCode (4-8 digits only)

    func test_2FA_accepts6DigitCode() {
        XCTAssertTrue(SensitiveDataFilter.isLikelyTwoFactorCode("123456"))
    }

    func test_2FA_accepts4DigitCode() {
        XCTAssertTrue(SensitiveDataFilter.isLikelyTwoFactorCode("1234"))
    }

    func test_2FA_accepts8DigitCode() {
        XCTAssertTrue(SensitiveDataFilter.isLikelyTwoFactorCode("12345678"))
    }

    func test_2FA_rejectsTooShort() {
        XCTAssertFalse(SensitiveDataFilter.isLikelyTwoFactorCode("123"))
    }

    func test_2FA_rejectsTooLong() {
        XCTAssertFalse(SensitiveDataFilter.isLikelyTwoFactorCode("123456789"))
    }

    func test_2FA_rejectsAlphanumeric() {
        XCTAssertFalse(SensitiveDataFilter.isLikelyTwoFactorCode("abc123"))
    }

    func test_2FA_trimsWhitespace() {
        XCTAssertTrue(SensitiveDataFilter.isLikelyTwoFactorCode("  123456  "))
    }

    // MARK: - containsTwoFactorPhrase

    func test_2FA_phrase_koreanVerification() {
        XCTAssertTrue(SensitiveDataFilter.containsTwoFactorPhrase(
            "[네이버] 인증번호는 [123456]입니다"
        ))
    }

    func test_2FA_phrase_englishOTP() {
        XCTAssertTrue(SensitiveDataFilter.containsTwoFactorPhrase(
            "Your OTP is 987654"
        ))
    }

    func test_2FA_phrase_2faKeyword() {
        XCTAssertTrue(SensitiveDataFilter.containsTwoFactorPhrase(
            "2FA code: 445566"
        ))
    }

    func test_2FA_phrase_rejectsKeywordWithoutCode() {
        XCTAssertFalse(SensitiveDataFilter.containsTwoFactorPhrase(
            "Please enable 2FA for security"
        ))
    }

    func test_2FA_phrase_rejectsCodeWithoutKeyword() {
        XCTAssertFalse(SensitiveDataFilter.containsTwoFactorPhrase(
            "Meeting at 3pm room 12345"
        ))
    }
}
