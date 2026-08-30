import Foundation
import Testing
@testable import AudioReader

@Suite("Provider-neutral reading assistant prompts")
struct ReadingAssistantPromptTests {
    @Test("Sentence translation contract is tailored to the reader's mother language")
    func sentenceTranslationSupportsNativeLanguageLearners() {
        let prompt = ReadingAssistantPrompt.sentenceTranslation(
            language: .es,
            sourceLanguage: .englishUS,
            readerLevel: .intermediate,
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

    @Test("Prompt templates are loaded from the shared JSON resource")
    func promptsAreExternalized() throws {
        let catalog = try PromptTemplateCatalog.load()
        let swiftSource = try source("Sources/AudioReader/ReadingAssistantPrompt.swift")
        let config = try source("Sources/AudioReader/Resources/ReadingAssistantPrompts.json")

        #expect(!catalog.sentenceTranslationSystem.isEmpty)
        #expect(config.contains("sentenceTranslationSystem"))
        #expect(config.contains("{{readerLevelGuidance}}"))
        #expect(!swiftSource.contains("You are a literary translator"))
        #expect(!swiftSource.contains("Output exactly this layout"))
    }

    @Test("Language notes adapt to the audiobook language and reader proficiency")
    func promptAdaptsToSourceLanguageAndLevel() {
        let beginner = ReadingAssistantPrompt.sentenceTranslation(
            language: .en,
            sourceLanguage: .spanish,
            readerLevel: .beginner,
            metadata: "Book: Test",
            context: "TARGET id=one: Al final, se dio cuenta.",
            targetIDs: ["one"]
        ).system
        let advanced = ReadingAssistantPrompt.sentenceTranslation(
            language: .en,
            sourceLanguage: .spanish,
            readerLevel: .advanced,
            metadata: "Book: Test",
            context: "TARGET id=one: Al final, se dio cuenta.",
            targetIDs: ["one"]
        ).system

        #expect(beginner.contains("learning Spanish"))
        #expect(beginner.contains("A1–A2"))
        #expect(beginner.contains("essential vocabulary"))
        #expect(advanced.contains("C1–C2"))
        #expect(advanced.contains("nuanced"))
        #expect(!advanced.contains("explain every ordinary word"))
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

        let neighbors = ReadingAssistantPrompt.neighbors(around: segments[1], in: transcript)
        #expect(neighbors.previous == ["The room fell silent."])
        #expect(neighbors.next == ["Everyone relaxed."])
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
        #expect(appState.components(separatedBy: "completeStructuredJSON(").count - 1 == 3)
        #expect(appState.contains("structuredJSON: true"))
        #expect(appState.contains("translateSentenceBlock("))
        #expect(appState.contains("alignedBlock("))
        #expect(appState.contains("ManagedProductLLM.translateBatch"))
        #expect(!appState.contains("for segment in remaining"))
        #expect(!appState.contains("TranslationPrompt.sentence("))
        #expect(!appState.contains("TranslationPrompt.chapter("))
    }

    @Test("retryGloss retranslates the matching sentence instead of the current playback sentence")
    func retryGlossRetranslatesMatchingSentence() throws {
        let appState = try source("Sources/AudioReader/AppState.swift")
        let marker = "func retryGloss(_ entry: GlossEntry) {"
        #expect(appState.contains(marker))
        let start = try #require(appState.range(of: marker))
        let remainder = appState[start.lowerBound...]
        let end = remainder.range(of: "\n    private func selectedOrigin()")
        let body = String(remainder[..<(end?.lowerBound ?? remainder.endIndex)])
        #expect(body.contains("retranslateSentence("))
        #expect(!body.contains("if entry.kind == .sentence {\n            retranslateCurrentSentence()"))
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

    @Test("Gloss presentation preserves translation hierarchy and categorized notes")
    func parsesGlossPresentation() throws {
        let presentation = GlossPresentation.parse("""
        TRANSLATION:
        Ella rompió el hielo.

        LANGUAGE AND CONTEXT NOTES:
        • break the ice — [Idiom] Iniciar una conversación para reducir la tensión.
        • awkward silence — [Challenging combination] Un silencio socialmente incómodo.
        """)

        #expect(presentation.sections.map(\.kind) == [.translation, .learningNotes])
        let notes = try #require(presentation.sections.last?.notes)
        #expect(notes.count == 2)
        #expect(notes[0].source == "break the ice")
        #expect(notes[0].category == "Idiom")
        #expect(notes[1].explanation.contains("socialmente"))
    }

    @Test("Gloss presentation pairs examples with aligned translations")
    func parsesExampleTranslations() throws {
        let presentation = GlossPresentation.parse("""
        MEANING IN THIS SENTENCE:
        verbo — incluir o contener algo
        Aquí describe los subsistemas incluidos por un sistema mayor.

        EXAMPLES:
        • A forest encompasses many smaller systems.
          Un bosque abarca muchos sistemas más pequeños.
        • The report encompasses the whole year.
          El informe abarca todo el año.
        """)

        #expect(presentation.sections.map(\.kind) == [.sentenceMeaning, .examples])
        let meaning = try #require(presentation.sections.first)
        #expect(meaning.paragraphs.map(\.text) == [
            "verbo — incluir o contener algo",
            "Aquí describe los subsistemas incluidos por un sistema mayor."
        ])

        let examples = try #require(presentation.sections.last?.examples)
        #expect(examples.count == 2)
        #expect(examples[0].source == "A forest encompasses many smaller systems.")
        #expect(examples[0].translation == "Un bosque abarca muchos sistemas más pequeños.")
        #expect(examples[1].translation == "El informe abarca todo el año.")
    }

    @Test("Managed Qwen word results rebuild the in-sentence meaning layout")
    func wordMeaningTextRebuildsRichLayout() throws {
        let result = ProductTranslationResult(
            id: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            translation: "noun — the frozen sea in this chapter\nHere it is the ice that traps the ship.",
            notes: [
                ProductLearningNote(
                    source: "The ice closed over the channel.",
                    category: "example",
                    explanation: "冰封住了航道。"
                ),
                ProductLearningNote(
                    source: "The lake froze overnight.",
                    category: "example",
                    explanation: "湖一夜结了冰。"
                ),
                ProductLearningNote(
                    source: "closed over",
                    category: "phrasal_verb",
                    explanation: "封住、覆盖。"
                )
            ],
            provenance: "generated",
            policyVersion: "qwen-managed-v1",
            createdAt: "2026-08-29T00:00:00Z"
        )

        let text = ManagedProductLLM.wordMeaningText(from: result)
        #expect(text.contains(GlossTextFormat.sentenceMeaningHeading))
        #expect(text.contains(GlossTextFormat.examplesHeading))
        #expect(text.contains(GlossTextFormat.learningNotesHeading))

        let presentation = GlossPresentation.parse(text)
        #expect(presentation.sections.map(\.kind) == [.sentenceMeaning, .examples, .learningNotes])
        let examples = try #require(presentation.sections[1].examples)
        #expect(examples.count == 2)
        #expect(examples[0].source == "The ice closed over the channel.")
        #expect(examples[0].translation == "冰封住了航道。")
    }

    @Test("Legacy inline gloss labels keep their content out of the heading")
    func parsesLegacyInlineGlossLabels() throws {
        let presentation = GlossPresentation.parse("""
        译文：献给戴娜，1941年至2001年。
        短语：无
        """)

        #expect(presentation.sections.map(\.kind) == [.translation, .learningNotes])
        #expect(presentation.sections[0].title == "Translation")
        #expect(presentation.sections[0].paragraphs.map(\.text) == ["献给戴娜，1941年至2001年。"])
        #expect(presentation.sections[1].title == "Language & Context")
        #expect(presentation.sections[1].paragraphs.map(\.text) == ["无"])
    }

    @Test("Chapter and chat prose recognizes headings and list hierarchy")
    func parsesAssistantProseHierarchy() throws {
        let presentation = GlossPresentation.parse("""
        ## Main ideas
        The chapter explains feedback loops.

        **Key concepts**
        - Reinforcing loop: change that amplifies itself.
        - Balancing loop: change that resists itself.
        - Key themes:
        """)

        #expect(presentation.sections.map(\.title) == ["Main ideas", "Key concepts"])
        let concepts = try #require(presentation.sections.last)
        #expect(concepts.paragraphs.map(\.kind) == [.bullet, .bullet, .bullet])
        #expect(concepts.paragraphs[0].text == "Reinforcing loop: change that amplifies itself.")
        #expect(concepts.paragraphs[2].text == "Key themes:")
    }

    @Test("Assistant type stays compact without crossing the native readability floor")
    func assistantTypographyIsSmallerThanBookText() {
        let compact = ReaderType.metrics(columnWidth: 320, scale: 0.65)
        #expect(compact.body == AssistantTypography.minimumBodySize)
        #expect(compact.dual == AssistantTypography.minimumBodySize)
        #expect(compact.gloss == AssistantTypography.minimumBodySize)
        #expect(AssistantTypography.bodySize(forReaderScale: 0.65) == compact.gloss)

        let regular = ReaderType.metrics(columnWidth: 420, scale: 1)
        #expect(regular.gloss < regular.body)
        #expect(regular.gloss >= AssistantTypography.minimumBodySize)
        #expect(regular.gloss <= AssistantTypography.maximumBodySize)

        let wide = ReaderType.metrics(columnWidth: 1200, scale: 1.6)
        #expect(wide.gloss < wide.body)
        #expect(wide.gloss == AssistantTypography.maximumBodySize)
    }

    @Test("Chapter summary is structured reading content while chat remains learner-focused")
    func chapterAssistantSeparatesSummaryFromLanguageStudy() {
        let summary = ReadingAssistantPrompt.chapterSummary(language: .ko)
        let chat = ReadingAssistantPrompt.chapterChat(language: .ko)

        #expect(summary.contains("native speaker of Korean"))
        #expect(summary.contains("Return valid JSON only"))
        #expect(summary.contains("\"overview\""))
        #expect(summary.contains("\"keyPoints\""))
        #expect(summary.contains("\"keyConcepts\""))
        #expect(!summary.localizedCaseInsensitiveContains("phrasal verbs"))
        #expect(!summary.localizedCaseInsensitiveContains("idioms"))
        #expect(!summary.localizedCaseInsensitiveContains("challenging words"))
        #expect(!summary.localizedCaseInsensitiveContains("language guide"))
        #expect(chat.contains("native speaker of Korean"))
        #expect(chat.contains("nearby previous and next sentences"))
        #expect(chat.contains("language or concept"))
    }

    @Test("Chapter summary JSON decodes into presentation sections")
    func chapterSummaryDecodesStructuredResponse() throws {
        let response = """
        {
          "overview": "A concise overview.",
          "keyPoints": ["First point", "Second point"],
          "charactersOrIdeas": ["The central idea"],
          "keyConcepts": [
            {"name": "Feedback loop", "explanation": "A result changes its own future cause."}
          ],
          "themes": ["Systems and responsibility"]
        }
        """

        let summary = try ChapterSummaryPresentation.parse(response)

        #expect(summary.overview == "A concise overview.")
        #expect(summary.keyPoints == ["First point", "Second point"])
        #expect(summary.charactersOrIdeas == ["The central idea"])
        #expect(summary.keyConcepts.first?.name == "Feedback loop")
        #expect(summary.themes == ["Systems and responsibility"])
    }

    @Test("Chapter summary accepts a provider-added JSON fence")
    func chapterSummaryAcceptsJSONFence() throws {
        let response = """
        ```json
        {"overview":"Overview","keyPoints":[],"charactersOrIdeas":[],"keyConcepts":[],"themes":[]}
        ```
        """

        #expect(try ChapterSummaryPresentation.parse(response).overview == "Overview")
    }

    @Test("Chapter summary rejects malformed provider output")
    func chapterSummaryRejectsMalformedResponse() {
        #expect(throws: Error.self) {
            try ChapterSummaryPresentation.parse("Summary: unstructured prose")
        }
    }

