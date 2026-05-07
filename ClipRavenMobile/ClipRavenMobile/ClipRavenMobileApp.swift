import Sentry
import SwiftUI
import GRDB
import os.log
import ClipRavenSync

// MARK: - Cross-file notification names
//
// SettingsView posts these when the user toggles sync; SyncAppDelegate
// listens and starts the engine. Defined here (iOS-side) because iOS
// doesn't include the Mac SettingsWindow file where Mac's equivalents live.

extension Notification.Name {
    /// Posted when the user toggles iCloud sync on. SyncAppDelegate calls
    /// `engine.startIfEligible()` in response.
    static let clipRavenSyncEnabledChanged = Notification.Name("clipRavenSyncEnabledChanged")

    /// Posted when the keyboard extension's search button (deep link
    /// `clipraven://search`) is tapped. `ClipListView` activates its
    /// `.searchable` and focuses the search field in response.
    static let clipRavenOpenSearch = Notification.Name("clipRavenOpenSearch")
}

@main
struct ClipRavenMobileApp: App {

    /// AppDelegate-equivalent for SwiftUI lifecycle. Owns iCloud sync state.
    @UIApplicationDelegateAdaptor(SyncAppDelegate.self) private var syncDelegate

    /// 온보딩 완료 여부. false면 앱 최초 실행으로 간주해 OnboardingView를 fullScreenCover로 표시.
    @AppStorage("onboarding.completed") private var onboardingCompleted = false

    /// SettingsView 의 테마 선택값. "system" | "light" | "dark".
    /// `.preferredColorScheme()` 로 즉시 반영 (재시작 불필요).
    @AppStorage("clipraven.preferredColorScheme") private var preferredColorScheme = "system"

    private var colorSchemeOverride: ColorScheme? {
        switch preferredColorScheme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(colorSchemeOverride)
                .onOpenURL { url in
                    // 키보드 익스텐션이 SwiftUI Link 로 deep link 호출:
                    // `clipraven://search` → 메인 앱 검색 모드 진입
                    // (iOS 18+ 에서 키보드 익스텐션의 직접 앱 실행이 차단됐으나,
                    //  SwiftUI Link 경유는 OS 가 정상 처리.)
                    if url.scheme == "clipraven" && url.host == "search" {
                        NotificationCenter.default.post(name: .clipRavenOpenSearch, object: nil)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Trigger sync + clipboard capture when the app comes
                    // to foreground. Three independent actions:
                    //   - sync: pull latest from CloudKit
                    //   - capture: read UIPasteboard once and save if new
                    //   - drain: 키보드 익스텐션이 백그라운드에서 잡은
                    //     pending clip 들을 main DB 로 이관
                    syncDelegate.triggerSyncFetch(reason: "didBecomeActive")
                    syncDelegate.drainPendingCapturesNow()
                    Task { @MainActor in
                        await syncDelegate.captureService.captureCurrentClipboard()
                    }
                }
                // 첫 실행 시 온보딩 표시. OnboardingView 내부에서
                // @AppStorage("onboarding.completed") = true 설정 시 자동 해제.
                .fullScreenCover(isPresented: Binding(
                    get: { !onboardingCompleted },
                    set: { _ in }   // OnboardingView가 직접 AppStorage를 변경해 dismiss
                )) {
                    OnboardingView()
                }
        }
    }
}

/// iOS sync lifecycle holder — same role Mac's AppDelegate plays.
/// SwiftUI `@UIApplicationDelegateAdaptor` lets us keep the SwiftUI App
/// entry point while still owning the engine + observer in a single place.
final class SyncAppDelegate: NSObject, UIApplicationDelegate {

    /// `SyncEngine` requires iOS 17+. iOS app's deployment target is 17.0
    /// (set in xcodeproj), so this is unconditionally safe — but we use
    /// `Any?` for symmetry with Mac (where the gate matters because Mac
    /// supports macOS 13.0).
    private var syncEngine: SyncEngine?
    private var syncChangeCapture: SyncChangeCapture?
    private var syncStartTask: Task<Void, Never>?

    /// Foreground 클립보드 캡처. Lazy 초기화 — 첫 호출 시 만들면
    /// AppDatabase 마이그레이션이 끝난 다음 시점이 보장됨.
    lazy var captureService: PasteboardCaptureService = PasteboardCaptureService()

