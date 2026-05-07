import Foundation

// MARK: - AISummaryService (macOS 26+ only)

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
actor AISummaryService {
    static let shared = AISummaryService()

    private var session: LanguageModelSession?

    @Generable
    struct SummaryOutput {
        @Guide(description: "A concise 2-3 sentence summary of the provided text")
        var summary: String
    }

    /// Returns a 2-3 sentence summary, or nil if summarization is disabled / text is too short.
    func summarize(text: String) async -> String? {
        // 기본값 ON — @AppStorage 기본값이 UserDefaults에 쓰여지지 않는 문제 회피
        let enabled = UserDefaults.standard.object(forKey: "aiSummaryEnabled") as? Bool ?? true
        guard enabled else { return nil }
        guard text.count > 500 else { return nil }

        let model = SystemLanguageModel.default
        guard model.availability == .available else { return nil }

        do {
            if session == nil {
                session = LanguageModelSession(
                    model: model,
                    instructions: "You are a concise text summarizer. Produce a 2-3 sentence summary of the provided text."
                )
            }

            let prompt = String(text.prefix(4000))
            let response = try await session!.respond(to: prompt, generating: SummaryOutput.self)
            return response.content.summary
        } catch {
            ClipRavenLog.ai.error("summarize failed: \(String(describing: error), privacy: .public)")
            session = nil
            return nil
        }
    }
}
#endif
