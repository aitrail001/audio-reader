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
        let state = AppState()
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
}
