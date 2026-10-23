#if QA
import AppKit
import SwiftUI
import ClipRavenSync

/// QA 빌드 전용 실행 옵션 (테스트 계획 0단계 E3). 빌드 구성 `Debug-QA` 의 컴파일 플래그
/// `QA` 가 있을 때만 컴파일된다.
///
/// 실행 인자로 준다 (`UserDefaults` 인자 도메인이라 저장되지 않는다):
/// - `-qaReset YES` — 시작 전에 QA 컨테이너의 기록 DB·이미지·설정·체험 상태를
///   지워 첫 실행 상태로 만든다.
/// - `-qaStartTrial YES` — 체험을 지금 시작한 것으로 기록한다(온보딩을 거치지 않고).
///   시작일은 실제 현재 시각이라 `-qaTrialOffsetDays` 와 함께 주면 바로 만료된다.
/// - `-qaTrialOffsetDays 16` — 체험 경과일을 앞당긴다. 공용 패키지의 `QARuntime`
///   이 처리한다.
/// - 온보딩 건너뛰기는 기존 설정 키를 인자로 준다: `-hasCompletedOnboarding YES`.
///
/// App Store 스크린샷용 장치도 여기 있다: 클립 출처 앱 지정(`pbwrite --source`)과
/// 셸에서 화면을 바꾸는 장면 명령(`Scripts/qa/scene.swift`).
///
/// 사용법은 `Scripts/qa/README.md`.
enum QALaunchOptions {

    /// 다른 코드가 DB·설정을 읽기 전에 불러야 한다 (`applicationWillFinishLaunching`).
    static func applyBeforeLaunch() {
        // 번들 ID 가 `.qa` 로 끝나지 않으면 아무것도 하지 않는다. QA 플래그가 실수로
        // 다른 구성에 붙더라도 실제 사용자 데이터를 지우지 않게 하는 이중 안전장치다.
        guard QARuntime.isQABuild else { return }
        if UserDefaults.standard.bool(forKey: "qaReset") {
            reset()
        }
        if UserDefaults.standard.bool(forKey: "qaStartTrial") {
            startTrialNow()
        }
    }

    /// `TrialManager.shared` 는 QA 시계(오프셋 적용)로 시작일을 기록하므로, 실제
    /// 현재 시각을 저장소에 직접 쓴다. 이미 시작했으면 그대로 둔다.
    private static func startTrialNow() {
        let storage = AppGroupStorage(groupIdentifier: TrialManager.trialAppGroup)
        guard storage.loadFirstLaunchDate() == nil else { return }
        try? storage.saveFirstLaunchDate(Date())
    }

    // MARK: - 스크린샷

    /// `pbwrite --source <번들 ID>` 가 클립보드 항목에 붙이는 표시. 있으면 맨 앞 앱 대신
    /// 그 앱을 출처로 기록해, 예시 데이터의 카드마다 다른 앱 아이콘이 보이게 한다.
    static let sourceAppPasteboardType = NSPasteboard.PasteboardType("com.lumibear.clipraven.qa.source")

