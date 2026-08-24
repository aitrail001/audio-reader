import Foundation
import Testing
@testable import AudioReader

@Suite("Provider-neutral reading assistant prompts")
struct ReadingAssistantPromptTests {
    @Test("Sentence translation contract is tailored to the reader's mother language")
    func sentenceTranslationSupportsNativeLanguageLearners() {
        let prompt = ReadingAssistantPrompt.sentenceTranslation(
            language: .es,
            metadata: "Book: Test Book\nAuthor: Test Author\nChapter: One",
            context: "PREVIOUS: The room fell silent.\nTARGET id=sentence-1: She broke the ice.\nNEXT: Everyone relaxed.",
            targetIDs: ["sentence-1"]
        )

        #expect(prompt.system.contains("native speaker of Spanish"))
        #expect(prompt.system.contains("phrasal verbs"))
        #expect(prompt.system.contains("idioms"))
        #expect(prompt.system.contains("challenging words"))
        #expect(prompt.system.contains("challenging combinations"))
        #expect(prompt.system.contains("key concepts"))
        #expect(prompt.system.contains("previous and next sentences"))
        #expect(prompt.user.contains("Book: Test Book"))
        #expect(prompt.user.contains("TARGET id=sentence-1"))
        #expect(prompt.user.contains("Return results only for these target IDs: sentence-1"))
    }

    @Test("Sentence context always includes the target's previous and next sentences")
    func sentenceContextIncludesNeighbors() {
        let segments = [
            segment(id: "previous", text: "The room fell silent."),
            segment(id: "target", text: "She broke the ice."),
            segment(id: "next", text: "Everyone relaxed.")
        ]
        let transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/context.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: segments,
            source: "test",
            ebookAligned: false
        )

        let context = ReadingAssistantPrompt.sentenceContext(
            around: [segments[1]],
            in: transcript,
            radius: 0
        )

        #expect(context.contains("PREVIOUS: The room fell silent."))
        #expect(context.contains("TARGET id=target: She broke the ice."))
        #expect(context.contains("NEXT: Everyone relaxed."))
    }

    @Test("Core prompts do not name a provider or model")
    func promptsAreProviderNeutral() {
        let prompts = [
            ReadingAssistantPrompt.sentenceTranslation(
                language: .ja,
                metadata: "Book: Test",
                context: "TARGET id=one: Test.",
                targetIDs: ["one"]
            ).system,
            ReadingAssistantPrompt.word(language: .ja),
            ReadingAssistantPrompt.chapterSummary(language: .ja),
            ReadingAssistantPrompt.chapterChat(language: .ja)
        ]

        for prompt in prompts {
            for providerName in ["Grok", "xAI", "Qwen", "OpenAI", "ChatGPT", "Codex"] {
                #expect(!prompt.localizedCaseInsensitiveContains(providerName))
            }
        }
    }

    @Test("Single and batch translation flows use the same prompt and structured result contract")
    func sentenceFlowsShareOneContract() throws {
        let appState = try source("Sources/AudioReader/AppState.swift")

        #expect(appState.components(separatedBy: "ReadingAssistantPrompt.sentenceTranslation(").count - 1 == 2)
        #expect(appState.components(separatedBy: "completeStructuredJSON(").count - 1 == 2)
        #expect(!appState.contains("TranslationPrompt.sentence("))
        #expect(!appState.contains("TranslationPrompt.chapter("))
    }

    @Test("Structured translation results preserve categorized language and concept notes")
    func parsesLearnerNotes() throws {
        let response = """
        {
          "translations": [{
            "id": "sentence-1",
            "translation": "Ella rompió el hielo.",
            "notes": [
              {"source":"break the ice","category":"idiom","explanation":"Iniciar una conversación para reducir la tensión."},
              {"source":"awkward silence","category":"challenging_combination","explanation":"Una combinación que describe un silencio socialmente incómodo."},
              {"source":"social tension","category":"concept","explanation":"La presión interpersonal que explica por qué este gesto importa en la escena."}
            ]
          }]
        }
        """

        let result = try #require(
            ChapterTranslationBatch.parse(response, expectedIDs: ["sentence-1"]).first
        )

        #expect(result.notes.map(\.category) == ["idiom", "challenging_combination", "concept"])
        #expect(result.glossText.contains(GlossTextFormat.learningNotesHeading))
        #expect(result.glossText.contains("break the ice — [Idiom]"))
        #expect(result.glossText.contains("social tension — [Concept]"))
        let extracted = GlossPhrases.extract(from: result.glossText)
        #expect(extracted.map(\.phrase) == ["break the ice", "awkward silence", "social tension"])
    }

    @Test("One shared schema requires categorized learner notes")
    func structuredSchemaCoversLearnerNotes() throws {
        let data = try JSONSerialization.data(withJSONObject: SentenceTranslationContract.jsonSchema)
        let schema = try #require(String(data: data, encoding: .utf8))

        #expect(schema.contains("notes"))
        #expect(schema.contains("phrasal_verb"))
        #expect(schema.contains("phrase"))
        #expect(schema.contains("idiom"))
        #expect(schema.contains("challenging_word"))
        #expect(schema.contains("challenging_combination"))
        #expect(schema.contains("concept"))
    }

    @Test("Chapter summary and chat remain learner-focused")
    func chapterAssistantExplainsLanguageAndConcepts() {
        let summary = ReadingAssistantPrompt.chapterSummary(language: .ko)
        let chat = ReadingAssistantPrompt.chapterChat(language: .ko)

        #expect(summary.contains("native speaker of Korean"))
        #expect(summary.contains("phrasal verbs, phrases, idioms"))
        #expect(summary.contains("challenging concepts"))
        #expect(chat.contains("native speaker of Korean"))
        #expect(chat.contains("nearby previous and next sentences"))
        #expect(chat.contains("language or concept"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func segment(id: String, text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: 0,
            end: 1,
            words: [.init(id: "\(id)-word", text: text, start: 0, end: 1, confidence: nil)]
        )
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
