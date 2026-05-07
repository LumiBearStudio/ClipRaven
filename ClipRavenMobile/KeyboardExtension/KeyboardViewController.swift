import UIKit
import SwiftUI
import GRDB
import CryptoKit
import os.log
import ClipRavenSync

/// Custom keyboard that shows recent ClipRaven clips as horizontally-scrollable
/// cards and pastes the selected one into the host app via
/// `UITextDocumentProxy.insertText`.
///
/// Card layout (inspired by Paste):
/// - Single row of portrait-aspect cards, horizontal scroll.
/// - Image clips: thumbnail fills the card with a gradient overlay.
/// - Text/URL clips: dark card background with a 3-line text preview.
/// - Each card shows a relative time label ("2d", "방금") at the top-right.
///
/// Multi-queue mode: Long-press a card to start a paste queue; tap the
/// "붙여넣기 (N)" button to insert them in the selected order.
///
/// Search mode: Tap the magnifier icon → search bar replaces the header row.
/// Supports full-text search (FTS5) and Korean chosung (초성) search.
///
/// Requirements (Info.plist):
/// - `RequestsOpenAccess = true` so `UIPasteboard` and the App Group
///   SQLite are accessible. User must enable "Allow Full Access" in
///   Settings → General → Keyboards → ClipRaven → Allow Full Access.
class KeyboardViewController: UIInputViewController {

    private let log = Logger(subsystem: "com.lumibear.ClipRavenMobile.kb", category: "KbExt")

