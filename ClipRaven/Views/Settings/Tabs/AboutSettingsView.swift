import SwiftUI
import ClipRavenSync

/// 정보 탭 — 앱 버전, 라이선스, 정책 링크.
struct AboutSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showLicenses = false
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                // Use the shipped app icon so the About panel shows real brand
                // artwork instead of a generic SF Symbol. `NSImage(named:
                // "AppIcon")` resolves the asset catalog's AppIcon set on
                // macOS — the rendered variant matches what Finder/Dock show.
                // Fallback keeps the old SF Symbol treatment if the asset
                // is missing (dev builds without a generated icon set).
                Group {
                    if let nsImage = NSImage(named: "AppIcon") {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    } else {
                        ZStack {
                            Circle()
                                .fill(themeManager.colorPreset.accentColor.opacity(0.12))
                                .frame(width: 80, height: 80)
                            Image(systemName: "doc.on.clipboard.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(themeManager.colorPreset.accentColor)
                        }
                    }
                }

                VStack(spacing: 4) {
                    Text("ClipRaven")
                        .font(.title2.bold())
                    Text("버전 \(version) (\(build))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("by LumiBear Studio")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                PurchaseStatusRow()

                HStack(spacing: 16) {
                    Button("지원") {
                        NSWorkspace.shared.open(AppLinks.support)
                    }
                    .buttonStyle(.link)

                    Button("개인정보 처리방침") {
                        NSWorkspace.shared.open(AppLinks.privacyPolicy)
                    }
                    .buttonStyle(.link)

                    Button("오픈소스 라이선스") { showLicenses = true }
                        .buttonStyle(.link)
                }
                .font(.callout)

                Button {
                    OnboardingWindowController.shared.show()
                } label: {
                    Label("온보딩 다시 보기", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            Text("© 2026 LumiBear Studio. All rights reserved.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLicenses) {
            LicensesSheet(isPresented: $showLicenses)
        }
    }
}

private struct LicensesSheet: View {
    @Binding var isPresented: Bool

    private let dependencies: [(name: String, url: String, license: String)] = [
        ("GRDB.swift", "https://github.com/groue/GRDB.swift", "MIT License"),
        ("xxHash-Swift", "https://github.com/daisuke-t-jp/xxHash-Swift", "MIT License")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("오픈소스 라이선스").font(.title3.bold())
                Spacer()
                Button("닫기") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("ClipRaven은 다음 오픈소스 라이브러리를 사용합니다:")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ForEach(dependencies, id: \.name) { dep in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dep.name).font(.headline)
                            Text(dep.license).font(.caption).foregroundStyle(.secondary)
                            Button {
                                if let url = URL(string: dep.url) { NSWorkspace.shared.open(url) }
                            } label: {
                                Text(dep.url).font(.caption).lineLimit(1)
                            }
                            .buttonStyle(.link)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 360)
    }
}

/// 구매 상태와 구매·복원 버튼. 설정에서도 복원에 닿을 수 있어야 한다 (3.1.1).
private struct PurchaseStatusRow: View {
    @ObservedObject private var pm = PurchaseManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Text(statusText)
                .foregroundStyle(.secondary)
            if pm.lockState != .paid {
                Button("구매…") { PaywallWindowController.shared.show() }
                    .buttonStyle(.link)
            }
            Button("구매 복원") { Task { await pm.restore() } }
                .buttonStyle(.link)
                .disabled(pm.isPurchasing)
        }
        .font(.callout)
        .onAppear { pm.recomputeTrialState() }
    }

    private var statusText: String {
        switch pm.lockState {
        case .paid:            return String(localized: "구매 완료")
        case .trial(let days): return String(localized: "무료 체험 \(days)일 남음")
        case .expired:         return String(localized: "무료 체험 만료")
        }
    }
}
