import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import ClipRavenSync
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Intelligence status helper

private func appleIntelligenceStatusText() -> String {
    #if canImport(FoundationModels)
    if #available(macOS 26, *) {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return "사용 가능"
        case .unavailable(let reason):
            return "사용 불가: \(String(describing: reason))"
        @unknown default:
            return "알 수 없음"
        }
    }
    return "macOS 26 이상 필요"
    #else
    return "FoundationModels 프레임워크 미포함 (Xcode 26+ SDK 필요)"
    #endif
}

// MARK: - Dark Form Style Helper

private extension View {
    func darkFormStyle() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Settings Section

enum SettingsSection: String, CaseIterable, Identifiable {
    // Primary (top group in sidebar)
    case general       = "general"
    case capture       = "capture"
    case shortcuts     = "shortcuts"
    case appearance    = "appearance"
    case privacy       = "privacy"
    case iCloud        = "iCloud"
    case aiAutomation  = "aiAutomation"
    // Meta (bottom group, visually separated)
    case backup        = "backup"
    case about         = "about"

    var id: String { rawValue }

    /// The primary group in the sidebar (top). The remaining cases render
    /// under the "meta" group below a visual divider.
    static let primaryCases: [SettingsSection] = [
        .general, .capture, .shortcuts, .appearance, .privacy, .iCloud, .aiAutomation,
    ]
    static let metaCases: [SettingsSection] = [.backup, .about]

    var title: LocalizedStringKey {
        switch self {
        case .general:       return "section.general"
        case .capture:       return "section.capture"
        case .shortcuts:     return "section.shortcuts"
        case .appearance:    return "section.appearance"
        case .privacy:       return "section.privacy"
        case .iCloud:        return "iCloud 동기화"
        case .aiAutomation:  return "section.aiAutomation"
        case .backup:        return "section.backup"
        case .about:         return "section.about"
        }
    }

    var icon: String {
        switch self {
        case .general:       return "gear"
        case .capture:       return "tray.and.arrow.down"
        case .shortcuts:     return "keyboard"
        case .appearance:    return "paintbrush"
        case .privacy:       return "hand.raised.fill"
        case .iCloud:        return "icloud.fill"
        case .aiAutomation:  return "wand.and.stars"
        case .backup:        return "externaldrive"
        case .about:         return "info.circle"
        }
    }
}

// MARK: - Settings Router (singleton, bypasses SwiftUI state restoration)

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var section: SettingsSection? = .general
    private init() {}
}

