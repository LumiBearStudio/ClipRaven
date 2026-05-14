import AppKit
import SwiftUI
import ClipRavenSync

/// Settings 윈도우의 라우터 + 컨테이너 + 사이드바 정의.
///
/// 9개 탭의 본문은 `Tabs/` 폴더의 개별 파일로 분리되어 있다.
/// 공통 헬퍼 (darkFormStyle, SectionHeader, appleIntelligenceStatusText) 는
/// `Helpers/SettingsCommon.swift` 에 있다.

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

// MARK: - NSApp Relaunch Helper

extension NSApplication {
    /// 앱을 재실행한다. 언어 변경 적용 등에 사용.
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

