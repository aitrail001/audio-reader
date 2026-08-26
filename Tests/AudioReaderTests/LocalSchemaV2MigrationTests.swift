import Foundation
import Testing
@testable import AudioReader
@testable import AudioReaderLocalStore

@Suite("Local schema v2 real-shaped migration")
struct LocalSchemaV2RealShapedMigrationTests {
    private let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let lastReviewedAt = Date(timeIntervalSince1970: 1_700_345_600)
    private let nextReview = Date(timeIntervalSince1970: 1_700_604_800)

    @Test("migrates a real-shaped legacy transcript with EPUB assessment")
    func migratesRealShapedTranscriptWithEPUBAssessment() throws {
        let fixture = try migrateFullFixture()
        defer { fixture.cleanup() }

        let transcripts = try fixture.store.loadTranscripts()
        let transcript = try #require(transcripts.first { $0.chapterID == ChapterID(rawValue: "chapter-loomings") })
        #expect(transcript.localMediaKey.hasSuffix("chapter-01.m4b"))
        #expect(transcript.locale == "en-US")
        #expect(transcript.source == "apple-speech")
        #expect(transcript.ebookAlignment?.status == "trusted")
        #expect(transcript.ebookAlignment?.reason == "anchors matched across sampled sentences")
        #expect(transcript.ebookAlignment?.metrics.extractedWordCount == 12_840)
        #expect(transcript.ebookAlignment?.metrics.matchedCoverage == 0.9375)
        #expect(transcript.ebookAlignment?.metrics.detailedAlignmentPerformed == true)
        #expect(transcript.segments[0].ebookText == "Call me Ishmael.")
        #expect(transcript.segments[0].individualEbookMatchTrusted == true)
        #expect(transcript.segments[0].words.map(\.text) == ["Call", " me", " Ishmael"])

        let jsonOnly = try #require(transcripts.first { $0.chapterID == ChapterID(rawValue: "chapter-json-only") })
        #expect(jsonOnly.segments[0].words[0].text == "Some years ago")
        #expect(try fixture.store.rowCount("local_transcript_revisions") == 2)
    }

    @Test("migrates vocabulary with dictionary HTML and review history")
    func migratesVocabularyWithDictionaryHTMLAndReviewHistory() throws {
        let fixture = try migrateFullFixture()
        defer { fixture.cleanup() }

        let vocab = try #require(try fixture.store.loadVocabulary().first { $0.id.rawValue == "vocab-ishmael" })
        #expect(vocab.surface == "Ishmael")
        #expect(vocab.dictionaryName == "牛津英汉汉英词典")
        #expect(vocab.dictionaryHTML == "<html><body><b>Ishmael</b> n. 以实玛利</body></html>")
        #expect(vocab.definition == "a biblical wanderer")
        #expect(vocab.translation == "以实玛利")
        #expect(vocab.reviewCount == 3)
        #expect(vocab.lastReviewQuality == "remember")
        #expect(vocab.reviewIntervalDays == 7)
        #expect(vocab.reviewEaseFactor == 2.6)
        #expect(vocab.isInLearnList)
        #expect(vocab.nextReview == nextReview)
        #expect(vocab.lastReviewedAt == lastReviewedAt)

        let cards = try fixture.store.loadReviewCards()
        let card = try #require(cards.first { $0.vocabularyID.rawValue == "vocab-ishmael" })
        #expect(card.face == "cloze")
        #expect(card.reviewCount == 3)
        #expect(card.lastReviewQuality == "remember")
        #expect(card.reviewIntervalDays == 7)

        let events = try fixture.store.loadReviewEvents()
        #expect(events.count == 1)
        #expect(events[0].vocabularyID.rawValue == "vocab-ishmael")
        #expect(events[0].rating == "remember")
        #expect(events[0].face == "cloze")
        #expect(events[0].reviewedAt == lastReviewedAt)

        #expect(try fixture.store.loadVocabulary().contains { $0.surface == "whale" } == false)
    }

