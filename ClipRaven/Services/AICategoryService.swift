import Foundation
import ClipRavenSync

private func aiDebugLog(_ msg: String) {
    ClipRavenLog.ai.debug("\(msg, privacy: .public)")
    #if DEBUG
    let line = "\(Date()): [AICategory] \(msg)\n"
    let logPath = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("clipraven_debug.log").path
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath))
    }
    #endif
}

// MARK: - AI Category constants (shared across all OS versions)

enum AICategory: String, CaseIterable {
    case receipt, meeting, code, phone, email, address, link, other

    var displayName: String {
        switch self {
        case .receipt:  return String(localized: "영수증")
        case .meeting:  return String(localized: "회의")
        case .code:     return String(localized: "코드")
        case .phone:    return String(localized: "전화")
        case .email:    return String(localized: "이메일")
        case .address:  return String(localized: "주소")
        case .link:     return String(localized: "링크")
        case .other:    return String(localized: "기타")
        }
    }

    var systemImage: String {
        switch self {
        case .receipt:  return "receipt"
        case .meeting:  return "calendar.badge.clock"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .phone:    return "phone"
        case .email:    return "envelope"
        case .address:  return "map"
        case .link:     return "link"
        case .other:    return "questionmark.circle"
        }
    }
}

// MARK: - AICategoryService (macOS 26+ only)

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
actor AICategoryService {
    static let shared = AICategoryService()

    private var session: LanguageModelSession?
    private let clipRepository = ClipRepository()

    @Generable
    struct CategoryOutput {
        @Guide(description: "Classify the text into exactly one of: receipt, meeting, code, phone, email, address, link, other")
        var category: String
    }

    /// Fast deterministic detection for simple structured content.
    /// Returns nil if the LLM should decide.
    private func heuristicCategory(for text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pure email (single address)
        if t.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil {
            return AICategory.email.rawValue
        }
        // Pure URL
        if t.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
            return AICategory.link.rawValue
        }
        // Pure phone (only digits/+/-/()/spaces, at least 7 digits)
        let phoneChars = CharacterSet(charactersIn: "0123456789+-() ")
        if t.unicodeScalars.allSatisfy({ phoneChars.contains($0) }),
           t.filter({ $0.isNumber }).count >= 7 {
            return AICategory.phone.rawValue
        }
        return nil
    }

    func categorize(clipId: Int64, text: String) async {
        aiDebugLog("categorize called clipId=\(clipId) textLen=\(text.count)")

        // 기본값 ON — @AppStorage 기본값이 UserDefaults에 쓰여지지 않는 문제 회피
        let enabled = UserDefaults.standard.object(forKey: "aiCategorizationEnabled") as? Bool ?? true
        guard enabled else {
            aiDebugLog("skip: disabled in settings")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else {
            aiDebugLog("skip: too short (\(trimmed.count) chars)")
            return
        }

        // Heuristic shortcut for structured content (email/phone/link)
        if let heuristic = heuristicCategory(for: trimmed) {
            try? clipRepository.updateAICategory(id: clipId, category: heuristic, generatedAt: Date())
            aiDebugLog("heuristic id=\(clipId) → \(heuristic)")
            return
        }

        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            aiDebugLog("skip: model unavailable — \(String(describing: model.availability))")
            return
        }
        aiDebugLog("model available, starting classification for id=\(clipId)")

        do {
            if session == nil {
                session = LanguageModelSession(
                    model: model,
                    instructions: """
                    You classify clipboard text into exactly one category. \
                    Categories:
                    - receipt: purchase confirmation, invoice, order total with price and items
                    - meeting: agenda, schedule, meeting minutes, invitation with date/time
                    - code: source code (has braces, semicolons, imports, function definitions)
                    - phone: a phone number (digits with +/-/() format)
                    - email: a single email address
                    - address: a physical mailing address (street + city)
                    - link: a URL (http/https)
                    - other: prose, notes, product names, short labels, anything that does not clearly fit above

                    Rules:
                    - Short generic text like product names, titles, single words → other
                    - Do NOT pick 'code' just because the text contains a technical term
                    - Reply with only the lowercase category name
                    """
                )
            }

            let prompt = String(trimmed.prefix(800))
            let response = try await session!.respond(to: prompt, generating: CategoryOutput.self)

            let raw = response.content.category.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let validCategories = AICategory.allCases.map { $0.rawValue }
            let finalCategory = validCategories.contains(raw) ? raw : AICategory.other.rawValue

            try? clipRepository.updateAICategory(id: clipId, category: finalCategory, generatedAt: Date())
            aiDebugLog("classified id=\(clipId) raw=\"\(raw)\" → \(finalCategory)")
        } catch {
            aiDebugLog("classify FAILED — \(error)")
            session = nil
        }
    }

    /// Batch re-classify all text/code clips without an aiCategory.
    /// Returns the number of clips processed.
    /// Pick the best text for classification:
    /// - text/code: use contentText
    /// - image: use ocrText
    private func textForClassification(_ clip: Clip) -> String? {
        if clip.contentType == .image {
            return clip.ocrText
        }
        return clip.contentText
    }

    @discardableResult
    func batchReclassifyUnclassified(progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> Int {
        aiDebugLog("batch reclassify requested")
        guard let targets = try? clipRepository.fetchUnclassifiedTextClips() else {
            aiDebugLog("batch: fetch failed")
            return 0
        }
        aiDebugLog("batch: \(targets.count) candidates")
        var done = 0
        for clip in targets {
            guard let id = clip.id, let text = textForClassification(clip) else { continue }
            await categorize(clipId: id, text: text)
            done += 1
            progress(done, targets.count)
        }
        aiDebugLog("batch done: processed=\(done)")
        return done
    }

    /// Force re-classify ALL eligible clips (clears existing aiCategory first).
    @discardableResult
    func batchReclassifyAll(progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> Int {
        aiDebugLog("FORCE batch reclassify requested")
        try? clipRepository.clearAllAICategories()
        guard let targets = try? clipRepository.fetchAllTextClips() else {
            aiDebugLog("force batch: fetch failed")
            return 0
        }
        aiDebugLog("force batch: \(targets.count) candidates")
        var done = 0
        for clip in targets {
            guard let id = clip.id, let text = textForClassification(clip) else { continue }
            await categorize(clipId: id, text: text)
            done += 1
            progress(done, targets.count)
        }
        aiDebugLog("force batch done: processed=\(done)")
        return done
    }
}
#endif
