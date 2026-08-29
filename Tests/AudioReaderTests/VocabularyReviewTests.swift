import Foundation
import Testing
@testable import AudioReader

@Suite("Vocabulary review scheduling")
struct VocabularyReviewTests {
    @Test("New and overdue vocabulary is recommended before future reviews")
    func recommendsDueVocabulary() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let new = entry(id: "new", addedAt: now.addingTimeInterval(-10))
        let overdue = entry(
            id: "overdue",
            addedAt: now.addingTimeInterval(-20),
            nextReview: now.addingTimeInterval(-60)
        )
        let future = entry(
            id: "future",
            addedAt: now.addingTimeInterval(-30),
            nextReview: now.addingTimeInterval(60)
        )

        let due = VocabReviewScheduler.dueEntries(in: [future, new, overdue], at: now)

        #expect(due.map(\.id) == ["new", "overdue"])
    }

    @Test(
        "First review records its time and quality and uses the initial cadence",
        arguments: [
            (VocabReviewQuality.forgot, 1.0),
            (VocabReviewQuality.vague, 3.0),
            (VocabReviewQuality.remember, 7.0)
        ]
    )
    func recordsFirstReview(quality: VocabReviewQuality, expectedDays: Double) throws {
        let now = Date(timeIntervalSince1970: 2_000_000)

        let reviewed = VocabReviewScheduler.applying(quality, to: entry(), at: now)

        #expect(reviewed.reviewCount == 1)
        #expect(reviewed.lastReviewedAt == now)
        #expect(reviewed.lastReviewQuality == quality)
        #expect(reviewed.reviewIntervalDays == expectedDays)
        let nextReview = try #require(reviewed.nextReview)
        #expect(nextReview.timeIntervalSince(now) == expectedDays * 86_400)
    }

    @Test("Cloze sessions still record review quality on the same scheduler")
    func clozeSessionStillAppliesSchedulerQuality() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let card = entry(id: "cloze", category: .word)
        #expect(VocabCloze.blankedSentence(for: card).contains(VocabCloze.blank))

        let reviewed = VocabReviewScheduler.applying(.remember, to: card, at: now)

        #expect(reviewed.reviewCount == 1)
        #expect(reviewed.lastReviewQuality == .remember)
        #expect(reviewed.reviewIntervalDays == 7)
    }

    @Test("Cloze blanks a whole word instead of a substring")
    func clozeUsesWholeWordMatch() {
        var card = entry(id: "whole-word", category: .word)
        card.word = "he"
        card.context = "The forest he entered."

        #expect(VocabCloze.blankedSentence(for: card) == "The forest ____ entered.")
        let range = StudyTextMatch.firstWholeTokenRange(of: "he", in: card.context)
        #expect(range.map { String(card.context[$0]) } == "he")
    }

    @Test("Remembering expands the previous interval and forgetting resets it")
    func adjustsLaterReviews() throws {
        let firstReview = Date(timeIntervalSince1970: 2_000_000)
        let remembered = VocabReviewScheduler.applying(
            .remember,
            to: entry(reviewCount: 2, reviewIntervalDays: 7, reviewEaseFactor: 2.5),
            at: firstReview
        )

        #expect(remembered.reviewIntervalDays == 17.5)
        #expect(remembered.reviewEaseFactor == 2.55)
        #expect(try #require(remembered.nextReview).timeIntervalSince(firstReview) == 17.5 * 86_400)

        let forgottenAt = firstReview.addingTimeInterval(100)
        let forgotten = VocabReviewScheduler.applying(.forgot, to: remembered, at: forgottenAt)

        #expect(forgotten.reviewIntervalDays == 1)
        #expect(forgotten.reviewEaseFactor == 2.35)
        #expect(try #require(forgotten.nextReview).timeIntervalSince(forgottenAt) == 86_400)
    }

    @Test("Legacy vocabulary decodes as an immediately due card")
    func decodesLegacyVocabulary() throws {
        let original = entry()
        let encoded = try JSONEncoder.iso.encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lastReviewedAt")
        object.removeValue(forKey: "lastReviewQuality")
        object.removeValue(forKey: "reviewIntervalDays")
        object.removeValue(forKey: "reviewEaseFactor")
        object.removeValue(forKey: "nextReview")
        object.removeValue(forKey: "isInLearnList")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.iso.decode(VocabEntry.self, from: legacy)

        #expect(decoded.lastReviewedAt == nil)
        #expect(decoded.lastReviewQuality == nil)
        #expect(decoded.reviewIntervalDays == 0)
        #expect(decoded.reviewEaseFactor == 2.5)
        #expect(!decoded.isInLearnList)
        #expect(VocabReviewScheduler.isDue(decoded, at: Date()))
    }

    @Test("Learn-list membership survives vocabulary persistence encoding")
    func learnListMembershipRoundTrips() throws {
        let learned = entry(isInLearnList: true)

        let decoded = try JSONDecoder.iso.decode(
            VocabEntry.self,
            from: JSONEncoder.iso.encode(learned)
        )

        #expect(decoded.isInLearnList)
    }

    @Test("Audiobook source language survives vocabulary persistence encoding")
    func sourceLanguageRoundTrips() throws {
        var original = entry()
        original.sourceLanguage = "es"

        let decoded = try JSONDecoder.iso.decode(
            VocabEntry.self,
            from: JSONEncoder.iso.encode(original)
        )

        #expect(decoded.sourceLanguage == "es")
    }

    @Test("Review scopes select due items by book, category, and learn-list membership")
    func selectsScopedReviewEntries() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let bookWord = entry(id: "book-word", bookID: "book-a", category: .word)
        let bookPhrase = entry(id: "book-phrase", bookID: "book-a", category: .phrase)
        let otherLearned = entry(id: "other-learned", bookID: "book-b", category: .sentence, isInLearnList: true)
        let bookLearned = entry(id: "book-learned", bookID: "book-a", category: .sentence, isInLearnList: true)
        let futureLearned = entry(
            id: "future-learned",
            bookID: "book-a",
            category: .word,
            nextReview: now.addingTimeInterval(60),
            isInLearnList: true
        )
        let entries = [futureLearned, otherLearned, bookPhrase, bookLearned, bookWord]

        #expect(Set(VocabReviewScheduler.dueEntries(
            in: entries,
            scope: .book("book-a"),
            at: now
        ).map(\.id)) == ["book-word", "book-phrase", "book-learned"])
        #expect(VocabReviewScheduler.dueEntries(
            in: entries,
            scope: .bookCategory("book-a", .phrase),
            at: now
        ).map(\.id) == ["book-phrase"])
        #expect(Set(VocabReviewScheduler.dueEntries(
            in: entries,
            scope: .learnList,
            at: now
        ).map(\.id)) == ["other-learned", "book-learned"])
        #expect(VocabReviewScheduler.dueEntries(
            in: entries,
            scope: .learnListBook("book-a"),
            at: now
        ).map(\.id) == ["book-learned"])
    }

    @Test("Learn-list browsing includes future items when no review is due")
    func browsesLearnListIndependentlyFromDueReview() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let futureLearned = entry(
            id: "future-learned",
            nextReview: now.addingTimeInterval(86_400),
            isInLearnList: true
        )
        let ordinary = entry(id: "ordinary")
        let entries = [futureLearned, ordinary]

        #expect(VocabReviewScheduler.scopedEntries(
            in: entries,
            scope: .learnList
        ).map(\.id) == ["future-learned"])
        #expect(VocabReviewScheduler.dueEntries(
            in: entries,
            scope: .learnList,
            at: now
        ).isEmpty)
    }

    @MainActor
    @Test("Learn-list management removes an item without deleting its vocabulary")
    func removesOnlyLearnListMembership() {
        let state = AppState(composition: .inMemory())
        state.vocab = [entry(id: "learned", isInLearnList: true)]

        state.setVocabularyLearnList("learned", included: false)

        #expect(state.vocab.count == 1)
        #expect(state.vocab.first?.id == "learned")
        #expect(state.vocab.first?.isInLearnList == false)
    }

    @Test("Review state survives vocabulary persistence encoding")
    func reviewStateRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reviewed = VocabReviewScheduler.applying(.vague, to: entry(), at: now)

        let decoded = try JSONDecoder.iso.decode(
            VocabEntry.self,
            from: JSONEncoder.iso.encode(reviewed)
        )

        #expect(decoded.reviewCount == 1)
        #expect(decoded.lastReviewedAt == now)
        #expect(decoded.lastReviewQuality == .vague)
        #expect(decoded.nextReview == reviewed.nextReview)
        #expect(decoded.reviewIntervalDays == 3)
        #expect(decoded.reviewEaseFactor == 2.45)
    }

    @Test("The next round recommendation uses the earliest future review")
    func recommendsNextRound() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let tomorrow = now.addingTimeInterval(86_400)
        let later = now.addingTimeInterval(7 * 86_400)
        let unscheduled = entry(id: "new")
        let first = entry(id: "first", nextReview: later)
        let second = entry(id: "second", nextReview: tomorrow)

        #expect(VocabReviewScheduler.nextReviewDate(in: [first, unscheduled, second], after: now) == tomorrow)
    }

    @Test("Learning queue separates due reviews, learning cards, and new cards")
    func buildsLearningQueue() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let new = entry(id: "new")
        let learningDue = entry(
            id: "learning-due",
            reviewCount: 2,
            nextReview: now.addingTimeInterval(-30),
            reviewIntervalDays: 3
        )
        let learningLater = entry(
            id: "learning-later",
            reviewCount: 1,
            nextReview: now.addingTimeInterval(86_400),
            reviewIntervalDays: 1
        )
        let reviewDue = entry(
            id: "review-due",
            reviewCount: 4,
            nextReview: now.addingTimeInterval(-60),
            reviewIntervalDays: 14
        )
        let reviewLater = entry(
            id: "review-later",
            reviewCount: 3,
            nextReview: now.addingTimeInterval(7 * 86_400),
            reviewIntervalDays: 7
        )

        let queue = VocabularyLearningAnalytics.queue(
            entries: [reviewLater, new, learningLater, reviewDue, learningDue],
            at: now
        )

        #expect(queue.new.map(\.id) == ["new"])
        #expect(queue.learning.map(\.id) == ["learning-due", "learning-later"])
        #expect(queue.due.map(\.id) == ["learning-due", "review-due"])
        #expect(queue.session.map(\.id) == ["learning-due", "review-due", "new"])
    }

    @Test("Daily learning sessions cap new cards without hiding the backlog")
    func capsDailyNewCards() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let entries = (0..<25).map { index in
            entry(id: String(format: "new-%02d", index))
        }

        let queue = VocabularyLearningAnalytics.queue(entries: entries, at: now)

        #expect(queue.new.count == 25)
        #expect(queue.session.count == VocabularyLearningPolicy.dailyNewCardLimit)
        #expect(queue.session.map(\.id) == entries.prefix(20).map(\.id))
    }

    @Test("Learning snapshot derives today, streak, retention, forecast, and book distribution")
    func buildsLearningSnapshot() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 12)))
        let today = try #require(calendar.date(byAdding: .hour, value: -1, to: now))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: now))

        var newA = entry(id: "new-a", bookID: "book-a")
        newA.bookTitle = "Book A"
        var learningA = entry(
            id: "learning-a",
            bookID: "book-a",
            reviewCount: 2,
            nextReview: now.addingTimeInterval(-60),
            reviewIntervalDays: 3
        )
        learningA.bookTitle = "Book A"
        var reviewB = entry(
            id: "review-b",
            bookID: "book-b",
            reviewCount: 4,
            nextReview: nextDay,
            reviewIntervalDays: 14
        )
        reviewB.bookTitle = "Book B"
        let events = [
            reviewEvent(id: "today-good", vocabularyID: learningA.id, rating: .remember, at: today),
            reviewEvent(id: "today-again", vocabularyID: newA.id, rating: .forgot, at: today),
            reviewEvent(id: "yesterday", vocabularyID: reviewB.id, rating: .vague, at: yesterday),
            reviewEvent(id: "two-days", vocabularyID: learningA.id, rating: .remember, at: twoDaysAgo)
        ]

        let snapshot = VocabularyLearningAnalytics.snapshot(
            entries: [newA, learningA, reviewB],
            events: events,
            at: now,
            calendar: calendar
        )

        #expect(snapshot.todayReviewCount == 2)
        #expect(snapshot.streakDays == 3)
        #expect(snapshot.retention == 0.75)
        #expect(snapshot.forecast.prefix(2).map(\.count) == [1, 1])
        #expect(snapshot.books.map(\.bookTitle) == ["Book A", "Book B"])
        #expect(snapshot.books[0].newCount == 1)
        #expect(snapshot.books[0].learningCount == 1)
        #expect(snapshot.books[0].dueCount == 1)
        #expect(snapshot.books[0].reviewedToday == 2)
        #expect(snapshot.books[1].reviewCount == 1)
    }

    @MainActor
    @Test("Grading appends a local review event with the displayed face and rating")
    func gradingAppendsReviewEvent() throws {
        let reviews = InMemoryReviewEventRepository()
        let state = AppState(composition: .inMemory(reviewEvents: reviews))
        state.vocab = [entry(id: "reviewed")]
        state.vocabReviewPrompt = .reverse
        let reviewedAt = Date(timeIntervalSince1970: 2_000_000)

        let saved = state.reviewVocabulary(
            "reviewed",
            quality: .vague,
            face: .recognition,
            at: reviewedAt
        )

        #expect(saved)
        let event = try #require(reviews.loadReviewEvents().only)
        #expect(event.vocabularyID.rawValue == "reviewed")
        #expect(event.face == VocabReviewPrompt.recognition.rawValue)
        #expect(event.rating == VocabReviewQuality.vague.rawValue)
        #expect(event.reviewedAt == reviewedAt)
        #expect(state.vocabReviewEvents == [event])
    }

    @MainActor
    @Test("A history write failure leaves the review due instead of advancing an unsynced card")
    func gradingFailureDoesNotAdvanceCard() {
        let state = AppState(composition: AppComposition(
            vocabulary: InMemoryVocabularyRepository(),
            knownLemmas: InMemoryKnownLemmaRepository(),
            reviewEvents: FailingReviewEventRepository()
        ))
        state.vocab = [entry(id: "reviewed")]

        let saved = state.reviewVocabulary("reviewed", quality: .remember, face: .recognition)

        #expect(!saved)
        #expect(state.vocab.first?.reviewCount == 0)
        #expect(state.vocab.first?.nextReview == nil)
        #expect(state.vocabReviewEvents.isEmpty)
        #expect(state.errorMessage == "The review could not be saved. This card is still due.")
    }

    @MainActor
    @Test("Grading a missing card reports failure without creating history")
    func gradingMissingCardReportsFailure() {
        let reviews = InMemoryReviewEventRepository()
        let state = AppState(composition: .inMemory(reviewEvents: reviews))

        let saved = state.reviewVocabulary("missing", quality: .remember)

        #expect(!saved)
        #expect((try? reviews.loadReviewEvents())?.isEmpty == true)
    }

    @Test("Sentence playback uses the matching transcript segment bounds")
    func sentencePlaybackUsesTranscriptBounds() {
        let entry = sentenceEntry(segmentID: "second", timestamp: 2)
        let bounds = VocabSentencePlayback.bounds(for: entry, transcript: sentenceTranscript())

        #expect(bounds.start == 2)
        #expect(bounds.end == 4)
    }

    @Test("Sentence playback can recover a segment from the saved timestamp")
    func sentencePlaybackRecoversSegmentFromTimestamp() {
        let entry = sentenceEntry(segmentID: nil, timestamp: 2.05)
        let bounds = VocabSentencePlayback.bounds(for: entry, transcript: sentenceTranscript())

        #expect(bounds.start == 2)
        #expect(bounds.end == 4)
    }

    @Test("Word and phrase playback uses the containing sentence")
    func wordPlaybackUsesContainingSentence() {
        let word = VocabEntry(
            id: "word",
            word: "Second",
            category: .word,
            context: "Second.",
            bookID: "book",
            bookTitle: "Thinking in Systems",
            chapterID: "chapter",
            chapterTitle: "The Basics",
            timestamp: 3.2,
            addedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let bounds = VocabSentencePlayback.bounds(for: word, transcript: sentenceTranscript())

        #expect(bounds.start == 2)
        #expect(bounds.end == 4)
    }

    @Test("Sentence playback falls back to a short clip without a transcript")
    func sentencePlaybackFallsBackWithoutTranscript() {
        let entry = sentenceEntry(segmentID: nil, timestamp: 12)
        let bounds = VocabSentencePlayback.bounds(for: entry, transcript: nil)

        #expect(bounds.start == 12)
        #expect(bounds.end == 18)
    }

    @MainActor
    @Test("Locatable word, phrase, and sentence cards can play original narration")
    func locatableVocabCardsPlayOriginal() {
        let state = AppState()
        let missing = sentenceEntry(id: "missing", bookID: "absent", bookTitle: "No Such Book")
        let word = entry(id: "word", category: .word)
        let phrase = entry(id: "phrase", category: .phrase)
        state.books = [
            Book(
                id: "book",
                title: "Thinking in Systems",
                author: nil,
                folderPath: "/tmp",
                coverPath: nil,
                ebookPath: nil,
                chapters: [
                    Chapter(id: "chapter", index: 0, title: "The Basics", audioPath: "/tmp/vocab-play.m4b")
                ]
            )
        ]

        #expect(state.canPlayVocabSentence(word))
        #expect(state.canPlayVocabSentence(phrase))
        #expect(!state.canPlayVocabSentence(missing))
        #expect(!state.playVocabSentence(missing))
        #expect(state.canPlayVocabSentence(sentenceEntry()))
    }

    @Test("Vocabulary and review cards share one original-narration control")
    func sentencePlayControlIsShared() throws {
        let vocabularyView = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AudioReader/VocabularyView.swift"),
            encoding: .utf8
        )
        let reviewView = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AudioReader/VocabularyReviewView.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AudioReader/AppState.swift"),
            encoding: .utf8
        )

        #expect(vocabularyView.contains("VocabOriginalPlayButton(state: state, entry: entry"))
        #expect(reviewView.contains("VocabOriginalPlayButton(state: state, entry: entry"))
        #expect(!reviewView.contains("entry.category == .sentence"))
        #expect(!vocabularyView.contains("if entry.category == .sentence"))
        #expect(appState.contains("func playVocabSentence("))
        #expect(appState.contains("func toggleVocabSentencePlayback("))
        #expect(appState.contains("func canPlayVocabSentence("))
        #expect(!reviewView.contains("#if os("))
    }

    private func sentenceTranscript() -> Transcript {
        Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/vocab-play.m4b",
            createdAt: Date(timeIntervalSince1970: 1),
            locale: "en-US",
            segments: [
                TranscriptSegment(
                    id: "first",
                    start: 0,
                    end: 2,
                    words: [TranscriptWord(id: "first-word", text: "First.", start: 0, end: 2, confidence: nil)],
                    ebookText: nil,
                    alignmentScore: nil
                ),
                TranscriptSegment(
                    id: "second",
                    start: 2,
                    end: 4,
                    words: [TranscriptWord(id: "second-word", text: "Second.", start: 2, end: 4, confidence: nil)],
                    ebookText: nil,
                    alignmentScore: nil
                )
            ],
            source: "test",
            ebookAligned: false
        )
    }

    private func sentenceEntry(
        id: String = "sentence",
        bookID: String = "book",
        bookTitle: String = "Thinking in Systems",
        segmentID: String? = "second",
        timestamp: TimeInterval = 2
    ) -> VocabEntry {
        VocabEntry(
            id: id,
            word: "A forest encompasses subsystems of trees and animals.",
            category: .sentence,
            context: "A forest encompasses subsystems of trees and animals.",
            bookID: bookID,
            bookTitle: bookTitle,
            chapterID: "chapter",
            chapterTitle: "The Basics",
            segmentID: segmentID,
            timestamp: timestamp,
            addedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private func entry(
        id: String = "entry",
        addedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        bookID: String = "book",
        category: VocabCategory = .word,
        reviewCount: Int = 0,
        nextReview: Date? = nil,
        reviewIntervalDays: Double = 0,
        reviewEaseFactor: Double = 2.5,
        isInLearnList: Bool = false
    ) -> VocabEntry {
        VocabEntry(
            id: id,
            word: "encompass",
            category: category,
            definition: "surround and hold within",
            translation: "包含",
            context: "A forest encompasses subsystems of trees and animals.",
            bookID: bookID,
            bookTitle: "Thinking in Systems",
            chapterID: "chapter",
            chapterTitle: "The Basics",
            timestamp: 42,
            addedAt: addedAt,
            reviewCount: reviewCount,
            nextReview: nextReview,
            reviewIntervalDays: reviewIntervalDays,
            reviewEaseFactor: reviewEaseFactor,
            isInLearnList: isInLearnList
        )
    }

    private func reviewEvent(
        id: String,
        vocabularyID: String,
        rating: VocabReviewQuality,
        at date: Date
    ) -> StoredReviewEvent {
        StoredReviewEvent(
            id: ReviewEventID(rawValue: id),
            vocabularyID: VocabularyOccurrenceID(rawValue: vocabularyID),
            face: VocabReviewPrompt.recognition.rawValue,
            rating: rating.rawValue,
            reviewedAt: date
        )
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private struct FailingReviewEventRepository: ReviewEventRepository {
    struct Failure: Error {}

    func loadReviewEvents() throws -> [StoredReviewEvent] { [] }

    func appendReviewEvent(_ event: StoredReviewEvent) throws {
        throw Failure()
    }
}
