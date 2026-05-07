import AppIntents
import Foundation
import ClipRavenSync

/// Adds a user-supplied string to ClipRaven's history as if the user had just
/// copied it. Uses the same `ClipProcessor` pipeline as normal captures, which
/// means:
/// - Automatic content-type classification (text / code / url / color)
/// - Invisible-character stripping (if enabled)
/// - Dedupe against the last 2 seconds + DB hash
/// - Smart-rule auto-tagging
struct AddClipIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Clip"
    static var description = IntentDescription(
        "Adds text to ClipRaven's clipboard history. Content type is detected automatically.",
        categoryName: "ClipRaven"
    )

    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Text",
        description: "히스토리에 추가할 텍스트",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to ClipRaven")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<ClipEntity> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClipRavenIntentError.processingFailed
        }

        // Feed into the standard processing pipeline so everything (classification,
        // dedup, smart rules, chosung extraction) happens exactly like an ordinary capture.
        let data = ClipboardData(text: text, imageData: nil, fileURLs: nil)
        let source = SourceAppInfo(
            bundleId: "com.lumibear.clipraven.intent",
            name: "Shortcuts",
            icon: nil
        )
        await ClipProcessor().process(clipboardData: data, sourceApp: source)

        // Fetch back the clip that now exists (either freshly inserted or deduped hit).
        // We hash by the normalized text so it matches what ClipProcessor stored.
        let normalized = TextNormalizer.normalize(
            TextNormalizer.stripInvisibleCharacters(text)
        )
        let hash = XXHash64Wrapper.hash(normalized)

        let repo = ClipRepository()
        if let existing = try? repo.fetchByHash(hash) {
            return .result(value: ClipEntity(from: existing))
        }

        // Fallback — processing may have classified it into a different hash
        // (unlikely, but keep the intent resilient). Return the newest clip.
        if let latest = (try? repo.fetchAll(limit: 1))?.first {
            return .result(value: ClipEntity(from: latest))
        }
        throw ClipRavenIntentError.processingFailed
    }
}
