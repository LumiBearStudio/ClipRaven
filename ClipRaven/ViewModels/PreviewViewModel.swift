import Foundation
import Combine
import ClipRavenSync

@MainActor
final class PreviewViewModel: ObservableObject {
    @Published var selectedClip: Clip?
    @Published var isShowingPreview = false

    private let clipRepository = ClipRepository()

    func showPreview(for clip: Clip) {
        selectedClip = clip
        isShowingPreview = true
    }

    func hidePreview() {
        isShowingPreview = false
        selectedClip = nil
    }

    func togglePreview(for clip: Clip) {
        if isShowingPreview && selectedClip?.id == clip.id {
            hidePreview()
        } else {
            showPreview(for: clip)
        }
    }

    func updateClip(_ clip: Clip) {
        try? clipRepository.update(clip)
        selectedClip = clip
    }

    func togglePin() {
        guard let clip = selectedClip, let id = clip.id else { return }
        try? clipRepository.togglePin(id: id)
        var updated = clip
        updated.isPinned.toggle()
        selectedClip = updated
    }
}
