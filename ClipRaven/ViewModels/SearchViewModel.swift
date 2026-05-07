import Foundation
import Combine
import ClipRavenSync

struct SearchResult: Identifiable {
    var id: Int64? { clip.id }
    let clip: Clip
    let snippet: String
}

/// A "Did you mean?" offer shown below the empty search results when the
/// user likely typed the query with the wrong keyboard layout. Produced
/// by `KeyboardLayoutRecoverer` implementations and populated only when
/// (a) the original query found zero clips AND (b) a decoded alternate
/// query finds at least one. Both gates must hold or we show nothing —
/// silence beats a bad suggestion.
struct SearchRecoverySuggestion: Equatable {
    let originalQuery: String
    let suggestedQuery: String
    let resultCount: Int
    let language: String
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var contentTypeFilter: ContentType?
    @Published var results: [SearchResult] = []
    @Published var isSearching = false
    @Published var recentSearches: [String] = []
    /// Non-nil only when the current search returned 0 results AND a
    /// keyboard-layout-decoded alternate query returned >0.
    @Published var recoverySuggestion: SearchRecoverySuggestion?

    private let searchRepository = SearchRepository()
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private static let recentSearchesKey = "recentSearches"

    init() {
        loadRecentSearches()

        // Debounced search
        $query
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.performSearch(query)
            }
            .store(in: &cancellables)
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            recoverySuggestion = nil
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            defer { isSearching = false }

            do {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

                // Check if chosung-only query
                if ChosungConverter.isChosungOnly(trimmed) {
                    let clips = try searchRepository.searchChosung(query: trimmed)
                    guard !Task.isCancelled else { return }
                    results = clips.map { SearchResult(clip: $0, snippet: "") }
                } else {
                    let searchResults = try searchRepository.searchWithSnippet(
                        query: trimmed,
                        limit: 50
                    )
                    guard !Task.isCancelled else { return }
                    results = searchResults.map { SearchResult(clip: $0.clip, snippet: $0.snippet) }
                }

                // Keyboard-layout recovery: only when the primary search
                // returned nothing. If an alternate layout decodes the
                // query into a form that does find results, surface it
                // as a "Did you mean?" banner. Silence if decode fails
                // or the alternate also returns zero — avoiding bad
                // suggestions is more important than catching every
                // possible mistake.
                if results.isEmpty {
                    recoverySuggestion = try findRecoverySuggestion(for: trimmed)
                } else {
                    recoverySuggestion = nil
                }

                // Save to recent searches
                saveRecentSearch(trimmed)
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                recoverySuggestion = nil
                ClipRavenLog.search.error("Search failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Try every registered keyboard-layout recoverer. The first one
    /// whose decoded query produces real hits wins. Returns nil if none
    /// of them yield anything — in that case no banner is shown.
    private func findRecoverySuggestion(for query: String) throws -> SearchRecoverySuggestion? {
        for recoverer in LayoutRecoveryRegistry.recoverers {
            let alternates = [
                recoverer.decodeLatinToNative(query),
                recoverer.decodeNativeToLatin(query),
            ]
            for alt in alternates {
                guard let alt, alt != query, !alt.isEmpty else { continue }
                let altResults: [Clip]
                if ChosungConverter.isChosungOnly(alt) {
                    altResults = try searchRepository.searchChosung(query: alt)
                } else {
                    altResults = try searchRepository
                        .searchWithSnippet(query: alt, limit: 50)
                        .map { $0.clip }
                }
                guard !altResults.isEmpty else { continue }
                return SearchRecoverySuggestion(
                    originalQuery: query,
                    suggestedQuery: alt,
                    resultCount: altResults.count,
                    language: recoverer.language
                )
            }
        }
        return nil
    }

    /// Accept a suggestion — replaces the query text and lets the
    /// normal debounce + search flow re-run with the decoded form.
    func acceptRecoverySuggestion() {
        guard let s = recoverySuggestion else { return }
        query = s.suggestedQuery
    }

    private func saveRecentSearch(_ term: String) {
        var recent = recentSearches
        recent.removeAll { $0 == term }
        recent.insert(term, at: 0)
        if recent.count > 10 { recent = Array(recent.prefix(10)) }
        recentSearches = recent
        UserDefaults.standard.set(recent, forKey: Self.recentSearchesKey)
    }

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? []
    }
}
