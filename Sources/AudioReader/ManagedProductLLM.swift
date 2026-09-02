import CryptoKit
import Foundation
#if canImport(AudioReaderNetworking)
import AudioReaderNetworking
#endif

enum ManagedProductLLM {
    private static let client = LiveProductAIClient(baseURL: ProductAPI.resolvedBaseURL)

    static func complete(
        system: String,
        user: String,
        sourceLanguage: String = "en",
        targetLanguage: String = "zh",
        learnerLevel: String = "intermediate",
        chapterID: String = ManagedAccountCredentials.unscopedChapterID,
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = ""
    ) async throws -> String {
        let credentials = try credentials()
        return try await client.complete(
            accessToken: credentials.accessToken,
            deviceID: credentials.deviceID,
            system: system,
            user: user,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            learnerLevel: learnerLevel,
            chapterID: chapterID,
            bookTitle: bookTitle,
            author: author,
            chapterTitle: chapterTitle
        )
    }

    static func completeWithTrace(
        system: String,
        user: String,
        sourceLanguage: String = "en",
        targetLanguage: String = "zh",
        learnerLevel: String = "intermediate",
        chapterID: String = ManagedAccountCredentials.unscopedChapterID,
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = ""
    ) async throws -> ProductAICompletion {
        let credentials = try credentials()
        return try await client.completeWithTrace(
            accessToken: credentials.accessToken,
            deviceID: credentials.deviceID,
            system: system,
            user: user,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            learnerLevel: learnerLevel,
            chapterID: chapterID,
            bookTitle: bookTitle,
            author: author,
            chapterTitle: chapterTitle
        )
    }

    static func translate(
        task: String,
        source: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        targetID: String? = nil,
        context: String? = nil,
        contextPrevious: [String] = [],
        contextNext: [String] = [],
        editionFingerprint: String = "",
        chapterFingerprint: String = "",
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        lookupOnly: Bool = false,
        refresh: Bool = false,
        assistantResultID: String? = nil
    ) async throws -> ProductTranslationResult {
        let credentials = try credentials()
        return try await client.translate(
            accessToken: credentials.accessToken,
            deviceID: credentials.deviceID,
            request: ProductTranslationRequest(
                task: task,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                learnerLevel: learnerLevel,
                source: source,
                editionFingerprint: editionFingerprint,
                chapterFingerprint: chapterFingerprint,
                contextBefore: context,
                contextPrevious: contextPrevious,
                contextNext: contextNext,
                targetId: targetID,
                bookTitle: bookTitle,
                author: author,
                chapterTitle: chapterTitle,
                lookupOnly: lookupOnly,
                refresh: refresh,
                assistantResultId: assistantResultID
            )
        )
    }

    /// One managed Qwen call for a chapter block. Each sentence is cached independently.
    static func translateBatch(
        sentences: [ProductTranslationSentence],
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        contextBefore: String? = nil,
        contextPrevious: [String] = [],
        contextNext: [String] = [],
        editionFingerprint: String = "",
        chapterFingerprint: String = "",
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        lookupOnly: Bool = false,
        refreshIds: [String] = []
    ) async throws -> ProductTranslationBatchResult {
        let credentials = try credentials()
        return try await client.translateBatch(
            accessToken: credentials.accessToken,
            deviceID: credentials.deviceID,
            request: ProductTranslationBatchRequest(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                learnerLevel: learnerLevel,
                sentences: sentences,
                editionFingerprint: editionFingerprint,
                chapterFingerprint: chapterFingerprint,
                contextBefore: contextBefore,
                contextPrevious: contextPrevious,
                contextNext: contextNext,
                bookTitle: bookTitle,
                author: author,
                chapterTitle: chapterTitle,
                lookupOnly: lookupOnly,
                refreshIds: refreshIds
            )
        )
    }

    static func chapterResults(from batch: ProductTranslationBatchResult) -> [ChapterTranslationResult] {
        batch.results.compactMap { result in
            let targetID = result.targetId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !targetID.isEmpty else { return nil }
            let translation = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty else { return nil }
            return ChapterTranslationResult(
                id: targetID,
                translation: translation,
                notes: result.notes.map {
                    ChapterTranslationResult.Note(
                        source: $0.source,
                        category: $0.category,
                        explanation: $0.explanation
                    )
                },
                assistantResultID: result.id,
                model: result.model,
                promptVersion: result.promptVersion,
                modelPolicyHash: result.modelPolicyHash,
                sharedCacheEntryID: result.sharedCacheEntryID
            )
        }
    }