    @Test("migrates accepted and pending glosses")
    func migratesAcceptedAndPendingGlosses() throws {
        let fixture = try migrateFullFixture()
        defer { fixture.cleanup() }

        let results = try fixture.store.loadAssistantResults()
        let pending = try #require(results.first { $0.id == "gloss-pending" })
        let accepted = try #require(results.first { $0.id == "gloss-accepted" })
        #expect(pending.kind == .sentenceGloss)
        #expect(pending.status == .pending)
        #expect(pending.text == "叫我以实玛利。")
        #expect(accepted.kind == .wordGloss)
        #expect(accepted.status == .accepted)
        #expect(accepted.text == "以实玛利")
        #expect(accepted.decidedAt != nil)

        let summary = try #require(results.first { $0.kind == .chapterSummary })
        #expect(summary.status == .pending)
        #expect(summary.text.contains("A sailor narrates his first days at sea"))
        let translation = try #require(results.first { $0.kind == .chapterTranslation })
        #expect(translation.status == .pending)
        #expect(translation.source == "checkpoint")

        #expect(results.contains { $0.id == "gloss-json-only" } == false)
    }

    @Test("migrates known lemmas and activity log")
    func migratesKnownLemmasAndActivityLog() throws {
        let fixture = try migrateFullFixture()
        defer { fixture.cleanup() }

        #expect(try fixture.store.loadKnownLemmas().map(\.form).sorted() == ["forest", "whale"])
        #expect(try fixture.store.loadStudyActivityDays() == ["2023-11-14", "2023-11-15"])
        let settings = try #require(try fixture.store.loadMigratedSettings())
        #expect(settings.playbackRate == 1.25)
        #expect(settings.vocabReviewPrompt == "cloze")
        #expect(settings.targetLanguage == "zh-Hans")

        let books = try fixture.store.loadBooks()
        #expect(books.contains { $0.id.rawValue == "book-moby-dick" && $0.title == "Moby-Dick" })
        #expect(try fixture.store.loadAssets().contains { $0.localMediaKey.hasSuffix("chapter-01.m4b") })
        #expect(try fixture.store.rowCount("sync_outbox") == 0)
        #expect(try fixture.store.rowCount("entity_versions") > 0)
        #expect(try fixture.store.loadReceipt()?.schemaVersion == LocalSchemaV2.version)
    }

