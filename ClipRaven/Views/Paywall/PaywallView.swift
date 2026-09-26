import SwiftUI
import ClipRavenSync

/// 체험 만료 시 패널 위에 덮이는 전체 페이월.
struct PaywallView: View {
    @ObservedObject private var pm = PurchaseManager.shared

    var body: some View {
        ZStack {
            // Blurred backdrop
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Icon
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                VStack(spacing: 6) {
                    Text("ClipRaven")
                        .font(.title2.bold())
                    // 상태별 문구. 이전에는 체험 중에 "지금 구매하기…" 로 열어도
                    // "체험 기간이 종료되었습니다" 를 보여줬다 (v1 리뷰 M3).
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Price
                if let product = pm.product {
                    Text(product.displayPrice)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                // 플랫폼 약속은 하지 않는다 — iOS 앱이 같은 시점에 출시되지 않으면
                // 사실과 달라진다 (2.3.1). 구독이 아니라는 점만 분명히 적는다.
                Text("1회 구매 · 구독 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Error message
                if let error = pm.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Actions
                VStack(spacing: 8) {
                    if pm.lockState != .paid {
                    Button {
                        Task { await pm.purchase() }
                    } label: {
                        Group {
                            if pm.isPurchasing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("지금 구매하기")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pm.isPurchasing || pm.product == nil)
                    .accessibilityIdentifier("paywall.purchaseButton")
                    }

                    Button("구매 복원") {
                        Task { await pm.restore() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(pm.isPurchasing)
                    .accessibilityIdentifier("paywall.restoreButton")
                }
                .padding(.horizontal, 24)
            }
            .padding(28)
            .frame(maxWidth: 280)
        }
        .task { await pm.refresh() }
        // .paid 전환 시 PaywallWindowController 가 자동 close.
        // (구매 또는 restore 양쪽 다 .paid → 사용자가 다음 동작 안 해도 패널 사라짐)
        // Legacy 단일-파라미터 onChange (macOS 13 호환).
        .onChange(of: pm.lockState) { newState in
            if newState == .paid {
                NotificationCenter.default.post(
                    name: .clipRavenPaywallShouldClose, object: nil
                )
            }
        }
    }
    private var headline: String {
        switch pm.lockState {
        case .expired:        return String(localized: "체험 기간이 종료되었습니다")
        case .trial(let days): return String(localized: "무료 체험 \(days)일 남음")
        case .paid:           return String(localized: "구매해 주셔서 감사합니다")
        }
    }
}

/// 체험 중 패널 하단에 표시되는 배너.
struct TrialBannerView: View {
    let daysLeft: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("무료 체험 \(daysLeft)일 남음")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("업그레이드") {
                Task { await PurchaseManager.shared.purchase() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

}