    static func sourceApp(from pasteboard: NSPasteboard) -> SourceAppInfo? {
        guard QARuntime.isQABuild,
              let bundleID = pasteboard.string(forType: sourceAppPasteboardType),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let bundle = Bundle(url: url)
        let name = ["CFBundleDisplayName", "CFBundleName"].lazy
            .compactMap { bundle?.object(forInfoDictionaryKey: $0) as? String }
            .first
        return SourceAppInfo(bundleId: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    /// 패널 안의 상태(검색어, 붙여넣기 스택)를 바꾸는 장면은 `MainPanelViewModel` 이 듣는다.
    static let panelSceneNotification = Notification.Name("com.lumibear.clipraven.qa.panelScene")

    /// `Scripts/qa/scene.swift` 가 보내는 분산 알림. 알림의 object 가 장면 이름이다.
    private static let sceneNotification = Notification.Name("com.lumibear.clipraven.qa.scene")
    @MainActor private static var sceneObserver: NSObjectProtocol?
    @MainActor private static var stageWindow: NSWindow?
    /// 문구를 둔 영역. 설정·구매 창을 이 영역 가운데, 문구 아래로 옮길 때 쓴다.
    @MainActor private static var stageLayout: (width: CGFloat?, top: CGFloat) = (nil, 170)

    /// 장면:
    /// - `stage:<제목>|<부제>[|width=<pt>][|top=<pt>][|light]` — 화면 전체에 스크린샷 배경과
    ///   문구를 깐다. width 를 주면 문구를 화면 왼쪽 그 너비 안에서 가운데 맞춘다(왼쪽부터
    ///   잘라 쓸 때), top 은 문구 위 여백, light 는 밝은 배경(밝은 테마 장면용)
    /// - `panel` — 클립 패널을 연다 (`stage` 다음에 부르면 배경 위에 뜬다)
    /// - `search:<검색어>` — 패널을 열고 검색어를 넣는다
    /// - `stack:<개수>` — 패널을 열고 앞에서부터 그 개수만큼 붙여넣기 스택에 담는다 (0 이면 스택을 비운다)
    /// - `settings:<탭>` — 설정 창을 그 탭으로 연다 (`SettingsSection` 의 rawValue)
    /// - `paywall` — 구매 창을 연다
    /// - `snap` — 시스템 스크린샷(⇧⌘3)을 누른다. 이 앱이 맨 앞에 있어야 패널이 닫히지
    ///   않으므로 다른 도구 대신 앱이 직접 누른다 (붙여넣기 권한으로 키 이벤트를 보낸다)
    /// - `clear` — 패널·배경과 배경 위로 올린 창을 닫는다
    ///
    /// 패널은 다른 앱이 활성화되면 닫히므로, 장면마다 이 앱을 먼저 활성화한다.
    @MainActor
    static func listenForScenes(panel: MainPanelController, openSettings: @escaping (SettingsSection) -> Void) {
        guard QARuntime.isQABuild, sceneObserver == nil else { return }
        sceneObserver = DistributedNotificationCenter.default().addObserver(
            forName: sceneNotification, object: nil, queue: .main
        ) { note in
            guard let scene = note.object as? String else { return }
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                let (name, argument) = splitScene(scene)
                switch name {
                case "stage":
                    let parts = argument.components(separatedBy: "|")
                    var options: [String: CGFloat] = [:]
                    for part in parts.dropFirst(2) {
                        let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                        if pair.count == 2, let value = Double(pair[1]) { options[pair[0]] = CGFloat(value) }
                    }
                    showStage(
                        title: parts[0],
                        subtitle: parts.count > 1 ? parts[1] : nil,
                        width: options["width"],
                        top: options["top"] ?? 170,
                        light: parts.dropFirst(2).contains("light")
                    )
                case "panel":
                    panel.show()
                case "search", "stack":
                    panel.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        NotificationCenter.default.post(name: panelSceneNotification, object: scene)
                    }
                case "settings":
                    openSettings(SettingsSection(rawValue: argument) ?? .general)
                    raiseAboveStage()
                case "paywall":
                    PaywallWindowController.shared.show()
                    raiseAboveStage()
                case "snap":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { pressSystemScreenshotShortcut() }
                case "clear":
                    panel.hide()
                    stageWindow?.orderOut(nil)
                    // 배경 위로 올렸던 설정·구매 창도 닫는다.
                    let raised = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                    for window in NSApp.windows where window.level == raised {
                        window.orderOut(nil)
                        window.level = .normal
                    }
                default:
                    break
                }
            }
        }
    }