    private let log = Logger(subsystem: "com.lumibear.ClipRavenMobile", category: "SyncAppDelegate")
    private let containerIdentifier = "iCloud.com.lumibear.ClipRaven"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Crash reporting — strictly opt-in (toggle in Settings)
        if UserDefaults.standard.bool(forKey: "crashReportsEnabled") {
            SentrySDK.start { options in
                options.dsn = "https://2e87dafa4228a756923fbb0e0d914949@o4510949994266624.ingest.de.sentry.io/4511348636778576"
                options.environment = "production"
                options.sendDefaultPii = false
                options.attachScreenshot = false
                options.attachViewHierarchy = false
                options.maxBreadcrumbs = 200
                // 모든 이벤트(크래시 포함)에 최근 120초 os.log 첨부
                if #available(iOS 15.0, *) {
                    options.beforeSend = { event in
                        if let logs = CRSentry.recentLogLines() {
                            var extra = event.extra ?? [:]
                            extra["recent_oslog"] = logs
                            event.extra = extra
                        }
                        return event
                    }
                }
            }
            CRSentry.breadcrumb("app launched", category: "app")
            SentrySDK.captureMessage("ClipRaven iOS launched", level: .info)
        }

        // Force AppDatabase initialization so migrations run before any
        // code touches Clip (UI loads list immediately on launch).
        _ = AppDatabase.shared

        // Phase C — sync 패키지가 플랫폼별 이미지 영구 저장소를 알아야
        // SyncRecordMapper 가 CKAsset round-trip 시 우리 디렉터리를 사용한다.
        ImageOriginalStoreRegistry.register(IOSImageOriginalStore())

        // 셀룰러 정책 — NWPathMonitor 기반 provider 등록.
        // Mapper.encode 가 매 클립마다 read 하므로 앱 launch 시점에 초기화.
        NetworkStateRegistry.register(NWPathMonitorBasedProvider.shared)

        // Stale staging 파일 정리 (앱 재시작 시 1회). 7일 이상 된 고아 파일.
        AssetStaging.shared.purgeStaleStaging()

        // 이미지 binary TTL cleanup — 30일 이상 된 non-pinned 이미지 원본 삭제.
        // .utility 우선순위로 백그라운드 실행, 메인 launch 차단 안 함.
        Task.detached(priority: .utility) {
            do {
                _ = try await ImageBinaryCleanup.run(dbPool: AppDatabase.shared.dbPool)
            } catch {
                ClipRavenLog.cleanup.error("ImageBinaryCleanup failed: \(String(describing: error), privacy: .public)")
                CRSentry.capture(error, context: "ImageBinaryCleanup on launch")
            }
        }

        // 키보드 익스텐션이 백그라운드 동안 capture 한 pending clips 처리.
        // 메인 앱이 깨어날 때마다 호출 — main DB 로 이관 + sync 자동 trigger.
        Task.detached(priority: .userInitiated) {
            await drainKeyboardCaptures()
        }

        // Background OCR backfill — scan existing image clips without ocrText.
        // Runs at .utility priority and throttles itself (200ms between clips).
        ImageOCRService.backfillMissingOCR(dbPool: AppDatabase.shared.dbPool)

        // Build the sync engine eagerly — same pattern as Mac. The engine
        // self-gates on `SyncFeatureFlag.isEnabled` + iCloud account
        // status, so flag-off is a clean no-op.
        let engine = SyncEngine(
            stateStore: SyncStateStore(dbWriter: AppDatabase.shared.dbPool),
            containerIdentifier: containerIdentifier,
            clipRepository: ClipSyncRepository(dbPool: AppDatabase.shared.dbPool)
        )
        self.syncEngine = engine

        // Hook GRDB transaction observer so any local insert/update flows
        // into the upload queue automatically.
        let capture = SyncChangeCapture { [weak engine] saves, deletes in
            guard SyncFeatureFlag.isEnabled, let engine else { return }
            Task { @MainActor in
                engine.enqueueSaves(uuids: saves)
                for uuid in deletes {
                    engine.enqueueDelete(uuid: uuid)
                }
            }
        }
        AppDatabase.shared.dbPool.add(transactionObserver: capture)
        self.syncChangeCapture = capture

        // Fire-and-forget startup. Engine no-ops if flag is off.
        self.syncStartTask = Task { [weak self] in
            await engine.startIfEligible()
            self?.syncStartTask = nil
        }

        // Register for silent push so CloudKit can wake the app when a
        // peer device commits. iOS background sync is more constrained
        // than macOS — we still register, but the 30-min periodic
        // failsafe inside SyncEngine + foreground-active fetch in this
        // file are the practical wake-up paths.
        application.registerForRemoteNotifications()

        // Settings → toggle on
        NotificationCenter.default.addObserver(
            forName: .clipRavenSyncEnabledChanged,
            object: nil,
            queue: .main
        ) { [weak engine] notification in
            guard let engine,
                  let enabled = notification.object as? Bool, enabled
            else { return }
            Task { @MainActor in
                await engine.startIfEligible()
            }
        }

        // 우리 코드가 직접 UIPasteboard write 후 알림. capture service가
        // 그 변경을 자기 변경으로 인식해 다음 capture를 skip.
        NotificationCenter.default.addObserver(
            forName: .clipRavenIntentionalPasteboardWrite,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.captureService.markIntentionalWrite()
            }
        }

        // 백그라운드 진입 시 WAL checkpoint — 메인 앱이 백그라운드에서
        // suspend 되기 전 -wal 파일을 main DB 로 merge + truncate.
        // 효과: 키보드/위젯 extension 이 다음 read 시 항상 최신 데이터 봄
        // (PERSIST_WAL 와 함께 안전망 역할).
        // .didEnterBackground 시점에 iOS 가 ~5초의 background time 보장.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            // .utility 우선순위 — 짧고 빠른 작업.
            Task.detached(priority: .utility) {
                do {
                    try AppDatabase.shared.dbPool.writeWithoutTransaction { db in
                        // TRUNCATE: WAL 을 main DB 에 merge 후 -wal 길이 0으로.
                        // 다른 reader 가 active 면 partial checkpoint 만 일어나고
                        // 다음 기회에 truncate. 어느 쪽이든 안전.
                        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    }
                } catch {
                    ClipRavenLog.database.error("WAL checkpoint failed: \(String(describing: error), privacy: .public)")
                    CRSentry.capture(error, context: "background WAL checkpoint")
                }
            }
        }

        return true
    }

    /// Sync trigger — called by SwiftUI on foreground activation and by
    /// Settings "지금 동기화" button. `requestSyncCycle` coalesces.
    @MainActor
    func triggerSyncFetch(reason: String) {
        guard let engine = syncEngine else { return }
        log.debug("triggerSyncFetch reason=\(reason, privacy: .public)")
        CRSentry.breadcrumb("syncFetch: \(reason)", category: "sync")
        engine.fetchChangesOnWake()
    }

    /// 키보드 익스텐션이 capture 한 pending clip 들을 main DB 에 이관.
    /// 메인 앱 launch + foreground 진입 시 호출.
    func drainPendingCapturesNow() {
        Task.detached(priority: .userInitiated) {
            await drainKeyboardCaptures()
        }
    }

    // MARK: - Remote notification

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        log.info("registered for remote notifications (\(deviceToken.count) byte token)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        let ns = error as NSError
        log.error("APS register failed — domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription, privacy: .public)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // CloudKit pushes carry a "ck" key — ignore everything else.
        guard userInfo["ck"] != nil else {
            completionHandler(.noData)
            return
        }
        guard let engine = syncEngine else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            engine.fetchChangesOnWake()
            // Best-effort: tell iOS the wake produced new data so future
            // discretionary fetches stay enabled. We don't have a direct
            // signal of "did anything change" in time for this callback,
            // so return .newData optimistically.
            completionHandler(.newData)
        }
    }
}

