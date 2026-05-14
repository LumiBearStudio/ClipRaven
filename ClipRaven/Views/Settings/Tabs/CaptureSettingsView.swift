import SwiftUI

/// 캡처 설정 탭 — 선택 캡처 모드, 저장 한도, 보관 기간, 수동 정리.
/// 'Capture' tab — everything that controls *what and how* clips enter the database.
/// 'why this clip wasn't saved?' / 'how to keep clips longer?' 같은 질문이 한 곳에서 답된다.
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