    /// ⇧⌘3. 파일은 시스템 스크린샷 설정의 위치(기본 데스크탑)에 저장된다.
    private static func pressSystemScreenshotShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let key3: CGKeyCode = 20  // kVK_ANSI_3
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key3, keyDown: isDown)
            event?.flags = [.maskCommand, .maskShift]
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func splitScene(_ scene: String) -> (String, String) {
        guard let colon = scene.firstIndex(of: ":") else { return (scene, "") }
        return (String(scene[..<colon]), String(scene[scene.index(after: colon)...]))
    }

    /// 배경은 메뉴 막대와 Dock 을 덮도록 패널과 같은 `.statusBar` 레벨에 둔다.
    /// 패널은 나중에 앞으로 나오므로 배경 위에 뜬다.
    @MainActor
    private static func showStage(title: String, subtitle: String?, width: CGFloat?, top: CGFloat, light: Bool) {
        guard let screen = stageScreen else { return }
        let window = stageWindow ?? QAStageWindow(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: QAStageView(title: title, subtitle: subtitle, width: width, top: top, light: light)
        )
        window.setFrame(screen.frame, display: true)
        // 배경을 키 창으로 만들어 NSScreen.main 을 이 화면으로 맞춘다. 패널은 NSScreen.main 에 뜬다.
        window.makeKeyAndOrderFront(nil)
        stageWindow = window
        stageLayout = (width, top)
    }

    /// 스크린샷 배경이 떠 있는 화면. 패널이 이 화면에 뜨도록 `MainPanelController` 가 묻는다.
    /// 패널 컨트롤러는 메인 액터로 표시돼 있지 않지만 항상 메인 스레드에서 부른다.
    static var stageScreenInUse: NSScreen? {
        MainActor.assumeIsolated {
            guard let stage = stageWindow, stage.isVisible else { return nil }
            return stage.screen
        }
    }

    /// App Store 규격(2880×1800 이상)은 레티나 화면에서만 나오므로 내장 화면을 쓴다.
    /// 내장 화면이 없으면(외장 모니터만 쓰는 Mac) 현재 주 화면.
    @MainActor
    private static var stageScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main
    }

    /// 설정·구매 창은 일반 레벨이라 배경 뒤로 숨는다. 배경이 떠 있으면 그 위로 올리고,
    /// 문구 영역 가운데, 아이콘과 문구(약 250pt) 아래로 옮긴다.
    @MainActor
    private static func raiseAboveStage() {
        guard let stage = stageWindow, stage.isVisible, let screen = stage.screen else { return }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible && window !== stage && window.level == .normal {
                window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                var frame = window.frame
                let regionWidth = stageLayout.width ?? screen.frame.width
                frame.origin.x = screen.frame.minX + (regionWidth - frame.width) / 2
                frame.origin.y = screen.frame.maxY - (stageLayout.top + 270) - frame.height
                window.setFrame(frame, display: true)
                window.orderFrontRegardless()
            }
        }
    }

    private static func reset() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: AppRuntime.dataDirectory)

        // 체험 시작일(`trial.dat`)과 공유 설정은 QA 전용 App Group 에 있다.
        let group = AppGroupDatabase.appGroupID
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) {
            try? fileManager.removeItem(at: container.appendingPathComponent("trial.dat"))
        }
        UserDefaults(suiteName: group)?.removePersistentDomain(forName: group)

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}
/// 테두리 없는 창은 기본으로 키 창이 될 수 없다. 배경을 키 창으로 만들어야 패널이 같은 화면에 뜬다.
private final class QAStageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// 스크린샷 배경. 앱 아이콘 색(청록·보라·남색)이 은은하게 번지는 오로라 빛, 제목 둘레만 보이는
/// 점 격자, 가장자리 비네트. light 는 밝은 테마 장면용.
///
/// 색 번짐은 문구 영역(`width`, 없으면 화면 전체) 기준으로 놓는다 — 스크린샷은 화면 왼쪽
/// 그 너비만큼 잘라 쓰기 때문이다. 패널은 반투명 재질이라 뒤의 번짐이 비친다.
private struct QAStageView: View {
    let title: String
    let subtitle: String?
    let width: CGFloat?
    let top: CGFloat
    let light: Bool

    private let teal = Color(red: 0.30, green: 0.85, blue: 0.75)
    private let violet = Color(red: 0.55, green: 0.38, blue: 0.95)
    private let indigo = Color(red: 0.25, green: 0.30, blue: 0.85)

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geometry in
                background(in: geometry.size)
            }
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(teal.opacity(light ? 0.35 : 0.45))
                        .frame(width: 150, height: 150)
                        .blur(radius: 40)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(light ? 0.18 : 0.40), radius: 18, y: 10)
                }
                .frame(height: 96)
                .padding(.bottom, 6)
                Text(title)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(light ? Color(red: 0.10, green: 0.12, blue: 0.23) : .white)
                    .shadow(color: .black.opacity(light ? 0 : 0.25), radius: 12, y: 4)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(light ? Color(red: 0.05, green: 0.55, blue: 0.48) : teal)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 80)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .padding(.top, top)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func background(in size: CGSize) -> some View {
        let regionWidth = width ?? size.width
        let height = size.height
        ZStack {
            (light ? Color(red: 0.95, green: 0.96, blue: 0.99) : Color(red: 0.05, green: 0.06, blue: 0.14))
            blob(teal, diameter: regionWidth * 0.55, at: CGPoint(x: regionWidth * 0.10, y: height * 0.28),
                 opacity: light ? 0.30 : 0.42)
            blob(violet, diameter: regionWidth * 0.50, at: CGPoint(x: regionWidth * 0.92, y: height * 0.22),
                 opacity: light ? 0.24 : 0.40)
            blob(indigo, diameter: regionWidth * 0.75, at: CGPoint(x: regionWidth * 0.50, y: height * 0.95),
                 opacity: light ? 0.16 : 0.38)
            dotGrid
                .mask(
                    RadialGradient(
                        colors: [.white, .clear],
                        center: UnitPoint(x: regionWidth / 2 / max(size.width, 1), y: (top + 120) / max(height, 1)),
                        startRadius: 0, endRadius: regionWidth * 0.55
                    )
                )
            RadialGradient(
                colors: [.clear, .black.opacity(light ? 0.05 : 0.35)],
                center: UnitPoint(x: regionWidth / 2 / max(size.width, 1), y: 0.55),
                startRadius: regionWidth * 0.35, endRadius: regionWidth * 0.85
            )
        }
    }

    private func blob(_ color: Color, diameter: CGFloat, at point: CGPoint, opacity: Double) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.28)
            .position(point)
    }

    private var dotGrid: some View {
        Canvas { context, size in
            let step: CGFloat = 26
            let dot = light ? Color.black.opacity(0.07) : Color.white.opacity(0.09)
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(dot))
                    x += step
                }
                y += step
            }
        }
    }
}
#endif