    private lazy var dbPool: DatabasePool? = {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
        ) else {
            log.error("App Group container missing — full access not granted?")
            return nil
        }
        let dbURL = containerURL
            .appendingPathComponent("ClipRaven", isDirectory: true)
            .appendingPathComponent("clipraven.sqlite")
        do {
            var config = Configuration()
            config.foreignKeysEnabled = true
            config.readonly = true
            config.busyMode = .timeout(5.0)   // multi-process 안전망
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
            return try DatabasePool(path: dbURL.path, configuration: config)
        } catch {
            log.error("dbPool init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    // MARK: - Layout constants

    /// 카드 너비. 화면 너비의 ~42% 정도로 화면에 2.4장이 보인다.
    private static let cardWidth: CGFloat = 148
    /// 키보드 전체 높이. 헤더 28 + 카드 ~175 + 키row 44 + 여백.
    /// (Globe 는 우리가 안 그림 — iOS 가 시스템 row 로 자동 표시.)
    private static let keyboardHeight: CGFloat = 274

    // MARK: - State

    private var clips: [Clip] = []
    private var pasteQueue: [Clip] = []

    /// 콘텐츠 타입 필터 (radio).
    private var currentFilter: KeyboardFilter = .all
    /// 날짜 범위 필터 (radio).
    private var currentDateFilter: KeyboardDateFilter = .all
    /// AI 카테고리 필터 (radio). Mac 의 Foundation Models 가 분류한 카테고리.
    /// iOS 단독 사용자에겐 sync 받은 클립만 카테고리 가짐.
    private var currentAICategory: KeyboardAICategory = .all
    /// 소스 앱 필터 (radio). nil = 전체.
    private var currentSourceApp: String? = nil
    /// 선택된 태그들 (multi, toggle).
    private var selectedTagIds: Set<Int64> = []

    /// DB 에서 read 한 사용자 태그 목록.
    private var availableTags: [Tag] = []
    /// DB 에서 read 한 자주 쓰는 소스 앱 목록 (top 10).
    private var availableSourceApps: [String] = []

    // MARK: - UI

    private var headerContainer: UIView!
    private var headerAccentDot: UIView!
    private var headerLabel: UILabel!
    private var countLabel: UILabel!
    /// 필터/태그 메뉴 버튼 — 검색 버튼 옆에 별도 배치 (발견성).
    /// 활성 필터/태그 시 accent color 로 강조.
    private var filterButton: UIButton!
    /// 검색 버튼 — SwiftUI `Link` 를 `UIHostingController` 로 wrap.
    /// iOS 18+ 에서 키보드 익스텐션의 직접 앱 실행이 차단됐으나 SwiftUI Link
    /// 경유는 OS 가 정상 처리 (KeyboardKit 8.8.6 검증 패턴).
    private var searchHostController: UIHostingController<KeyboardSearchLink>!
    private var collectionView: UICollectionView!
    private var emptyStateView: KeyboardEmptyStateView!
    private var queueBar: UIView!
    private var pasteQueueButton: UIButton!
    private var clearQueueButton: UIButton!

    // Bottom key row — globe + delete + space + return (Paste 스타일)
    private var bottomKeyRow: UIView!
    private var nextKeyboardButton: UIButton!  // globe, leading
    private var deleteButton: UIButton!         // ⌫
    private var spaceButton: UIButton!          // [ space ]
    private var returnButton: UIButton!         // return

    /// 자동 capture 시점 dedup — 같은 클립 내용을 키보드 활성화 매번 중복 잡지
    /// 않도록 changeCount + content hash 기억.
    ///
    /// 초기값 `-1` (sentinel) — 키보드 첫 활성화 시 changeCount 와 비교해도
    /// 다르므로 capture 진행됨. iOS 의 "Allow paste?" 다이얼로그는 우리가
    /// `pasteboard.hasStrings/.image/.string` 등을 호출할 때 트리거되는데,
    /// changeCount 가 같으면 early return 해서 호출 자체 안 함 → 다이얼로그
    /// 안 뜸. 따라서 첫 호출은 무조건 진행해야 정상 다이얼로그 표시됨.
    private var lastSeenChangeCount: Int = -1
    private var recentCapturedHashes: Set<String> = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        // viewDidLoad 에서 lastSeenChangeCount 캐시 안 함 (sentinel -1 유지).
        // 첫 viewWillAppear 호출 시 captureFromPasteboard 가 무조건 진행해
        // 다이얼로그 트리거.
        Task {
            await loadFilterMetadata()
            await loadClips()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // ⭐ Paste 패턴 — 키보드 활성화 시 새 클립 자동 capture
        captureFromPasteboard()
        Task {
            await loadFilterMetadata()  // 메인 앱이 태그 추가/삭제했을 수 있음
            await loadClips()
        }
    }

    // MARK: - Colors

    static var keyboardBackground: UIColor {
        UIColor { t in t.userInterfaceStyle == .dark
            ? UIColor(white: 0.16, alpha: 1)
            : UIColor(red: 0.80, green: 0.82, blue: 0.85, alpha: 1)
        }
    }

    static var cardBackgroundColor: UIColor {
        UIColor { t in t.userInterfaceStyle == .dark
            ? UIColor(white: 0.24, alpha: 1)
            : UIColor(white: 0.94, alpha: 1)
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = Self.keyboardBackground
        setupHeader()
        setupCollectionView()
        setupEmptyState()
        setupQueueBar()
        setupBottomKeyRow()
        applyConstraints()
    }

    private func setupHeader() {
        headerContainer = UIView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerContainer)

        // ● accent dot
        headerAccentDot = UIView()
        headerAccentDot.backgroundColor = .systemIndigo
        headerAccentDot.layer.cornerRadius = 4
        headerAccentDot.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerAccentDot)

        // "ClipRaven" — 단순 라벨
        headerLabel = UILabel()
        headerLabel.text = "ClipRaven"
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.textColor = .label
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerLabel)

        // "12개"
        countLabel = UILabel()
        countLabel.text = ""
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabel
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(countLabel)

        // 🔍 검색 버튼 — SwiftUI Link 로 메인 앱 실행 (clipraven://search)
        // iOS 18+ 키보드 익스텐션의 직접 앱 실행 차단을 우회하는 검증된 패턴.
        searchHostController = UIHostingController(
            rootView: KeyboardSearchLink()
        )
        searchHostController.view.translatesAutoresizingMaskIntoConstraints = false
        searchHostController.view.backgroundColor = .clear
        addChild(searchHostController)
        headerContainer.addSubview(searchHostController.view)
        searchHostController.didMove(toParent: self)

        // 🔽 필터 버튼 — 명시적 위치 (검색 옆). 누르면 필터/태그 메뉴.
        // 활성 필터/태그 있으면 accent color 로 강조.
        var filterCfg = UIButton.Configuration.plain()
        filterCfg.image = UIImage(
            systemName: "line.3.horizontal.decrease.circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        )
        filterCfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        filterButton = UIButton(configuration: filterCfg)
        filterButton.tintColor = .secondaryLabel
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.showsMenuAsPrimaryAction = true
        filterButton.menu = makeFilterMenu()
        headerContainer.addSubview(filterButton)

        NSLayoutConstraint.activate([
            headerAccentDot.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            headerAccentDot.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            headerAccentDot.widthAnchor.constraint(equalToConstant: 8),
            headerAccentDot.heightAnchor.constraint(equalToConstant: 8),

            headerLabel.leadingAnchor.constraint(equalTo: headerAccentDot.trailingAnchor, constant: 6),
            headerLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            // 우측 끝: 검색
            searchHostController.view.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            searchHostController.view.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            searchHostController.view.widthAnchor.constraint(equalToConstant: 32),
            searchHostController.view.heightAnchor.constraint(equalToConstant: 28),

            // 검색 좌측: 필터 버튼
            filterButton.trailingAnchor.constraint(equalTo: searchHostController.view.leadingAnchor, constant: -2),
            filterButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 32),
            filterButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 8       // 카드 간 수평 간격
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(ClipCardCell.self, forCellWithReuseIdentifier: ClipCardCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.allowsMultipleSelection = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = .fast    // 카드 스냅감
        collectionView.clipsToBounds = false       // 카드 그림자가 bounds 밖으로 나오도록
        view.addSubview(collectionView)
    }

    private func setupEmptyState() {
        emptyStateView = KeyboardEmptyStateView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)
    }

    private func setupQueueBar() {
        queueBar = UIView()
        queueBar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)

        // iOS 26 beta 환경에서도 UIBlurEffect fallback 없이 동작하도록 단순화
        queueBar.layer.shadowColor = UIColor.black.cgColor
        queueBar.layer.shadowOpacity = 0.12
        queueBar.layer.shadowOffset = CGSize(width: 0, height: -2)
        queueBar.layer.shadowRadius = 8
        queueBar.translatesAutoresizingMaskIntoConstraints = false
        queueBar.isHidden = true
        view.addSubview(queueBar)

        // "붙여넣기 (N)" — filled capsule
        var cfg = UIButton.Configuration.filled()
        cfg.title = String(localized: "붙여넣기")
        cfg.baseForegroundColor = .white
        cfg.baseBackgroundColor = .systemIndigo
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var b = a; b.font = UIFont.systemFont(ofSize: 13, weight: .semibold); return b
        }
        pasteQueueButton = UIButton(configuration: cfg)
        pasteQueueButton.translatesAutoresizingMaskIntoConstraints = false
        pasteQueueButton.addTarget(self, action: #selector(pasteQueueTapped), for: .touchUpInside)
        queueBar.addSubview(pasteQueueButton)

        // × 취소 버튼
        clearQueueButton = UIButton(type: .system)
        let xCfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        clearQueueButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: xCfg), for: .normal)
        clearQueueButton.tintColor = .tertiaryLabel
        clearQueueButton.translatesAutoresizingMaskIntoConstraints = false
        clearQueueButton.addTarget(self, action: #selector(clearQueueTapped), for: .touchUpInside)
        queueBar.addSubview(clearQueueButton)

        NSLayoutConstraint.activate([
            clearQueueButton.leadingAnchor.constraint(equalTo: queueBar.leadingAnchor, constant: 14),
            clearQueueButton.centerYAnchor.constraint(equalTo: queueBar.centerYAnchor),
            clearQueueButton.widthAnchor.constraint(equalToConstant: 28),
            clearQueueButton.heightAnchor.constraint(equalToConstant: 28),

            pasteQueueButton.trailingAnchor.constraint(equalTo: queueBar.trailingAnchor, constant: -14),
            pasteQueueButton.centerYAnchor.constraint(equalTo: queueBar.centerYAnchor),
            pasteQueueButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    // MARK: - Bottom Key Row
    //
    // ┌────────────────────────────────────┐
    // │ ⌫    [   space   ]   return        │  메인 키 row (44pt)
    // └────────────────────────────────────┘
    //
    // Globe 는 우리가 그리지 않음 — iOS 가 키보드 영역 아래에 별도 시스템 row
    // 로 keyboard switcher (🌐) + dictation (🎤) 을 자동 표시한다. 우리도
    // globe 를 그리면 중복 노출되어 어색. 사용자 검증 (캡처 2026-05-04)
    // 으로 자동 표시 확인됨.

    private func setupBottomKeyRow() {
        bottomKeyRow = UIView()
        bottomKeyRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomKeyRow)

        // ⌫ delete
        deleteButton = makeKeyButton(systemImage: "delete.left", title: nil)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        // 길게 누르면 연속 삭제 — 일반 키보드 패턴
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(deleteLongPress(_:)))
        lp.minimumPressDuration = 0.4
        deleteButton.addGestureRecognizer(lp)
        bottomKeyRow.addSubview(deleteButton)

        // [ space ] — 가운데 가로 길게
        spaceButton = makeKeyButton(systemImage: nil, title: "space")
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        bottomKeyRow.addSubview(spaceButton)

        // return
        returnButton = makeKeyButton(systemImage: nil, title: "return")
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        bottomKeyRow.addSubview(returnButton)

        // Globe 는 시스템이 자동 표시하므로 우리는 그리지 않는다.
        // 단 Apple 정책상 `handleInputModeList` 액션은 키보드 익스텐션이
        // 내부적으로 처리 가능해야 하므로 nextKeyboardButton 를 hidden 으로
        // 만들어 reference 만 유지 — 향후 OS 동작 변경 대비.
        nextKeyboardButton = UIButton(type: .system)
        nextKeyboardButton.isHidden = true
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboardButton.addTarget(
            self,
            action: #selector(handleInputModeList(from:with:)),
            for: .allTouchEvents
        )
        view.addSubview(nextKeyboardButton)

        NSLayoutConstraint.activate([
            // ⌫ — leading, 50x36
            deleteButton.leadingAnchor.constraint(equalTo: bottomKeyRow.leadingAnchor, constant: 6),
            deleteButton.centerYAnchor.constraint(equalTo: bottomKeyRow.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 50),
            deleteButton.heightAnchor.constraint(equalToConstant: 36),

            // return — trailing, 70x36
            returnButton.trailingAnchor.constraint(equalTo: bottomKeyRow.trailingAnchor, constant: -6),
            returnButton.centerYAnchor.constraint(equalTo: bottomKeyRow.centerYAnchor),
            returnButton.widthAnchor.constraint(equalToConstant: 70),
            returnButton.heightAnchor.constraint(equalToConstant: 36),

            // space — fills middle
            spaceButton.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 6),
            spaceButton.trailingAnchor.constraint(equalTo: returnButton.leadingAnchor, constant: -6),
            spaceButton.centerYAnchor.constraint(equalTo: bottomKeyRow.centerYAnchor),
            spaceButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    /// 시스템 키 모양 버튼 생성. 흰색/어두운 배경 + 둥근 모서리 + subtle shadow.
    private func makeKeyButton(systemImage: String?, title: String?) -> UIButton {
        var config = UIButton.Configuration.plain()
        if let title { config.title = title }
        if let img = systemImage {
            let imgCfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            config.image = UIImage(systemName: img, withConfiguration: imgCfg)
        }
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            return a
        }

        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.backgroundColor = Self.cardBackgroundColor
        btn.layer.cornerRadius = 7
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.10
        btn.layer.shadowRadius = 1
        btn.layer.shadowOffset = CGSize(width: 0, height: 1)
        return btn
    }

    // MARK: - Key actions

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// ⌫ 길게 누르면 연속 삭제 — 처음 0.4s 후 0.08s 간격.
    private var deleteRepeatTimer: Timer?

    @objc private func deleteLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            // 첫 1회는 button tap 으로 이미 일어남, 여기서는 추가 반복만 시작
            deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.textDocumentProxy.deleteBackward()
            }
        case .ended, .cancelled, .failed:
            deleteRepeatTimer?.invalidate()
            deleteRepeatTimer = nil
        default:
            break
        }
    }

    private func applyConstraints() {
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: Self.keyboardHeight),

            // Header row
            headerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            headerContainer.heightAnchor.constraint(equalToConstant: 28),

            // Card collection — stretches between header and bottom key row
            collectionView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomKeyRow.topAnchor, constant: -6),

            // Empty state — centered in card area
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),

            // Bottom key row — ⌫ / space / return (44pt tall)
            // safeAreaLayoutGuide 하단에 직접 붙음. iOS 가 그 아래에
            // globe + dictation 시스템 row 를 자동 표시.
            bottomKeyRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            bottomKeyRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            bottomKeyRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            bottomKeyRow.heightAnchor.constraint(equalToConstant: 44),

            // Hidden globe — Apple 정책 fallback. 화면 밖에 위치 (offscreen).
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextKeyboardButton.widthAnchor.constraint(equalToConstant: 1),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 1),

            // Queue bar — overlays bottom of collection view (above key row)
            queueBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            queueBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            queueBar.heightAnchor.constraint(equalToConstant: 46),
            queueBar.bottomAnchor.constraint(equalTo: bottomKeyRow.topAnchor, constant: -4),
        ])
    }

    // MARK: - Data

    private func loadClips(query: String = "") async {
        guard let dbPool else {
            await MainActor.run { showFullAccessHint() }
            return
        }
        do {
            let rows: [Clip]
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

            // 사용자 필터 5가지 모두 적용 (조합 가능):
            // 1) contentType (radio)
            // 2) date range (radio)  → lastCopiedAt >= startDate
            // 3) ai category (radio) → aiCategory = ?
            // 4) source app (radio)  → sourceAppName = ?
            // 5) tags (multi)        → JOIN clipTags + IN(...)
            if trimmed.isEmpty {
                rows = try await dbPool.read { [
                    currentFilter, currentDateFilter, currentAICategory,
                    currentSourceApp, selectedTagIds
                ] db in
                    let hasTagFilter = !selectedTagIds.isEmpty

                    var sql = "SELECT \(hasTagFilter ? "DISTINCT " : "")clips.* FROM clips"
                    var conditions: [String] = [
                        "clips.isDeleted = 0",
                        "(clips.contentText IS NOT NULL OR clips.thumbnail IS NOT NULL)"
                    ]
                    var args: [DatabaseValueConvertible] = []

                    if hasTagFilter {
                        sql += " JOIN clipTags ON clipTags.clipId = clips.id"
                        let idsList = selectedTagIds.map(String.init).joined(separator: ",")
                        conditions.append("clipTags.tagId IN (\(idsList))")
                    }

                    let typeCondition = currentFilter.sqlCondition
                    if !typeCondition.isEmpty {
                        let prefixed = typeCondition
                            .replacingOccurrences(of: "contentType", with: "clips.contentType")
                            .replacingOccurrences(of: "isPinned", with: "clips.isPinned")
                        conditions.append(prefixed)
                    }

                    if let cutoff = currentDateFilter.startDate {
                        conditions.append("clips.lastCopiedAt >= ?")
                        args.append(cutoff)
                    }
                    if let aiValue = currentAICategory.sqlValue {
                        conditions.append("clips.aiCategory = ?")
                        args.append(aiValue)
                    }
                    if let app = currentSourceApp {
                        conditions.append("clips.sourceAppName = ?")
                        args.append(app)
                    }

                    sql += " WHERE " + conditions.joined(separator: " AND ")
                    sql += " ORDER BY clips.isPinned DESC, clips.lastCopiedAt DESC LIMIT 50"

                    return try Clip.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }
            } else if Self.shouldUseChosungSearch(trimmed) {
                let pattern = "%\(trimmed)%"
                rows = try await dbPool.read { db in
                    try Clip.fetchAll(db, sql: """
                        SELECT * FROM clips
                        WHERE isDeleted = 0
                          AND contentChosung IS NOT NULL
                          AND contentChosung LIKE ?
                        ORDER BY isPinned DESC, lastCopiedAt DESC
                        LIMIT 50
                        """, arguments: [pattern])
                }
            } else {
                let ftsQuery = trimmed
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .map { "\($0)*" }
                    .joined(separator: " ")
                rows = try await dbPool.read { db in
                    try Clip.fetchAll(db, sql: """
                        SELECT clips.*
                        FROM clips
                        JOIN clips_fts ON clips_fts.rowid = clips.id
                        WHERE clips_fts MATCH ?
                          AND clips.isDeleted = 0
                        ORDER BY clips.isPinned DESC, bm25(clips_fts) ASC
                        LIMIT 50
                        """, arguments: [ftsQuery])
                }
            }

            // ⭐ pending captures merge — 키보드가 방금 capture 한 클립이
            // 메인 앱 처리 전에 즉시 카드에 보이도록.
            // 빈 query 일 때만 prepend (검색 시는 DB 결과만)
            let mergedClips: [Clip]
            if trimmed.isEmpty {
                let pending = KeyboardCaptureBuffer.peekAll(
                    appGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
                )
                let pendingClips = pending.compactMap(Self.clipFromPending)
                // pending 이 더 최신 (capturedAt 내림차순) — 카드 앞쪽에
                let sortedPending = pendingClips.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
                // dedup: contentText/imageHash 같은 게 이미 DB rows 에 있으면 제외
                let dbTextSet = Set(rows.compactMap { $0.contentText })
                let dbImageHashSet = Set(rows.compactMap { $0.imageHash })
                let uniquePending = sortedPending.filter { p in
                    // 활성 필터/태그에 매칭하지 않으면 제외
                    if !self.matchesActiveFilter(p) { return false }
                    if let t = p.contentText, dbTextSet.contains(t) { return false }
                    if let h = p.imageHash, dbImageHashSet.contains(h) { return false }
                    return true
                }
                mergedClips = uniquePending + rows
            } else {
                mergedClips = rows
            }

            await MainActor.run {
                self.clips = mergedClips
                self.collectionView.reloadData()
                self.updateQueueBar()
                self.emptyStateView.isHidden = !mergedClips.isEmpty
                self.countLabel.text = self.formatCountLabel(count: mergedClips.count)
            }
        } catch {
            log.error("loadClips failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `KeyboardCaptureBuffer.PendingCapture` → `Clip`.
    /// 메인 앱이 아직 main DB 에 INSERT 하지 않은 임시 클립으로, 키보드 카드에
    /// 즉시 노출하기 위함. uuid 는 임시 — 메인 앱이 처리 시 실제 새 uuid 부여됨.
    private static func clipFromPending(_ p: KeyboardCaptureBuffer.PendingCapture) -> Clip? {
        let type = ContentType(rawValue: p.contentType) ?? .text
        let thumbnail: Data? = p.thumbnailBase64.flatMap { Data(base64Encoded: $0) }
        return Clip(
            contentType: type,
            contentText: p.contentText,
            imageHash: p.imageHash,
            thumbnail: thumbnail,
            createdAt: p.capturedAt,
            lastCopiedAt: p.capturedAt,
            uuid: "pending-\(p.capturedAt.timeIntervalSince1970)"
        )
    }

    @MainActor
    private func showFullAccessHint() {
        guard view.subviews.first(where: { $0.tag == 9999 }) == nil else { return }

        let container = UIView()
        container.tag = 9999
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let iconView = UIImageView()
        let lockCfg = UIImage.SymbolConfiguration(pointSize: 24, weight: .light)
        iconView.image = UIImage(systemName: "lock.slash", withConfiguration: lockCfg)
        iconView.tintColor = .quaternaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        let label = UILabel()
        label.text = String(localized: "'전체 접근 허용'을 활성화해주세요\n설정 → 일반 → 키보드 → ClipRaven")
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            iconView.topAnchor.constraint(equalTo: container.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Search

    private static func shouldUseChosungSearch(_ text: String) -> Bool {
        let hasChosung  = text.unicodeScalars.contains { $0.value >= 0x3131 && $0.value <= 0x314E }
        let hasFullHan  = text.unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }
        return hasChosung && !hasFullHan
    }

    // 검색 관련 메서드들은 모두 제거됨 (2026-05-04).
    // 이유: iOS 키보드 익스텐션 안 UITextField 가 first responder 되면
    // host app 텍스트필드 입력이 안 되어 검색어 입력 자체 불가능.
    // 대안: SwiftUI Link 로 메인 앱 검색 모드로 deep link.

    // MARK: - Queue

    private func updateQueueBar() {
        let hasQueue = !pasteQueue.isEmpty
        queueBar.isHidden = !hasQueue
        if hasQueue {
            pasteQueueButton.configuration?.title = String(localized: "붙여넣기 (\(pasteQueue.count))")
        }
    }

    @objc private func pasteQueueTapped() {
        let texts = pasteQueue.compactMap { $0.contentText }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return }
        textDocumentProxy.insertText(texts.joined(separator: "\n"))
        clearQueueTapped()
    }

    @objc private func clearQueueTapped() {
        pasteQueue.removeAll()
        collectionView.indexPathsForSelectedItems?.forEach {
            collectionView.deselectItem(at: $0, animated: false)
        }
        collectionView.reloadData()
        updateQueueBar()
    }

    // MARK: - Filter & Tag Menu

    /// 헤더 dropdown 메뉴 — 자주 쓰는 필터는 inline, 나머지는 submenu.
    ///
    /// 구조:
    /// - **콘텐츠 타입** (radio, inline) — 가장 자주
    /// - **태그** (multi-toggle, inline) — 자주
    /// - **날짜 / AI / 소스앱** (submenu, 접힘) — 가끔
    ///
    /// submenu 항목의 title 에 현재 선택 반영 (예: "📅 오늘 ▸") — 펼치지 않아도
    /// 활성 상태 한눈에 파악 가능.
    private func makeFilterMenu() -> UIMenu {
        var groups: [UIMenuElement] = []

        // ① 콘텐츠 타입 (inline radio)
        let typeActions = KeyboardFilter.allCases.map { f in
            UIAction(
                title: f.displayName,
                image: f.systemImage.flatMap { UIImage(systemName: $0) },
                state: f == currentFilter ? .on : .off
            ) { [weak self] _ in
                self?.currentFilter = f
                self?.applyFilterChange()
            }
        }
        groups.append(UIMenu(
            options: [.singleSelection, .displayInline],
            children: typeActions
        ))

        // ② 태그 (inline multi-toggle, 있는 경우만)
        if !availableTags.isEmpty {
            let tagActions = availableTags.map { tag -> UIAction in
                let isSelected = tag.id.map { selectedTagIds.contains($0) } ?? false
                return UIAction(
                    title: tag.name,
                    image: Self.tagDotImage(hex: tag.colorHex),
                    attributes: .keepsMenuPresented,
                    state: isSelected ? .on : .off
                ) { [weak self] _ in
                    guard let self, let tagId = tag.id else { return }
                    if self.selectedTagIds.contains(tagId) {
                        self.selectedTagIds.remove(tagId)
                    } else {
                        self.selectedTagIds.insert(tagId)
                    }
                    self.refreshFilterUI()
                    Task { await self.loadClips() }
                }
            }
            groups.append(UIMenu(
                title: String(localized: "태그"),
                options: .displayInline,
                children: tagActions
            ))
        }

        // ③ 날짜 (submenu)
        groups.append(makeDateSubmenu())

        // ④ AI 카테고리 (submenu)
        groups.append(makeAICategorySubmenu())

        // ⑤ 소스 앱 (submenu, 데이터 있을 때만)
        if !availableSourceApps.isEmpty {
            groups.append(makeSourceAppSubmenu())
        }

        return UIMenu(children: groups)
    }

    private func makeDateSubmenu() -> UIMenu {
        let actions = KeyboardDateFilter.allCases.map { d in
            UIAction(
                title: d.displayName,
                image: d.systemImage.flatMap { UIImage(systemName: $0) },
                state: d == currentDateFilter ? .on : .off
            ) { [weak self] _ in
                self?.currentDateFilter = d
                self?.applyFilterChange()
            }
        }
        let title = currentDateFilter == .all
            ? String(localized: "날짜")
            : "📅 \(currentDateFilter.displayName)"
        return UIMenu(
            title: title,
            image: UIImage(systemName: "calendar"),
            options: .singleSelection,
            children: actions
        )
    }

    private func makeAICategorySubmenu() -> UIMenu {
        let actions = KeyboardAICategory.allCases.map { c in
            UIAction(
                title: c.displayName,
                image: c.systemImage.flatMap { UIImage(systemName: $0) },
                state: c == currentAICategory ? .on : .off
            ) { [weak self] _ in
                self?.currentAICategory = c
                self?.applyFilterChange()
            }
        }
        let title = currentAICategory == .all
            ? String(localized: "AI 카테고리")
            : "🤖 \(currentAICategory.displayName)"
        return UIMenu(
            title: title,
            image: UIImage(systemName: "sparkles"),
            options: .singleSelection,
            children: actions
        )
    }

    private func makeSourceAppSubmenu() -> UIMenu {
        var actions: [UIAction] = [
            UIAction(
                title: String(localized: "전체"),
                state: currentSourceApp == nil ? .on : .off
            ) { [weak self] _ in
                self?.currentSourceApp = nil
                self?.applyFilterChange()
            }
        ]
        for app in availableSourceApps {
            actions.append(UIAction(
                title: app,
                state: currentSourceApp == app ? .on : .off
            ) { [weak self] _ in
                self?.currentSourceApp = app
                self?.applyFilterChange()
            })
        }
        let title = currentSourceApp.map { "📱 \($0)" } ?? String(localized: "소스 앱")
        return UIMenu(
            title: title,
            image: UIImage(systemName: "iphone.gen2"),
            options: .singleSelection,
            children: actions
        )
    }

    /// radio 필터(타입/날짜/AI/소스앱) 변경 후 공통 갱신.
    private func applyFilterChange() {
        refreshFilterUI()
        Task { await loadClips() }
    }

    /// 활성 필터/태그에 in-memory pending clip 이 매칭되는지.
    /// pending 은 메타가 부족하므로 (태그/AI/소스앱 정보 없음) 해당 필터 활성
    /// 시 모두 제외 — 메인 앱이 처리한 후 다음 read 시 정상 표시.
    private func matchesActiveFilter(_ clip: Clip) -> Bool {
        // 콘텐츠 타입
        switch currentFilter {
        case .all: break
        case .text:
            if clip.contentType != .text && clip.contentType != .code { return false }
        case .url:    if clip.contentType != .url { return false }
        case .image:  if clip.contentType != .image { return false }
        case .pinned: if !clip.isPinned { return false }
        }
        // 날짜
        if let cutoff = currentDateFilter.startDate, clip.createdAt < cutoff {
            return false
        }
        // AI / 태그 / 소스앱 — pending 은 정보 부족, 활성 시 제외
        if currentAICategory != .all { return false }
        if currentSourceApp != nil { return false }
        if !selectedTagIds.isEmpty { return false }
        return true
    }

    /// 필터/태그 변경 후 UI 갱신.
    private func refreshFilterUI() {
        filterButton.menu = makeFilterMenu()
        filterButton.tintColor = isAnyFilterActive ? .systemIndigo : .secondaryLabel
        countLabel.text = formatCountLabel(count: clips.count)
    }

    private var isAnyFilterActive: Bool {
        currentFilter != .all
            || currentDateFilter != .all
            || currentAICategory != .all
            || currentSourceApp != nil
            || !selectedTagIds.isEmpty
    }

    /// "12개" 또는 "12개 · 이미지 · 오늘 · 🤖 회의 · 🏷 작업 +1" 형태.
    private func formatCountLabel(count: Int) -> String {
        guard count > 0 else { return "" }
        var parts: [String] = [String(localized: "\(count)개")]
        if currentFilter != .all { parts.append(currentFilter.displayName) }
        if currentDateFilter != .all { parts.append(currentDateFilter.displayName) }
        if currentAICategory != .all { parts.append("🤖 \(currentAICategory.displayName)") }
        if let app = currentSourceApp { parts.append("📱 \(app)") }
        if !selectedTagIds.isEmpty {
            let firstTag = availableTags.first(where: {
                $0.id.map { selectedTagIds.contains($0) } ?? false
            })
            if let firstTag {
                let extra = selectedTagIds.count - 1
                parts.append(extra > 0 ? "🏷 \(firstTag.name) +\(extra)" : "🏷 \(firstTag.name)")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// 태그 색깔 dot 을 Symbol image 로. UIMenuAction 의 image 에 사용.
    private static func tagDotImage(hex: String) -> UIImage? {
        let size = CGSize(width: 16, height: 16)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let color = UIColor(hexString: hex) ?? .systemGray
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 메뉴 구성에 필요한 메타 데이터 (태그 + 소스앱) 한 번에 로드.
    /// viewDidLoad / viewWillAppear 시점에 호출.
    private func loadFilterMetadata() async {
        guard let dbPool else { return }
        let tags: [Tag] = (try? await dbPool.read { db in
            try Tag.order(Column("name").asc).fetchAll(db)
        }) ?? []
        // 자주 쓰는 소스앱 top 10 — 사용 빈도(copyCount) 기준
        let sourceApps: [String] = (try? await dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT sourceAppName FROM clips
                WHERE isDeleted = 0 AND sourceAppName IS NOT NULL
                GROUP BY sourceAppName
                ORDER BY SUM(copyCount) DESC
                LIMIT 10
                """)
        }) ?? []
        await MainActor.run {
            self.availableTags = tags
            self.availableSourceApps = sourceApps
            self.filterButton.menu = self.makeFilterMenu()
        }
    }

    // MARK: - Pasteboard auto-capture (Paste 스타일)

    /// 사용자가 다른 앱에서 복사한 새 클립을 키보드 활성화 시점에 잡아
    /// `KeyboardCaptureBuffer` 에 저장. 메인 앱이 깨어날 때 main DB 로 이관.
    ///
    /// iOS UI:
    /// - 첫 호출 시 사용자에게 "Allow paste?" 다이얼로그 표시 (iOS 16+)
    /// - 사용자 거부 시 capture 안 됨 (조용히 skip)
    ///
    /// 즉시 표시 보장: capture 직후 self.clips 에 prepend + reload — pending
    /// JSON 의 NSFileCoordinator 가 fail 해도 사용자에게 카드 즉시 노출.
    private func captureFromPasteboard() {
        let pasteboard = UIPasteboard.general

        // changeCount 비교 — 마지막 본 이후 변경 없으면 skip (다이얼로그 안 뜸)
        let currentChange = pasteboard.changeCount
        log.info("CAP changeCount=\(currentChange, privacy: .public) lastSeen=\(self.lastSeenChangeCount, privacy: .public)")
        guard currentChange != lastSeenChangeCount else {
            log.info("CAP skip — changeCount unchanged")
            return
        }
        lastSeenChangeCount = currentChange

        // Universal Clipboard remote item 은 sync 으로 어차피 받으므로 skip
        if pasteboard.contains(pasteboardTypes: ["com.apple.is-remote-clipboard"]) {
            log.info("CAP skip — Universal Clipboard remote item")
            return
        }

        // 텍스트 우선 (Mac ClipProcessor 와 동일 정책)
        if pasteboard.hasStrings, let text = pasteboard.string {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                log.info("CAP skip — empty trimmed text")
                return
            }
            let hash = String(trimmed.hashValue)
            guard !recentCapturedHashes.contains(hash) else {
                log.info("CAP skip — text dedup")
                return
            }
            recentCapturedHashes.insert(hash)
            cleanRecentHashes()

            let now = Date()
            let capture = KeyboardCaptureBuffer.PendingCapture(
                contentType: "text",
                contentText: trimmed,
                thumbnailBase64: nil,
                imageHash: nil,
                capturedAt: now,
                sourceHostBundleId: nil
            )
            KeyboardCaptureBuffer.append(
                capture,
                appGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
            )
            // 즉시 표시 — in-memory clips 에 prepend
            let tempClip = Clip(
                contentType: .text,
                contentText: trimmed,
                createdAt: now,
                lastCopiedAt: now,
                uuid: "pending-\(now.timeIntervalSince1970)"
            )
            insertPendingClipImmediate(tempClip)
            log.info("CAP captured text len=\(trimmed.count, privacy: .public)")
            return
        }

        // 이미지 — UIPasteboard.image
        if pasteboard.hasImages, let image = pasteboard.image,
           let pngData = image.pngData()
        {
            let imageHash = Self.sha256(pngData)
            guard !recentCapturedHashes.contains(imageHash) else {
                log.info("CAP skip — image dedup")
                return
            }
            recentCapturedHashes.insert(imageHash)
            cleanRecentHashes()

            let thumbnail = Self.makeThumbnail(image, maxDimension: 200)
            let thumbnailData = thumbnail.flatMap { $0.jpegData(compressionQuality: 0.7) }
            let thumbBase64 = thumbnailData?.base64EncodedString()

            let now = Date()
            let capture = KeyboardCaptureBuffer.PendingCapture(
                contentType: "image",
                contentText: nil,
                thumbnailBase64: thumbBase64,
                imageHash: imageHash,
                capturedAt: now,
                sourceHostBundleId: nil
            )
            KeyboardCaptureBuffer.append(
                capture,
                appGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
            )
            // 즉시 표시 — thumbnail 포함한 임시 image 클립 prepend
            let tempClip = Clip(
                contentType: .image,
                imageHash: imageHash,
                thumbnail: thumbnailData,
                createdAt: now,
                lastCopiedAt: now,
                uuid: "pending-\(now.timeIntervalSince1970)"
            )
            insertPendingClipImmediate(tempClip)
            log.info("CAP captured image hash=\(imageHash.prefix(12), privacy: .public)")
        }
    }

    /// capture 한 클립을 self.clips 에 prepend 하고 collection view 즉시 reload.
    /// pending JSON 저장과 별개 백업 — NSFileCoordinator 동작 여부 무관하게
    /// 사용자에게 카드 즉시 노출.
    ///
    /// 활성 필터/태그에 안 맞으면 prepend 안 함 (예: 이미지 필터인데 텍스트
    /// capture 시) — 사용자 인지 일관성 유지.
    @MainActor
    private func insertPendingClipImmediate(_ clip: Clip) {
        // 활성 필터에 안 맞으면 표시하지 않음 (capture 자체는 pending JSON 에
        // 저장됨 — 필터 해제 시 정상 표시).
        guard matchesActiveFilter(clip) else { return }

        // 같은 uuid prefix 또는 contentText 가 이미 있으면 skip (race 방지)
        if let text = clip.contentText, clips.contains(where: { $0.contentText == text }) {
            return
        }
        if let hash = clip.imageHash, clips.contains(where: { $0.imageHash == hash }) {
            return
        }
        clips.insert(clip, at: 0)
        collectionView.reloadData()
        emptyStateView.isHidden = !clips.isEmpty
        countLabel.text = formatCountLabel(count: clips.count)
    }

    /// in-memory hash cache — 30개 넘으면 가장 오래된 것 제거 (LRU 근사).
    private func cleanRecentHashes() {
        if recentCapturedHashes.count > 30 {
            recentCapturedHashes.removeAll()
        }
    }

    private static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeThumbnail(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxDimension else { return image }
        let scale = maxDimension / longSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Insert

    /// 카드 탭 시 클립 paste.
    ///
    /// iOS 키보드 익스텐션의 본질적 한계:
    /// - `UITextDocumentProxy.insertText` 는 **텍스트만** insert 가능
    /// - 이미지는 host app 의 textfield 에 직접 못 넣음
    /// - 우회: `UIPasteboard.image` 설정 → 사용자가 입력란에서 길게 누르고
    ///   "붙여넣기" 수동 액션 (Paste 같은 경쟁사도 동일 패턴)
    ///
    /// 메신저/메일/노트 등 대부분 host app 이 이미지 paste 받음.
    private func insertClip(_ clip: Clip) {
        // 이미지 클립
        if clip.contentType == .image {
            // 1순위: imagePath 의 원본 (Phase C)
            // 2순위: thumbnail
            let image: UIImage? = {
                if let relPath = clip.imagePath,
                   let img = Self.loadImageFromAppGroup(relativePath: relPath) {
                    return img
                }
                if let data = clip.thumbnail, let img = UIImage(data: data) {
                    return img
                }
                return nil
            }()
            guard let image else {
                showToast(String(localized: "이미지를 불러올 수 없습니다"))
                return
            }
            UIPasteboard.general.image = image
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showToast(String(localized: "이미지 복사됨 — 입력란을 길게 눌러 붙여넣기"))
            return
        }

        // 텍스트/URL/.file 등 — contentText 직접 insert
        guard let text = clip.contentText, !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
    }

    /// App Group `ClipRaven/images/` 디렉터리에서 PNG/JPEG 로드.
    /// 메인 앱의 `ImageStorageService` 와 같은 경로 규약. 키보드 익스텐션은
    /// 별도 target 이라 직접 import 못 하므로 inline.
    private static func loadImageFromAppGroup(relativePath: String) -> UIImage? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.lumibear.ClipRavenMobile"
        ) else { return nil }
        let fileURL = containerURL
            .appendingPathComponent("ClipRaven/images", isDirectory: true)
            .appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Toast

    /// 키보드 영역 가운데에 짧은 안내 메시지 표시. ~2초 후 자동 사라짐.
    private func showToast(_ message: String) {
        // 기존 토스트가 있으면 제거
        view.subviews.filter { $0.tag == 7777 }.forEach { $0.removeFromSuperview() }

        let label = PaddedLabel()
        label.tag = 7777
        label.text = message
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        label.alpha = 0
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak label] in
            UIView.animate(withDuration: 0.3, animations: {
                label?.alpha = 0
            }) { _ in
                label?.removeFromSuperview()
            }
        }
    }
}

/// 텍스트에 가로/세로 padding 가진 UILabel.
private final class PaddedLabel: UILabel {
    let padding = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: padding))
    }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + padding.left + padding.right,
                      height: s.height + padding.top + padding.bottom)
    }
}

// MARK: - Collection data source / delegate / flow layout

extension KeyboardViewController: UICollectionViewDataSource, UICollectionViewDelegate,
                                   UICollectionViewDelegateFlowLayout {

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        clips.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(
            withReuseIdentifier: ClipCardCell.reuseID,
            for: indexPath
        ) as! ClipCardCell
        let clip = clips[indexPath.item]
        let queueIndex = pasteQueue.firstIndex { $0.id == clip.id }
        cell.configure(with: clip, queueIndex: queueIndex.map { $0 + 1 })
        if queueIndex != nil { cv.selectItem(at: indexPath, animated: false, scrollPosition: []) }
        return cell
    }

    /// 카드 크기 — 너비 고정, 높이는 collectionView 높이에 맞춤.
    func collectionView(
        _ cv: UICollectionView,
        layout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let h = max(cv.bounds.height - 2, 100)
        return CGSize(width: KeyboardViewController.cardWidth, height: h)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let clip = clips[indexPath.item]
        if pasteQueue.isEmpty {
            insertClip(clip)
            cv.deselectItem(at: indexPath, animated: true)
        } else {
            if !pasteQueue.contains(where: { $0.id == clip.id }) {
                pasteQueue.append(clip)
            }
            updateQueueBar()
            cv.reloadItems(at: [indexPath])
        }
    }

    func collectionView(_ cv: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        let clip = clips[indexPath.item]
        pasteQueue.removeAll { $0.id == clip.id }
        updateQueueBar()
        cv.reloadItems(at: [indexPath])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if collectionView.gestureRecognizers?.contains(where: { $0 is UILongPressGestureRecognizer }) == false {
            let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            lp.minimumPressDuration = 0.4
            collectionView.addGestureRecognizer(lp)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let indexPath = collectionView.indexPathForItem(at: gesture.location(in: collectionView))
        else { return }
        let clip = clips[indexPath.item]
        if !pasteQueue.contains(where: { $0.id == clip.id }) {
            pasteQueue.append(clip)
            collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
            updateQueueBar()
            collectionView.reloadItems(at: [indexPath])
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}

// MARK: - Filter enums

/// 키보드 헤더 dropdown 메뉴의 콘텐츠 타입 필터.
enum KeyboardFilter: String, CaseIterable {
    case all, text, url, image, pinned

    var displayName: String {
        switch self {
        case .all: return String(localized: "전체")
        case .text: return String(localized: "텍스트")
        case .url: return "URL"
        case .image: return String(localized: "이미지")
        case .pinned: return String(localized: "핀 고정")
        }
    }

    var systemImage: String? {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "doc.text"
        case .url: return "link"
        case .image: return "photo"
        case .pinned: return "pin.fill"
        }
    }

    var sqlCondition: String {
        switch self {
        case .all: return ""
        case .text: return "contentType IN ('text', 'code')"
        case .url: return "contentType = 'url'"
        case .image: return "contentType = 'image'"
        case .pinned: return "isPinned = 1"
        }
    }
}

/// 날짜 범위 필터.
enum KeyboardDateFilter: String, CaseIterable {
    case all, today, thisWeek, thisMonth

    var displayName: String {
        switch self {
        case .all: return String(localized: "전체 기간")
        case .today: return String(localized: "오늘")
        case .thisWeek: return String(localized: "이번 주")
        case .thisMonth: return String(localized: "이번 달")
        }
    }

    var systemImage: String? {
        switch self {
        case .all: return "calendar"
        case .today: return "sun.max"
        case .thisWeek: return "calendar.badge.clock"
        case .thisMonth: return "calendar.circle"
        }
    }

    /// SQL 의 `lastCopiedAt >= startDate` 비교용. nil = 조건 추가 없음.
    var startDate: Date? {
        let cal = Calendar.current
        switch self {
        case .all: return nil
        case .today: return cal.startOfDay(for: Date())
        case .thisWeek:
            return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
        case .thisMonth:
            return cal.date(from: cal.dateComponents([.year, .month], from: Date()))
        }
    }
}

/// AI 카테고리 필터. Mac 의 Foundation Models 가 자동 분류 — sync 로 iOS 도착.
enum KeyboardAICategory: String, CaseIterable {
    case all
    case receipt, meeting, code, phone, email, address, link, other

    var displayName: String {
        switch self {
        case .all: return String(localized: "전체")
        case .receipt: return String(localized: "영수증")
        case .meeting: return String(localized: "회의")
        case .code: return String(localized: "코드")
        case .phone: return String(localized: "전화")
        case .email: return String(localized: "이메일")
        case .address: return String(localized: "주소")
        case .link: return String(localized: "링크")
        case .other: return String(localized: "기타")
        }
    }

    var systemImage: String? {
        switch self {
        case .all: return "sparkles"
        case .receipt: return "receipt"
        case .meeting: return "person.2"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .phone: return "phone"
        case .email: return "envelope"
        case .address: return "mappin"
        case .link: return "link"
        case .other: return "questionmark.circle"
        }
    }

    /// SQL 의 aiCategory 컬럼과 비교할 값.
    var sqlValue: String? {
        self == .all ? nil : rawValue
    }
}

// MARK: - UIColor hex

private extension UIColor {
    convenience init?(hexString: String) {
        var hex = hexString.uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8) & 0xFF) / 255
        let b = CGFloat(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - SwiftUI 검색 Link

/// 키보드 헤더 우측의 🔍 검색 아이콘. SwiftUI `Link` 가 OS 의 `openURL`
/// action 을 트리거 — iOS 18+ 키보드 익스텐션의 직접 앱 실행 차단을 우회.
/// `clipraven://search` → 메인 앱 검색 모드 진입.
struct KeyboardSearchLink: View {
    var body: some View {
        Link(destination: URL(string: "clipraven://search")!) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Card Cell

/// Paste 스타일 카드 셀.
/// - 이미지 클립: 썸네일이 카드를 꽉 채우고 그라디언트 오버레이 위에 텍스트.
/// - 텍스트/URL 클립: 어두운(라이트에선 밝은) 카드 배경 위에 텍스트 미리보기.
private final class ClipCardCell: UICollectionViewCell {
    static let reuseID = "ClipCardCell"

    // Layers / views
    private let thumbnailView = UIImageView()
    private let gradientLayer = CAGradientLayer()
    private let topRow = UIView()
    private let typeIconView = UIImageView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let sourceAppLabel = UILabel()
    private let previewLabel = UILabel()
    private let pinIconView = UIImageView()
    private let badgeView = UIView()
    private let badgeLabel = UILabel()

    override var isSelected: Bool { didSet { updateSelectionStyle() } }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Card shape
        contentView.layer.cornerRadius = 14
        contentView.layer.masksToBounds = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.masksToBounds = false

        // ① Thumbnail (image clips)
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnailView)

        // ② Gradient overlay (bottom-to-top dark → clear)
        gradientLayer.colors = [
            UIColor.black.withAlphaComponent(0.6).cgColor,
            UIColor.clear.cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradientLayer.endPoint   = CGPoint(x: 0.5, y: 0.3)
        contentView.layer.addSublayer(gradientLayer)

        // ③ Top row: type icon + title + time label
        topRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topRow)

        typeIconView.contentMode = .scaleAspectFit
        typeIconView.tintColor = .white
        typeIconView.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(typeIconView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(titleLabel)

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        timeLabel.textAlignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        topRow.addSubview(timeLabel)

        // ④ Source app name (소형, top row 아래)
        sourceAppLabel.font = .systemFont(ofSize: 10)
        sourceAppLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        sourceAppLabel.numberOfLines = 1
        sourceAppLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceAppLabel.isHidden = true
        contentView.addSubview(sourceAppLabel)

        // ⑤ Text preview (카드 중앙~하단)
        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.textColor = .white
        previewLabel.numberOfLines = 6
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewLabel)

        // ⑥ Pin icon (우하단)
        let pinCfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        pinIconView.image = UIImage(systemName: "pin.fill", withConfiguration: pinCfg)
        pinIconView.tintColor = UIColor.white.withAlphaComponent(0.8)
        pinIconView.contentMode = .scaleAspectFit
        pinIconView.translatesAutoresizingMaskIntoConstraints = false
        pinIconView.isHidden = true
        contentView.addSubview(pinIconView)

        // ⑦ Queue order badge (카드 중앙 오버레이)
        badgeView.backgroundColor = .systemIndigo
        badgeView.layer.cornerRadius = 16
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.isHidden = true
        contentView.addSubview(badgeView)

        badgeLabel.font = .systemFont(ofSize: 16, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            // Thumbnail — fills card
            thumbnailView.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Top row — inset 10pt from edges, 10pt from top
            topRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            topRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            topRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            topRow.heightAnchor.constraint(equalToConstant: 18),

            typeIconView.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
            typeIconView.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            typeIconView.widthAnchor.constraint(equalToConstant: 14),
            typeIconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: typeIconView.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -4),

            timeLabel.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            timeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 36),

            // Source app label — directly below top row
            sourceAppLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 2),
            sourceAppLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            sourceAppLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),

            // Text preview — from source label (or below top row) to pin area
            previewLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 18),
            previewLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            previewLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -28),

            // Pin icon — bottom-right
            pinIconView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            pinIconView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            pinIconView.widthAnchor.constraint(equalToConstant: 14),
            pinIconView.heightAnchor.constraint(equalToConstant: 14),

            // Queue badge — centered on card
            badgeView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            badgeView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badgeView.widthAnchor.constraint(equalToConstant: 32),
            badgeView.heightAnchor.constraint(equalToConstant: 32),
            badgeLabel.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
        ])

        updateSelectionStyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = contentView.bounds
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with clip: Clip, queueIndex: Int?) {
        // ─── Content type icon ───────────────────────────────────
        let iconName: String
        switch clip.contentType {
        case .url:   iconName = "link"
        case .image: iconName = "photo"
        default:     iconName = "doc.text"
        }
        let iconCfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        typeIconView.image = UIImage(systemName: iconName, withConfiguration: iconCfg)

        // ─── Image thumbnail ─────────────────────────────────────
        if clip.contentType == .image, let data = clip.thumbnail,
           let image = UIImage(data: data) {
            thumbnailView.image = image
            thumbnailView.isHidden = false
            gradientLayer.isHidden = false
            contentView.backgroundColor = .black
            // 이미지 카드: 텍스트를 흰색으로
            setTextColors(.white, alpha70: UIColor.white.withAlphaComponent(0.7))
        } else {
            thumbnailView.image = nil
            thumbnailView.isHidden = true
            gradientLayer.isHidden = true
            contentView.backgroundColor = KeyboardViewController.cardBackgroundColor
            // 텍스트 카드: trait-aware color
            setTextColors(.label, alpha70: .secondaryLabel)
            typeIconView.tintColor = clip.isPinned ? .systemIndigo : .tertiaryLabel
        }

        // ─── Title (nickname > ogTitle > contentType) ────────────
        let title = clip.nickname?.nilIfEmpty
            ?? clip.ogTitle?.nilIfEmpty
            ?? clip.contentType.rawValue
        titleLabel.text = title

        // ─── Time ago ────────────────────────────────────────────
        timeLabel.text = relativeTime(from: clip.lastCopiedAt)

        // ─── Source app ──────────────────────────────────────────
        if let appName = clip.sourceAppName?.nilIfEmpty {
            sourceAppLabel.text = appName
            sourceAppLabel.isHidden = false
        } else {
            sourceAppLabel.isHidden = true
        }

        // ─── Text preview ────────────────────────────────────────
        previewLabel.text = clip.contentText.map { String($0.prefix(200)) }

        // ─── Pin ─────────────────────────────────────────────────
        pinIconView.isHidden = !clip.isPinned || queueIndex != nil

        // ─── Queue badge ─────────────────────────────────────────
        if let idx = queueIndex {
            badgeLabel.text = "\(idx)"
            badgeView.isHidden = false
        } else {
            badgeView.isHidden = true
        }

        updateSelectionStyle()
    }

    private func setTextColors(_ primary: UIColor, alpha70 secondary: UIColor) {
        typeIconView.tintColor = primary
        titleLabel.textColor   = primary
        timeLabel.textColor    = secondary
        sourceAppLabel.textColor = secondary
        previewLabel.textColor = primary
    }

    private func updateSelectionStyle() {
        contentView.layer.borderWidth = isSelected ? 2.0 : 0
        contentView.layer.borderColor = isSelected ? UIColor.systemIndigo.cgColor : UIColor.clear.cgColor

        // 선택 시 약한 어두운 오버레이 (별도 layer 없이 alpha로 처리)
        contentView.alpha = isSelected ? 0.85 : 1.0
    }

    // MARK: - Helpers

    private func relativeTime(from date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60    { return String(localized: "방금") }
        if secs < 3600  { return String(localized: "\(secs / 60)분") }
        if secs < 86400 { return String(localized: "\(secs / 3600)시간") }
        let days = secs / 86400
        if days < 7     { return String(localized: "\(days)일") }
        return String(localized: "\(days / 7)주")
    }
}

// MARK: - Empty State

final class KeyboardEmptyStateView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)

        let iconView = UIImageView()
        let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .light)
        iconView.image = UIImage(systemName: "clipboard", withConfiguration: cfg)
        iconView.tintColor = .quaternaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let label = UILabel()
        label.text = String(localized: "복사한 클립이 없습니다")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
