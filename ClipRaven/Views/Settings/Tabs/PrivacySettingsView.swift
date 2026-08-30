import AppKit
import SwiftUI

/// 개인정보 설정 탭 — invisible char strip, 2FA 필터, 앱별 제외 목록.
struct PrivacySettingsView: View {
    @AppStorage("blockSensitive")       private var blockSensitive = true
    @AppStorage("filter2FA")            private var filter2FA = true
    @AppStorage("stripInvisibleChars")  private var stripInvisibleChars = true
    @AppStorage("stripURLTracking")     private var stripURLTracking = true
    @AppStorage("hideOnScreenSharing")  private var hideOnScreenSharing = true
    /// 기본 OFF — 켜면 복사한 URL 로 앱이 직접 HTTP 요청을 보낸다 (감사 P3-b).
    @AppStorage("linkPreviewEnabled")   private var linkPreviewEnabled = false
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

                    Toggle("링크 미리보기 가져오기", isOn: $linkPreviewEnabled)
                    Text("URL 클립의 제목과 이미지를 해당 사이트에서 직접 가져옵니다. 켜면 복사한 주소로 앱이 접속하므로, 비밀번호 재설정 링크처럼 한 번만 쓸 수 있는 주소가 소진될 수 있습니다. 기본값은 꺼짐입니다.")
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
