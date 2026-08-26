import Foundation
import Testing
@testable import AudioReaderDomain

@Suite("Local repository records")
struct LocalRepositoryRecordTests {
    private let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("stored records round-trip through Codable with typed IDs")
    func storedRecordsRoundTripThroughCodable() throws {
        let settings = StoredSettings.default
        try assertRoundTrip(settings)

        let book = StoredBook(
            id: BookID(rawValue: "book-1"),
            title: "Moby-Dick",
            author: "Herman Melville",
            source: "localFolder",
            chapters: [
                StoredChapter(
                    id: ChapterID(rawValue: "chapter-1"),
                    index: 0,
                    title: "Loomings",
                    duration: 321.5,
                    startTime: nil
                )
            ]
        )
        try assertRoundTrip(book)

        let transcript = sampleTranscript()
        try assertRoundTrip(transcript)

        let vocab = sampleVocabulary()
        try assertRoundTrip(vocab)

        let lemma = StoredKnownLemma(language: "en", form: "forest", updatedAt: occurredAt)
        try assertRoundTrip(lemma)

        let review = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-1"),
            vocabularyID: vocab.id,
            face: "recognition",
            rating: "remember",
            reviewedAt: occurredAt
        )
        try assertRoundTrip(review)

        let assistant = sampleAssistantResult()
        try assertRoundTrip(assistant)

        let mutation = OutboxMutation(
            id: MutationID(rawValue: "mutation-1"),
            entityType: .vocabulary,
            entityID: vocab.id.rawValue,
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: occurredAt,
            payload: Data("{\"surface\":\"forest\"}".utf8),
            status: .pending
        )
        try assertRoundTrip(mutation)
        #expect(mutation.id == MutationID(rawValue: "mutation-1"))
        #expect(book.id == BookID(rawValue: "book-1"))
        #expect(transcript.chapterID == ChapterID(rawValue: "chapter-1"))
    }

    @Test("missing settings match current Persistence defaults for shared fields")
    func missingSettingsMatchCurrentDefaults() {
        let settings = StoredSettings.default
        #expect(settings.playbackRate == 1.0)
        #expect(settings.skipSeconds == 5)
        #expect(settings.transcriptionLanguage == "en-US")
        #expect(settings.textSource == "Spoken")
        #expect(settings.readerLanguageLevel == "intermediate")
        #expect(settings.targetLanguage == "zh-Hans")
        #expect(settings.appearance == "dark")
        #expect(settings.vocabReviewPrompt == "recognition")
        #expect(settings.showStudyOverlay == false)
        #expect(settings.playOnSelect == true)
        #expect(settings.deepReadingMode == false)
        #expect(settings.autoTranslate == false)
        #expect(settings.readerFont == "New York")
        #expect(settings.readerFontScale == 1.0)
        #expect(settings.readerBold == false)
        #expect(settings.readerLineSpacing == 1.0)
        #expect(settings.readerWordSpacing == 2.0)
        #expect(settings.readerMargin == 32)
        #expect(settings.libraryPath.isEmpty)
    }

    @Test("repository protocols are usable without a concrete store")
    func repositoryProtocolsAreUsableWithoutAConcreteStore() throws {
        let settings = StubSettingsRepository()
        var loaded = try settings.loadSettings()
        loaded.playbackRate = 1.25
        try settings.saveSettings(loaded)
        #expect(try settings.loadSettings().playbackRate == 1.25)
    }

    private func sampleTranscript() -> StoredTranscript {
        StoredTranscript(
            chapterID: ChapterID(rawValue: "chapter-1"),
            localMediaKey: "chapter-1-audio",
            chapterStart: nil,
            createdAt: occurredAt,
            locale: "en-US",
            source: "apple-speech",
            ebookAligned: false,
            ebookAlignment: StoredEPUBAlignment(
                status: "trusted",
                reason: "anchors matched",
                metrics: StoredEPUBAlignmentMetrics(
                    extractedWordCount: 12,
                    extractedSentenceCount: 2,
                    sampledAnchorCount: 4,
                    matchedAnchorCount: 4,
                    matchedCoverage: 1,
                    medianScore: 0.9,
                    lowerPercentileScore: 0.8,
                    backwardJumps: 0,
                    longestUnmatchedPassage: 0,
                    titleSimilarity: 1,
                    authorSimilarity: 0.95,
                    candidateComparisons: 3,
                    detailedAlignmentPerformed: true
                )
            ),
            ebookUseOverride: nil,
            segments: [
                StoredTranscriptSegment(
                    id: "seg-1",
                    start: 0,
                    end: 1.5,
                    words: [
                        StoredTranscriptWord(
                            id: "w-1",
                            text: "Call",
                            start: 0,
                            end: 0.4,
                            confidence: 0.9
                        )
                    ],
                    ebookText: nil,
                    alignmentScore: nil,
                    individualEbookMatchTrusted: nil,
                    documentEbookUseAllowed: nil
                )
            ]
        )
    }

    private func sampleVocabulary() -> StoredVocabularyOccurrence {
        StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "vocab-1"),
            surface: "forest",
            category: "word",
            definition: "a large area of trees",
            dictionaryName: nil,
            dictionaryHTML: nil,
            translation: "森林",
            translationLanguage: "zh-Hans",
            translationModel: nil,
            sourceLanguage: "en",
            context: "the forest was dark",
            spokenText: "the forest was dark",
            ebookText: nil,
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Loomings",
            segmentID: "seg-1",
            wordID: "w-1",
            timestamp: 12.5,
            addedAt: occurredAt,
            reviewCount: 0,
            nextReview: nil,
            lastReviewedAt: nil,
            lastReviewQuality: nil,
            reviewIntervalDays: 0,
            reviewEaseFactor: 2.5,
            isInLearnList: false
        )
    }

    private func sampleAssistantResult() -> StoredAssistantResult {
        StoredAssistantResult(
            id: "gloss-1",
            kind: .sentenceGloss,
            status: .pending,
            language: "zh-Hans",
            model: "test-model",
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Loomings",
            source: "Call me Ishmael.",
            text: "叫我以实玛利。",
            context: nil,
            timestamp: 0,
            createdAt: occurredAt,
            decidedAt: nil,
            replacedText: nil,
            replacedModel: nil
        )
    }

    private func assertRoundTrip<Value: Codable & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(Value.self, from: data) == value)
    }
}

private final class StubSettingsRepository: SettingsRepository, @unchecked Sendable {
    private var value = StoredSettings.default

    func loadSettings() throws -> StoredSettings { value }

    func saveSettings(_ settings: StoredSettings) throws {
        value = settings
    }
}
