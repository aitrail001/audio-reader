import Foundation
import Testing
@testable import AudioReader

@Suite("Study token and familiarity map")
struct StudyLexiconTests {
    @Test("Headword stripping yields a language-keyed lemma")
    func stripsPunctuationViaHeadword() throws {
        let lemma = try #require(StudyTokenIndex.lemma(from: "Forest,", language: "en"))

        #expect(lemma.form == "forest")
        #expect(lemma.language == "en")
        #expect(StudyTokenIndex.languageKey(for: .englishUS) == "en")
        #expect(StudyTokenIndex.languageKey(localeIdentifier: "en-GB") == "en")
    }

    @Test("English function words are not content")
    func marksEnglishStopwordsNonContent() throws {
        let the = try #require(StudyLemma.make(language: "en", surface: "The"))
        let forest = try #require(StudyLemma.make(language: "en", surface: "forest"))

        #expect(!StudyTokenIndex.isContentWord(the))
        #expect(StudyTokenIndex.isContentWord(forest))
    }

    @Test("CJK tokens remain content words")
    func keepsCJKTokensAsContent() throws {
        let lemma = try #require(StudyLemma.make(language: "zh", surface: "森林"))

        #expect(StudyTokenIndex.isContentWord(lemma))
    }

    @Test("Vocabulary words are learning even when also marked known")
    func vocabWordIsLearningEvenIfAlsoKnown() throws {
        let lemma = try #require(StudyLemma.make(language: "en", surface: "forest"))
        let vocab = [wordEntry("Forest")]
        let known = [KnownLemmaRecord(language: "en", form: "forest", updatedAt: Date())]
        let status = WordFamiliarityResolver.status(
            surface: "forest",
            language: "en",
            vocab: vocab,
            known: known
        )

        #expect(status == .learning)
        #expect(WordFamiliarityResolver.status(
            lemma: lemma,
            learning: WordFamiliarityResolver.learningLemmas(from: vocab, language: "en"),
            known: WordFamiliarityResolver.knownLemmas(from: known, language: "en")
        ) == .learning)
    }

    @Test("An explicit lemma is known when it is not in vocabulary")
    func explicitLemmaIsKnown() {
        let status = WordFamiliarityResolver.status(
            surface: "canopy",
            language: "en",
            vocab: [wordEntry("forest")],
            known: [KnownLemmaRecord(language: "en", form: "canopy", updatedAt: Date())]
        )

        #expect(status == .known)
    }

    @Test("Unmarked content is unknown and does not use timestamp matching")
    func unknownOtherwiseWithoutTimestampMatch() {
        let nearbyVocab = VocabEntry(
            id: "near",
            word: "forest",
            context: "A forest.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "One",
            timestamp: 3.2,
            addedAt: Date()
        )
        let status = WordFamiliarityResolver.status(
            surface: "canopy",
            language: "en",
            vocab: [nearbyVocab],
            known: []
        )

        #expect(status == .unknown)
    }

    @Test("Phrase and sentence cards do not seed the learning set")
    func onlyWordCardsSeedLearning() {
        let phrase = VocabEntry(
            id: "phrase",
            word: "break the ice",
            category: .phrase,
            context: "She broke the ice.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "One",
            timestamp: 1,
            addedAt: Date()
        )

        #expect(WordFamiliarityResolver.learningLemmas(from: [phrase], language: "en").isEmpty)
    }

    @Test("Vocabulary only seeds the matching audiobook language")
    func vocabularyDoesNotCrossLanguageBoundaries() {
        var english = wordEntry("actual")
        english.sourceLanguage = "en"
        var spanish = wordEntry("bosque")
        spanish.sourceLanguage = "es"

        #expect(
            WordFamiliarityResolver.learningLemmas(
                from: [english, spanish],
                language: "en"
            ).map(\.form) == ["actual"]
        )
        #expect(
            WordFamiliarityResolver.learningLemmas(
                from: [english],
                language: "es"
            ).isEmpty
        )
    }

    @Test("Legacy vocabulary is tagged only when its book can be identified")
    func migratesLegacyVocabularyLanguage() {
        var legacy = wordEntry("forest")
        legacy.sourceLanguage = nil
        let book = Book(
            id: "book",
            title: "Book",
            folderPath: "/tmp/book",
            chapters: []
        )
        var unknown = wordEntry("orphan")
        unknown.bookID = "missing"
        unknown.bookTitle = "Missing"
        unknown.sourceLanguage = nil

        let migrated = VocabSourceLanguageMigration.migrated(
            [legacy, unknown],
            books: [book],
            languageForBook: { _ in "en-US" }
        )

        #expect(migrated[0].sourceLanguage == "en")
        #expect(migrated[1].sourceLanguage == nil)
    }
}

