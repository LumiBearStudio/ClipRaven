import AppKit
import Carbon
import Sentry
import WebKit
import ClipRavenSync

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = StatusItemController()
    private let panelController = MainPanelController()
    private let hotKeyManager = HotKeyManager()
    private let clipboardMonitor = ClipboardMonitor()
    private let cleanupService = CleanupService()
    private let clipRepository = ClipRepository()
    private let feedbackService = FeedbackService()
    // onboarding window is managed by OnboardingWindowController.shared

    /// iCloud sync engine. Opaque because `SyncEngine` requires macOS 14+
    /// and we support 13.0 — the concrete type is only visible behind an
    /// `if #available` block. On macOS 13 this stays nil forever and
    /// every sync path is a no-op.
    private var syncEngineBox: Any?

    /// Handle to the fire-and-forget start task so `applicationWillTerminate`
    /// can cancel it before calling `shutdown()`. Without this, a slow
    /// start racing a fast quit could instantiate `CKSyncEngine` after
    /// teardown and leak the delegate.
    private var syncStartTask: Task<Void, Never>?

    /// GRDB transaction observer that surfaces clips-table commits to the
    /// sync engine. Attached even on macOS 13 so the observer lifecycle
    /// is uniform; the commit closure is a no-op on pre-14 systems
    /// because `syncEngineBox` is nil there.
    private var syncChangeCapture: SyncChangeCapture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Crash reporting — strictly opt-in (toggle on onboarding last page)
        if UserDefaults.standard.bool(forKey: "crashReportsEnabled") {
            SentrySDK.start { options in
                options.dsn = "https://c5f56450b1edd3c00bbe4efb757a3bc1@o4510949994266624.ingest.de.sentry.io/4511348541489232"
                options.environment = "production"
                options.sendDefaultPii = false
                options.attachScreenshot = false
                options.attachViewHierarchy = false
                options.maxBreadcrumbs = 200
                // 모든 이벤트(크래시 포함)에 최근 120초 os.log 첨부
                if #available(macOS 12.0, *) {
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
            SentrySDK.captureMessage("ClipRaven Mac launched", level: .info)
        }

        // Register default UserDefaults values
        UserDefaults.standard.register(defaults: [
            "blockSensitive": true,
            "maxClipCount": AppConstants.maxClipCount,
            "maxDaysToKeep": 90,
            "selectiveMode": false,
            "doubleCopyWindowMs": 500,
        ])

        // Phase C — sync 패키지에 Mac 측 이미지 저장 어댑터 등록.
        // SyncRecordMapper 가 CKAsset round-trip 시 이 어댑터를 통해 우리
        // 영구 저장소(`~/Library/Application Support/ClipRaven/images/`)를
        // 사용한다.
        ImageOriginalStoreRegistry.register(MacImageOriginalStore())

        // 셀룰러 정책 provider 등록. Mac 은 보통 Wi-Fi/유선이지만 Personal
        // Hotspot 사용 시 셀룰러로 보일 수 있음 → 동일 정책 적용.
        NetworkStateRegistry.register(NWPathMonitorBasedProvider.shared)

        // 7일 이상 된 staging 고아 파일 정리.
        AssetStaging.shared.purgeStaleStaging()

        // 이미지 binary TTL cleanup — 30일 이상 된 non-pinned 이미지 원본 삭제.
        // 백그라운드 detached task — 메인 launch 차단하지 않음.
        Task.detached(priority: .utility) {
            do {
                _ = try await ImageBinaryCleanup.run(dbPool: AppDatabase.shared.dbPool)
            } catch {
                ClipRavenLog.cleanup.error("ImageBinaryCleanup failed: \(String(describing: error), privacy: .public)")
                CRSentry.capture(error, context: "ImageBinaryCleanup on launch")
            }
        }

        // Restore Dock icon visibility from saved preference. Info.plist sets
        // LSUIElement=1, so every launch starts as .accessory (no Dock icon)
        // regardless of what the user picked last session. Without this line
        // the Settings toggle appears to "forget" itself — it's actually
        // saved, just never re-applied on launch.
        if UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        }

        // Prevent duplicate instances
        terminateOtherInstances()

        // Setup feedback (sound + haptic)
        feedbackService.setup()

        // Setup panel
        panelController.setup()

        // Setup menu bar
        statusItemController.panelController = panelController
        statusItemController.setup()

        // Register global hotkey (reads from HotKeyStore, defaults to ⇧V)
        let store = HotKeyStore.shared
        hotKeyManager.register(keyCode: store.keyCode, modifiers: store.modifiers) { [weak self] in
            self?.panelController.toggle()
        }

        // Re-register when user changes the hotkey in Settings
        NotificationCenter.default.addObserver(
            forName: .clipRavenHotKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotKeyManager.unregister()
            let s = HotKeyStore.shared
            self.hotKeyManager.register(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
                self?.panelController.toggle()
            }
        }

        // Observe image confirmation requests (selective mode)
        NotificationCenter.default.addObserver(
            forName: .clipRavenImageNeedsConfirmation,
            object: nil,
            queue: .main
        ) { notification in
            guard let confirmation = notification.object as? PendingImageConfirmation else { return }
            ImageConfirmPanel.shared.show(confirmation)
        }

        // Register per-clip custom shortcuts (v10). Each matching clip gets its own
        // global hotkey; pressing it pastes that clip without opening the panel.
        reloadAllClipHotkeys()

        // Any change to a clip's shortcut — triggered by MainPanelViewModel — rewires
        // only the affected clip so we don't thrash Carbon event tables on every edit.
        NotificationCenter.default.addObserver(
            forName: .clipRavenClipShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let clipId = notification.userInfo?["clipId"] as? Int64 {
                self.reregisterClipHotkey(clipId: clipId)
            } else {
                // No clipId → reload all (safe fallback)
                self.reloadAllClipHotkeys()
            }
        }

        // Start clipboard monitoring
        clipboardMonitor.start()
        CRSentry.breadcrumb("clipboard monitoring started", category: "app")

        // 우리가 직접 NSPasteboard에 write 한 직후 ClipboardMonitor가
        // 그 변경을 자기 changeCount로 갱신해서 echo-back capture를 막음.
        // 호출자: DetailModalView/PreviewPanelView 등의 "복사" 버튼.
        NotificationCenter.default.addObserver(
            forName: .clipRavenIntentionalPasteboardWrite,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clipboardMonitor.markIntentionalWrite()
        }

        // Start cleanup service (runs on startup + every 6 hours)
        Task {
            await cleanupService.startSchedule()
        }

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        }

        // iCloud sync engine. Engine is created eagerly but self-gates on
        // the feature flag + account status before doing any CloudKit I/O
        // — safe to fire-and-forget regardless of user state.
        //
        // ChangeCapture is attached alongside so clip-table commits are
        // buffered from the moment the app is up. The closure gates on
        // `SyncFeatureFlag.isEnabled` every commit: when sync is off we
        // still pay the per-commit rowID dedup cost (negligible), and
        // toggling the flag on at runtime takes effect on the next commit
        // without re-attaching the observer.
        if #available(macOS 14.0, *) {
            let engine = SyncEngine(
                stateStore: SyncStateStore(dbWriter: AppDatabase.shared.dbPool),
                containerIdentifier: "iCloud.com.lumibear.ClipRaven",
                clipRepository: ClipSyncRepository(dbPool: AppDatabase.shared.dbPool)
            )
            self.syncEngineBox = engine

            let capture = SyncChangeCapture { [weak engine] saves, deletes in
                // Flag check runs every commit — a cheap UserDefaults read.
                // Keeps the observer trivially safe to attach before the
                // user has opted in via the future Settings UI.
                guard SyncFeatureFlag.isEnabled else { return }
                guard let engine else { return }
                // Hop to the main actor — enqueue API is main-actor-isolated.
                // The commit closure itself runs on GRDB's writer queue.
                Task { @MainActor in
                    engine.enqueueSaves(uuids: saves)
                    for uuid in deletes {
                        engine.enqueueDelete(uuid: uuid)
                    }
                }
            }
            AppDatabase.shared.dbPool.add(transactionObserver: capture)
            self.syncChangeCapture = capture

            self.syncStartTask = Task { [weak self] in
                await engine.startIfEligible()
                self?.syncStartTask = nil
            }

            // Register for silent push so CloudKit can wake the app when
            // another device commits. macOS treats
            // `shouldSendContentAvailable` pushes as alert-less — no user
            // permission prompt. Safe to call even when sync is flag-off;
            // the handler gates on engine presence.
            NSApplication.shared.registerForRemoteNotifications()

            // APS registration can fail on Xcode dev builds (OSStatus 13),
            // which means silent-push wake-ups are unavailable. Compensate
            // by pulling fresh changes every time the user opens the panel
            // or brings the app forward — these are the only moments the
            // user cares about freshness. `requestSyncCycle` coalesces
            // back-to-back calls into a single in-flight cycle.
            NotificationCenter.default.addObserver(
                forName: .clipRavenPanelShown,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.triggerSyncFetch(reason: "panelShown")
            }

            // Settings → iCloud 동기화 toggle ON. The engine instance is
            // already constructed eagerly at launch above, but
            // `startIfEligible()` was a no-op back then because the flag
            // was off. Calling it again now picks up the new flag value.
            NotificationCenter.default.addObserver(
                forName: .clipRavenSyncEnabledChanged,
                object: nil,
                queue: .main
            ) { [weak engine] notification in
                guard let engine = engine,
                      let enabled = notification.object as? Bool, enabled
                else { return }
                Task { @MainActor in
                    await engine.startIfEligible()
                }
            }

            // Settings → "지금 동기화" button.
            NotificationCenter.default.addObserver(
                forName: .clipRavenSyncRefreshRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.triggerSyncFetch(reason: "settings.refresh")
            }

            // Settings → "iCloud에서 모두 지우기" — shut down the engine
            // synchronously so the subsequent destructive wipe can clear
            // sync_engine_state without racing live writes.
            NotificationCenter.default.addObserver(
                forName: .clipRavenSyncShutdownRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if #available(macOS 14.0, *), let engine = self.syncEngineBox as? SyncEngine {
                    _ = engine.shutdown()
                }
            }
        }
    }

    /// Sync trigger. Routed through a single helper so we can instrument
    /// all wake-up paths in one place (panel open, app activate, future
    /// Settings "Sync Now" button).
    ///
    /// `fetchChangesOnWake` is @MainActor on SyncEngine; we're either
    /// called from a @MainActor notification queue or from the
    /// NSApplicationDelegate callbacks which run on the main thread, so
    /// the `MainActor.assumeIsolated` is a zero-cost annotation — NOT a
    /// hop to a different context.
    private func triggerSyncFetch(reason: String) {
        if #available(macOS 14.0, *), let engine = syncEngineBox as? SyncEngine {
            ClipRavenLog.app.debug("triggerSyncFetch reason=\(reason, privacy: .public)")
            CRSentry.breadcrumb("syncFetch: \(reason)", category: "sync")
            MainActor.assumeIsolated {
                engine.fetchChangesOnWake()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Fires when user clicks the menu bar icon, brings the Settings
        // window forward, or otherwise activates the app. A good proxy
        // for "user wants fresh data now."
        triggerSyncFetch(reason: "didBecomeActive")
    }

    // MARK: - Remote notifications

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Token isn't used — CloudKit resolves push routing server-side
        // via the container identifier. Log length for diagnostics only.
        let tokenBytes = deviceToken.count
        ClipRavenLog.app.info("registered for remote notifications (\(tokenBytes, privacy: .public) byte token)")
        CRSentry.breadcrumb("APNs registered (\(tokenBytes)B token)", category: "app")
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Non-fatal. App continues to function; sync falls back to the
        // engine's foreground polling — device B will pull on next launch
        // or `fetchChangesOnWake` trigger.
        //
        // Dump full NSError so we can diagnose the real cause:
        //   - NSCocoaErrorDomain 3000 → missing `aps-environment` entitlement.
        //   - NSPOSIXErrorDomain 13 (EACCES) → signing/provisioning problem,
        //     typically a stale profile that predates Push capability.
        //   - Anything else → look up `domain` + `code` in Apple docs.
        let ns = error as NSError
        ClipRavenLog.app.error("APNs registration failed — domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public)")
        CRSentry.capture(error, context: "APNs registration failed — domain=\(ns.domain) code=\(ns.code)")
    }

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        // Filter to CloudKit pushes — any other framework sending to this
        // delegate (unlikely) is ignored. `ck` prefix covers both
        // CKDatabase and CKQuery subscriptions.
        guard userInfo["ck"] != nil else { return }

        if #available(macOS 14.0, *), let engine = syncEngineBox as? SyncEngine {
            engine.fetchChangesOnWake()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
        hotKeyManager.unregister()

        // Clean shutdown: cancel the start task first so it can't re-race
        // the engine back up, then release the CKSyncEngine. The returned
        // token is discarded — clearAll isn't called here.
        syncStartTask?.cancel()
        syncStartTask = nil
        if #available(macOS 14.0, *), let engine = syncEngineBox as? SyncEngine {
            _ = engine.shutdown()
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        OnboardingWindowController.shared.show()
    }

    // MARK: - Per-clip hotkey registration

    /// Unregister all per-clip hotkeys, then register every clip that currently has one.
    private func reloadAllClipHotkeys() {
        hotKeyManager.unregisterAllClipHotkeys()
        let clips = (try? clipRepository.fetchClipsWithShortcuts()) ?? []
        for clip in clips {
            guard let clipId = clip.id,
                  let keyCode = clip.customShortcutKeyCode,
                  let modifiers = clip.customShortcutModifiers
            else { continue }
            registerClipHotkey(clipId: clipId, keyCode: keyCode, modifiers: modifiers)
        }
    }

    /// Re-register a single clip's hotkey from its current DB state.
    /// If the clip no longer has a shortcut assigned, just unregister.
    private func reregisterClipHotkey(clipId: Int64) {
        hotKeyManager.unregisterClipHotkey(clipId: clipId)
        guard let clip = try? clipRepository.fetchOne(id: clipId),
              !clip.isDeleted,
              let keyCode = clip.customShortcutKeyCode,
              let modifiers = clip.customShortcutModifiers
        else { return }
        registerClipHotkey(clipId: clipId, keyCode: keyCode, modifiers: modifiers)
    }

    /// Wire a hotkey → paste-this-clip action.
    /// Uses MainPanelViewModel's static paste flow so no view state is required.
    private func registerClipHotkey(clipId: Int64, keyCode: UInt32, modifiers: UInt32) {
        let repo = self.clipRepository
        hotKeyManager.registerClipHotkey(
            clipId: clipId,
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            // Carbon callbacks run on the main thread via the shared event handler,
            // but hop to the main actor explicitly for safety (NSPasteboard + NSWorkspace).
            DispatchQueue.main.async {
                guard let clip = try? repo.fetchOne(id: clipId),
                      !clip.isDeleted else { return }
                MainPanelViewModel.pasteClipStatic(clip, clipRepository: repo)
            }
        }
    }

    // MARK: - Duplicate Instance Prevention

    private func terminateOtherInstances() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier ?? ""

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID) {
            guard app.processIdentifier != myPID else { continue }
            app.terminate()
            // Synchronously wait for the old instance to actually exit — otherwise
            // its Carbon hotkey registration blocks us (-9868 eventHotKeyExistsErr)
            // and Shift+V silently stops working until the next restart.
            let softDeadline = Date().addingTimeInterval(2.0)
            while !app.isTerminated && Date() < softDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if !app.isTerminated {
                app.forceTerminate()
                let hardDeadline = Date().addingTimeInterval(1.0)
                while !app.isTerminated && Date() < hardDeadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
        }
    }
}
