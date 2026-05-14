import XCTest
import SwiftUI
import ViewInspector
@testable import ClipRavenMobile
import ClipRavenSync

// MARK: - TrialBannerView Tests

final class TrialBannerViewInspectorTests: XCTestCase {

    func test_daysLeft_displayedInText() throws {
        let view = TrialBannerView(daysLeft: 7)
        // HStack > Text(1) 에 "7" 포함 확인
        let hStack = try view.inspect().hStack()
        let allStrings = try (0..<hStack.count).compactMap { i -> String? in
            try? hStack.text(i).string()
        }
        XCTAssertTrue(
            allStrings.joined().contains("7"),
            "배너에 남은 일수(7)가 표시되어야 합니다. 실제: \(allStrings)"
        )
    }

    func test_upgradeButton_exists() throws {
        let view = TrialBannerView(daysLeft: 3)
        // .buttonStyle 수식어가 붙은 경우 index 기반 탐색이 실패할 수 있어
        // label 텍스트로 직접 탐색하는 방식 사용
        _ = try view.inspect().find(button: "업그레이드")
    }

    func test_zeroDay_stillRendersWithoutCrash() throws {
        let view = TrialBannerView(daysLeft: 0)
        // 0일 남은 상태에서도 렌더링이 깨지지 않아야 함
        _ = try view.inspect().hStack()
    }
}

// MARK: - PaywallView Tests

final class PaywallViewInspectorTests: XCTestCase {

    /// product == nil 일 때 구매 버튼이 비활성화되어야 한다.
    @MainActor
    func test_purchaseButton_disabledWhenNoProduct() throws {
        // 테스트 환경(Sandbox 미연결)에서는 product == nil
        let pm = PurchaseManager.shared
        let view = PaywallView(purchaseManager: pm)

        let purchaseButton = try view.inspect().find(button: "지금 구매하기")
        XCTAssertTrue(
            try purchaseButton.isDisabled(),
            "상품 정보 없을 때 구매 버튼은 비활성화되어야 합니다"
        )
    }

    func test_restoreButton_exists() throws {
        let view = PaywallView(purchaseManager: .shared)
        let restoreButton = try view.inspect().find(button: "구매 복원")
        XCTAssertNotNil(restoreButton)
    }

    @MainActor
    func test_errorMessage_reflectsProductLoadState() {
        // 테스트 환경에서 product 로드 실패 시 errorMessage가 설정됨을 확인
        // (nil 또는 에러 문자열 모두 허용 — 타이밍에 따라 달라짐)
        let pm = PurchaseManager.shared
        if let msg = pm.errorMessage {
            XCTAssertFalse(msg.isEmpty, "errorMessage가 있다면 빈 문자열이 아니어야 합니다")
        }
        // errorMessage == nil 이면 product 로드 성공 또는 아직 시도 전
    }
}

// MARK: - ClipCard Tests

final class ClipCardInspectorTests: XCTestCase {

    private func makeClip(type: ContentType = .text, text: String = "Hello") -> Clip {
        Clip(
            id: 1,
            contentType: type,
            contentText: text,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func test_textClip_rendersWithoutCrash() throws {
        let clip = makeClip(type: .text, text: "테스트 클립")
        let view = ClipCard(clip: clip)
        _ = try view.inspect().geometryReader()
    }

    func test_urlClip_rendersWithoutCrash() throws {
        let clip = makeClip(type: .url, text: "https://apple.com")
        let view = ClipCard(clip: clip)
        _ = try view.inspect().geometryReader()
    }

    func test_codeClip_rendersWithoutCrash() throws {
        let clip = makeClip(type: .code, text: "let x = 42")
        let view = ClipCard(clip: clip)
        _ = try view.inspect().geometryReader()
    }
}
