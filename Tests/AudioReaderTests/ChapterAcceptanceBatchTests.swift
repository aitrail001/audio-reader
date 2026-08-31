import Foundation
import Testing
@testable import AudioReader

@Suite("Chapter acceptance batch")
struct ChapterAcceptanceBatchTests {
    @MainActor
    @Test("Accept all reports progress and finishes the shared app-state workflow")
    func reportsProgressWhileAcceptingAll() async throws {
        let source = "A sentence ready for review."
        let chapter = Chapter(
            id: "chapter",
            index: 0,
            title: "Chapter",
            audioPath: "/tmp/chapter.m4b",
            duration: 2,
            startTime: nil
        )
        let state = AppState(composition: .inMemory())
        state.settings.targetLanguage = "zh-Hans"
        state.books = [Book(
            id: "book",
            title: "Book",
            author: nil,
            folderPath: "/tmp",
            coverPath: nil,
            ebookPath: nil,
            chapters: [chapter]
        )]
        state.selectedBookID = "book"
        state.selectedChapterID = chapter.id
        state.transcript = Transcript(
            chapterID: chapter.id,
            audioPath: chapter.audioPath,
            createdAt: Date(timeIntervalSince1970: 1),
            locale: "en-US",
            segments: [segment(id: "segment", text: source)],
            source: "test",
            ebookAligned: false
        )
        state.glosses = [GlossEntry(
            id: "pending",
            kind: .sentence,
            language: "zh-Hans",
            source: source,
            context: nil,
            text: "译文",
            status: .pending,
            model: "test-model",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            decidedAt: nil
        )]
        state.vocab = []

        state.acceptAllChapterTranslations()

        #expect(state.chapterAcceptanceProgress != nil)
        #expect(state.glosses.first?.status == .pending)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while state.chapterAcceptanceProgress != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.chapterAcceptanceProgress == nil)
        #expect(state.glosses.first?.status == .accepted)
        let sentence = state.vocab.first { $0.category == .sentence && $0.translation == "译文" }
        #expect(sentence?.captureSource == .acceptedSentenceTranslation)
        #expect(sentence?.reviewEligible == false)
        #expect(VocabularyLearningAnalytics.queue(entries: state.vocab, at: .now).new.isEmpty)
    }

    @Test("Accepted sentences update vocabulary and capture phrases without duplicates")
    func updatesSentencesAndCapturesPhrases() {
        let source = "A very useful phrase appears here."
        let existing = VocabEntry(
            id: "sentence-entry",
            word: source,
            captureSource: .acceptedSentenceTranslation,
            reviewEligible: false,
            category: .sentence,
            translation: "Old translation",
            context: source,
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )
        let gloss = acceptedGloss(
            id: "accepted",
            source: source,
            text: "译文：新译文\n短语：\n- useful phrase — 有用的短语"
        )

        let result = ChapterAcceptanceBatch.prepare(
            glosses: [gloss, gloss],
            vocab: [existing],
            segments: [segment(id: "segment", text: source)],
            defaults: .empty
        )

        let sentence = result.vocab.first { $0.id == existing.id }
        #expect(sentence?.translation == gloss.text)
        #expect(sentence?.translationModel == gloss.model)
        #expect(sentence?.captureSource == .acceptedSentenceTranslation)
        #expect(sentence?.reviewEligible == false)
        let phrases = result.vocab.filter { $0.category == .phrase && $0.word == "useful phrase" }
        #expect(phrases.count == 1)
        #expect(phrases.first?.translation == "有用的短语")
        #expect(phrases.first?.segmentID == "segment")
        #expect(phrases.first?.captureSource == .automaticPhraseSuggestion)
        #expect(phrases.first?.reviewEligible == false)
        #expect(VocabularyLearningAnalytics.queue(entries: result.vocab, at: .now).new.isEmpty)
        #expect(result.upserts.count == 2)
    }

    @Test("Large chapter acceptance is indexed and produces one sentence per gloss")
    func preparesLargeChapter() {
        let count = 5_000
        let glosses = (0..<count).map { index in
            acceptedGloss(
                id: "gloss-\(index)",
                source: "Sentence \(index)",
                text: "Translation \(index)"
            )
        }
        let vocab = (0..<count).map { index in
            VocabEntry(
                id: "vocab-\(index)",
                word: "Sentence \(index)",
                category: .sentence,
                translation: "Old \(index)",
                context: "  SENTENCE   \(index)  ",
                bookID: "book",
                bookTitle: "Book",
                chapterID: "chapter",
                chapterTitle: "Chapter",
                timestamp: Double(index),
                addedAt: Date(timeIntervalSince1970: 1)
            )
        }

        let result = ChapterAcceptanceBatch.prepare(
            glosses: glosses,
            vocab: vocab,
            segments: [],
            defaults: .empty
        )

        #expect(result.vocab.count == count)
        #expect(result.upserts.count == count)
        #expect(result.vocab.allSatisfy { $0.translation?.hasPrefix("Translation ") == true })
    }