    @Test("interrupted real-shaped migration rolls back")
    func interruptedRealShapedMigrationRollsBack() throws {
        let planted = try plantFullFixture()
        defer { planted.cleanup() }
        planted.store.interruptAfterTable = "local_assistant_results"
        #expect(throws: LocalMigrationError.interrupted(table: "local_assistant_results")) {
            try planted.store.migrateLegacyData(from: planted.sources)
        }
        #expect(try planted.store.loadReceipt() == nil)
        for name in LocalSchemaV2.requiredTables {
            #expect(try planted.store.rowCount(name) == 0, "partial rows left in \(name)")
        }
    }

    @Test("repeated launch of a real-shaped library does not duplicate rows")
    func repeatedLaunchDoesNotDuplicateRealShapedRows() throws {
        let fixture = try migrateFullFixture()
        defer { fixture.cleanup() }
        let first = try #require(try fixture.store.loadReceipt())
        let counts = try requiredCounts(fixture.store)
        let second = try fixture.store.migrateLegacyData(from: fixture.sources)
        #expect(second == first)
        #expect(try requiredCounts(fixture.store) == counts)
        #expect(try fixture.store.rowCount("local_vocabulary_occurrences") == 1)
        #expect(try fixture.store.rowCount("local_review_events") == 1)
        #expect(try fixture.store.rowCount("local_transcript_revisions") == 2)
    }

    @Test("isolated LibraryStore and v2 migrator do not read Persistence.root")
    func isolatedLibraryStoreDoesNotReadPersistenceRoot() throws {
        let token = "v2-lib-\(UUID().uuidString)"
        let planted = Transcript(
            chapterID: token,
            audioPath: "/tmp/\(token).m4b",
            createdAt: occurredAt,
            locale: "en-US",
            segments: [
                TranscriptSegment(
                    id: "seg",
                    start: 0,
                    end: 1,
                    words: [TranscriptWord(id: "w", text: token, start: 0, end: 1, confidence: nil)]
                )
            ],
            source: "planted",
            ebookAligned: false
        )
        let plantedURL = Persistence.transcriptURL(chapterID: token)
        try JSONEncoder.iso.encode(planted).write(to: plantedURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: plantedURL) }

        let fixture = try IsolatedMigrationFixture()
        defer { fixture.remove() }
        _ = LibraryStore(fileURL: fixture.sqliteURL)
        let store = LocalSQLiteStore(fileURL: fixture.sqliteURL)
        _ = try store.migrateLegacyData(from: fixture.sources)

        #expect(try store.loadTranscripts().isEmpty)
        let sqliteData = try Data(contentsOf: fixture.sqliteURL)
        #expect(sqliteData.range(of: Data(token.utf8)) == nil)
        #expect(Persistence.loadTranscriptJSON(chapterID: token)?.segments[0].words[0].text == token)
        #expect(store.url != Persistence.root.appendingPathComponent("library.sqlite"))
    }

    @Test("shared importLegacyJSON path migrates from an isolated persistence root")
    func sharedImportLegacyJSONPathMigratesFromIsolatedRoot() throws {
        let fixture = try IsolatedMigrationFixture()
        defer { fixture.remove() }
        try JSONEncoder.iso.encode([
            KnownLemmaRecord(language: "en", form: "forest", updatedAt: occurredAt)
        ]).write(to: fixture.root.appendingPathComponent("lexicon.json"), options: .atomic)
        try JSONEncoder.iso.encode(StudyActivityLog(days: ["2023-11-14"]))
            .write(to: fixture.root.appendingPathComponent("study-activity.json"), options: .atomic)

        let library = LibraryStore(fileURL: fixture.sqliteURL, importingLegacyJSONFrom: fixture.root)
        let store = LocalSQLiteStore(fileURL: fixture.sqliteURL)

        #expect(library.url == fixture.sqliteURL)
        #expect(try store.loadReceipt()?.schemaVersion == LocalSchemaV2.version)
        #expect(try store.loadKnownLemmas().map(\.form) == ["forest"])
        #expect(try store.loadStudyActivityDays() == ["2023-11-14"])
        #expect(library.url != Persistence.root.appendingPathComponent("library.sqlite"))
    }

    private func migrateFullFixture() throws -> PlantedMigration {
        let planted = try plantFullFixture()
        _ = try planted.store.migrateLegacyData(from: planted.sources)
        return planted
    }

    private func plantFullFixture() throws -> PlantedMigration {
        let fixture = try IsolatedMigrationFixture()
        let transcript = Transcript(
            chapterID: "chapter-loomings",
            audioPath: "/Books/Moby-Dick/chapter-01.m4b",
            chapterStart: 0,
            createdAt: occurredAt,
            locale: "en-US",
            segments: [
                TranscriptSegment(
                    id: "seg-1",
                    start: 0,
                    end: 2.4,
                    words: [
                        TranscriptWord(id: "w-1", text: "Call", start: 0, end: 0.4, confidence: 0.96),
                        TranscriptWord(id: "w-2", text: " me", start: 0.4, end: 0.7, confidence: 0.99),
                        TranscriptWord(id: "w-3", text: " Ishmael", start: 0.7, end: 1.4, confidence: 0.98)
                    ],
                    ebookText: "Call me Ishmael.",
                    alignmentScore: 0.94,
                    individualEbookMatchTrusted: true,
                    documentEbookUseAllowed: true
                )
            ],
            source: "apple-speech",
            ebookAligned: true,
            ebookAlignment: EPUBAlignmentAssessment(
                status: .trusted,
                reason: "anchors matched across sampled sentences",
                metrics: EPUBAlignmentMetrics(
                    extractedWordCount: 12_840,
                    extractedSentenceCount: 612,
                    sampledAnchorCount: 48,
                    matchedAnchorCount: 45,
                    matchedCoverage: 0.9375,
                    medianScore: 0.91,
                    lowerPercentileScore: 0.74,
                    backwardJumps: 1,
                    longestUnmatchedPassage: 18,
                    titleSimilarity: 0.99,
                    authorSimilarity: 0.88,
                    candidateComparisons: 3,
                    detailedAlignmentPerformed: true
                )
            )
        )
        let vocab = VocabEntry(
            id: "vocab-ishmael",
            word: "Ishmael",
            category: .word,
            definition: "a biblical wanderer",
            dictionaryName: "牛津英汉汉英词典",
            dictionaryHTML: "<html><body><b>Ishmael</b> n. 以实玛利</body></html>",
            translation: "以实玛利",
            translationLanguage: "zh-Hans",
            translationModel: "grok-4.6",
            sourceLanguage: "en",
            context: "Call me Ishmael.",
            spokenText: "Call me Ishmael.",
            ebookText: "Call me Ishmael.",
            bookID: "book-moby-dick",
            bookTitle: "Moby-Dick",
            chapterID: "chapter-loomings",
            chapterTitle: "Loomings",
            segmentID: "seg-1",
            wordID: "w-3",
            timestamp: 1.2,
            addedAt: occurredAt,
            reviewCount: 3,
            nextReview: nextReview,
            lastReviewedAt: lastReviewedAt,
            lastReviewQuality: .remember,
            reviewIntervalDays: 7,
            reviewEaseFactor: 2.6,
            isInLearnList: true
        )
        let pending = GlossEntry(
            id: "gloss-pending",
            kind: .sentence,
            language: "zh-Hans",
            source: "Call me Ishmael.",
            context: nil,
            text: "叫我以实玛利。",
            status: .pending,
            model: "grok-4.6",
            bookID: "book-moby-dick",
            bookTitle: "Moby-Dick",
            chapterID: "chapter-loomings",
            chapterTitle: "Loomings",
            timestamp: 0,
            createdAt: occurredAt
        )
        let accepted = GlossEntry(
            id: "gloss-accepted",
            kind: .word,
            language: "zh-Hans",
            source: "Ishmael",
            context: "Call me Ishmael.",
            text: "以实玛利",
            status: .accepted,
            model: "grok-4.6",
            bookID: "book-moby-dick",
            bookTitle: "Moby-Dick",
            chapterID: "chapter-loomings",
            chapterTitle: "Loomings",
            timestamp: 1.2,
            createdAt: occurredAt,
            decidedAt: occurredAt.addingTimeInterval(400)
        )

        do {
            let library = LibraryStore(fileURL: fixture.sqliteURL)
            try library.saveTranscript(transcript)
            library.replaceVocab([vocab])
            library.replaceGlosses([pending, accepted])
        }

        let jsonOnly = Transcript(
            chapterID: "chapter-json-only",
            audioPath: "/Books/Moby-Dick/chapter-02.m4b",
            createdAt: occurredAt,
            locale: "en-US",
            segments: [
                TranscriptSegment(
                    id: "seg-json",
                    start: 0,
                    end: 1.5,
                    words: [TranscriptWord(id: "w-json", text: "Some years ago", start: 0, end: 1.5, confidence: 0.9)]
                )
            ],
            source: "apple-speech",
            ebookAligned: false
        )
        let transcriptsDir = fixture.root.appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(jsonOnly).write(
            to: transcriptsDir.appendingPathComponent("chapter-json-only.json"),
            options: .atomic
        )

        let ignoredVocab = VocabEntry(
            id: "vocab-whale",
            word: "whale",
            context: "the white whale",
            bookID: "book-moby-dick",
            bookTitle: "Moby-Dick",
            chapterID: "chapter-loomings",
            chapterTitle: "Loomings",
            timestamp: 8,
            addedAt: occurredAt
        )
        try JSONEncoder.iso.encode([vocab, ignoredVocab]).write(
            to: fixture.root.appendingPathComponent("vocab.json"),
            options: .atomic
        )
        var jsonOnlyGloss = pending
        jsonOnlyGloss.id = "gloss-json-only"
        try JSONEncoder.iso.encode([pending, accepted, jsonOnlyGloss]).write(
            to: fixture.root.appendingPathComponent("glosses.json"),
            options: .atomic
        )
        try JSONEncoder.iso.encode([
            KnownLemmaRecord(language: "en", form: "forest", updatedAt: occurredAt),
            KnownLemmaRecord(language: "en", form: "whale", updatedAt: occurredAt.addingTimeInterval(86_400))
        ]).write(to: fixture.root.appendingPathComponent("lexicon.json"), options: .atomic)
        try JSONEncoder.iso.encode(StudyActivityLog(days: ["2023-11-14", "2023-11-15"]))
            .write(to: fixture.root.appendingPathComponent("study-activity.json"), options: .atomic)

        var settings = AppSettings.default
        settings.playbackRate = 1.25
        settings.vocabReviewPrompt = VocabReviewPrompt.cloze.rawValue
        settings.targetLanguage = StudyLanguage.zhHans.rawValue
        try JSONEncoder().encode(settings).write(
            to: fixture.root.appendingPathComponent("settings.json"),
            options: .atomic
        )

        let summary = ChapterSummaryRecord(
            id: ChapterSummaryRecord.makeID(chapterID: "chapter-loomings", language: "zh-Hans"),
            summary: ChapterSummaryPresentation(
                overview: "A sailor narrates his first days at sea",
                keyPoints: ["He takes the name Ishmael"],
                charactersOrIdeas: ["Ishmael"],
                keyConcepts: [ChapterSummaryPresentation.Concept(name: "wandering", explanation: "restlessness")],
                themes: ["identity"]
            ),
            language: "zh-Hans",
            status: .pending,
            model: "grok-4.6",
            bookID: "book-moby-dick",
            bookTitle: "Moby-Dick",
            chapterID: "chapter-loomings",
            chapterTitle: "Loomings",
            createdAt: occurredAt,
            decidedAt: nil,
            replacedSummary: nil,
            replacedModel: nil
        )
        try JSONEncoder.iso.encode([summary]).write(
            to: fixture.root.appendingPathComponent("chapter-summaries.json"),
            options: .atomic
        )
        let checkpoint = ChapterTranslationCheckpoint(
            chapterID: "chapter-loomings",
            language: "zh-Hans",
            mode: .untranslatedOnly,
            nextSegmentIndex: 4,
            totalSentences: 12,
            status: .awaitingReview,
            updatedAt: occurredAt
        )
        try JSONEncoder.iso.encode([checkpoint]).write(
            to: fixture.root.appendingPathComponent("chapter-translation-checkpoints.json"),
            options: .atomic
        )

        return PlantedMigration(
            fixture: fixture,
            store: LocalSQLiteStore(fileURL: fixture.sqliteURL)
        )
    }

    private func requiredCounts(_ store: LocalSQLiteStore) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for name in LocalSchemaV2.requiredTables {
            counts[name] = try store.rowCount(name)
        }
        return counts
    }
}

private struct IsolatedMigrationFixture {
    let root: URL

    var sqliteURL: URL { root.appendingPathComponent("library.sqlite") }

    var sources: LegacyLocalDataSources {
        LegacyLocalDataSources(sqliteURL: sqliteURL, persistenceRoot: root)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-schema-v2-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct PlantedMigration {
    let fixture: IsolatedMigrationFixture
    let store: LocalSQLiteStore

    var sources: LegacyLocalDataSources { fixture.sources }

    func cleanup() {
        fixture.remove()
    }
}
