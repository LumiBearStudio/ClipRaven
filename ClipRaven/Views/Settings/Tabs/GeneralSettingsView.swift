import AppKit
import ServiceManagement
import SwiftUI

/// 일반 설정 탭 — 시작/Dock, 언어, 사운드/햅틱.
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
                            Text("日本語").tag("ja")
                            Text("简体中文").tag("zh-Hans")
                            Text("繁體中文").tag("zh-Hant")
                            Text("Deutsch").tag("de")
                            Text("Français").tag("fr")
                            Text("Español").tag("es")
                            Text("Italiano").tag("it")
                            Text("Português (Brasil)").tag("pt-BR")
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