@Suite("Chapter coverage and priming")
struct ChapterStudyListTests {
    @Test("Coverage counts unique content lemmas")
    func coverageUsesUniqueContentLemmas() {
        let coverage = ChapterCoverageCalculator.snapshot(
            segments: sampleSegments(),
            language: "en",
            vocab: [wordEntry("forest")],
            known: [KnownLemmaRecord(language: "en", form: "canopy", updatedAt: Date())]
        )

        #expect(coverage.contentCount == 3)
        #expect(coverage.knownCount == 1)
        #expect(coverage.learningCount == 1)
        #expect(coverage.unknownCount == 1)
        #expect(coverage.percentKnown == 67)
        #expect(coverage.caption.contains("1 learning"))
        #expect(coverage.titleFragment == "Known 67% · 1 learning · 1 new")
        #expect(coverage.caption.hasPrefix("This chapter · "))
    }

    @Test("The reader window title appends chapter coverage after book and chapter")
    func readerWindowTitleIncludesCoverage() {
        let coverage = ChapterCoverage(
            contentCount: 3,
            knownCount: 1,
            learningCount: 1,
            unknownCount: 1
        )
        #expect(
            ReaderWindowTitle.make(
                book: "Thinking in Systems",
                chapter: "Chapter 2",
                coverage: coverage
            ) == "Thinking in Systems · Chapter 2 · Known 67% · 1 learning · 1 new"
        )
        #expect(
            !ReaderWindowTitle.make(
                book: "Thinking in Systems",
                chapter: "Chapter 2",
                coverage: coverage
            ).contains("This chapter")
        )
        #expect(ReaderWindowTitle.make(book: "Book", chapter: "One", coverage: .empty) == "Book · One")
        #expect(ReaderWindowTitle.make(book: "Book", chapter: nil, coverage: .empty) == "Book")
    }

    @Test("Stopwords do not inflate coverage")
    func ignoresStopwords() {
        let coverage = ChapterCoverageCalculator.snapshot(
            segments: sampleSegments(),
            language: "en",
            vocab: [],
            known: []
        )

        #expect(coverage.contentCount == 3)
        #expect(!coverage.caption.contains("the"))
    }

    @Test("Vocabulary counts as covered without an explicit known mark")
    func treatsVocabAsCoveredWithoutKnownMark() {
        let coverage = ChapterCoverageCalculator.snapshot(
            segments: sampleSegments(),
            language: "en",
            vocab: [wordEntry("forest")],
            known: []
        )

        #expect(coverage.learningCount == 1)
        #expect(coverage.knownCount == 0)
        #expect(coverage.percentKnown == 33)
    }

    @Test("An empty transcript has zero coverage")
    func emptyTranscriptIsZero() {
        #expect(ChapterCoverageCalculator.snapshot(
            segments: [],
            language: "en",
            vocab: [wordEntry("forest")],
            known: []
        ) == .empty)
    }

    @Test("Priming is first-occurrence order and skips known lemmas")
    func primingIsFirstOccurrenceOrder() {
        let items = ChapterPrimingList.build(
            segments: sampleSegments(),
            language: "en",
            vocab: [wordEntry("forest")],
            known: [KnownLemmaRecord(language: "en", form: "canopy", updatedAt: Date())]
        )

        #expect(items.map(\.lemma.form) == ["forest", "stream"])
        #expect(items[0].familiarity == .learning)
        #expect(items[1].familiarity == .unknown)
        #expect(items[0].timestamp == 0.2)
    }

    @Test("Priming walks every sentence, not only the selected one")
    func primingIgnoresUnselectedSentenceLimitation() {
        let items = ChapterPrimingList.build(
            segments: sampleSegments(),
            language: "en",
            vocab: [],
            known: []
        )

        #expect(items.map(\.lemma.form) == ["forest", "canopy", "stream"])
        #expect(items.last?.segmentID == "second")
    }

    @Test("Coverage and priming recover words from trusted ebook text when tokens are missing")
    func usesEbookTextWhenWordTokensAreMissing() {
        var segment = TranscriptSegment(
            id: "ebook-only",
            start: 0,
            end: 2,
            words: [],
            ebookText: "The forest canopy",
            alignmentScore: 0.9
        )
        segment.individualEbookMatchTrusted = true
        segment.documentEbookUseAllowed = true

        let tokens = StudyTokenIndex.tokens(in: segment)
        #expect(tokens.map(\.text) == ["The", "forest", "canopy"])

        let index = StudyIndex.build(
            segments: [segment],
            language: "en",
            vocab: [],
            knownRecords: []
        )
        #expect(index.coverage.contentCount == 2)
        #expect(index.priming.map(\.lemma.form) == ["forest", "canopy"])
    }

    @Test("Original-mode overlay tokens preserve trusted ebook wording")
    func originalOverlayUsesTrustedEbookText() {
        var segment = TranscriptSegment(
            id: "different-wording",
            start: 0,
            end: 2,
            words: [
                TranscriptWord(id: "spoken-1", text: "ASR", start: 0, end: 1, confidence: nil),
                TranscriptWord(id: "spoken-2", text: "wording", start: 1, end: 2, confidence: nil)
            ],
            ebookText: "Published prose",
            alignmentScore: 0.9
        )
        segment.individualEbookMatchTrusted = true
        segment.documentEbookUseAllowed = true

        let spoken = StudyTokenIndex.tokens(in: segment, source: .spoken)
        let original = StudyTokenIndex.tokens(in: segment, source: .original)

        #expect(spoken.map(\.text) == ["ASR", "wording"])
        #expect(original.map(\.text) == ["Published", "prose"])
        #expect(original.allSatisfy { $0.id.contains("ebook") })
    }

    @Test("A single study index walk fills coverage and priming together")
    func studyIndexIsBuiltInOnePass() {
        let index = StudyIndex.build(
            segments: sampleSegments(),
            language: "en",
            vocab: [wordEntry("forest")],
            knownRecords: [KnownLemmaRecord(language: "en", form: "canopy", updatedAt: Date())]
        )

        #expect(index.coverage.contentCount == 3)
        #expect(index.priming.map(\.lemma.form) == ["forest", "stream"])
        #expect(index.familiarity(for: "Forest") == .learning)
        #expect(index.familiarity(for: "canopy") == .known)
        #expect(index.coverage.caption.contains("This chapter"))
    }
}

