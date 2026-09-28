import XCTest

/// 문자열 카탈로그 회귀 검사 (테스트 계획 B4).
///
/// 이번 출시 준비에서 실제로 나온 번역 버그가 다시 들어오지 않게 한다.
/// - 번역이 빠진 키: 다른 언어 화면에 한국어 원문이 그대로 보였다.
/// - 서식 지정자 불일치: 키는 `%@` 인데 코드가 Int 를 보간하면(`%lld`) 키가 맞지 않아
///   번역이 통째로 무시됐다 (iOS 체험 배너, 글자 수).
/// - 한국어 항목이 하나도 없는 카탈로그: `ko.lproj` 가 생기지 않아 한국어 기기에서
///   영어로 나왔다 (공용 패키지, iOS).
/// - 역슬래시가 들어간 키(`\"`): 실제 문자열과 절대 일치하지 않는다.
final class LocalizationCatalogTests: XCTestCase {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let catalogs = [
        "ClipRaven/Localization/Localizable.xcstrings",
        "Packages/ClipRavenSync/Sources/ClipRavenSync/Resources/Localizable.xcstrings",
        "ClipRavenMobile/ClipRavenMobile/Localizable.xcstrings",
        "ClipRavenMobile/KeyboardExtension/Localizable.xcstrings",
        "ClipRavenMobile/ShareExtension/Localizable.xcstrings",
        "ClipRavenMobile/WidgetExtension/Localizable.xcstrings",
    ]

    /// 한국어 원문 외에 반드시 있어야 하는 언어.
    static let targetLanguages = ["en", "ja", "de", "fr", "es", "it", "pt-BR", "zh-Hans", "zh-Hant"]

    /// 번역하지 않는 키: 고유명사, 기호, 언어 선택 목록의 언어 이름(각 언어로 표기).
    static let untranslatable: Set<String> = [
        "ClipRaven", "HD", "·", "© 2026 LumiBear Studio. All rights reserved.",
        "English", "한국어", "日本語", "简体中文", "繁體中文",
        "Español", "Français", "Deutsch", "Italiano", "Português (Brasil)",
    ]

    // MARK: - Tests

    func test_everyKeyHasAllTargetLanguages() throws {
        var problems: [String] = []
        for (path, strings) in try Self.loadCatalogs() {
            for (key, entry) in strings where Self.needsTranslation(key: key, entry: entry) {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                let missing = Self.targetLanguages.filter { lang in
                    guard let loc = localizations[lang] as? [String: Any] else { return true }
                    return Self.values(of: loc).allSatisfy { $0.isEmpty }
                }
                if !missing.isEmpty {
                    problems.append("\(Self.short(path)): \"\(key.prefix(40))\" — 없음: \(missing.joined(separator: ","))")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "번역 누락 \(problems.count)건\n" + problems.prefix(30).joined(separator: "\n"))
    }

    func test_formatSpecifiersMatchKey() throws {
        var problems: [String] = []
        for (path, strings) in try Self.loadCatalogs() {
            for (key, entry) in strings where Self.isLive(entry) {
                let expected = Self.specifiers(in: key)
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                for (lang, loc) in localizations {
                    guard let loc = loc as? [String: Any] else { continue }
                    for value in Self.values(of: loc) where Self.specifiers(in: value) != expected {
                        problems.append("\(Self.short(path)) [\(lang)] \"\(key.prefix(30))\": \(expected) ≠ \(Self.specifiers(in: value)) in \"\(value.prefix(40))\"")
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "서식 지정자 불일치 \(problems.count)건\n" + problems.prefix(30).joined(separator: "\n"))
    }

    /// 한국어 항목이 하나라도 있어야 `ko.lproj` 가 만들어진다. 없으면 개발 지역(en)으로
    /// 떨어져 한국어 기기에서 영어가 나온다.
    func test_everyCatalogProducesKoreanBundle() throws {
        for (path, strings) in try Self.loadCatalogs() {
            let hasKorean = strings.values.contains { entry in
                ((entry["localizations"] as? [String: Any])?["ko"]) != nil
            }
            XCTAssertTrue(hasKorean, "\(Self.short(path)): 한국어 항목이 없어 ko.lproj 가 생기지 않는다")
        }
    }

    func test_noKeyContainsEscapedQuote() throws {
        for (path, strings) in try Self.loadCatalogs() {
            for key in strings.keys where key.contains("\\\"") {
                XCTFail("\(Self.short(path)): 역슬래시가 든 키는 실제 문자열과 일치하지 않는다 — \(key)")
            }
        }
    }

    // MARK: - Helpers

    static func loadCatalogs() throws -> [(String, [String: [String: Any]])] {
        try catalogs.map { path in
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
            return (path, strings)
        }
    }

    static func isLive(_ entry: [String: Any]) -> Bool {
        (entry["extractionState"] as? String) != "stale" && (entry["shouldTranslate"] as? Bool) != false
    }

    static func needsTranslation(key: String, entry: [String: Any]) -> Bool {
        guard isLive(entry), !untranslatable.contains(key) else { return false }
        // 서식 지정자와 기호를 뺀 뒤 글자가 남아야 번역 대상이다.
        let stripped = key.replacingOccurrences(of: specifierPattern, with: "", options: .regularExpression)
        return stripped.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// stringUnit 값과 복수형·기기별 변형 값을 모두 모은다.
    static func values(of localization: [String: Any]) -> [String] {
        var result: [String] = []
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            result.append(value)
        }
        if let variations = localization["variations"] as? [String: Any] {
            for case let group as [String: Any] in variations.values {
                for case let variant as [String: Any] in group.values {
                    result.append(contentsOf: values(of: variant))
                }
            }
        }
        return result
    }

    static let specifierPattern = #"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA%]"#

    /// 서식 지정자의 종류 목록(순서 무관). `%%` 는 제외한다.
    static func specifiers(in string: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: specifierPattern)
        let ns = string as NSString
        return regex.matches(in: string, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .filter { $0 != "%%" }
            .map { $0.replacingOccurrences(of: #"^%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?"#, with: "%", options: .regularExpression) }
            .sorted()
    }

    static func short(_ path: String) -> String {
        path.replacingOccurrences(of: "/Localizable.xcstrings", with: "")
    }
}
