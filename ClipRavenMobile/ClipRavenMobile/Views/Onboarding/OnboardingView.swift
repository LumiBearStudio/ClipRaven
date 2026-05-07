import SwiftUI
import UserNotifications
import ClipRavenSync

// MARK: - OnboardingView
//
// iOS/iPad 첫 실행 온보딩.
//
// 7페이지 구성 (스와이프 + 하단 도트 navigation):
//   1) Welcome           — 로고/슬로건/가격 정체성
//   2) Features          — 4-grid 핵심 기능 미리보기 (검색/태그/AI/Sync)
//   3) Sync              — iCloud 동기화 + 라이브 계정 상태 + 토글
//   4) Keyboard          — 키보드 익스텐션 4-step + "설정 앱 열기" 버튼
//   5) Try It            — visual mock 데모 (복사 → 카드 등장 애니메이션)
//   6) Privacy & Pricing — 광고/구독/추적 없음 + 일회성 구매
//   7) Personalize       — 테마/언어/햅틱/알림 권한 + "시작하기"
//
// 폼팩터 적응:
//   - iPhone (compact): 풀스크린 single column TabView
//   - iPad (regular):   2-column split for visual-heavy pages
//
// 정체성:
//   - 구독제 반대 — Page 6 에서 명시
//   - 사용자 데이터를 외부 서버로 보내지 않음 (Apple iCloud 만)
//
// 상태 관리:
//   - `@AppStorage("onboarding.completed")` 가 true 되면
//     ClipRavenMobileApp 의 fullScreenCover 가 자동 dismiss
//   - 비-크리티컬 페이지(Features / Try It)에선 "건너뛰기" 가능
//
struct OnboardingView: View {

    // MARK: - Persisted state
    @AppStorage("onboarding.completed")  private var completed  = false
    @AppStorage("clipraven.sync.enabled") private var syncEnabled = false
    @AppStorage("clipraven.feedback.hapticOnPaste") private var hapticOnPaste      = true

    // MARK: - Local state
    @State private var page = 0
    @State private var notificationGranted: Bool? = nil  // nil = 아직 요청 X
    @State private var keyboardSetupConfirmed = false    // page 4 의 사용자 self-confirm

    // MARK: - Layout adaptation
    @Environment(\.horizontalSizeClass) private var hSize
    /// iPad regular (size class .regular) 면 2-column 등 적응 레이아웃 사용.
    private var isPad: Bool { hSize == .regular }

    private let total = 7

    /// 건너뛰기 가능 페이지 — non-critical (보여주기용).
    /// Welcome / Sync / Keyboard / Privacy / Personalize 는 통과 필요.
    private func canSkip(_ p: Int) -> Bool { p == 1 || p == 4 }

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundLayer

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcomePage.tag(0)
                    featuresPage.tag(1)
                    syncPage.tag(2)
                    keyboardPage.tag(3)
                    tryItPage.tag(4)
                    privacyPage.tag(5)
                    personalizePage.tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomSection
                    .padding(.horizontal, isPad ? 80 : 24)
                    .padding(.bottom, 40)
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Background

