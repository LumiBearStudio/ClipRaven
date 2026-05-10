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
                    Text("체험 기간이 종료되었습니다")
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

                Text("한 번 구매로 Mac + iPhone/iPad 모두 사용")
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

                    Button("구매 복원") {
                        Task { await pm.restore() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(pm.isPurchasing)
                }
                .padding(.horizontal, 24)
            }
            .padding(28)
            .frame(maxWidth: 280)
        }
        .task { await pm.refresh() }
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
