import SwiftUI
import ClipRavenSync

struct SearchModalView: View {
    @StateObject private var viewModel = SearchViewModel()
    @Binding var isPresented: Bool
    var onClipSelected: (Clip) -> Void = { _ in }

    var body: some View {
        ZStack {
            // Blur overlay
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                // Search input
                SearchInputView(
                    query: $viewModel.query,
                    selectedFilter: $viewModel.contentTypeFilter
                )

                Divider()

                // Results
                if viewModel.query.isEmpty {
                    recentSection
                } else {
                    resultsSection
                }
            }
            .frame(width: 500, height: 360)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20)
        }
        .onExitCommand { isPresented = false }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("최근 검색")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if viewModel.recentSearches.isEmpty {
                Spacer()
                Text("검색 기록이 없습니다")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(viewModel.recentSearches, id: \.self) { term in
                    Button(action: { viewModel.query = term }) {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(.secondary)
                            Text(term)
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Result count
            HStack {
                Text("\(viewModel.results.count)개 결과")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if viewModel.isSearching {
                    ProgressView()
                        .scaleEffect(0.5)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // "Did you mean?" — only rendered when results are empty AND
            // a keyboard-layout-decoded alternate found something.
            if viewModel.results.isEmpty, let suggestion = viewModel.recoverySuggestion {
                SearchSuggestionBannerView(suggestion: suggestion) {
                    viewModel.acceptRecoverySuggestion()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // Results list
            List(viewModel.results, id: \.clip.id) { result in
                SearchResultRow(clip: result.clip, snippet: result.snippet)
                    .onTapGesture {
                        onClipSelected(result.clip)
                        isPresented = false
                    }
            }
            .listStyle(.plain)
        }
    }
}

/// "Did you mean 'XX'? N results" banner. Google-style soft prompt —
/// user already knows the pattern and we avoid surprising them with
/// auto-replacement.
struct SearchSuggestionBannerView: View {
    let suggestion: SearchRecoverySuggestion
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    // "혹시 'XX'를 찾으셨나요?"
                    (Text(String(localized: "search.didyoumean.prefix")) +
                     Text("'\(suggestion.suggestedQuery)'").bold() +
                     Text(String(localized: "search.didyoumean.suffix")))
                        .font(.system(size: 12))
                    Text(String(
                        format: String(localized: "search.suggestion.count"),
                        suggestion.resultCount
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.yellow.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(
            format: String(localized: "search.didyoumean.a11y"),
            suggestion.suggestedQuery,
            suggestion.resultCount
        ))
    }
}
