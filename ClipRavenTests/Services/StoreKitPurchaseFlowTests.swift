import XCTest
import StoreKit
import StoreKitTest
@testable import ClipRavenSync

/// 구매·복원·환불 흐름을 로컬 StoreKit 세션으로 검증한다 (테스트 계획 B1).
///
/// 스킴에 연결된 `ClipRaven.storekit` 을 그대로 쓰고, 대화상자 없이 진행한다.
/// 앱의 `PurchaseManager.shared` 는 상품 캐시와 잠금 상태가 테스트 사이에 남으므로
/// 테스트마다 새 인스턴스를 만든다. 체험 상태는 QA 컨테이너의 것이라 여기서는
/// "구매됨(.paid)인가 아닌가" 만 본다.
@MainActor
final class StoreKitPurchaseFlowTests: XCTestCase {

    private var session: SKTestSession!

    static var configURL: URL {
        // ClipRavenTests/Services/<이 파일> → 저장소 루트
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClipRaven.storekit")
    }

    override func setUp() async throws {
        session = try SKTestSession(contentsOf: try Self.freshConfig())
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        try await Self.requireLocalStoreKitProducts()
    }

    /// 로컬 StoreKit 서버가 상품을 돌려주지 않는 환경이면 건너뛴다.
    ///
    /// 2026-09-28, macOS 26.6.2 에서 `xcodebuild test` 로 돌리면 구성 저장·서버 연결·거래
    /// 초기화는 정상인데 상품 요청만 빈 응답이 온다(storekitagent: "Ignoring empty product
    /// response"). 이때는 실패가 아니라 "검증하지 못함" 으로 남긴다. Xcode 에서 ⌘U 로
    /// 돌리거나 로컬 서버가 정상인 환경에서는 그대로 실행된다.
    static func requireLocalStoreKitProducts() async throws {
        let products = try await Product.products(for: [PurchaseManager.productID])
        if products.isEmpty {
            throw XCTSkip("로컬 StoreKit 서버가 상품을 돌려주지 않는 환경 — 결제 흐름은 Xcode 에서 확인")
        }
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
    }

    // MARK: - Helpers

    private func makeManager() async -> PurchaseManager {
        let manager = PurchaseManager()
        await manager.refresh()
        return manager
    }

    /// 거래 알림(`Transaction.updates`)이 비동기로 도착하는 경우를 기다린다.
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("조건이 \(Int(timeout))초 안에 참이 되지 않았다", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    // MARK: - 상품

    func test_refresh_loadsProductFromLocalConfig() async throws {
        let manager = await makeManager()
        let product = try XCTUnwrap(manager.product)
        XCTAssertEqual(product.id, PurchaseManager.productID)
        XCTAssertEqual(product.type, .nonConsumable)
        XCTAssertNil(manager.errorMessage)
        XCTAssertNotEqual(manager.lockState, .paid)
    }

    /// App Store Connect 에 상품이 아직 없거나 ID 가 다를 때.
    func test_missingProduct_reportsNotFound_andPurchaseExplainsLoading() async throws {
        session = try SKTestSession(contentsOf: try Self.freshConfig(withoutProducts: true))
        session.disableDialogs = true
        session.clearTransactions()

        let manager = await makeManager()
        XCTAssertNil(manager.product)
        XCTAssertEqual(
            manager.errorMessage,
            Self.localized("App Store에서 상품 정보를 찾을 수 없습니다. 인터넷 연결을 확인해 주세요.")
        )

        await manager.purchase()
        XCTAssertEqual(
            manager.errorMessage,
            Self.localized("상품 정보를 불러오는 중입니다. 잠시 후 다시 시도해 주세요.")
        )
        XCTAssertNotEqual(manager.lockState, .paid)
    }

    // MARK: - 구매

    func test_purchase_success_unlocks() async throws {
        let manager = await makeManager()
        await manager.purchase()
        XCTAssertEqual(manager.lockState, .paid)
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.isPurchasing)
    }

    /// 자녀 계정의 "구입 요청": 승인 전에는 잠겨 있고 안내가 뜨며, 승인되면 풀린다.
    func test_purchase_askToBuy_isPendingThenUnlocksWhenApproved() async throws {
        session.askToBuyEnabled = true
        let manager = await makeManager()

        await manager.purchase()
        XCTAssertNotEqual(manager.lockState, .paid)
        XCTAssertEqual(
            manager.errorMessage,
            Self.localized("결제 대기 중입니다. 승인 후 자동으로 잠금이 해제됩니다.")
        )

        let pending = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await waitUntil { manager.lockState == .paid }
    }

    func test_purchase_failure_staysLockedAndReportsError() async throws {
        session.failTransactionsEnabled = true
        let manager = await makeManager()

        await manager.purchase()
        XCTAssertNotEqual(manager.lockState, .paid)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.isPurchasing)
    }

    // MARK: - 복원

    func test_restore_withoutPurchase_reportsNothingToRestore() async throws {
        let manager = await makeManager()
        await manager.restore()
        XCTAssertNotEqual(manager.lockState, .paid)
        XCTAssertEqual(manager.errorMessage, Self.localized("복원할 구매 내역이 없습니다."))
    }

    /// 다른 Mac 이나 재설치 전에 산 경우: 이 설치의 인스턴스는 복원 후 풀린다.
    func test_restore_afterPurchaseElsewhere_unlocks() async throws {
        try session.buyProduct(productIdentifier: PurchaseManager.productID)
        let manager = await makeManager()
        await manager.restore()
        XCTAssertEqual(manager.lockState, .paid)
        XCTAssertNil(manager.errorMessage)
    }

    // MARK: - 환불

    func test_refund_locksAgain() async throws {
        let manager = await makeManager()
        await manager.purchase()
        XCTAssertEqual(manager.lockState, .paid)

        let transaction = try XCTUnwrap(
            session.allTransactions().first { $0.productIdentifier == PurchaseManager.productID }
        )
        try session.refundTransaction(identifier: transaction.identifier)
        try await waitUntil { manager.lockState != .paid }
    }

    // MARK: - Fixtures

    /// `ClipRaven.storekit` 사본을 새 구성 ID 로 임시 폴더에 만든다.
    ///
    /// StoreKit 에이전트는 오래 떠 있는 시스템 프로세스라 같은 구성 ID 로 저장한 내용을
    /// 붙들고 있다. 상품을 비운 구성과 원본이 같은 ID 를 쓰면 이후 테스트까지 상품이
    /// 비어 보였다. 매번 새 ID 를 주면 서로 섞이지 않는다.
    static func freshConfig(withoutProducts: Bool = false) throws -> URL {
        let data = try Data(contentsOf: configURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["identifier"] = UUID().uuidString
        if withoutProducts { json["nonConsumableProducts"] = [Any]() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipRaven-\(UUID().uuidString).storekit")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }
}
