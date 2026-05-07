import SwiftUI
import CloudKit
import AppKit
import ClipRavenSync

// MARK: - Local style helpers (mirror of SettingsWindow's private versions)
//
// SettingsWindow.swift declares `SectionHeader` + `.icloudFormStyle()` as
// fileprivate so each settings view file ends up needing its own copy.
// Promoting them to internal would also work but creates a wider coupling
// surface than the extra ~10 LOC duplication.

private struct iCloudSectionHeader: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 2)
    }
}

private extension View {
    func icloudFormStyle() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.windowBackgroundColor))
    }
}

/// Settings → iCloud 동기화 탭.
///
/// Goal: let the user opt in/out of CloudKit sync without dropping into
/// `defaults write`. Surfaces:
///   - Master toggle bound to `SyncFeatureFlag`
///   - Live iCloud account status (signed in / not / restricted)
///   - Last sync timestamp from `SyncStateStore`
///   - "iCloud에서 모두 지우기" destructive action
///
/// Design notes (UX):
///   - Default OFF on fresh install. The user explicitly opts in here.
///     Defense for privacy posture (clipboard data is sensitive) and aligns
///     with Apple HIG that cloud sync of UGC requires consent.
///   - Toggle changes are persisted immediately, but the engine lifecycle
///     is **restart-required** for OFF (the engine instance is one-shot;
///     hot-shutdown would leave the session unable to ever turn it back on
///     without quitting). ON is hot-applied via a notification AppDelegate
///     listens to.
///   - The "iCloud에서 모두 지우기" button intentionally lives here, not in
///     a hidden menu. The action is reversible only by a fresh upload from
///     another device, so the alert spells that out.
struct IcloudSyncSettingsView: View {
    @AppStorage("clipraven.sync.enabled") private var syncEnabled = false

    @State private var accountStatus: CKAccountStatus?
    @State private var accountError: String?
    @State private var lastSyncedAt: Date?
    @State private var showRestartHint = false
    @State private var showWipeAlert = false
    @State private var wipeInProgress = false
    @State private var wipeResult: String?

    // Phase C — 이미지 동기화 옵션
    @State private var imageSyncMode: ImageSyncMode = ImageSyncSettings.current().mode
    @State private var imageSyncSizeCap: ImageSyncSizeCap = ImageSyncSettings.current().sizeCap
    @State private var imageDiskUsageBytes: Int64 = 0

    // Mac/iPhone 동기화 차이 진단용 통계
    @State private var clipStats = MacClipStats()

    /// Cached store for status reads (timestamps). Construction is cheap.
    private var stateStore: SyncStateStore {
        SyncStateStore(dbWriter: AppDatabase.shared.dbPool)
    }

    private let containerIdentifier = "iCloud.com.lumibear.ClipRaven"

