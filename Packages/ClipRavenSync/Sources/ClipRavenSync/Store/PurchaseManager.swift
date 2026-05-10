import StoreKit
import OSLog

private let log = Logger(subsystem: "com.lumibear.clipraven", category: "purchase")

/// StoreKit 2 기반 구매 관리자. Mac + iOS 공유.
///
/// 앱 시작 시 `shared.refresh()` 를 한 번 호출하면 된다.
/// 이후 `lockState` 변화를 SwiftUI 에서 관찰해 페이월을 표시한다.
@MainActor
public final class PurchaseManager: ObservableObject {

    public static let shared = PurchaseManager()
    public static let productID = "com.lumibear.clipraven.fullaccess"

    @Published public private(set) var lockState: LockState = .trial(daysLeft: TrialManager.trialDays)
    @Published public private(set) var product: Product?
    @Published public private(set) var isPurchasing = false
    @Published public private(set) var errorMessage: String?

    private var transactionTask: Task<Void, Never>?

    private init() {
        transactionTask = listenForTransactions()
    }

    deinit { transactionTask?.cancel() }

    // MARK: - Public

    /// 앱 시작 시 호출 — 상품 정보 로드 + 구매 상태 확인.
    public func refresh() async {
        async let productLoad: Void = loadProduct()
        async let stateUpdate: Void = updateLockState()
        _ = await (productLoad, stateUpdate)
    }

    /// 구매 진행.
    public func purchase() async {
        guard let product else {
            errorMessage = "상품 정보를 불러오는 중입니다. 잠시 후 다시 시도해 주세요."
            return
        }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await updateLockState()
                    log.info("purchase verified — productID=\(transaction.productID, privacy: .public)")
                } else {
                    errorMessage = "구매 검증에 실패했습니다."
                }
            case .userCancelled:
                break
            case .pending:
                errorMessage = "결제 대기 중입니다. 승인 후 자동으로 잠금이 해제됩니다."
            @unknown default:
                break
            }
        } catch {
            errorMessage = "구매 중 오류가 발생했습니다: \(error.localizedDescription)"
            log.error("purchase failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 이전 구매 복원.
    public func restore() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await updateLockState()
            if lockState != .paid {
                errorMessage = "복원할 구매 내역이 없습니다."
            }
        } catch {
            errorMessage = "복원 중 오류가 발생했습니다: \(error.localizedDescription)"
            log.error("restore failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Private

    private func loadProduct() async {
        guard product == nil else { return }
        do {
            let products = try await Product.products(for: [Self.productID])
            self.product = products.first
            log.info("product loaded: \(self.product?.displayPrice ?? "nil", privacy: .public)")
        } catch {
            log.error("product load failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateLockState() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, tx.productID == Self.productID {
                lockState = .paid
                log.info("entitlement verified — user is paid")
                return
            }
        }
        let days = TrialManager.daysRemaining()
        lockState = days > 0 ? .trial(daysLeft: days) : .expired
        log.info("lockState updated: \(String(describing: self.lockState), privacy: .public)")
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let tx) = result {
                    await tx.finish()
                    await self?.updateLockState()
                }
            }
        }
    }
}
