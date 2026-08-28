import Foundation
import Testing
@testable import AudioReader

@Suite("On-device Apple Intelligence provider")
struct FoundationModelsProviderTests {
    @Test("Apple Intelligence is a first-class local provider with no remote API")
    func providerIsLocalOnly() {
        #expect(LLMProvider.allCases == [.managedQwen, .grok, .qwenCloud, .openAI, .appleFoundation])
        #expect(LLMProvider.appleFoundation.menuLabel == "Apple Intelligence")
        #expect(LLMProvider.appleFoundation.usesRemoteAPI == false)
        #expect(LLMProvider.appleFoundation.environmentKey.isEmpty)
        #expect(LLMProvider.appleFoundation.defaultEndpoint.isEmpty)
        #expect(LLMProvider.grok.usesRemoteAPI)
        #expect(AppSettings.default.endpoint(for: .appleFoundation).isEmpty)
    }

    @Test("Availability copy does not ask for an API key")
    func availabilityMessagesAvoidAPIKeys() {
        let cases: [AppleIntelligenceAvailability] = [
            .appleIntelligenceNotEnabled,
            .deviceNotEligible,
            .modelNotReady,
            .unavailable("model missing")
        ]

        for availability in cases {
            let error = LLMError.appleIntelligenceUnavailable(availability.userMessage)
            #expect(!error.localizedDescription.contains("API key"))
            #expect(availability.userMessage.contains("Apple Intelligence"))
        }
        #expect(AppleIntelligenceAvailability.available.isReady)
        #expect(!AppleIntelligenceAvailability.modelNotReady.isReady)
    }

    @Test("On-device structured JSON matches existing translation and summary parsers")
    func encodedJSONMatchesExistingContracts() throws {
        let translationJSON = try AppleOnDeviceJSON.translationEnvelope(
            id: "sentence-1",
            translation: "Ella rompió el hielo.",
            notes: [(
                source: "broke the ice",
                category: "idiom",
                explanation: "empezó una conversación tensa"
            )]
        )
        let translations = try ChapterTranslationBatch.parse(
            translationJSON,
            expectedIDs: ["sentence-1"]
        )
        #expect(translations.count == 1)
        #expect(translations[0].translation == "Ella rompió el hielo.")
        #expect(translations[0].notes.first?.category == "idiom")

        let summaryJSON = try AppleOnDeviceJSON.chapterSummary(
            overview: "The chapter introduces a forest as a system.",
            keyPoints: ["Trees and animals form subsystems."],
            charactersOrIdeas: ["the forest"],
            keyConcepts: [("subsystem", "a system inside a larger system")],
            themes: ["interdependence"]
        )
        let summary = try ChapterSummaryPresentation.parse(summaryJSON)
        #expect(summary.overview.contains("forest"))
        #expect(summary.keyConcepts.first?.name == "subsystem")
    }

    @Test("On-device prompts are truncated and chapter blocks stay small")
    func truncatesLongPayloadsAndCapsBlocks() {
        let long = String(repeating: "word ", count: 4_000)
        let truncated = FoundationModelsPromptPolicy.truncatedUserPayload(long)

        #expect(truncated.didTruncate)
        #expect(truncated.text.contains("Chapter truncated for the on-device model"))
        #expect(truncated.text.count < long.count)
        #expect(FoundationModelsPromptPolicy.chapterTranslationBlockSize(
            for: .appleFoundation,
            requested: 5
        ) == 2)
        #expect(FoundationModelsPromptPolicy.chapterTranslationBlockSize(
            for: .openAI,
            requested: 5
        ) == 5)
    }

    @Test("GrokClient routes Apple Intelligence before HTTP")
    func grokClientRoutesLocally() throws {
        let client = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AudioReader/GrokClient.swift"),
            encoding: .utf8
        )
        let complete = try #require(client.range(of: "func complete("))
        let structured = try #require(client.range(of: "func completeStructuredJSON("))
        let completeBody = String(client[complete.lowerBound..<structured.lowerBound])

        #expect(completeBody.contains("provider == .appleFoundation"))
        #expect(completeBody.contains("FoundationModelsClient.shared.complete"))
        let httpIndex = try #require(completeBody.range(of: "LLMRequestBuilder")?.lowerBound)
        let appleIndex = try #require(completeBody.range(of: "FoundationModelsClient")?.lowerBound)
        #expect(appleIndex < httpIndex)
    }
}