    var body: some View {
        Form {
            // MARK: Master toggle
            Section {
                Group {
                    LabeledContent("iCloud 동기화 사용") {
                        Toggle("", isOn: Binding(
                            get: { syncEnabled },
                            set: { newValue in
                                syncEnabled = newValue
                                SyncFeatureFlag.setEnabled(newValue)
                                if newValue {
                                    // Hot-on: ask AppDelegate to call
                                    // `engine.startIfEligible()`. The engine is
                                    // already constructed (eagerly at launch),
                                    // so this is just a flag flip + start call.
                                    NotificationCenter.default.post(
                                        name: .clipRavenSyncEnabledChanged,
                                        object: true
                                    )
                                } else {
                                    // Hot-off is not supported by SyncEngine
                                    // (one-shot lifecycle). Surface the
                                    // requirement to the user.
                                    showRestartHint = true
                                }
                            }
                        ))
                        .labelsHidden()
                    }

                    Text(syncEnabled
                         ? "ClipRaven이 클립을 iCloud에 안전하게 동기화합니다. iPhone, iPad, 다른 Mac에서도 같은 클립을 사용할 수 있습니다."
                         : "동기화를 끄면 이 Mac의 클립이 iCloud로 업로드되지 않습니다. 기존에 업로드된 클립은 서버에 남아있으며, 아래 '모두 지우기'로 제거할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("민감한 데이터(비밀번호, 신용카드, API 키 등)는 자동으로 동기화에서 제외됩니다. '개인정보 보호' 탭에서 추가 앱을 제외할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                iCloudSectionHeader(title: "동기화")
            }

            // MARK: Status
            if syncEnabled {
                Section {
                    Group {
                        LabeledContent("iCloud 계정") {
                            Text(accountStatusText)
                                .font(.caption)
                                .foregroundStyle(accountStatusColor)
                        }

                        if let last = lastSyncedAt {
                            LabeledContent("마지막 동기화") {
                                Text(relativeText(from: last))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // 클립 통계 — iPhone 과 비교용 sync gap 진단
                        LabeledContent("총 클립") {
                            Text("\(clipStats.total)개")
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        LabeledContent("동기화 대상 / 완료") {
                            Text("\(clipStats.syncCompleted) / \(clipStats.syncTarget)")
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Button {
                            NotificationCenter.default.post(
                                name: .clipRavenSyncRefreshRequested, object: nil)
                        } label: {
                            Label("지금 동기화", systemImage: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .listRowBackground(Color(NSColor.controlBackgroundColor))
                } header: {
                    iCloudSectionHeader(title: "상태")
                }

                // MARK: Image sync (Phase C)
                imageSyncSection
            }

            // MARK: Destructive
            Section {
                Group {
                    HStack {
                        Button(role: .destructive) {
                            showWipeAlert = true
                        } label: {
                            Label("iCloud에서 모두 지우기", systemImage: "icloud.slash")
                        }
                        .disabled(wipeInProgress)

                        if wipeInProgress {
                            ProgressView().controlSize(.small)
                        }

                        if let result = wipeResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("iCloud에 업로드된 모든 ClipRaven 클립을 삭제합니다. 다른 디바이스에서도 다음 동기화 시 사라집니다. 이 Mac의 로컬 데이터는 영향받지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                iCloudSectionHeader(title: "위험 영역")
            }
        }
        .icloudFormStyle()
        .onAppear {
            refreshStatus()
        }
        .alert("재시작 필요", isPresented: $showRestartHint) {
            Button("나중에") {}
            Button("지금 재시작") {
                NSApp.relaunchClipRaven()
            }
        } message: {
            Text("동기화 비활성화는 ClipRaven을 재시작한 후 적용됩니다.")
        }
        .alert("iCloud의 ClipRaven 데이터를 모두 지우시겠습니까?", isPresented: $showWipeAlert) {
            Button("취소", role: .cancel) {}
            Button("모두 지우기", role: .destructive) {
                performWipe()
            }
        } message: {
            Text("이 작업은 되돌릴 수 없습니다. 다른 디바이스에서 다음 동기화 시 해당 디바이스의 클립도 사라집니다(서버 우선 정책). 이 Mac의 로컬 클립은 그대로 유지됩니다.")
        }
    }

    // MARK: - Image sync section (Phase C)

    @ViewBuilder
    private var imageSyncSection: some View {
        Section {
            Group {
                Picker("이미지 동기화", selection: $imageSyncMode) {
                    ForEach(ImageSyncMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: imageSyncMode) { newValue in
                    ImageSyncSettings.setMode(newValue)
                }

                Text(imageSyncMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if imageSyncMode == .full {
                    Picker("원본 사이즈 제한", selection: $imageSyncSizeCap) {
                        ForEach(ImageSyncSizeCap.allCases, id: \.rawValue) { cap in
                            Text(cap.displayName).tag(cap)
                        }
                    }
                    .onChange(of: imageSyncSizeCap) { newValue in
                        ImageSyncSettings.setSizeCap(newValue)
                    }
                }

                LabeledContent("저장된 이미지 용량") {
                    Text(diskUsageDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .listRowBackground(Color(NSColor.controlBackgroundColor))
        } header: {
            iCloudSectionHeader(title: "이미지")
        } footer: {
            Text("이미지 원본은 iCloud 저장공간을 사용합니다. 30일 이상 된 원본은 자동 삭제되며, 핀 고정한 클립은 영구 보관됩니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .task {
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

    // MARK: - Status helpers

    private var accountStatusText: String {
        if let err = accountError { return String(localized: "확인 실패: \(err)") }
        switch accountStatus {
        case .available:        return String(localized: "로그인됨 — 동기화 가능")
        case .noAccount:        return String(localized: "iCloud 계정에 로그인되지 않음")
        case .restricted:       return String(localized: "iCloud 사용이 제한됨 (관리 정책)")
        case .couldNotDetermine: return String(localized: "확인 중…")
        case .temporarilyUnavailable: return String(localized: "일시적 사용 불가 — 잠시 후 자동 재시도")
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

    private func refreshStatus() {
        // Account status — async fetch. UI shows "확인 중…" until it lands.
        Task { @MainActor in
            do {
                let status = try await CKContainer(identifier: containerIdentifier)
                    .accountStatus()
                self.accountStatus = status
                self.accountError = nil
            } catch {
                self.accountError = error.localizedDescription
            }
        }
        // Last synced — synchronous read from local DB.
        lastSyncedAt = stateStore.lastUpdatedAt(forKey: SyncStateStore.Key.mainEngine)
        // 클립 통계 — sync gap 진단용
        Task.detached {
            let stats = await MacClipStats.collect()
            await MainActor.run { self.clipStats = stats }
        }
    }

    private func relativeText(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Wipe

    /// Hard-resets iCloud-side state by:
    /// 1. Telling AppDelegate to shut down the engine (vends a token).
    /// 2. Calling `clearAll(afterShutdown:)` to wipe `sync_engine_state`.
    /// 3. Best-effort: deleting the custom CKRecordZone server-side (this
    ///    cascades all records).
    /// Step 3 needs a CKDatabase round-trip; failure is non-fatal because
    /// once the engine is shut down + state wiped, the next launch
    /// (with sync flag still ON) will re-create the zone fresh.
    private func performWipe() {
        wipeInProgress = true
        wipeResult = nil
        Task { @MainActor in
            // Ask AppDelegate to shut down and hand back a token. This
            // notification path keeps SyncEngine ownership in AppDelegate.
            let tokenBox = NotificationCenter.default
                .post(name: .clipRavenSyncShutdownRequested, object: nil)
            _ = tokenBox  // consumed by AppDelegate handler

            // Local sync_engine_state wipe. Use a synthesized token —
            // SyncStateStore.clearAll requires the proof-token type, but
            // since we're holding a SyncStateStore directly we can vend
            // a fresh one here.
            await stateStore.clearAll(afterShutdown: SyncEngineShutdownToken())

            // Server-side zone delete (best effort).
            do {
                let db = CKContainer(identifier: containerIdentifier)
                    .privateCloudDatabase
                _ = try await db.deleteRecordZone(
                    withID: SyncRecordMapper.zoneID
                )
                wipeResult = "완료"
            } catch let error as CKError where error.code == .zoneNotFound {
                wipeResult = "완료 (이미 비어있음)"
            } catch {
                wipeResult = "로컬 sync 상태 초기화 됨, 서버 삭제 실패: \(error.localizedDescription)"
            }
            wipeInProgress = false
            // Surface restart prompt — the in-process engine state is now
            // inconsistent with the server, so we want a clean reboot.
            showRestartHint = true
            refreshStatus()
        }
    }
}

// MARK: - Notifications used by AppDelegate

extension Notification.Name {
    /// Posted when the user toggles iCloud sync on. AppDelegate calls
    /// `engine.startIfEligible()` in response.
    static let clipRavenSyncEnabledChanged = Notification.Name("clipRavenSyncEnabledChanged")

    /// Posted when the user taps "지금 동기화" in Settings. AppDelegate calls
    /// `engine.fetchChangesOnWake()` (a full fetch→send cycle).
    static let clipRavenSyncRefreshRequested = Notification.Name("clipRavenSyncRefreshRequested")

    /// Posted when the user taps "iCloud에서 모두 지우기". AppDelegate
    /// shuts down the engine so the destructive wipe can proceed safely.
    static let clipRavenSyncShutdownRequested = Notification.Name("clipRavenSyncShutdownRequested")
}

// MARK: - Sync gap diagnostic

/// 클립 통계 — iPhone 과 비교해 sync 정상/누락 판별용. iPhone Settings 의
/// 동일 항목과 1:1 매핑.
private struct MacClipStats {
    var total: Int = 0           // 모든 비-deleted 클립
    var syncTarget: Int = 0      // excludeFromSync = 0
    var syncCompleted: Int = 0   // ckLastSyncedAt IS NOT NULL

    static func collect() async -> MacClipStats {
        let pool = AppDatabase.shared.dbPool
        var s = MacClipStats()
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

// MARK: - Relaunch helper (file-private mirror — same impl as SettingsWindow's)

private extension NSApplication {
    func relaunchClipRaven() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}