    @Test("Chapter summary review preserves or discards the previous accepted result")
    func chapterSummaryReviewTransitions() {
        let original = ChapterSummaryPresentation(
            overview: "Saved overview",
            keyPoints: [],
            charactersOrIdeas: [],
            keyConcepts: [],
            themes: []
        )
        let replacement = ChapterSummaryPresentation(
            overview: "New draft",
            keyPoints: ["New point"],
            charactersOrIdeas: [],
            keyConcepts: [],
            themes: []
        )
        var record = ChapterSummaryRecord.pending(
            summary: replacement,
            language: "zh-Hans",
            model: "test-model",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            replacing: ChapterSummaryRecord.pending(
                summary: original,
                language: "zh-Hans",
                model: "saved-model",
                bookID: "book",
                bookTitle: "Book",
                chapterID: "chapter",
                chapterTitle: "Chapter",
                replacing: nil
            ).accept(at: Date(timeIntervalSince1970: 10))
        )

        let restored = record.reject(at: Date(timeIntervalSince1970: 20))
        #expect(restored.status == .accepted)
        #expect(restored.summary.overview == "Saved overview")
        #expect(restored.model == "saved-model")

        record = record.accept(at: Date(timeIntervalSince1970: 30))
        #expect(record.status == .accepted)
        #expect(record.summary.overview == "New draft")
        #expect(record.replacedSummary == nil)
    }

    @Test("Accepted chapter summaries persist and reload")
    func chapterSummaryPersistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Chapter-Summary-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("summaries.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = ChapterSummaryRecord.pending(
            summary: .init(
                overview: "Overview",
                keyPoints: ["Point"],
                charactersOrIdeas: [],
                keyConcepts: [],
                themes: []
            ),
            language: "es",
            model: "test-model",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            replacing: nil,
            createdAt: Date(timeIntervalSince1970: 30)
        ).accept(at: Date(timeIntervalSince1970: 40))

        Persistence.saveChapterSummaries([record], to: url)
        let loaded = Persistence.loadChapterSummaries(from: url)

        #expect(loaded == [record])
        #expect(loaded.first?.status == .accepted)
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