@Suite("Cached chapter study index")
struct StudyIndexCacheTests {
    @MainActor
    @Test("Marking known updates the cached chapter index without requiring a view pass")
    func cachedIndexUpdatesWhenMarkingKnown() {
        let state = AppState()
        state.settings.transcriptionLanguage = TranscriptionLanguage.englishUS.rawValue
        state.vocab = []
        state.knownLemmas = []
        state.transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/study-index.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: sampleSegments(),
            source: "test",
            ebookAligned: false
        )

        #expect(state.chapterCoverage.contentCount == 3)
        #expect(state.chapterStudyItems.map(\.lemma.form) == ["forest", "canopy", "stream"])

        let canopy = TranscriptWord(id: "canopy-1", text: "canopy", start: 0.6, end: 1.1, confidence: nil)
        state.markKnown(canopy, known: true)

        #expect(state.chapterCoverage.knownCount == 1)
        #expect(state.chapterStudyItems.map(\.lemma.form) == ["forest", "stream"])
    }
}

@Suite("Cloze and reverse review prompts")
struct VocabClozeTests {
    @Test("Cloze blanks the first case-insensitive match and keeps the sentence")
    func blanksFirstInsensitiveMatch() {
        let entry = wordEntry("Forest", context: "The forest encompasses subsystems of trees.")

        #expect(VocabCloze.blankedSentence(for: entry) == "The ____ encompasses subsystems of trees.")
    }

    @Test("Cloze matching ignores diacritics")
    func isCaseAndDiacriticInsensitive() {
        let entry = VocabEntry(
            id: "cafe",
            word: "cafe",
            context: "A café opened nearby.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "One",
            timestamp: 1,
            addedAt: Date()
        )

        #expect(VocabCloze.blankedSentence(for: entry) == "A ____ opened nearby.")
    }

    @Test("Cloze falls back to a blank when the word is missing from context")
    func fallsBackWhenWordMissing() {
        let entry = wordEntry("canopy", context: "The forest is quiet.")

        #expect(VocabCloze.blankedSentence(for: entry) == VocabCloze.blank)
    }

    @Test("Cloze generation does not call an LLM")
    func doesNotUseLLM() throws {
        let source = try! String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AudioReader/StudyLexicon.swift"),
            encoding: .utf8
        )
        let cloze = try #require(source.range(of: "enum VocabCloze"))
        let reverse = try #require(source.range(of: "enum VocabReversePrompt", range: cloze.upperBound..<source.endIndex))
        let body = String(source[cloze.lowerBound..<reverse.lowerBound])

