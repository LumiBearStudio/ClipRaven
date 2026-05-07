import SwiftUI
import CloudKit
import ClipRavenSync

/// iOS Settings 화면.
///
/// Mac SettingsWindow 의 9개 탭 구조를 iPhone 폼팩터에 맞게 단일
/// NavigationStack + Section 으로 재배치.
///
/// 섹션 구성:
///   - General: Language, Onboarding 다시 보기
///   - Appearance: Theme (System/Light/Dark)
///   - iCloud Sync: 토글 + 상태 + 이미지 동기화 (기존 보존)
///   - Privacy: 민감 데이터/2FA/URL 트래킹/제어 문자 자동 처리
///   - Sound & Haptic: 복사/붙여넣기 시 사운드/햅틱
///   - About: 버전, 라이선스, 정책
///
/// 구독제 반대 정체성: ClipRaven은 일회성 구매. Settings에서 "구독 정보"
/// 같은 항목 노출 금지.
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    // MARK: - Persisted preferences

    @AppStorage("clipraven.sync.enabled") private var syncEnabled = false

    /// 사용자 선택 언어. "system" | "ko" | "en". `AppleLanguages` UserDefault
    /// 와 함께 읽혀 SwiftUI Localized 키 해석에 영향. 변경은 앱 재시작 필요.
    @AppStorage("clipraven.preferredLanguage") private var preferredLanguage = "system"

    /// 색상 스키마. "system" | "light" | "dark". ClipRavenMobileApp 의
    /// `.preferredColorScheme()` 모디파이어가 이 값을 읽어 즉시 적용.
    @AppStorage("clipraven.preferredColorScheme") private var preferredColorScheme = "system"
    @AppStorage(AppAnimations.key) private var animationsEnabled = true

    // 민감 데이터 자동 차단 (캡처 전 검사)
    @AppStorage("clipraven.privacy.filterSensitive") private var filterSensitive = true
    @AppStorage("clipraven.privacy.filter2FA")       private var filter2FA       = true
    @AppStorage("clipraven.privacy.stripUrlTracking") private var stripUrlTracking = true
    @AppStorage("clipraven.privacy.stripInvisibles") private var stripInvisibles = true

    // Sound / Haptic
    @AppStorage("clipraven.feedback.soundOnCopy")  private var soundOnCopy  = false
    @AppStorage("clipraven.feedback.soundOnPaste") private var soundOnPaste = false
    @AppStorage("clipraven.feedback.hapticOnCopy") private var hapticOnCopy = true
    @AppStorage("clipraven.feedback.hapticOnPaste") private var hapticOnPaste = true

    // Onboarding 다시 보기
    @AppStorage("onboarding.completed") private var onboardingCompleted = false

    // MARK: - Local state

    @State private var accountStatus: CKAccountStatus?
    @State private var accountError: String?
    @State private var lastSyncedAt: Date?
    @State private var showRestartHint = false
    @State private var showLanguageRestartAlert = false
    @State private var showOnboardingResetConfirm = false
    @State private var clipStats = ClipStats()
    @State private var showLicenses = false

    @State private var imageSyncMode: ImageSyncMode = ImageSyncSettings.current().mode
    @State private var imageSyncSizeCap: ImageSyncSizeCap = ImageSyncSettings.current().sizeCap
    @State private var cellularAllowed: Bool = ImageSyncSettings.current().cellularAllowed
    @State private var imageDiskUsageBytes: Int64 = 0

    private let containerIdentifier = "iCloud.com.lumibear.ClipRaven"

    private var stateStore: SyncStateStore {
        SyncStateStore(dbWriter: AppDatabase.shared.dbPool)
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                appearanceSection
                syncSection
                if syncEnabled {
                    statusSection
                    imageSyncSection
                }
                privacySection
                feedbackSection
                aboutSection
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }
                        .fontWeight(.medium)
                }
            }
            .onAppear { refreshStatus() }
            .alert("재시작 필요", isPresented: $showRestartHint) {
                Button("확인") {}
            } message: {
                Text("동기화 설정 변경은 ClipRaven을 다시 실행한 후 적용됩니다.")
            }
            .alert("재시작 필요", isPresented: $showLanguageRestartAlert) {
                Button("확인") {}
            } message: {
                Text("언어 설정을 적용하려면 ClipRaven을 종료하고 다시 실행해주세요.")
            }
            .alert("온보딩 다시 보기", isPresented: $showOnboardingResetConfirm) {
                Button("취소", role: .cancel) {}
                Button("다시 보기") {
                    onboardingCompleted = false
                    dismiss()
                }
            } message: {
                Text("환영 화면을 처음부터 다시 봅니다. 클립 데이터는 유지됩니다.")
            }
            .sheet(isPresented: $showLicenses) {
                LicensesSheet()
            }
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section {
            Picker(selection: Binding(
                get: { preferredLanguage },
                set: { applyLanguage($0) }
            )) {
                Text("시스템 기본값").tag("system")
                // 매출 기여도 + 알파벳 mix 순서. native 표기로 표시 — 사용자가
                // 자국어로 인식 가능. xcstrings 의 `한국어` 키는 이미 자기 자신
                // 으로 번역 등록되어 다른 언어 locale 에서도 자국어 보임.
                Text("한국어").tag("ko")
                Text("English").tag("en")
                Text("日本語").tag("ja")
                Text("简体中文").tag("zh-Hans")
                Text("繁體中文").tag("zh-Hant")
                Text("Deutsch").tag("de")
                Text("Français").tag("fr")
                Text("Español").tag("es")
                Text("Italiano").tag("it")
                Text("Português (Brasil)").tag("pt-BR")
            } label: {
                Label("언어", systemImage: "globe")
            }

            Button {
                showOnboardingResetConfirm = true
            } label: {
                Label("온보딩 다시 보기", systemImage: "sparkles.rectangle.stack")
            }
        } header: {
            Text("일반")
        } footer: {
            Text("언어 변경은 앱 재시작 후 적용됩니다.")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(selection: $preferredColorScheme) {
                Label("시스템 기본값", systemImage: "circle.lefthalf.filled").tag("system")
                Label("라이트", systemImage: "sun.max.fill").tag("light")
                Label("다크", systemImage: "moon.fill").tag("dark")
            } label: {
                Label("테마", systemImage: "paintbrush.fill")
            }
            Toggle(isOn: $animationsEnabled) {
                Label("애니메이션", systemImage: "wand.and.stars")
            }
        } header: {
            Text("화면")
        } footer: {
            Text("애니메이션을 끄면 화면 전환이 즉시 표시됩니다.")
        }
    }

    private var syncSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { syncEnabled },
                set: { handleToggle($0) }
            )) {
                Label("iCloud 동기화", systemImage: "icloud.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(syncEnabled ? Color.blue : Color.secondary)
            }

            Text(syncEnabled
                 ? "이 iPhone의 클립이 다른 기기와 자동으로 동기화됩니다."
                 : "동기화를 끄면 클립이 이 iPhone에만 저장됩니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("동기화")
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Label("iCloud 계정", systemImage: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(accountStatusText)
                    .foregroundStyle(accountStatusColor)
                    .font(.subheadline)
            }

            if let last = lastSyncedAt {
                HStack {
                    Label("마지막 동기화", systemImage: "clock")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(last, style: .relative)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            // 클립 통계 — Mac 과 비교 가능. 차이 100개 이상이면 sync 누락 의심
            HStack {
                Label("총 클립", systemImage: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(clipStats.totalText)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .monospacedDigit()
            }
            HStack {
                Label("동기화 대상 / 완료", systemImage: "icloud.and.arrow.up")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(clipStats.syncedText)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .monospacedDigit()
            }

            Button {
                NotificationCenter.default.post(
                    name: .clipRavenSyncRefreshRequested, object: nil
                )
            } label: {
                Label("지금 동기화", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("상태")
        }
    }

    // MARK: - Image sync section (Phase C)

    private var imageSyncSection: some View {
        Section {
            Picker("이미지 동기화", selection: $imageSyncMode) {
                ForEach(ImageSyncMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: imageSyncMode) { _, newValue in
                ImageSyncSettings.setMode(newValue)
            }

            Text(imageSyncMode.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if imageSyncMode == .full {
                Picker("원본 사이즈 제한", selection: $imageSyncSizeCap) {
                    ForEach(ImageSyncSizeCap.allCases, id: \.rawValue) { cap in
                        Text(cap.displayName).tag(cap)
                    }
                }
                .onChange(of: imageSyncSizeCap) { _, newValue in
                    ImageSyncSettings.setSizeCap(newValue)
                }

                Toggle(isOn: Binding(
                    get: { cellularAllowed },
                    set: {
                        cellularAllowed = $0
                        ImageSyncSettings.setCellularAllowed($0)
                    }
                )) {
                    Label("셀룰러로도 원본 보내기", systemImage: "antenna.radiowaves.left.and.right")
                }

                if !cellularAllowed {
                    Text("Wi-Fi에서만 원본을 보냅니다. 다른 기기가 보낸 원본은 셀룰러에서도 받을 수 있습니다 (Apple iCloud 정책).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("저장된 이미지 용량", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(diskUsageDisplay)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .monospacedDigit()
            }
        } header: {
            Text("이미지")
        } footer: {
            Text("이미지 원본은 iCloud 저장공간을 사용합니다. 30일 이상 된 원본은 자동 삭제되며, 핀 고정한 클립은 영구 보관됩니다.")
        }
        .task {
            // 디스크 사용량 비동기 계산
            let usage = await Task.detached { ImageStorageService.diskUsage() }.value
            imageDiskUsageBytes = usage
        }
    }

    private var diskUsageDisplay: String {
        let bytes = imageDiskUsageBytes
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    private var privacySection: some View {
        Section {
            Toggle(isOn: $filterSensitive) {
                Label("민감한 데이터 자동 차단", systemImage: "lock.shield")
            }
            Toggle(isOn: $filter2FA) {
                Label("2단계 인증 코드 자동 필터", systemImage: "number.square")
            }
            Toggle(isOn: $stripUrlTracking) {
                Label("URL 트래킹 파라미터 자동 제거", systemImage: "link.badge.plus")
            }
            Toggle(isOn: $stripInvisibles) {
                Label("보이지 않는 제어 문자 자동 제거", systemImage: "wand.and.stars")
            }
        } header: {
            Text("개인정보")
        } footer: {
            Text("비밀번호, 신용카드, API 키 등 민감한 데이터는 자동으로 동기화에서 제외됩니다.")
        }
    }

    private var feedbackSection: some View {
        Section {
            Toggle("복사 시 사운드", isOn: $soundOnCopy)
            Toggle("붙여넣기 시 사운드", isOn: $soundOnPaste)
            Toggle("복사 시 햅틱", isOn: $hapticOnCopy)
            Toggle("붙여넣기 시 햅틱", isOn: $hapticOnPaste)
        } header: {
            Text("사운드 / 햅틱")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(appVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } label: {
                Label("앱 버전", systemImage: "info.circle")
            }

            Link(destination: URL(string: "https://github.com/yourorg/ClipRaven/blob/main/PRIVACY.md")!) {
                Label("개인정보 처리방침", systemImage: "hand.raised.fill")
            }

            Button {
                showLicenses = true
            } label: {
                Label("오픈소스 라이선스", systemImage: "doc.text")
            }

            HStack {
                Label("ClipRaven", systemImage: "doc.on.clipboard")
                    .foregroundStyle(.primary)
                Spacer()
                Text("by LumiBear Studio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("정보")
        } footer: {
            Text("© 2026 LumiBear Studio. All rights reserved.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private func handleToggle(_ newValue: Bool) {
        syncEnabled = newValue
        SyncFeatureFlag.setEnabled(newValue)
        if newValue {
            NotificationCenter.default.post(
                name: .clipRavenSyncEnabledChanged, object: true
            )
        } else {
            showRestartHint = true
        }
    }

    /// 언어 변경. `AppleLanguages` UserDefault 를 override 하면 SwiftUI 의
    /// 로컬라이즈 lookup 이 그 언어를 우선 사용. iOS 는 hot-reload 가 안
    /// 되므로 사용자에게 재시작 요청.
    private func applyLanguage(_ lang: String) {
        preferredLanguage = lang
        if lang == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
        showLanguageRestartAlert = true
    }

    private var accountStatusText: String {
        if accountError != nil { return String(localized: "확인 실패") }
        switch accountStatus {
        case .available:        return String(localized: "로그인됨")
        case .noAccount:        return String(localized: "iCloud 로그인 필요")
        case .restricted:       return String(localized: "사용 제한됨")
        case .couldNotDetermine: return String(localized: "확인 중…")
        case .temporarilyUnavailable: return String(localized: "일시적 사용 불가")
        case .none:             return String(localized: "확인 중…")
        @unknown default:       return String(localized: "알 수 없음")
        }
    }

    private var accountStatusColor: Color {
        switch accountStatus {
        case .available: return .green
        case .noAccount, .restricted: return .red
        default: return .secondary
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func refreshStatus() {
        Task { @MainActor in
            do {
                accountStatus = try await CKContainer(identifier: containerIdentifier)
                    .accountStatus()
                accountError = nil
            } catch {
                accountError = error.localizedDescription
            }
        }
        lastSyncedAt = stateStore.lastUpdatedAt(forKey: SyncStateStore.Key.mainEngine)

        // 클립 통계 — Mac 과 비교용 sync gap 진단
        Task.detached {
            let stats = await ClipStats.collect()
            await MainActor.run { self.clipStats = stats }
        }
    }
}

// MARK: - Sync gap diagnostic

/// 클립 통계 — Mac 과 비교해 sync 정상/누락 판별용.
private struct ClipStats {
    var total: Int = 0           // 모든 비-deleted 클립
    var syncTarget: Int = 0      // excludeFromSync = 0
    var syncCompleted: Int = 0   // ckLastSyncedAt IS NOT NULL

    var totalText: String { "\(total)개" }
    var syncedText: String { "\(syncCompleted) / \(syncTarget)" }

    static func collect() async -> ClipStats {
        let pool = AppDatabase.shared.dbPool
        var s = ClipStats()
        do {
            try await pool.read { db in
                s.total = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM clips WHERE isDeleted = 0"
                ) ?? 0
                s.syncTarget = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM clips WHERE isDeleted = 0 AND excludeFromSync = 0"
                ) ?? 0
                s.syncCompleted = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM clips WHERE isDeleted = 0 AND excludeFromSync = 0 AND ckLastSyncedAt IS NOT NULL"
                ) ?? 0
            }
        } catch { /* fail-silent */ }
        return s
    }
}

// MARK: - Licenses sheet

/// 사용 중인 오픈소스 라이브러리 + 간단한 라이선스 정보. Mac 의 LicensesSheet
/// 과 같은 패턴이지만 iOS Form 스타일로.
private struct LicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Library: Identifiable {
        let id: String
        let name: String
        let url: String
        let license: String
        init(_ name: String, url: String, license: String) {
            self.id = name; self.name = name; self.url = url; self.license = license
        }
    }

    private let libs: [Library] = [
        Library("GRDB.swift", url: "https://github.com/groue/GRDB.swift", license: "MIT"),
        Library("xxHash-Swift", url: "https://github.com/daisuke-t-jp/xxHash-Swift", license: "MIT"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("ClipRaven은 다음 오픈소스 라이브러리를 사용합니다:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(libs) { lib in
                        Link(destination: URL(string: lib.url)!) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lib.name).font(.body)
                                    Text(lib.license)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("오픈소스 라이선스")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
