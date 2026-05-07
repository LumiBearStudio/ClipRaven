import XCTest
@testable import ClipRaven

/// Verifies the BCP-47 tag → onboarding-bundle key mapping. The
/// onboarding HTML ships 9 language bundles; this resolver decides which
/// one to inject at load time, and English is the fallback for any
/// unmapped locale.
final class OnboardingLanguageResolverTests: XCTestCase {

    private func resolve(_ tag: String?) -> String {
        OnboardingWindowController.resolveOnboardingLanguage(from: tag)
    }

    // MARK: - Direct matches

    func test_koreanVariantsMapToKo() {
        XCTAssertEqual(resolve("ko"), "ko")
        XCTAssertEqual(resolve("ko-KR"), "ko")
    }

    func test_japaneseVariantsMapToJa() {
        XCTAssertEqual(resolve("ja"), "ja")
        XCTAssertEqual(resolve("ja-JP"), "ja")
    }

    func test_romanceLanguages() {
        XCTAssertEqual(resolve("es"), "es")
        XCTAssertEqual(resolve("es-ES"), "es")
        XCTAssertEqual(resolve("es-MX"), "es")
        XCTAssertEqual(resolve("fr"), "fr")
        XCTAssertEqual(resolve("fr-FR"), "fr")
        XCTAssertEqual(resolve("fr-CA"), "fr")
        XCTAssertEqual(resolve("it"), "it")
        XCTAssertEqual(resolve("it-IT"), "it")
    }

    func test_germanVariants() {
        XCTAssertEqual(resolve("de"), "de")
        XCTAssertEqual(resolve("de-DE"), "de")
        XCTAssertEqual(resolve("de-AT"), "de")
    }

    // MARK: - Chinese script discrimination

    func test_simplifiedChineseCanonical() {
        XCTAssertEqual(resolve("zh"), "zh-Hans", "bare 'zh' should default to Simplified (modern iCloud default)")
        XCTAssertEqual(resolve("zh-CN"), "zh-Hans")
        XCTAssertEqual(resolve("zh-Hans"), "zh-Hans")
        XCTAssertEqual(resolve("zh-Hans-CN"), "zh-Hans")
    }

    func test_traditionalChineseCanonical() {
        XCTAssertEqual(resolve("zh-Hant"), "zh-Hant")
        XCTAssertEqual(resolve("zh-Hant-TW"), "zh-Hant")
        XCTAssertEqual(resolve("zh-TW"), "zh-Hant")
        XCTAssertEqual(resolve("zh-HK"), "zh-Hant")
        XCTAssertEqual(resolve("zh-MO"), "zh-Hant")
    }

    // MARK: - Portuguese

    func test_portugueseBrazilOnly() {
        XCTAssertEqual(resolve("pt-BR"), "pt-BR")
    }

    func test_portugueseEuropeFallsBackToEn() {
        // We don't ship a pt-PT bundle yet; European Portuguese users
        // should see English rather than Brazilian-only copy.
        XCTAssertEqual(resolve("pt"), "en")
        XCTAssertEqual(resolve("pt-PT"), "en")
    }

    // MARK: - Fallbacks

    func test_englishIsFallbackForNilOrEmpty() {
        XCTAssertEqual(resolve(nil), "en")
        XCTAssertEqual(resolve(""), "en")
    }

    func test_unsupportedLocaleFallsBackToEn() {
        XCTAssertEqual(resolve("sv-SE"), "en") // Swedish
        XCTAssertEqual(resolve("nl-NL"), "en") // Dutch
        XCTAssertEqual(resolve("ar-SA"), "en") // Arabic
        XCTAssertEqual(resolve("he-IL"), "en") // Hebrew
    }

    func test_caseInsensitivity() {
        // Some locale sources upper-case region subtags (KO-KR); we
        // should not care.
        XCTAssertEqual(resolve("KO-KR"), "ko")
        XCTAssertEqual(resolve("ZH-TW"), "zh-Hant")
        XCTAssertEqual(resolve("PT-BR"), "pt-BR")
    }
}