// MARK: - Keyboard pending capture drainage

/// 키보드 익스텐션이 `KeyboardCaptureBuffer` 에 쌓아둔 클립들을 main DB 에
/// insert. 메인 앱 launch / foreground 진입 시 호출.
///
/// 키보드는 SQLite write 가 위험(0xDEAD10CC)해서 단순 JSON 파일에 임시 저장만 함.
/// 메인 앱이 깨어날 때 여기서 처리 → ClipRepository 정상 path → SyncChangeCapture
/// 가 자동으로 sync queue 에 넣음.
private func drainKeyboardCaptures() async {
    let appGroupID = "group.com.lumibear.ClipRavenMobile"
    let captures = KeyboardCaptureBuffer.drainAll(appGroupIdentifier: appGroupID)
    guard !captures.isEmpty else { return }

    let log = Logger(subsystem: "com.lumibear.ClipRavenMobile", category: "PendingDrain")
    log.info("처리 중 — \(captures.count, privacy: .public)개 pending capture")

    let repository = ClipRepository()
    var insertedText = 0
    var insertedImage = 0

    var skippedDup = 0
    for capture in captures {
        switch capture.contentType {
        case "text", "url", "code":
            guard let text = capture.contentText, !text.isEmpty else { continue }
            // contentHash dedup — 메인 앱이 깨어나면서 capture 도 같이 도는데
            // 같은 텍스트가 두 경로로 들어와 중복 INSERT 되는 걸 방지.
            let normalized = TextNormalizer.normalize(text)
            let hash = XXHash64Wrapper.hash(normalized)
            do {
                if (try repository.incrementIfExists(contentHash: hash)) != nil {
                    skippedDup += 1
                    continue
                }
                _ = try repository.insert(text: text)
                insertedText += 1
            } catch {
                log.error("text insert failed: \(error.localizedDescription, privacy: .public)")
            }

        case "image":
            guard let b64 = capture.thumbnailBase64,
                  let data = Data(base64Encoded: b64),
                  let hash = capture.imageHash
            else { continue }
            // imageHash dedup
            do {
                if (try repository.incrementIfExists(imageHash: hash)) != nil {
                    skippedDup += 1
                    continue
                }
                _ = try repository.insertImage(thumbnail: data, imageHash: hash, imagePath: nil)
                insertedImage += 1
            } catch {
                log.error("image insert failed: \(error.localizedDescription, privacy: .public)")
            }

        default:
            break
        }
    }

    log.info("드레인 완료 — 텍스트 \(insertedText, privacy: .public)개, 이미지 \(insertedImage, privacy: .public)개 추가, dedup skip \(skippedDup, privacy: .public)개")
    CRSentry.breadcrumb("drain: text=\(insertedText) image=\(insertedImage) skip=\(skippedDup)", category: "drain")
}