        #expect(!body.contains("GrokClient"))
        #expect(!body.contains("FoundationModels"))
        #expect(!body.contains("LLM"))
    }

    @Test("Reverse prefers a saved translation, then the dictionary preview")
    func prefersTranslationThenDefinition() {
        var translated = wordEntry("forest")
        translated.translation = "森林"
        translated.definition = "a large area of trees"

        var defined = wordEntry("canopy")
        defined.definition = "the upper layer of a forest"

        #expect(VocabReversePrompt.promptText(for: translated) == "森林")
        #expect(VocabReversePrompt.promptText(for: defined) == "the upper layer of a forest")
        #expect(VocabReversePrompt.promptText(for: wordEntry("stream")) == nil)
        #expect(VocabReversePrompt.effectivePrompt(for: wordEntry("stream"), requested: .reverse) == .recognition)
        #expect(VocabReversePrompt.effectivePrompt(for: translated, requested: .reverse) == .reverse)
    }
}

@Suite("Known-lemma persistence")
struct KnownLemmaPersistenceTests {
    @Test("Known lemmas round-trip language and form")
    func roundTripsLanguageAndForm() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let records = KnownLemmaStore.upsert(
            try #require(StudyLemma.make(language: "en", surface: "Forest")),
            into: [],
            at: Date(timeIntervalSince1970: 2_000_000)
        )
        Persistence.saveKnownLemmas(records, to: fixture)
        let loaded = Persistence.loadKnownLemmas(from: fixture)

        #expect(loaded.map(\.form) == ["forest"])
        #expect(loaded.first?.language == "en")
        #expect(KnownLemmaStore.remove(try #require(loaded.first?.lemma), from: loaded).isEmpty)
    }

    @Test("Missing overlay and review-face settings default off / recognition")
    func settingsOverlayDefaultsFalse() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "showStudyOverlay")
        object.removeValue(forKey: "vocabReviewPrompt")

        let migrated = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(!migrated.showStudyOverlay)
        #expect(migrated.vocabReviewPrompt == VocabReviewPrompt.recognition.rawValue)
    }

    @MainActor
    @Test("Marking known does not delete vocabulary and uses the audiobook language")
    func markDoesNotRemoveVocabOrUseGlossLanguage() {
        let state = AppState()
        state.settings.targetLanguage = StudyLanguage.zhHans.rawValue
        state.settings.transcriptionLanguage = TranscriptionLanguage.englishUS.rawValue
        let word = TranscriptWord(id: "w1", text: "Forest.", start: 0.2, end: 0.6, confidence: nil)
        state.vocab = [wordEntry("Forest")]
        state.knownLemmas = []

        state.markKnown(word, known: true)

        #expect(state.vocab.count == 1)
        #expect(state.familiarity(for: word) == .learning)
        #expect(state.knownLemmas.contains { $0.form == "forest" && $0.language == "en" })
        #expect(!state.knownLemmas.contains { $0.language == "zh" })

        state.vocab = []
        #expect(state.familiarity(for: word) == .known)

        state.markKnown(word, known: false)
        #expect(state.familiarity(for: word) == .unknown)
    }

    @MainActor
    @Test("Seeking and Deep Reading do not mutate the lexicon")
    func doesNotAutoMarkOnScroll() {
        let state = AppState()
        state.knownLemmas = []
        state.settings.deepReadingMode = true
        state.transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/lexicon.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: sampleSegments(),
            source: "test",
            ebookAligned: false
        )
        state.player.currentTime = 0.3
        state.player.isPlaying = true
        state.tickPlaybackModes()
        state.seekPlayback(to: 2.5)

        #expect(state.knownLemmas.isEmpty)
    }
}

private func wordEntry(_ word: String, context: String = "The forest encompasses subsystems of trees.") -> VocabEntry {
    VocabEntry(
        id: word,
        word: word,
        category: .word,
        sourceLanguage: "en",
        context: context,
        bookID: "book",
        bookTitle: "Book",
        chapterID: "chapter",
        chapterTitle: "One",
        timestamp: 0.2,
        addedAt: Date(timeIntervalSince1970: 1_000_000)
    )
}

private func sampleSegments() -> [TranscriptSegment] {
    [
        TranscriptSegment(
            id: "first",
            start: 0,
            end: 2,
            words: [
                TranscriptWord(id: "the-1", text: "The", start: 0, end: 0.2, confidence: nil),
                TranscriptWord(id: "forest-1", text: "forest", start: 0.2, end: 0.6, confidence: nil),
                TranscriptWord(id: "canopy-1", text: "canopy", start: 0.6, end: 1.1, confidence: nil)
            ],
            ebookText: nil,
            alignmentScore: nil
        ),
        TranscriptSegment(
            id: "second",
            start: 2,
            end: 4,
            words: [
                TranscriptWord(id: "the-2", text: "The", start: 2, end: 2.2, confidence: nil),
                TranscriptWord(id: "forest-2", text: "forest", start: 2.2, end: 2.7, confidence: nil),
                TranscriptWord(id: "stream-1", text: "stream", start: 2.7, end: 3.2, confidence: nil)
            ],
            ebookText: nil,
            alignmentScore: nil
        )
    ]
}
