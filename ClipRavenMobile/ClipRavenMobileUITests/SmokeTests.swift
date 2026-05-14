import XCTest

/// ClipRavenMobile 핵심 플로우 스모크 테스트.
/// 실제 시뮬레이터에서 앱을 실행하며 주요 화면/기능이 동작하는지 검증한다.
final class SmokeTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 1. 앱 실행

    func test_appLaunches_navigationTitleVisible() {
        let title = app.staticTexts["ClipRaven"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 5),
            "앱 실행 시 ClipRaven 타이틀이 보여야 합니다"
        )
    }

    // MARK: - 2. 툴바 버튼

    func test_settingsButton_exists() {
        let settingsBtn = app.buttons["clipList.settingsButton"]
        XCTAssertTrue(
            settingsBtn.waitForExistence(timeout: 5),
            "설정 버튼(gear)이 툴바에 존재해야 합니다"
        )
    }

    func test_addButton_exists() {
        let addBtn = app.buttons["clipList.addButton"]
        XCTAssertTrue(
            addBtn.waitForExistence(timeout: 5),
            "추가 버튼(plus)이 툴바에 존재해야 합니다"
        )
    }

    // MARK: - 3. 설정 화면 오픈

    func test_settingsButton_opensSettingsSheet() {
        let settingsBtn = app.buttons["clipList.settingsButton"]
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: 5))
        settingsBtn.tap()

        // SettingsView 툴바의 "완료" 버튼 (accessibilityIdentifier) 으로 시트 오픈 확인
        // navigationBars 타이틀 방식보다 안정적 — 로케일·iOS 버전 무관
        let doneBtn = app.buttons["settings.doneButton"]
        XCTAssertTrue(
            doneBtn.waitForExistence(timeout: 5),
            "설정 버튼 탭 시 설정 시트가 열려야 합니다"
        )
    }

    // MARK: - 4. 클립 추가 시트 오픈

    func test_addButton_opensAddSheet() {
        let addBtn = app.buttons["clipList.addButton"]
        XCTAssertTrue(addBtn.waitForExistence(timeout: 5))
        addBtn.tap()

        // AddClipView 툴바의 "취소" 버튼 (accessibilityIdentifier) 으로 시트 오픈 확인
        let cancelBtn = app.buttons["addClip.cancelButton"]
        XCTAssertTrue(
            cancelBtn.waitForExistence(timeout: 5),
            "추가 버튼 탭 시 클립 추가 시트가 열려야 합니다"
        )
    }

    // MARK: - 5. 검색창

    func test_searchBar_typeAndClear() {
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 3) {
            app.swipeDown()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "검색창이 표시되어야 합니다")

        searchField.tap()
        // ASCII 입력 — 한글 IME 레이어 우회, 모든 기기/로케일에서 안정적
        searchField.typeText("hello")
        XCTAssertEqual(searchField.value as? String, "hello")

        // 검색 필드 내부의 × (clear) 버튼 — locale 무관하게 첫 번째 버튼
        let clearBtn = searchField.buttons.firstMatch
        if clearBtn.waitForExistence(timeout: 2) { clearBtn.tap() }

        // 지운 후: 빈 문자열 또는 placeholder "클립 검색" 모두 "지워진" 상태
        let afterValue = searchField.value as? String ?? ""
        XCTAssertTrue(
            afterValue.isEmpty || afterValue == "클립 검색",
            "검색창이 비워져야 합니다. 실제: \(afterValue)"
        )
    }

    // MARK: - 6. 페이월 버튼 (트라이얼 만료 상태)

    func test_paywallButtons_existWhenTrialExpired() {
        let purchaseBtn = app.buttons["paywall.purchaseButton"]
        let restoreBtn  = app.buttons["paywall.restoreButton"]

        if purchaseBtn.waitForExistence(timeout: 3) {
            XCTAssertTrue(purchaseBtn.exists, "구매 버튼이 있어야 합니다")
            XCTAssertTrue(restoreBtn.exists,  "복원 버튼이 있어야 합니다")
        } else {
            XCTSkip("트라이얼 기간 중이므로 페이월 테스트를 건너뜁니다")
        }
    }
}
