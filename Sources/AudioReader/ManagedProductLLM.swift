import Foundation
#if canImport(AudioReaderNetworking)
import AudioReaderNetworking
#endif

enum ManagedProductLLM {
    private static let client = LiveProductAIClient(baseURL: ProductAPI.resolvedBaseURL)

    static func complete(system: String, user: String) async throws -> String {
        let credentials = try credentials()
        return try await client.complete(
            accessToken: credentials.accessToken,
            deviceID: credentials.deviceID,
            system: system,
            user: user
        )
    }

    static func translate(
        task: String,
        source: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        targetID: String? = nil,
        context: String? = nil
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
                contextBefore: context,
                targetId: targetID
            )
        )
    }

    static func translationEnvelope(
        targetID: String,
        source: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        context: String? = nil
    ) async throws -> String {
        let result = try await translate(
            task: "sentence",
            source: source,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            learnerLevel: learnerLevel,
            targetID: targetID,
            context: context
        )
        let notes = result.notes.map {
            [
                "source": $0.source,
                "category": $0.category,
                "explanation": $0.explanation
            ]
        }
        let envelope: [String: Any] = [
            "translations": [
                [
                    "id": targetID,
                    "translation": result.translation,
                    "notes": notes
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return String(data: data, encoding: .utf8) ?? result.translation
    }

    static func summarize(
        chapterID: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        segments: [String]
    ) async throws -> String {
        let credentials = try credentials()
        let summary = try await client.summarize(
            accessToken: credentials.accessToken,
            deviceID: credentials.deviceID,
            request: ProductChapterSummaryRequest(
                chapterId: uuidOrUnscoped(chapterID),
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                learnerLevel: learnerLevel,
                chapterFingerprint: chapterID,
                segments: segments
            )
        )
        let payload: [String: Any] = [
            "overview": summary.overview,
            "keyPoints": summary.keyPoints,
            "charactersOrIdeas": summary.charactersOrIdeas ?? [],
            "keyConcepts": summary.keyConcepts.map {
                ["name": $0.name, "explanation": $0.explanation]
            },
            "themes": summary.themes
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8) ?? summary.overview
    }

    private static func credentials() throws -> (accessToken: String, deviceID: String) {
        guard let current = ManagedAccountCredentials.current() else {
            throw LLMError.managedAccountRequired
        }
        return current
    }

    private static func uuidOrUnscoped(_ value: String) -> String {
        let pattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        return value.wholeMatch(of: pattern) != nil
            ? value.lowercased()
            : ManagedAccountCredentials.unscopedChapterID
    }
}
