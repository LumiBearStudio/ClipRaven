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

    // 삭제를 부르는 변경은 확인을 받는다 (v1 리뷰 M7).
    // 이전에는 입력칸이 Stepper 범위와 무관하게 아무 값이나 받았고, 5000 을 500 으로
    // 잘못 치면 다음 정리 때 확인 없이 4500개가 지워졌다. 동기화가 켜져 있으면 그
    // 삭제가 모든 기기로 전파된다.
    /// 마지막으로 확정된 값 — 확인을 취소하면 여기로 되돌린다.
    @State private var confirmedClipCount: Int?
    @State private var confirmedDays: Int?
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion {
        enum Setting { case clipCount, days }
        let setting: Setting
        let affected: Int
    }

    private static let clipCountRange = 100...50_000
    private static let daysRange = 1...365

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
                                await CleanupService.production().runCleanup()
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
        .onAppear {
            // 이전 빌드에서 범위 밖으로 저장된 값을 보정한다.
            maxClipCount = Self.clipCountRange.clamp(maxClipCount)
            maxDaysToKeep = Self.daysRange.clamp(maxDaysToKeep)
            confirmedClipCount = maxClipCount
            confirmedDays = maxDaysToKeep
        }
        .onChange(of: maxClipCount) { reviewClipCount($0) }
        .onChange(of: maxDaysToKeep) { reviewDays($0) }
        .alert(
            pendingDeletion.map { String(localized: "클립 \($0.affected)개가 삭제됩니다") } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { _ in }),
            presenting: pendingDeletion
        ) { change in
            Button("삭제하고 변경", role: .destructive) { confirm(change) }
            Button("취소", role: .cancel) { revert(change) }
        } message: { _ in
            Text("이 설정은 다음 정리 때 적용되며, 삭제된 클립은 되돌릴 수 없습니다. 고정한 클립은 삭제되지 않습니다.")
        }
    }

    // MARK: - 삭제 확인

    private func reviewClipCount(_ value: Int) {
        let clamped = Self.clipCountRange.clamp(value)
        if clamped != value { maxClipCount = clamped; return }   // onChange 가 다시 불린다
        guard let confirmed = confirmedClipCount, clamped != confirmed else { return }
        let affected = (try? ClipRepository().countExceeding(keepCount: clamped)) ?? 0
        if affected > 0 {
            pendingDeletion = PendingDeletion(setting: .clipCount, affected: affected)
        } else {
            confirmedClipCount = clamped
        }
    }

    private func reviewDays(_ value: Int) {
        let clamped = Self.daysRange.clamp(value)
        if clamped != value { maxDaysToKeep = clamped; return }
        guard let confirmed = confirmedDays, clamped != confirmed else { return }
        let affected = (try? ClipRepository().countOlderThan(days: clamped)) ?? 0
        if affected > 0 {
            pendingDeletion = PendingDeletion(setting: .days, affected: affected)
        } else {
            confirmedDays = clamped
        }
    }

    private func confirm(_ change: PendingDeletion) {
        switch change.setting {
        case .clipCount: confirmedClipCount = maxClipCount
        case .days:      confirmedDays = maxDaysToKeep
        }
        pendingDeletion = nil
    }

    private func revert(_ change: PendingDeletion) {
        switch change.setting {
        case .clipCount: if let v = confirmedClipCount { maxClipCount = v }
        case .days:      if let v = confirmedDays { maxDaysToKeep = v }
        }
        pendingDeletion = nil
    }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
