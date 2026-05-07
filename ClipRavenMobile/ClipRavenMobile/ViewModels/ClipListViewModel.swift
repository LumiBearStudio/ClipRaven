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
        Task {
            do {
                let results: [Clip]
                if ChosungConverter.shouldUseChosungSearch(query) {
                    results = try repository.searchChosung(
                        query: query,
                        contentType: selectedFilter,
                        tagIds: selectedTagIds,
                        sourceApp: selectedSourceApp,
                        dateRange: selectedDateRange,
                        aiCategory: selectedAICategory
                    )
                } else {
                    results = try repository.search(
                        query: query,
                        contentType: selectedFilter,
                        tagIds: selectedTagIds,
                        sourceApp: selectedSourceApp,
                        dateRange: selectedDateRange,
                        aiCategory: selectedAICategory
                    )
                }
                await MainActor.run { self.clips = results }
            } catch {
                log.error("search failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Tags

    func loadSourceApps() {
        Task {
            let apps = (try? repository.fetchSourceApps()) ?? []
            await MainActor.run { self.availableSourceApps = apps }
        }
    }

    func loadTags() {
        Task {
            do {
                let all = try tagRepository.fetchAll()
                await MainActor.run { self.tags = all }
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
        Task {
            var counts: [ContentType?: Int] = [:]
            counts[nil] = (try? repository.count()) ?? 0
            for type in ContentType.allCases {
                counts[type] = (try? repository.count(contentType: type)) ?? 0
            }
            await MainActor.run { self.filterCounts = counts }
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
                try await AppDatabase.shared.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE clips SET nickname = ?, updatedAt = ? WHERE uuid = ?",
                        arguments: [nickname, Date(), clip.uuid ?? ""]
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
        Task {
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
