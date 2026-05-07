import AppIntents
import Foundation
import ClipRavenSync

/// Returns the most recently copied clip as a `ClipEntity`.
/// No parameters. Read-only — safe to run from any context.
struct GetLatestClipIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Clip"
    static var description = IntentDescription(
        "Returns the most recently copied clip from ClipRaven.",
        categoryName: "ClipRaven"
    )

    /// Pure read — does not open the app even when invoked from outside it.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<ClipEntity> {
        let repo = ClipRepository()
        let clips = (try? repo.fetchAll(limit: 1)) ?? []
        guard let clip = clips.first else {
            throw ClipRavenIntentError.noClips
        }
        return .result(value: ClipEntity(from: clip))
    }
}
