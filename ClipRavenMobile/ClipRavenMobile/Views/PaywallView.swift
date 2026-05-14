import SwiftUI
import ClipRavenSync

/// 체험 만료 시 표시되는 iOS 페이월.
struct PaywallView: View {
    @ObservedObject private var pm: PurchaseManager

    init(purchaseManager: PurchaseManager = .shared) {
        self.pm = purchaseManager
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // App icon
                if let icon = UIImage(named: "AppIcon") {
                    Image(uiImage: icon)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(radius: 8, y: 4)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 8) {
                    Text("ClipRaven")
                        .font(.largeTitle.bold())
                    Text("무료 체험이 종료되었습니다")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Price
                Group {
                    if let product = pm.product {
                        VStack(spacing: 4) {
                            Text(product.displayPrice)
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                            Text("1회 결제 · 구독 없음")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                    }
                }

                // Feature list
                VStack(alignment: .leading, spacing: 10) {
                    FeatureRow(icon: "infinity", text: "Mac + iPhone/iPad 영구 무제한 사용")
                    FeatureRow(icon: "icloud", text: "기기 간 iCloud 동기화")
                    FeatureRow(icon: "person.2", text: "가족 공유 지원")
                }
                .padding(.horizontal, 32)

                // Error
                if let error = pm.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }

            Spacer()

            // Actions
            VStack(spacing: 12) {
                Button {
                    Task { await pm.purchase() }
                } label: {
                    Group {
                        if pm.isPurchasing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("지금 구매하기")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pm.isPurchasing || pm.product == nil)
                .accessibilityIdentifier("paywall.purchaseButton")

                Button("구매 복원") {
                    Task { await pm.restore() }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .disabled(pm.isPurchasing)
                .accessibilityIdentifier("paywall.restoreButton")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .task { await pm.refresh() }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
        }
    }
}

/// iOS 클립 리스트 상단 체험 배너.
struct TrialBannerView: View {
    let daysLeft: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("무료 체험 **\(daysLeft)일** 남음")
                .font(.caption)
            Spacer()
            Button("업그레이드") {
                Task { await PurchaseManager.shared.purchase() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}
