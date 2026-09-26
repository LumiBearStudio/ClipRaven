import Foundation
import SwiftUI
import GRDB
import Combine
import os.log
import ClipRavenSync

@MainActor
final class ClipListViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var clips: [Clip] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var filterCounts: [ContentType?: Int] = [:]

    // 검색
    @Published var searchQuery: String = "" {
        didSet { onSearchQueryChanged() }
    }

    // 콘텐츠 타입 필터 (nil = 전체)
    @Published var selectedFilter: ContentType? = nil {
        didSet { restartObservation() }
    }

    // 태그 필터
    @Published var selectedTagIds: Set<Int64> = [] {
        didSet { restartObservation() }
    }

    // 소스 앱 필터
    @Published var selectedSourceApp: String? = nil {
        didSet { restartObservation() }
    }
    @Published private(set) var availableSourceApps: [String] = []

    // 날짜 범위 필터
    @Published var selectedDateRange: DateRangeFilter? = nil {
        didSet { restartObservation() }
    }

    /// AI 카테고리 필터 (Mac 의 Foundation Models 가 자동 분류한 카테고리).
    /// iOS 단독 사용자에겐 sync 받은 클립만 카테고리 가짐.
    /// 값: "receipt"/"meeting"/"code"/"phone"/"email"/"address"/"link"/"other"
    @Published var selectedAICategory: String? = nil {
        didSet { restartObservation() }
    }

    // MARK: - Private

    private let repository: ClipRepository
    private let tagRepository: TagRepository
    private let log = Logger(subsystem: "com.lumibear.ClipRavenMobile", category: "ClipListVM")

    private var observation: AnyDatabaseCancellable?
    private var searchCancellable: AnyCancellable?
    /// 진행 중인 검색. 새 검색이나 검색어 삭제 시 취소한다 — 느린 초성 검색이
    /// 나중에 끝나며 새 결과를 덮어쓰는 것을 막는다 (v1 리뷰 G9).
    private var searchTask: Task<Void, Never>?

    init(
        repository: ClipRepository = ClipRepository(),
        tagRepository: TagRepository = TagRepository()
    ) {
        self.repository = repository
        self.tagRepository = tagRepository
        restartObservation()
        loadTags()
        updateCounts()
        loadSourceApps()
    }

    deinit {
        observation?.cancel()
    }

    // MARK: - Observation

    private func restartObservation() {
        // 검색 중엔 observation 대신 FTS 결과 사용
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        observation?.cancel()
        observation = repository.observeAll(
            contentType: selectedFilter,
            tagIds: selectedTagIds,
            sourceApp: selectedSourceApp,
            dateRange: selectedDateRange,
            aiCategory: selectedAICategory
        ) { [weak self] rows in
            Task { @MainActor [weak self] in
                self?.clips = rows
                self?.updateCounts()
                self?.loadSourceApps()
            }
        }
    }

    // MARK: - Search

    private func onSearchQueryChanged() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 200ms 뒤에 발화할 검색과 진행 중인 검색을 모두 취소한다. 이전에는
            // 검색어를 지운 뒤에도 대기 중이던 검색이 결과를 덮어썼다.
            searchCancellable?.cancel()
            searchTask?.cancel()
            restartObservation()
            return
        }

        // debounce 200ms
        searchCancellable?.cancel()
        searchCancellable = Just(trimmed)
            .delay(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.performSearch(query)
            }
    }

    private func performSearch(_ query: String) {
        // 필터 상태를 먼저 값으로 읽어 넘긴다 (MainActor 소유).
        let filter = selectedFilter
        let tagIds = selectedTagIds
        let sourceApp = selectedSourceApp
        let dateRange = selectedDateRange
        let aiCategory = selectedAICategory

        // B-B3 와 같은 이유로 detached: 이 클래스는 @MainActor 라 `Task { }` 는
        // 격리를 상속해 동기 DB 검색이 메인 스레드에서 돌았다. 바로 아래
        // loadTags/updateCounts 는 이미 고쳐져 있었는데 검색 경로만 남아 있었다
        // (감사 F2). 확장이 write 락을 쥐고 있으면 busyTimeout 5초까지 UI 가
        // 그대로 멈춘다.
        searchTask?.cancel()
        searchTask = Task.detached(priority: .userInitiated) { [repository, log] in
            do {
                let results: [Clip]
                if ChosungConverter.shouldUseChosungSearch(query) {
                    results = try repository.searchChosung(
                        query: query,
                        contentType: filter,
                        tagIds: tagIds,
                        sourceApp: sourceApp,
                        dateRange: dateRange,
                        aiCategory: aiCategory
                    )
                } else {
                    results = try repository.search(
                        query: query,
                        contentType: filter,
                        tagIds: tagIds,
                        sourceApp: sourceApp,
                        dateRange: dateRange,
                        aiCategory: aiCategory
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    // 느린 검색(초성 LIKE)이 늦게 끝나 새 검색어의 결과를 덮어쓰지
                    // 않도록, 그 사이 검색어가 바뀌었으면 버린다 (v1 리뷰 G9).
                    guard let self, !Task.isCancelled,
                          self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
                    else { return }
                    self.clips = results
                }
            } catch {
                log.error("search failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Tags

    // 품질 감사 B-B3: `Task { }` 가 @MainActor 격리를 inherit 해 DB 호출이
    // main thread 위에서 직렬 실행됐다. Task.detached + repository 캡처로 격리.

    func loadSourceApps() {
        Task.detached(priority: .userInitiated) { [repository] in
            let apps = (try? repository.fetchSourceApps()) ?? []
            await MainActor.run { [weak self] in self?.availableSourceApps = apps }
        }
    }

    func loadTags() {
        Task.detached(priority: .userInitiated) { [tagRepository, log] in
            do {
                let all = try tagRepository.fetchAll()
                await MainActor.run { [weak self] in self?.tags = all }
            } catch {
                log.error("loadTags failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func toggleTagFilter(_ tagId: Int64) {
        if selectedTagIds.contains(tagId) {
            selectedTagIds.remove(tagId)
        } else {
            selectedTagIds.insert(tagId)
        }
    }

    func createTag(name: String, colorHex: String) async {
        do {
            _ = try tagRepository.create(name: name, colorHex: colorHex)
            loadTags()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTag(id: Int64) async {
        do {
            try tagRepository.delete(id: id)
            selectedTagIds.remove(id)
            loadTags()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Filter counts

    func updateCounts() {
        Task.detached(priority: .userInitiated) { [repository] in
            var counts: [ContentType?: Int] = [:]
            counts[nil] = (try? repository.count()) ?? 0
            for type in ContentType.allCases {
                counts[type] = (try? repository.count(contentType: type)) ?? 0
            }
            await MainActor.run { [weak self] in self?.filterCounts = counts }
        }
    }

    // MARK: - Sync / Refresh

    func refreshAwaiting() async {
        isLoading = true
        defer { isLoading = false }
        NotificationCenter.default.post(name: .clipRavenSyncRefreshRequested, object: nil)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        loadTags()
        updateCounts()
    }

    func refresh() {
        Task { await refreshAwaiting() }
    }

    // MARK: - CRUD

    func addTextClip(text: String, nickname: String?) async {
        errorMessage = nil
        do {
            var clip = try repository.insert(text: text)
            if let nickname, !nickname.isEmpty {
                clip.nickname = nickname
                // v14 LWW: nicknameUpdatedAt 도 함께 갱신해 다른 device 의
                // stale nickname 이 이걸 덮어쓰지 않게.
                let now = Date()
                try await AppDatabase.shared.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE clips SET nickname = ?, nicknameUpdatedAt = ?, updatedAt = ? WHERE uuid = ?",
                        arguments: [nickname, now, now, clip.uuid ?? ""]
                    )
                }
            }
            updateCounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteClip(_ clip: Clip) async {
        guard let uuid = clip.uuid else { return }
        do {
            try repository.softDelete(uuid: uuid)
            updateCounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePin(_ clip: Clip) async {
        guard let uuid = clip.uuid else { return }
        do {
            try repository.togglePin(uuid: uuid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `excludeFromSync` 플래그를 토글. SyncChangeCapture가 이 변경을 감지해
    /// 해당 클립의 업로드 여부를 다음 sync 사이클부터 반영.
    func toggleExcludeFromSync(_ clip: Clip) async {
        guard let uuid = clip.uuid else { return }
        do {
            try repository.toggleExcludeFromSync(uuid: uuid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bumpCopyCount(_ clip: Clip) {
        guard let id = clip.id else { return }
        // B-B3: Task { } inherit @MainActor → DB write on main. Detached.
        Task.detached(priority: .utility) { [repository] in
            try? repository.incrementCopyCount(id: id)
        }
    }

    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let clipRavenSyncRefreshRequested = Notification.Name("clipRavenSyncRefreshRequested")
}