// MARK: - Root Settings View

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $router.section) {
                Section {
                    ForEach(SettingsSection.primaryCases) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
                Section {
                    ForEach(SettingsSection.metaCases) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 210)
        } detail: {
            Group {
                switch router.section ?? .general {
                case .general:       GeneralSettingsView()
                case .capture:       CaptureSettingsView()
                case .shortcuts:     ShortcutsSettingsView()
                case .appearance:    AppearanceSettingsView()
                case .privacy:       PrivacySettingsView()
                case .iCloud:        IcloudSyncSettingsView()
                case .aiAutomation:  AIAutomationSettingsView()
                case .backup:        BackupSettingsView()
                case .about:         AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 680, height: 480)
        .tint(themeManager.colorPreset.accentColor)
        .onAppear {
            let target = SettingsRouter.shared.section
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                SettingsRouter.shared.section = target
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipRavenOpenAboutSection)) { _ in
            router.section = .about
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: LocalizedStringKey   // must be LocalizedStringKey, not String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 2)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin")     private var launchAtLogin = false
    @AppStorage("showInDock")        private var showInDock = false
    @AppStorage("language")          private var language = "system"
    @AppStorage("soundOnCapture")    private var soundOnCapture = false
    @AppStorage("soundOnPaste")      private var soundOnPaste = false
    @AppStorage("hapticOnCapture")   private var hapticOnCapture = false
    @AppStorage("hapticOnPaste")     private var hapticOnPaste = false

    @State private var showRestartAlert = false

    var body: some View {
        Form {
            Section {
                Group {
                    LabeledContent("로그인 시 자동 실행") {
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin },
                            set: { setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                    }

                    LabeledContent("Dock에 아이콘 표시") {
                        Toggle("", isOn: Binding(
                            get: { showInDock },
                            set: {
                                showInDock = $0
                                NSApp.setActivationPolicy($0 ? .regular : .accessory)
                            }
                        ))
                        .labelsHidden()
                    }
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.system")
            }

            Section {
                Group {
                    LabeledContent("언어") {
                        Picker("", selection: Binding(
                            get: { language },
                            set: { applyLanguage($0) }
                        )) {
                            Text("시스템 기본값").tag("system")
                            Text("한국어").tag("ko")
                            Text("English").tag("en")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    Text("언어 변경은 앱 재시작 후 적용됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.language")
            }

            Section {
                Group {
                    Toggle("복사 시 사운드", isOn: $soundOnCapture)
                    Toggle("붙여넣기 시 사운드", isOn: $soundOnPaste)
                    Divider()
                    Toggle("복사 시 햅틱", isOn: $hapticOnCapture)
                    Toggle("붙여넣기 시 햅틱", isOn: $hapticOnPaste)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.soundHaptic")
            }
        }
        .darkFormStyle()
        .alert("재시작 필요", isPresented: $showRestartAlert) {
            Button("나중에") {}
            Button("지금 재시작") {
                NSApp.relaunch()
            }
        } message: {
            Text("언어 설정을 적용하려면 ClipRaven을 재시작해야 합니다.")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLogin = enabled
            } catch {
                ClipRavenLog.app.error("LaunchAtLogin: \(String(describing: error), privacy: .public)")
                // Still update the stored value even if SMAppService fails
                launchAtLogin = enabled
            }
        } else {
            launchAtLogin = enabled
        }
    }

    private func applyLanguage(_ lang: String) {
        language = lang
        if lang == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
        showRestartAlert = true
    }
}

// MARK: - Shortcuts

// MARK: - Capture

/// "Capture" tab — everything that controls *what and how* clips enter the
/// database. Combines what used to live in two places:
/// - old General tab's "선택 캡처 모드" (double-copy detection)
/// - old History tab's storage cap / retention / manual cleanup
///
/// Rationale: users asking "왜 이 클립이 안 저장됐지?" or "저장 기한을 늘리려면?"
/// should find everything on one page rather than hopping tabs.
struct CaptureSettingsView: View {
    @AppStorage("selectiveMode")      private var selectiveMode = false
    @AppStorage("doubleCopyWindowMs") private var doubleCopyWindowMs = 500
    @AppStorage("maxClipCount")       private var maxClipCount = 5000
    @AppStorage("maxDaysToKeep")      private var maxDaysToKeep = 90
    @State private var isRunningCleanup = false
    @State private var cleanupDone = false

    var body: some View {
        Form {
            // Capture mode — select-all vs. double-copy
            Section {
                Group {
                    LabeledContent("선택 캡처 모드") {
                        Toggle("", isOn: Binding(
                            get: { selectiveMode },
                            set: {
                                selectiveMode = $0
                                NotificationCenter.default.post(
                                    name: .clipRavenSelectiveModeChanged, object: nil)
                            }
                        ))
                        .labelsHidden()
                    }

                    if selectiveMode {
                        LabeledContent("더블 복사 감지 시간") {
                            HStack(spacing: 8) {
                                Slider(
                                    value: Binding(
                                        get: { Double(doubleCopyWindowMs) },
                                        set: { doubleCopyWindowMs = Int($0) }
                                    ),
                                    in: 300...1000,
                                    step: 50
                                )
                                .frame(width: 140)
                                Text("\(doubleCopyWindowMs)ms")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("• 텍스트/파일: ⌘C를 \(doubleCopyWindowMs)ms 이내에 두 번 눌러 저장")
                            Text("• 이미지: 복사 시 우측 상단에 팝업 — 클릭하면 저장")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    }
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.captureMode")
            }

            Section {
                Group {
                    LabeledContent("최대 저장 개수") {
                        HStack {
                            TextField("", value: $maxClipCount, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Stepper("", value: $maxClipCount, in: 100...50000, step: 500)
                                .labelsHidden()
                        }
                    }
                    Text("100 ~ 50,000개까지 설정 가능합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.storageLimit")
            }

            Section {
                Group {
                    LabeledContent("보관 기간") {
                        HStack {
                            TextField("", value: $maxDaysToKeep, formatter: NumberFormatter())
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                            Text("일")
                            Stepper("", value: $maxDaysToKeep, in: 1...365, step: 7)
                                .labelsHidden()
                        }
                    }
                    Text("지정된 일수가 지난 클립은 자동으로 삭제됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.autoCleanup")
            }

            Section {
                Group {
                    HStack {
                        Button {
                            guard !isRunningCleanup else { return }
                            isRunningCleanup = true
                            cleanupDone = false
                            Task {
                                await CleanupService().runCleanup()
                                await MainActor.run {
                                    isRunningCleanup = false
                                    cleanupDone = true
                                }
                            }
                        } label: {
                            if isRunningCleanup {
                                Label("정리 중...", systemImage: "arrow.clockwise")
                            } else {
                                Label("지금 정리하기", systemImage: "trash.slash")
                            }
                        }
                        .disabled(isRunningCleanup)

                        if cleanupDone {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("완료")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.manualCleanup")
            }
        }
        .darkFormStyle()
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var displayString = HotKeyStore.shared.displayString
    @State private var isRecording = false
    @State private var pendingKeyCode: UInt32?
    @State private var pendingModifiers: UInt32?

    var body: some View {
        Form {
            Section {
                Group {
                    LabeledContent("글로벌 단축키") {
                        HStack(spacing: 10) {
                            KeyRecorderView(
                                isRecording: $isRecording,
                                displayString: displayString,
                                onRecorded: { keyCode, modifiers in
                                    pendingKeyCode = keyCode
                                    pendingModifiers = modifiers
                                    displayString = HotKeyFormatter.format(keyCode: keyCode, modifiers: modifiers)
                                },
                                onCancel: {
                                    isRecording = false
                                    displayString = HotKeyStore.shared.displayString
                                }
                            )
                            .frame(width: 110, height: 28)

                            if !isRecording {
                                Button("변경") {
                                    isRecording = true
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(themeManager.colorPreset.accentColor)
                            } else {
                                Button("취소") {
                                    isRecording = false
                                    displayString = HotKeyStore.shared.displayString
                                    pendingKeyCode = nil
                                    pendingModifiers = nil
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            }

                            if let kc = pendingKeyCode, let mods = pendingModifiers {
                                Button("저장") {
                                    HotKeyStore.shared.update(keyCode: kc, modifiers: mods)
                                    pendingKeyCode = nil
                                    pendingModifiers = nil
                                    displayString = HotKeyStore.shared.displayString
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }

                    Text("이 단축키로 ClipRaven 패널을 열고 닫습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isRecording {
                        Text("키 조합을 입력하세요. ESC로 취소합니다.")
                            .font(.caption)
                            .foregroundStyle(themeManager.colorPreset.accentColor)
                    }
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.clipboardPanel")
            }
        }
        .darkFormStyle()
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage(AppAnimations.key) private var animationsEnabled = true

    var body: some View {
        Form {
            Section {
                Picker("테마", selection: $themeManager.themePreference) {
                    Label("시스템 기본값", systemImage: "circle.lefthalf.filled").tag("system")
                    Label("다크",         systemImage: "moon.fill").tag("dark")
                    Label("라이트",       systemImage: "sun.max.fill").tag("light")
                }
                .pickerStyle(.radioGroup)
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.colorTheme")
            }

            Section {
                ColorPresetGridView(selected: themeManager.colorPresetRaw) { preset in
                    themeManager.colorPresetRaw = preset.rawValue
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                SectionHeader(title: "header.accentColor")
            }

            Section {
                Toggle("애니메이션", isOn: $animationsEnabled)
                    .listRowBackground(Color(NSColor.controlBackgroundColor))
                Text("끄면 화면 전환과 카드 펼침이 즉시 표시됩니다. 시스템의 '동작 줄이기' 설정과 별개입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.motion")
            }
        }
        .darkFormStyle()
        .tint(themeManager.colorPreset.accentColor)
    }
}

// MARK: - Color Preset Grid

private struct ColorPresetGridView: View {
    let selected: String
    let onSelect: (ColorPreset) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ColorPreset.allCases) { preset in
                ColorSwatchCell(
                    preset: preset,
                    isSelected: preset.rawValue == selected,
                    onTap: { onSelect(preset) }
                )
            }
        }
    }
}

private struct ColorSwatchCell: View {
    let preset: ColorPreset
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(preset.swatchColor)
                        .frame(width: 32, height: 32)
                    if isSelected {
                        Circle()
                            .strokeBorder(Color(NSColor.labelColor), lineWidth: 2.5)
                            .frame(width: 36, height: 36)
                    }
                }
                Text(preset.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color(NSColor.labelColor) : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @AppStorage("blockSensitive")       private var blockSensitive = true
    @AppStorage("filter2FA")            private var filter2FA = true
    @AppStorage("stripInvisibleChars")  private var stripInvisibleChars = true
    @AppStorage("stripURLTracking")     private var stripURLTracking = true
    @AppStorage("hideOnScreenSharing")  private var hideOnScreenSharing = true
    @AppStorage("excludedApps")         private var excludedAppsRaw = ""

    @State private var excludedList: [String] = []
    @State private var newBundleID = ""
    @State private var showAppPicker = false

    var body: some View {
        Form {
            Section {
                Group {
                    Toggle("민감한 데이터 자동 차단", isOn: $blockSensitive)
                    Text("비밀번호, 신용카드 번호 등 민감한 정보 패턴이 감지되면 클립보드 저장을 건너뜁니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("2단계 인증 코드 자동 필터", isOn: $filter2FA)
                        .disabled(!blockSensitive)
                    Text("메일/메신저 앱에서 복사한 4~8자리 인증 코드를 저장하지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("보이지 않는 제어 문자 자동 제거", isOn: $stripInvisibleChars)
                    Text("BOM, 제로-너비 공백 등 눈에 보이지 않는 문자를 저장 시 자동으로 정리합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("URL 트래킹 파라미터 자동 제거", isOn: $stripURLTracking)
                    Text("붙여넣기 시 utm_source, fbclid 등 추적용 파라미터를 URL에서 제거합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("화면 공유 시 패널 숨기기", isOn: $hideOnScreenSharing)
                    Text("화면 공유 또는 녹화 중에 패널이 표시되지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.security")
            }

            Section {
                Group {
                    if excludedList.isEmpty {
                        Text("제외된 앱 없음")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(excludedList, id: \.self) { bundleId in
                            ExcludedAppRow(bundleId: bundleId) {
                                removeApp(bundleId)
                            }
                        }
                    }

                    HStack {
                        TextField("번들 ID 직접 입력 (예: com.apple.Safari)", text: $newBundleID)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addApp(newBundleID) }

                        Button {
                            addApp(newBundleID)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            showAppPicker = true
                        } label: {
                            Image(systemName: "macwindow.on.rectangle")
                        }
                        .help("실행 중인 앱에서 선택")
                        .popover(isPresented: $showAppPicker, arrowEdge: .bottom) {
                            RunningAppPickerView { bundleId in
                                addApp(bundleId)
                                showAppPicker = false
                            }
                        }
                    }
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                SectionHeader(title: "header.excludedApps")
            } footer: {
                Text("제외된 앱에서 복사한 내용은 ClipRaven에 저장되지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .darkFormStyle()
        .onAppear {
            excludedList = parseExcludedApps(excludedAppsRaw)
        }
        .onChange(of: excludedAppsRaw) { raw in
            excludedList = parseExcludedApps(raw)
        }
    }

    private func parseExcludedApps(_ raw: String) -> [String] {
        raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func addApp(_ bundleId: String) {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !excludedList.contains(trimmed) else {
            newBundleID = ""
            return
        }
        excludedList.append(trimmed)
        saveList()
        newBundleID = ""
    }

    private func removeApp(_ bundleId: String) {
        excludedList.removeAll { $0 == bundleId }
        saveList()
    }

    private func saveList() {
        excludedAppsRaw = excludedList.joined(separator: "\n")
    }
}

// MARK: - Excluded App Row

private struct ExcludedAppRow: View {
    let bundleId: String
    let onDelete: () -> Void

    var appInfo: (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return (bundleId, nil)
        }
        let bundle = Bundle(url: url)
        let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleName"] as? String
            ?? bundleId
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return (name, icon)
    }

    var body: some View {
        let info = appInfo
        HStack(spacing: 8) {
            if let icon = info.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(info.name)
                    .font(.system(size: 13))
                Text(bundleId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Running App Picker

private struct RunningAppPickerView: View {
    let onSelect: (String) -> Void

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter {
                $0.bundleIdentifier != nil
                && $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("실행 중인 앱 선택")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button {
                            if let id = app.bundleIdentifier {
                                onSelect(id)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.localizedName ?? "Unknown")
                                        .font(.system(size: 12))
                                    Text(app.bundleIdentifier ?? "")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.clear)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .frame(width: 280, height: 300)
    }
}

// MARK: - AI & Automation

/// "AI & 자동화" tab — groups the two "app-does-it-for-you" flavours:
/// Apple Intelligence (category/summary on macOS 26+) and custom Smart Rules
/// (regex → auto-tag). A segmented control at the top switches between them
/// — nested sub-navigation is common in System Settings (e.g. Accessibility
/// → Display), and keeps both features discoverable from one sidebar entry.
struct AIAutomationSettingsView: View {
    private enum SubTab: String, CaseIterable, Identifiable {
        case ai, rules
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .ai:    return "subtab.appleIntelligence"
            case .rules: return "subtab.autoRules"
            }
        }
    }

    @State private var subTab: SubTab = .ai

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $subTab) {
                ForEach(SubTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch subTab {
            case .ai:    AppleIntelligenceView()
            case .rules: SmartRulesSettingsView()
            }
        }
    }
}

/// Apple Intelligence controls — extracted from the old General tab into its
/// own view so `AIAutomationSettingsView` can swap it in on sub-tab selection.
struct AppleIntelligenceView: View {
    @AppStorage("aiCategorizationEnabled") private var aiCategorizationEnabled = true
    @AppStorage("aiSummaryEnabled")        private var aiSummaryEnabled = true

    @State private var batchInProgress = false
    @State private var batchProgress = ""
    @State private var batchResult: String? = nil
    @State private var showForceReclassifyAlert = false

    var body: some View {
        Form {
            if #available(macOS 26, *) {
                Section {
                    Group {
                        LabeledContent("상태") {
                            Text(appleIntelligenceStatusText())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Text("시스템 설정 → Apple Intelligence & Siri에서 활성화하고, 모델 다운로드가 완료되어야 분류가 작동합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("AI 자동 분류") {
                            Toggle("", isOn: $aiCategorizationEnabled)
                                .labelsHidden()
                        }

                        if aiCategorizationEnabled {
                            Text("클립 저장 시 Apple 온디바이스 AI가 자동으로 카테고리를 분류합니다 (영수증, 이메일, 코드 등).")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            LabeledContent("기존 클립 일괄 분류") {
                                HStack(spacing: 8) {
                                    if batchInProgress {
                                        Text(batchProgress)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ProgressView().controlSize(.small)
                                    } else {
                                        if let result = batchResult {
                                            Text(result)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Button("미분류만") { runBatchReclassify(force: false) }
                                        Button("모두 재분류") { showForceReclassifyAlert = true }
                                    }
                                }
                            }
                        }

                        LabeledContent("AI 요약") {
                            Toggle("", isOn: $aiSummaryEnabled)
                                .labelsHidden()
                        }

                        if aiSummaryEnabled {
                            Text("500자 이상의 텍스트 클립에서 프리뷰 패널의 '요약' 버튼으로 AI 요약을 생성합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color(NSColor.controlBackgroundColor))
                } header: {
                    SectionHeader(title: "Apple Intelligence")
                }
            } else {
                Section {
                    Text("Apple Intelligence는 macOS 26 이상에서 사용할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color(NSColor.controlBackgroundColor))
                } header: {
                    SectionHeader(title: "Apple Intelligence")
                }
            }
        }
        .darkFormStyle()
        .alert("모든 클립을 다시 분류할까요?", isPresented: $showForceReclassifyAlert) {
            Button("취소", role: .cancel) {}
            Button("재분류", role: .destructive) { runBatchReclassify(force: true) }
        } message: {
            Text("기존 AI 카테고리를 모두 초기화하고 새 프롬프트로 다시 분류합니다. 클립 수에 따라 시간이 걸릴 수 있습니다.")
        }
    }

    private func runBatchReclassify(force: Bool) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            batchInProgress = true
            batchResult = nil
            batchProgress = "준비 중…"
            Task.detached(priority: .utility) {
                let progressCB: @Sendable (Int, Int) -> Void = { done, total in
                    Task { @MainActor in
                        batchProgress = "\(done) / \(total)"
                    }
                }
                let count: Int
                if force {
                    count = await AICategoryService.shared.batchReclassifyAll(progress: progressCB)
                } else {
                    count = await AICategoryService.shared.batchReclassifyUnclassified(progress: progressCB)
                }
                await MainActor.run {
                    batchInProgress = false
                    batchResult = "완료: \(count)개 처리"
                }
            }
        }
        #endif
    }
}

// MARK: - Smart Rules

struct SmartRulesSettingsView: View {
    @State private var rules: [SmartRule] = []
    @State private var tags: [Tag] = []
    @State private var showingAddSheet = false

    private let ruleRepo = SmartRuleRepository()
    private let tagRepo  = TagRepository()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("자동 태그 규칙")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("규칙 추가", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if rules.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("등록된 규칙이 없습니다")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("새 클립이 복사되면 조건에 맞는 태그를 자동으로 할당합니다.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules) { rule in
                        SmartRuleRow(
                            rule: rule,
                            tagName: {
                            let tagId = rule.actions.compactMap { if case .assignTag(let id) = $0 { return id } else { return nil } }.first
                            return tags.first(where: { $0.id == tagId })?.name ?? "?"
                        }(),
                            onToggle: { toggleRule(rule) },
                            onDelete: { deleteRule(rule) }
                        )
                        .listRowBackground(Color(NSColor.controlBackgroundColor))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // Semantic window background adapts to dark/light — the
                // previous literal `Color(white: 0.09)` rendered as a
                // near-black panel in light mode and hid the list rows.
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .onAppear { loadData() }
        .sheet(isPresented: $showingAddSheet) {
            AddSmartRuleView(tags: tags) { newRule in
                var rule = newRule
                try? ruleRepo.save(&rule)
                SmartRuleEngine.shared.reloadRules()
                loadData()
            }
        }
    }

    private func loadData() {
        rules = (try? ruleRepo.fetchAll()) ?? []
        tags  = (try? tagRepo.fetchAll()) ?? []
    }

    private func toggleRule(_ rule: SmartRule) {
        guard let id = rule.id else { return }
        try? ruleRepo.toggleEnabled(id: id)
        SmartRuleEngine.shared.reloadRules()
        loadData()
    }

    private func deleteRule(_ rule: SmartRule) {
        guard let id = rule.id else { return }
        try? ruleRepo.delete(id: id)
        SmartRuleEngine.shared.reloadRules()
        loadData()
    }
}

struct SmartRuleRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let rule: SmartRule
    let tagName: String
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: .init(get: { rule.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    Text(rule.condition.displayType)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(themeManager.colorPreset.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(rule.condition.displayValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text(tagName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(themeManager.colorPreset.accentColor)
                }
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

struct AddSmartRuleView: View {
    let tags: [Tag]
    let onSave: (SmartRule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var conditionType = 0
    @State private var conditionValue = ""
    @State private var selectedContentType = "text"
    @State private var selectedTagId: Int64?

    private let conditionTypes = [
        NSLocalizedString("앱 (번들 ID)", comment: "Rule condition: app bundle ID"),
        NSLocalizedString("콘텐츠 유형", comment: "Rule condition: content type"),
        NSLocalizedString("텍스트 포함", comment: "Rule condition: text contains"),
        NSLocalizedString("URL 도메인", comment: "Rule condition: URL domain")
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("규칙 추가")
                .font(.headline)

            Form {
                TextField("규칙 이름", text: $name)

                Picker("조건 유형", selection: $conditionType) {
                    ForEach(0..<conditionTypes.count, id: \.self) { i in
                        Text(conditionTypes[i]).tag(i)
                    }
                }

                if conditionType == 1 {
                    Picker("콘텐츠 유형", selection: $selectedContentType) {
                        ForEach(ContentType.allCases, id: \.rawValue) { ct in
                            Text(ct.displayName).tag(ct.rawValue)
                        }
                    }
                } else {
                    TextField(conditionPlaceholder, text: $conditionValue)
                }

                if tags.isEmpty {
                    Text("태그를 먼저 만들어 주세요")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Picker("태그 할당", selection: $selectedTagId) {
                        Text("선택...").tag(nil as Int64?)
                        ForEach(tags) { tag in
                            Text(tag.name).tag(tag.id as Int64?)
                        }
                    }
                }
            }

            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: {
                    guard let tagId = selectedTagId, !name.isEmpty else { return }
                    let rule = SmartRule(
                        name: name,
                        isEnabled: true,
                        condition: buildCondition(),
                        actions: [.assignTag(tagId: tagId)],
                        createdAt: Date()
                    )
                    onSave(rule)
                    dismiss()
                }) {
                    Text("저장")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || selectedTagId == nil || !isConditionValid)
            }
        }
        .padding()
        .frame(width: 380, height: 300)
    }

    private var conditionPlaceholder: String {
        switch conditionType {
        case 0: return "com.apple.Safari"
        case 2: return NSLocalizedString("검색할 키워드", comment: "Placeholder: keyword to search")
        case 3: return "github.com"
        default: return ""
        }
    }

    private var isConditionValid: Bool {
        conditionType == 1 || !conditionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func buildCondition() -> RuleCondition {
        let value = conditionValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch conditionType {
        case 0: return .sourceApp(bundleId: value)
        case 1: return .contentType(selectedContentType)
        case 2: return .textContains(value)
        case 3: return .urlDomain(value)
        default: return .textContains(value)
        }
    }
}

// MARK: - About

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

                HStack(spacing: 16) {
                    Button("지원 (Issues)") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/LumiBearStudio/ClipRaven/issues")!)
                    }
                    .buttonStyle(.link)

                    Button("개인정보 처리방침") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/LumiBearStudio/ClipRaven/blob/main/PRIVACY.md")!)
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

// MARK: - Key Recorder (NSViewRepresentable)

struct KeyRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var displayString: String
    var onRecorded: (UInt32, UInt32) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyRecorderField {
        let field = KeyRecorderField()
        field.onRecorded = { kc, mods in
            DispatchQueue.main.async { onRecorded(kc, mods) }
        }
        field.onCancel = {
            DispatchQueue.main.async { onCancel() }
        }
        return field
    }

    func updateNSView(_ nsView: KeyRecorderField, context: Context) {
        nsView.displayString = displayString
        if nsView.isRecording != isRecording {
            nsView.isRecording = isRecording
            if isRecording {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

// MARK: - KeyRecorderField (NSView)

final class KeyRecorderField: NSView {
    var isRecording = false  { didSet { needsDisplay = true } }
    var displayString = ""   { didSet { needsDisplay = true } }
    var onRecorded: ((UInt32, UInt32) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 28) }

    // Key codes for pure modifier keys
    private let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),       UInt16(kVK_RightCommand),
        UInt16(kVK_Shift),         UInt16(kVK_RightShift),
        UInt16(kVK_Option),        UInt16(kVK_RightOption),
        UInt16(kVK_Control),       UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock),      UInt16(kVK_Function)
    ]

    override func draw(_ dirtyRect: NSRect) {
        // Background
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            (NSColor.separatorColor).setStroke()
        }
        path.fill()
        path.lineWidth = isRecording ? 1.5 : 1.0
        path.stroke()

        // Label
        let label = isRecording ? "입력 중..." : displayString
        let color: NSColor = isRecording ? .controlAccentColor : .labelColor
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attrStr = NSAttributedString(string: label, attributes: attrs)
        let size = attrStr.size()
        let pt = NSPoint(
            x: max(8, (bounds.width  - size.width)  / 2),
            y: (bounds.height - size.height) / 2
        )
        attrStr.draw(at: pt)
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // ESC cancels
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            onCancel?()
            return
        }

        // Ignore pure modifier keys
        if modifierKeyCodes.contains(event.keyCode) { return }

        let mods = carbonModifiers(from: event.modifierFlags)
        onRecorded?(UInt32(event.keyCode), mods)
        isRecording = false
    }

    override func flagsChanged(with event: NSEvent) {
        // Redraw to show current modifier state while recording
        if isRecording { needsDisplay = true }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            onCancel?()
        }
        return super.resignFirstResponder()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey)     }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey)   }
        if flags.contains(.option)  { mods |= UInt32(optionKey)  }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}

// MARK: - NSApp Relaunch Helper

private extension NSApplication {
    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}