    @Test("Accepting one hundred sentence translations creates zero New cards")
    func acceptedSentenceTranslationsAreReferenceOnly() {
        let glosses = (0..<100).map { index in
            acceptedGloss(
                id: "gloss-\(index)",
                source: "Sentence \(index)",
                text: "译文：Translation \(index)"
            )
        }

        let result = ChapterAcceptanceBatch.prepare(
            glosses: glosses,
            vocab: [],
            segments: [],
            defaults: .empty
        )

        #expect(result.vocab.count == 100)
        #expect(result.vocab.allSatisfy { $0.captureSource == .acceptedSentenceTranslation })
        #expect(result.vocab.allSatisfy { !$0.reviewEligible })
        #expect(VocabularyLearningAnalytics.queue(entries: result.vocab, at: .now).new.isEmpty)
    }

    @Test("Acceptance corrects one hundred legacy automatic sentences and phrases")
    func correctsLegacyAutomaticCaptureClassification() {
        let glosses = (0..<100).map { index in
            acceptedGloss(
                id: "gloss-\(index)",
                source: "Sentence \(index)",
                text: "译文：Translation \(index)\n短语：\n- phrase \(index) — meaning \(index)"
            )
        }
        let sentences = (0..<100).map { index in
            VocabEntry(
                id: "sentence-\(index)",
                word: "Sentence \(index)",
                category: .sentence,
                translation: "old",
                context: "Sentence \(index)",
                bookID: "book",
                bookTitle: "Book",
                chapterID: "chapter",
                chapterTitle: "Chapter",
                timestamp: 1,
                addedAt: Date(timeIntervalSince1970: 1)
            )
        }
        let phrases = (0..<100).map { index in
            VocabEntry(
                id: "phrase-\(index)",
                word: "phrase \(index)",
                category: .phrase,
                translation: "meaning \(index)",
                context: "Sentence \(index)",
                bookID: "book",
                bookTitle: "Book",
                chapterID: "chapter",
                chapterTitle: "Chapter",
                timestamp: 1,
                addedAt: Date(timeIntervalSince1970: 1)
            )
        }

        let result = ChapterAcceptanceBatch.prepare(
            glosses: glosses,
            vocab: sentences + phrases,
            segments: [],
            defaults: .empty
        )

        let migratedSentences = result.vocab.filter { $0.category == .sentence }
        let migratedPhrases = result.vocab.filter { $0.category == .phrase }
        #expect(migratedSentences.count == 100)
        #expect(migratedPhrases.count == 100)
        #expect(migratedSentences.allSatisfy {
            $0.captureSource == .acceptedSentenceTranslation && !$0.reviewEligible
        })
        #expect(migratedPhrases.allSatisfy {
            $0.captureSource == .automaticPhraseSuggestion && !$0.reviewEligible
        })
        #expect(result.upserts.count == 200)
        #expect(VocabularyLearningAnalytics.queue(entries: result.vocab, at: .now).new.isEmpty)
    }

    @Test("Already imported accepted glosses do not trigger another persistence batch")
    func skipsUnchangedVocabulary() {
        let gloss = acceptedGloss(id: "accepted", source: "Sentence", text: "Translation")
        let existing = VocabEntry(
            id: "existing",
            word: "Sentence",
            captureSource: .acceptedSentenceTranslation,
            reviewEligible: false,
            category: .sentence,
            translation: gloss.text,
            translationLanguage: gloss.language,
            translationModel: gloss.model,
            context: gloss.source,
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )

        let result = ChapterAcceptanceBatch.prepare(
            glosses: [gloss],
            vocab: [existing],
            segments: [],
            defaults: .empty
        )

        #expect(result.vocab == [existing])
        #expect(result.upserts.isEmpty)
    }

    private func acceptedGloss(id: String, source: String, text: String) -> GlossEntry {
        GlossEntry(
            id: id,
            kind: .sentence,
            language: "zh-Hans",
            source: source,
            context: nil,
            text: text,
            status: .accepted,
            model: "qwen3.7-flash",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            decidedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func segment(id: String, text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: 1,
            end: 2,
            words: [TranscriptWord(id: "word", text: text, start: 1, end: 2, confidence: nil)],
            ebookText: nil,
            alignmentScore: nil
        )
    }
}
