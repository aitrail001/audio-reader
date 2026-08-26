import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceAvailability: Equatable, Sendable {
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case unavailable(String)

    var isReady: Bool {
        self == .available
    }

    var shortLabel: String {
        switch self {
        case .available: "Ready"
        case .appleIntelligenceNotEnabled: "Off"
        case .deviceNotEligible: "Unsupported"
        case .modelNotReady: "Downloading"
        case .unavailable: "Unavailable"
        }
    }

    var userMessage: String {
        switch self {
        case .available:
            "Apple Intelligence is ready on this device."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in System Settings to use the on-device model."
        case .deviceNotEligible:
            "This Mac or iPad does not support Apple Intelligence."
        case .modelNotReady:
            "Apple Intelligence is downloading or not ready yet on this device."
        case .unavailable(let reason):
            "Apple Intelligence is unavailable. \(reason)"
        }
    }

    static func current() -> AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(let reason):
            from(unavailability: reason)
        }
        #else
        .unavailable("Foundation Models is not available in this build.")
        #endif
    }

    #if canImport(FoundationModels)
    static func from(unavailability reason: SystemLanguageModel.Availability.UnavailableReason) -> AppleIntelligenceAvailability {
        switch reason {
        case .appleIntelligenceNotEnabled:
            .appleIntelligenceNotEnabled
        case .deviceNotEligible:
            .deviceNotEligible
        case .modelNotReady:
            .modelNotReady
        @unknown default:
            .unavailable(String(describing: reason))
        }
    }
    #endif
}

enum FoundationModelsPromptPolicy {
    static let maxUserCharacters = 6_000
    static let chapterTranslationBlockSize = 2

    static func truncatedUserPayload(_ user: String) -> (text: String, didTruncate: Bool) {
        guard user.count > maxUserCharacters else { return (user, false) }
        let prefix = String(user.prefix(maxUserCharacters))
        return (
            prefix + "\n\n[Chapter truncated for the on-device model.]",
            true
        )
    }

    static func chapterTranslationBlockSize(for provider: LLMProvider, requested: Int) -> Int {
        guard provider == .appleFoundation else { return max(1, requested) }
        return min(max(1, requested), chapterTranslationBlockSize)
    }
}

enum AppleOnDeviceJSON {
    static func translationEnvelope(
        id: String,
        translation: String,
        notes: [(source: String, category: String, explanation: String)] = []
    ) throws -> String {
        let payload: [String: Any] = [
            "translations": [
                [
                    "id": id,
                    "translation": translation,
                    "notes": notes.map {
                        [
                            "source": $0.source,
                            "category": $0.category,
                            "explanation": $0.explanation
                        ]
                    }
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func chapterSummary(
        overview: String,
        keyPoints: [String] = [],
        charactersOrIdeas: [String] = [],
        keyConcepts: [(name: String, explanation: String)] = [],
        themes: [String] = []
    ) throws -> String {
        let payload: [String: Any] = [
            "overview": overview,
            "keyPoints": keyPoints,
            "charactersOrIdeas": charactersOrIdeas,
            "keyConcepts": keyConcepts.map { ["name": $0.name, "explanation": $0.explanation] },
            "themes": themes
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

actor FoundationModelsClient {
    static let shared = FoundationModelsClient()

    func complete(system: String, user: String) async throws -> String {
        try await respond(system: system, user: user, structuredJSON: false)
    }

    func completeStructuredJSON(system: String, user: String) async throws -> String {
        try await respond(system: system, user: user, structuredJSON: true)
    }

    private func respond(system: String, user: String, structuredJSON: Bool) async throws -> String {
        let availability = AppleIntelligenceAvailability.current()
        guard availability.isReady else {
            throw LLMError.appleIntelligenceUnavailable(availability.userMessage)
        }
        let payload = FoundationModelsPromptPolicy.truncatedUserPayload(user).text
        let instructions = structuredJSON
            ? system + "\nReturn valid JSON only. Do not wrap it in Markdown fences."
            : system
        #if canImport(FoundationModels)
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: payload)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw LLMError.empty }
            return text
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.appleIntelligenceUnavailable(error.localizedDescription)
        }
        #else
        throw LLMError.appleIntelligenceUnavailable("Foundation Models is not available in this build.")
        #endif
    }
}