    /// 페이지에 따라 미묘하게 다른 그라디언트 배경. 시각적 변화감.
    private var backgroundLayer: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.08)
            .ignoresSafeArea()
            .animation(AppAnimations.policy(.easeInOut(duration: 0.6)), value: page)
        }
    }

    private var gradientColors: [Color] {
        switch page {
        case 0: return [.blue, .cyan]
        case 1: return [.purple, .indigo]
        case 2: return [.cyan, .teal]
        case 3: return [.purple, .pink]
        case 4: return [.orange, .red]
        case 5: return [.green, .mint]
        default: return [.indigo, .blue]
        }
    }

    // MARK: - Bottom controls

    private var bottomSection: some View {
        VStack(spacing: 16) {
            pageDots

            HStack(spacing: 12) {
                if canSkip(page) {
                    Button {
                        AppAnimations.withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                    } label: {
                        Text("건너뛰기")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }

                if page < total - 1 {
                    actionButton(title: "계속") {
                        AppAnimations.withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                    }
                } else {
                    actionButton(title: "시작하기") {
                        AppAnimations.withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            completed = true
                        }
                    }
                }
            }
        }
        .animation(AppAnimations.policy(.easeInOut(duration: 0.25)), value: page)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == page ? 20 : 8, height: 8)
                    .animation(AppAnimations.policy(.spring(response: 0.3, dampingFraction: 0.7)), value: page)
            }
        }
    }

    private func actionButton(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: isPad ? 48 : 28) {
            Spacer()

            // 큰 로고 — Symbol 로 단순화
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: isPad ? 200 : 140, height: isPad ? 200 : 140)
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: isPad ? 96 : 68, weight: .light))
                    .foregroundStyle(Color.blue.gradient)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(spacing: 16) {
                Text("ClipRaven")
                    .font(isPad ? .system(size: 56, weight: .bold) : .largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("ClipRaven에 오신 걸\n환영합니다")
                    .font(isPad ? .title : .title3)
                    .foregroundStyle(.primary.opacity(0.8))
                    .multilineTextAlignment(.center)

                Text("광고도 추적도 없는,\n평생 쓰는 클립보드")
                    .font(isPad ? .title3 : .body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Page 2: Features showcase (NEW)

    private var featuresPage: some View {
        VStack(spacing: isPad ? 32 : 22) {
            Spacer(minLength: isPad ? 40 : 16)

            VStack(spacing: 8) {
                Text("이런 일을 할 수 있어요")
                    .font(isPad ? .system(size: 36, weight: .bold) : .title.bold())
                    .multilineTextAlignment(.center)

                Text("핵심 기능 미리보기")
                    .font(isPad ? .body : .subheadline)
                    .foregroundStyle(.secondary)
            }

            // 2x2 그리드
            let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
            LazyVGrid(columns: columns, spacing: 14) {
                FeatureTile(
                    icon: "magnifyingglass",
                    color: .blue,
                    title: "빠른 검색",
                    description: "한글 초성 검색 지원"
                )
                FeatureTile(
                    icon: "tag.fill",
                    color: .pink,
                    title: "태그",
                    description: "프로젝트별 정리"
                )
                FeatureTile(
                    icon: "sparkles",
                    color: .indigo,
                    title: "AI 카테고리",
                    description: "Mac에서 자동 분류"
                )
                FeatureTile(
                    icon: "icloud.and.arrow.down.fill",
                    color: .cyan,
                    title: "Mac 동기화",
                    description: "iCloud로 자동 공유"
                )
            }
            .padding(.horizontal, isPad ? 80 : 24)
            .frame(maxWidth: isPad ? 640 : .infinity)

            Spacer(minLength: 12)
        }
    }

    // MARK: - Page 3: Sync

    private var syncPage: some View {
        VStack(spacing: isPad ? 36 : 24) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                .font(.system(size: isPad ? 92 : 68))
                .foregroundStyle(Color.cyan.gradient)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 12) {
                Text("Mac과 자동으로 동기화")
                    .font(isPad ? .system(size: 32, weight: .bold) : .title2.bold())
                    .multilineTextAlignment(.center)

                Text("Mac ClipRaven에서 복사한 내용이\niCloud를 통해 이 iPhone으로\n자동 동기화됩니다.")
                    .font(isPad ? .title3 : .body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // iCloud 토글 카드 — Sync 페이지에 두어 사용자가 즉시 결정
            syncToggleCard
                .padding(.horizontal, isPad ? 80 : 28)
                .frame(maxWidth: isPad ? 560 : .infinity)

            Text("Mac 이 없어도 iPhone 단독으로\n클립보드 매니저로 사용할 수 있어요")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
    }

    private var syncToggleCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label("iCloud 동기화", systemImage: "icloud.fill")
                    .font(.body.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(syncEnabled ? Color.blue : Color.primary)
                Text("Mac과 클립 자동 공유")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { syncEnabled },
                set: { handleSyncToggle($0) }
            ))
            .labelsHidden()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func handleSyncToggle(_ enabled: Bool) {
        syncEnabled = enabled
        SyncFeatureFlag.setEnabled(enabled)
        if enabled {
            NotificationCenter.default.post(
                name: .clipRavenSyncEnabledChanged, object: true
            )
        }
    }

    // MARK: - Page 4: Keyboard Extension Setup

    private var keyboardPage: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 36)

                Image(systemName: "keyboard.fill")
                    .font(.system(size: isPad ? 92 : 68))
                    .foregroundStyle(Color.purple.gradient)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 12) {
                    Text("어디서나 바로 붙여넣기")
                        .font(isPad ? .system(size: 32, weight: .bold) : .title2.bold())
                        .multilineTextAlignment(.center)

                    Text("키보드 익스텐션을 활성화하면\n다른 앱에서도 클립을 바로 사용할 수 있어요.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                // 4단계 카드
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("설정 방법")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.bottom, 14)

                    keyboardStep(num: 1, text: "설정 앱 열기")
                    Divider().padding(.vertical, 8)
                    keyboardStep(num: 2, text: "일반 → 키보드 → 키보드")
                    Divider().padding(.vertical, 8)
                    keyboardStep(num: 3, text: "'새로운 키보드 추가' → ClipRaven")
                    Divider().padding(.vertical, 8)
                    keyboardStep(num: 4, text: "ClipRaven → 전체 접근 허용")
                }
                .padding(20)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, isPad ? 80 : 28)
                .frame(maxWidth: isPad ? 600 : .infinity)

                // "설정 앱 열기" 버튼 — 직접 안내
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("설정 앱 열기", systemImage: "arrow.up.right.square")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.purple)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(Color.purple.opacity(0.12))
                        )
                }

                // 자가 확인 토글 — 사용자가 활성화 했음을 알림
                Toggle(isOn: $keyboardSetupConfirmed) {
                    Text("키보드를 활성화 했어요")
                        .font(.subheadline)
                }
                .toggleStyle(SwitchToggleStyle(tint: .purple))
                .padding(.horizontal, isPad ? 100 : 36)

                Text("나중에 ClipRaven 설정에서도 안내받을 수 있어요")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer(minLength: 12)
            }
        }
    }

    private func keyboardStep(num: Int, text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Text("\(num)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.purple, in: Circle())
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }

    // MARK: - Page 5: Try It Now (visual mock)

    private var tryItPage: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 32)

                Image(systemName: "hand.tap.fill")
                    .font(.system(size: isPad ? 92 : 68))
                    .foregroundStyle(Color.orange.gradient)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 12) {
                    Text("이렇게 쓰는 거예요")
                        .font(isPad ? .system(size: 32, weight: .bold) : .title2.bold())
                        .multilineTextAlignment(.center)

                    Text("어떤 앱에서든 텍스트를 복사하면\nClipRaven에 자동으로 저장됩니다.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // 데모 mockup
                TryItDemoView()
                    .padding(.horizontal, isPad ? 100 : 28)
                    .frame(maxWidth: isPad ? 560 : .infinity)

                Text("스와이프하여 다음으로 진행하세요")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 16)
            }
        }
    }

    // MARK: - Page 6: Privacy & Pricing

    private var privacyPage: some View {
        VStack(spacing: isPad ? 36 : 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: isPad ? 92 : 68))
                .foregroundStyle(Color.green.gradient)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 12) {
                Text("광고 없음.\n구독 없음. 추적 없음.")
                    .font(isPad ? .system(size: 32, weight: .bold) : .title2.bold())
                    .multilineTextAlignment(.center)

                Text("모든 클립은 이 기기에 저장되며,\niCloud 동기화는 선택 사항입니다.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            // 특징 목록
            VStack(spacing: 0) {
                privacyRow(icon: "checkmark.circle.fill", color: .green,
                           text: "일회성 구매 — 평생 사용")
                Divider().padding(.horizontal)
                privacyRow(icon: "checkmark.circle.fill", color: .green,
                           text: "광고 없음")
                Divider().padding(.horizontal)
                privacyRow(icon: "checkmark.circle.fill", color: .green,
                           text: "외부 서버 전송 없음")
                Divider().padding(.horizontal)
                privacyRow(icon: "lock.fill", color: .green,
                           text: "민감한 정보 자동 제외")
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, isPad ? 100 : 28)
            .frame(maxWidth: isPad ? 560 : .infinity)

            Spacer()
            Spacer()
        }
    }

    private func privacyRow(icon: String, color: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 17))
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Page 7: Personalize

    private var personalizePage: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 32)

                Image(systemName: "wand.and.stars")
                    .font(.system(size: isPad ? 92 : 68))
                    .foregroundStyle(Color.indigo.gradient)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 8) {
                    Text("마지막 단계 — 개인화")
                        .font(isPad ? .system(size: 32, weight: .bold) : .title2.bold())
                        .multilineTextAlignment(.center)

                    Text("나중에 설정에서 언제든 변경할 수 있어요")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)

                // 설정 카드들 — 테마/언어는 의도적으로 제외 (시스템 기본값
                // 으로 충분, 필요시 Settings 에서 변경). 햅틱과 알림 권한만
                // 첫 실행 단계에서 명시적으로 제시.
                VStack(spacing: 14) {
                    hapticCard
                    notificationCard
                }
                .padding(.horizontal, isPad ? 100 : 28)
                .frame(maxWidth: isPad ? 560 : .infinity)

                Spacer(minLength: 16)
            }
        }
    }

    private var hapticCard: some View {
        OnboardingSettingCard(icon: "hand.point.up.left.fill", iconColor: .orange, title: "햅틱 피드백") {
            Toggle("", isOn: $hapticOnPaste).labelsHidden()
        }
    }

    private var notificationCard: some View {
        OnboardingSettingCard(icon: "bell.fill", iconColor: .red, title: "알림") {
            switch notificationGranted {
            case .none:
                Button("허용") { requestNotificationPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .some(true):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .some(false):
                Text("거부됨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            DispatchQueue.main.async {
                self.notificationGranted = granted
            }
        }
    }
}

// MARK: - Helper components

/// 4-grid feature 카드 — Page 2 의 미리보기.
private struct FeatureTile: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .foregroundStyle(color.gradient)
                    .font(.system(size: 20, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Page 5 의 인터랙티브 데모 — visual mock 만 (실제 클립보드 캡처 X).
/// 자동 애니메이션: 텍스트 카드 → 복사 효과 → 리스트에 새 클립 등장.
private struct TryItDemoView: View {
    @State private var stage: Int = 0   // 0: idle, 1: copying, 2: appeared

    var body: some View {
        VStack(spacing: 16) {
            // 상단: 복사할 sample 텍스트 카드
            HStack {
                Image(systemName: "quote.opening")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("어떤 앱이든 텍스트를 복사하세요")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if stage == 1 {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))

            // 화살표
            Image(systemName: "arrow.down")
                .foregroundStyle(.orange.opacity(0.6))
                .font(.title3)

            // 하단: ClipRaven 클립 리스트 mock
            VStack(spacing: 8) {
                if stage >= 2 {
                    mockClipCard(text: "어떤 앱이든 텍스트를 복사하세요",
                                 timestamp: "방금",
                                 highlight: true)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
                mockClipCard(text: "이전 클립…", timestamp: "5분 전", highlight: false)
                mockClipCard(text: "더 이전 클립…", timestamp: "1시간 전", highlight: false)
            }
            .padding(14)
            .background(Color(.tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .onAppear { runDemo() }
    }

    private func runDemo() {
        // 1.0s 후 "복사 중" 표시 → 0.8s 후 카드 등장 → 3s 후 리셋 (반복)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppAnimations.withAnimation(.easeOut(duration: 0.3)) { stage = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AppAnimations.withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { stage = 2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    AppAnimations.withAnimation(.easeIn(duration: 0.4)) { stage = 0 }
                    runDemo()
                }
            }
        }
    }

    private func mockClipCard(text: LocalizedStringKey, timestamp: LocalizedStringKey, highlight: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(highlight ? Color.orange : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text(timestamp)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(highlight ? Color.orange.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Page 7 의 단일 설정 카드 — icon + title + 우측 컨트롤.
private struct OnboardingSettingCard<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .foregroundStyle(iconColor.gradient)
                    .font(.system(size: 14, weight: .medium))
            }
            Text(title)
                .font(.body)
            Spacer()
            trailing()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Preview

#Preview("iPhone") {
    OnboardingView()
}

#Preview("iPad") {
    OnboardingView()
        .previewDevice("iPad Pro 11-inch (M4)")
}