    /// Rebuild MEANING IN THIS SENTENCE / EXAMPLES / notes from the cacheable JSON result.
    static func wordMeaningText(from result: ProductTranslationResult) -> String {
        let meaning = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = ["\(GlossTextFormat.sentenceMeaningHeading)\n\(meaning)"]
        let examples = result.notes.filter { $0.category == "example" }
        let notes = result.notes.filter { $0.category != "example" }
        if !examples.isEmpty {
            let lines = examples.map { note in
                let explanation = note.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                return explanation.isEmpty ? "• \(note.source)" : "• \(note.source)\n  \(explanation)"
            }.joined(separator: "\n")
            sections.append("\(GlossTextFormat.examplesHeading)\n\(lines)")
        }
        if !notes.isEmpty {
            let lines = notes.map { note in
                "• \(note.source) — [\(note.category.replacingOccurrences(of: "_", with: " "))] \(note.explanation)"
            }.joined(separator: "\n")
            sections.append("\(GlossTextFormat.learningNotesHeading)\n\(lines)")
        }
        return sections.joined(separator: "\n\n")
    }

    static func summarize(
        chapterID: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        segments: [String],
        editionFingerprint: String = "",
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        lookupOnly: Bool = false,
        refresh: Bool = false,
        assistantResultID: String? = nil
    ) async throws -> String {
        let summary = try await summarizeResult(
            chapterID: chapterID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            learnerLevel: learnerLevel,
            segments: segments,
            editionFingerprint: editionFingerprint,
            bookTitle: bookTitle,
            author: author,
            chapterTitle: chapterTitle,
            lookupOnly: lookupOnly,
            refresh: refresh,
            assistantResultID: assistantResultID
        )
        return summaryText(from: summary)
    }

    static func summarizeResult(
        chapterID: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        segments: [String],
        editionFingerprint: String = "",
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        lookupOnly: Bool = false,
        refresh: Bool = false,
        assistantResultID: String? = nil
    ) async throws -> ProductChapterSummary {
        let credentials = try credentials()
        return try await client.summarize(
            accessToken: credentials.accessToken,
            deviceID: credentials.deviceID,
            request: ProductChapterSummaryRequest(
                chapterId: hashedChapterID(chapterID),
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                learnerLevel: learnerLevel,
                editionFingerprint: editionFingerprint,
                chapterFingerprint: chapterID,
                bookTitle: bookTitle,
                author: author,
                chapterTitle: chapterTitle,
                segments: segments,
                lookupOnly: lookupOnly,
                refresh: refresh,
                assistantResultId: assistantResultID
            )
        )
    }

    static func summaryText(from summary: ProductChapterSummary) -> String {
        let payload: [String: Any] = [
            "overview": summary.overview,
            "keyPoints": summary.keyPoints,
            "charactersOrIdeas": summary.charactersOrIdeas ?? [],
            "keyConcepts": summary.keyConcepts.map {
                ["name": $0.name, "explanation": $0.explanation]
            },
            "themes": summary.themes
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? summary.overview
    }

    /// Sends only the completed Listen First sentence window; the server validates every cited id.
    static func heardQuiz(
        chapterID: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        segments: [ProductHeardSegment],
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = ""
    ) async throws -> String {
        let credentials = try credentials()
        let response = try await client.heardQuiz(
            accessToken: credentials.accessToken,
            deviceID: credentials.deviceID,
            request: ProductHeardQuizRequest(
                chapterId: hashedChapterID(chapterID),
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                learnerLevel: learnerLevel,
                bookTitle: bookTitle,
                author: author,
                chapterTitle: chapterTitle,
                segments: segments
            )
        )
        return response.raw
    }

    static func lookupSummary(
        chapterID: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        segments: [String],
        editionFingerprint: String = "",
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = ""
    ) async throws -> ProductChapterSummary? {
        do {
            return try await summarizeResult(
                chapterID: chapterID,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                learnerLevel: learnerLevel,
                segments: segments,
                editionFingerprint: editionFingerprint,
                bookTitle: bookTitle,
                author: author,
                chapterTitle: chapterTitle,
                lookupOnly: true
            )
        } catch let error as AuthClientError {
            if case .problem(status: 404, _, _) = error {
                return nil
            }
            throw error
        }
    }

    private static func credentials() throws -> (accessToken: String, deviceID: String) {
        guard let current = ManagedAccountCredentials.current() else {
            throw LLMError.managedAccountRequired
        }
        return current
    }

    /// Same UUID-5-shaped hash as AccountSession book/chapter ids so cache keys
    /// do not collapse every local chapter onto one sentinel.
    private static func hashedChapterID(_ value: String) -> String {
        let pattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        if value.wholeMatch(of: pattern) != nil {
            return value.lowercased()
        }
        let digest = SHA256.hash(data: Data("chapter:\(value)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let start = hex.startIndex
        func slice(_ offset: Int, _ count: Int) -> String {
            let from = hex.index(start, offsetBy: offset)
            let to = hex.index(from, offsetBy: count)
            return String(hex[from..<to])
        }
        return "\(slice(0, 8))-\(slice(8, 4))-\(slice(12, 4))-\(slice(16, 4))-\(slice(20, 12))"
    }
}
