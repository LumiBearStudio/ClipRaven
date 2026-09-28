import XCTest
import AppKit
import StoreKitTest
import ClipRavenSync
@testable import ClipRaven

/// 체험이 끝나면 붙여넣기 진입점이 모두 막히는지 (테스트 계획 B3).
///
/// 진입점: 패널, 붙여넣기 스택, 단축어 "Paste Clip". 클립별 전역 단축키는
/// `AppDelegate` 의 Carbon 콜백 안이라 여기서는 공통 관문(`blockPasteIfExpired`)만
/// 검증한다. 체험 시작일은 QA App Group 에 쓰고 테스트가 끝나면 되돌린다. StoreKit 은
/// 로컬 세션이라 App Store 에 닿지 않는다.
@MainActor
final class PasteGateTests: XCTestCase {

    private var session: SKTestSession!
    private var storage: AppGroupStorage!
    private var savedStart: Date?
    private var savedPresenter: (() -> Void)!
    private var paywallShown = 0

    override func setUp() async throws {
        session = try SKTestSession(contentsOf: try StoreKitPurchaseFlowTests.freshConfig())
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()

        storage = AppGroupStorage(groupIdentifier: TrialManager.trialAppGroup)
        savedStart = storage.loadFirstLaunchDate()

        savedPresenter = MainPanelViewModel.presentPaywall
        paywallShown = 0
        MainPanelViewModel.presentPaywall = { [weak self] in self?.paywallShown += 1 }
    }

    override func tearDown() async throws {
        MainPanelViewModel.presentPaywall = savedPresenter
        if let savedStart {
            try? storage.saveFirstLaunchDate(savedStart)
        } else if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TrialManager.trialAppGroup
        ) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("trial.dat"))
        }
        session?.clearTransactions()
        session = nil
        // 공유 인스턴스를 거래 없는 상태로 되돌린다 (다른 테스트가 .paid 를 보지 않게).
        await PurchaseManager.shared.refresh()
    }

    /// 체험을 `days` 일 전에 시작한 상태로 만들고 공유 인스턴스를 다시 계산한다.
    private func startTrial(daysAgo days: Int) async throws {
        try storage.saveFirstLaunchDate(Date().addingTimeInterval(-Double(days) * 86_400))
        await PurchaseManager.shared.refresh()
    }

    // MARK: - 공통 관문

    func test_gate_blocksAndShowsPaywall_whenTrialExpired() async throws {
        try await startTrial(daysAgo: 16)
        XCTAssertEqual(PurchaseManager.shared.lockState, .expired)
        XCTAssertTrue(MainPanelViewModel.blockPasteIfExpired())
        XCTAssertEqual(paywallShown, 1)
    }

    func test_gate_allowsDuringTrial() async throws {
        try await startTrial(daysAgo: 1)
        XCTAssertFalse(MainPanelViewModel.blockPasteIfExpired())
        XCTAssertEqual(paywallShown, 0)
    }

    func test_gate_allowsAfterPurchase_evenIfTrialExpired() async throws {
        try await StoreKitPurchaseFlowTests.requireLocalStoreKitProducts()
        try await startTrial(daysAgo: 30)
        try session.buyProduct(productIdentifier: PurchaseManager.productID)
        await PurchaseManager.shared.refresh()
        XCTAssertEqual(PurchaseManager.shared.lockState, .paid)
        XCTAssertFalse(MainPanelViewModel.blockPasteIfExpired())
        XCTAssertEqual(paywallShown, 0)
    }

    // MARK: - 진입점

    func test_panelPaste_writesNothing_whenTrialExpired() async throws {
        try await startTrial(daysAgo: 16)
        let viewModel = MainPanelViewModel()
        let before = NSPasteboard.general.changeCount

        viewModel.pasteClip(Clip(contentType: .text, contentText: "만료 후에는 붙여넣지 않는다"))

        XCTAssertEqual(NSPasteboard.general.changeCount, before, "만료 상태에서 클립보드에 쓰면 안 된다")
        XCTAssertEqual(paywallShown, 1)
    }

    func test_pasteStack_doesNotStart_whenTrialExpired() async throws {
        try await startTrial(daysAgo: 16)
        let engine = PasteStackEngine()
        engine.items = [PasteStackItem(id: 1, clipId: 1, sortOrder: 0)]
        let before = NSPasteboard.general.changeCount

        engine.start()

        XCTAssertFalse(engine.isActive)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
        XCTAssertEqual(paywallShown, 1)
    }

    func test_shortcutsPasteClip_throwsTrialExpired() async throws {
        try await startTrial(daysAgo: 16)
        var intent = PasteClipIntent()
        intent.clip = ClipEntity(from: Clip(contentType: .text, contentText: "단축어"))

        do {
            _ = try await intent.perform()
            XCTFail("만료 상태에서 단축어 붙여넣기가 실행됐다")
        } catch ClipRavenIntentError.trialExpired {
            XCTAssertEqual(paywallShown, 1)
        } catch {
            XCTFail("trialExpired 가 아닌 오류: \(error)")
        }
    }

    // MARK: - QA 시계 (테스트 계획 B2)

    /// QA 빌드의 체험 시계 오프셋은 만료를 앞당길 수만 있고 체험을 늘릴 수는 없다.
    func test_qaTrialOffset_cannotExtendTrial() throws {
        try XCTSkipUnless(QARuntime.isQABuild, "QA 빌드(Debug-QA)에서만 의미가 있다")
        let key = "qaTrialOffsetDays"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(-30, forKey: key)
        XCTAssertEqual(QARuntime.trialClockOffset, 0)

        UserDefaults.standard.set(2, forKey: key)
        XCTAssertEqual(QARuntime.trialClockOffset, 2 * 86_400)
    }
}
