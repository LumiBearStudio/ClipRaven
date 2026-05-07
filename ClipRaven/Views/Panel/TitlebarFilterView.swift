import SwiftUI

struct TitlebarFilterView: View {
    @ObservedObject var viewModel: MainPanelViewModel

    var body: some View {
        FilterBarView(
            selectedFilter: $viewModel.selectedFilter,
            showPinned: $viewModel.showPinned,
            selectedTagIds: $viewModel.selectedTagIds,
            selectedSourceApp: $viewModel.selectedSourceApp,
            dateRangeFilter: $viewModel.dateRangeFilter,
            selectedAICategory: $viewModel.selectedAICategory,
            counts: viewModel.filterCounts,
            tags: viewModel.boards,
            availableSourceApps: viewModel.availableSourceApps,
            clipCount: viewModel.clips.count,
            searchText: $viewModel.searchText,
            onCreateTag: { name, colorHex in
                viewModel.createTag(name: name, colorHex: colorHex)
            },
            onDeleteTag: { id in
                viewModel.deleteTag(id: id)
            },
            onUpdateTag: { id, name, colorHex in
                viewModel.updateTag(id: id, name: name, colorHex: colorHex)
            }
        )
    }
}
