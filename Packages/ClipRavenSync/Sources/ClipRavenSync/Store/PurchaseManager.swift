import StoreKit
import OSLog
#if os(macOS)
import AppKit
#endif

private let log = Logger(subsystem: "com.lumibear.clipraven", category: "purchase")

/// StoreKit 2 기반 구매 관리자. Mac + iOS 공유.
///
/// 앱 시작 시 `shared.refresh()` 를 한 번 호출하면 된다.
/// 이후 `lockState` 변화를 SwiftUI 에서 관찰해 페이월을 표시한다.
@MainActor
public final class PurchaseManager: ObservableObject {

    public static let shared = PurchaseManager()
    public static let productID = "com.lumibear.clipraven.fullaccess"

    // 초기값을 즉시 keychain 의 firstLaunchDate 기준으로 계산.
    //
    // 이전엔 `.trial(daysLeft: TrialManager.trialDays)` (= 항상 15) 로 초기화 후
    // `refresh()` 의 `updateLockState()` 가 정확한 값으로 갱신하는 패턴이었음.
    // 그런데 `Transaction.currentEntitlements` 의 for-await 가 sandbox 미설정
    // 환경(App Store Connect product 미등록 + StoreKitTest .storekit 없음)에선
    // stream 이 즉시 close 안 하고 hang 하는 케이스가 관찰됨 (로그에 "lockState
    // updated:" info 가 한 번도 안 찍힘 = 함수가 그 라인까지 도달 안 함). 결과로
    // UI 는 초기값 15 그대로 계속 표시.
    //
    // 해결: 초기값을 호출 시점에 즉시 정확한 daysRemaining 으로 계산. paid 사용자도
    // 1초 미만 잠시 .trial(N) 로 보일 수 있지만 `refresh()` 가 곧 .paid 로 갱신.
    @Published public private(set) var lockState: LockState = PurchaseManager.computeLockState(
        daysLeft: TrialManager.shared.daysRemaining(),  // instance API (정적 호환 layer 의 deprecated 경고 회피)
        hasPaidEntitlement: false
    )
    @Published public private(set) var product: Product?
    @Published public private(set) var isPurchasing = false
    @Published public private(set) var errorMessage: String?

    private var transactionTask: Task<Void, Never>?

    private init() {
        transactionTask = listenForTransactions()
    }

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
            errorMessage = String(localized: "상품 정보를 불러오는 중입니다. 잠시 후 다시 시도해 주세요.", bundle: .module)
            return
        }
        // macOS LSUIElement(메뉴바) 앱은 StoreKit 시트 표시 전에 앱을 activate해야 함
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif

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
                    errorMessage = String(localized: "구매 검증에 실패했습니다.", bundle: .module)
                }
            case .userCancelled:
                break
            case .pending:
                errorMessage = String(localized: "결제 대기 중입니다. 승인 후 자동으로 잠금이 해제됩니다.", bundle: .module)
            @unknown default:
                break
            }
        } catch {
            let fmt = String(localized: "구매 중 오류가 발생했습니다: %@", bundle: .module)
            errorMessage = String(format: fmt, error.localizedDescription)
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
                errorMessage = String(localized: "복원할 구매 내역이 없습니다.", bundle: .module)
            }
        } catch {
            let fmt = String(localized: "복원 중 오류가 발생했습니다: %@", bundle: .module)
            errorMessage = String(format: fmt, error.localizedDescription)
            log.error("restore failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Private

    private func loadProduct() async {
        // 이미 로드된 경우 재시도 불필요
        guard product == nil else { return }
        do {
            let products = try await Product.products(for: [Self.productID])
            guard let first = products.first else {
                // 빈 배열 — product를 nil로 두어 다음 refresh에서 재시도 가능하게 유지
                log.error("Product.products returned empty — check App Store Connect / Sandbox account / scheme StoreKit config")
                errorMessage = String(localized: "App Store에서 상품 정보를 찾을 수 없습니다. 인터넷 연결을 확인해 주세요.", bundle: .module)
                return
            }
            self.product = first
            errorMessage = nil
            log.info("product loaded: \(first.displayPrice, privacy: .public)")
        } catch {
            log.error("product load failed: \(String(describing: error), privacy: .public)")
            let fmt = String(localized: "상품 정보 로드에 실패했습니다: %@", bundle: .module)
            errorMessage = String(format: fmt, error.localizedDescription)
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
        lockState = Self.computeLockState(
            daysLeft: TrialManager.shared.daysRemaining(),
            hasPaidEntitlement: false
        )
        log.info("lockState updated: \(String(describing: self.lockState), privacy: .public)")
    }

    // MARK: - Pure State Function (테스트 가능)

    /// 트라이얼 잔여 일수와 paid 권한 보유 여부로 `LockState` 를 계산하는 순수 함수.
    /// StoreKit / Keychain 같은 외부 의존성 없이 단위 테스트 가능.
    ///
    /// 규칙:
    /// - `hasPaidEntitlement == true` 면 무조건 `.paid` (구매가 트라이얼보다 우선)
    /// - `daysLeft >= 1` 이면 `.trial(daysLeft:)`
    /// - 그 외 `.expired`
    public nonisolated static func computeLockState(
        daysLeft: Int,
        hasPaidEntitlement: Bool
    ) -> LockState {
        if hasPaidEntitlement { return .paid }
        return daysLeft > 0 ? .trial(daysLeft: daysLeft) : .expired
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
