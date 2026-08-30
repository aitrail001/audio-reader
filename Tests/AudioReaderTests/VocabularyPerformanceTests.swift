import Foundation
import Testing
@testable import AudioReader

@Suite("Vocabulary performance contracts")
struct VocabularyPerformanceTests {
    @Test("A large vocabulary projection derives filters and review data once")
    func largeVocabularyProjection() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var entries: [VocabEntry] = []
        entries.reserveCapacity(7_139)
        for index in 0..<7_139 {
            let item = entry(
                id: "entry-\(index)",
                word: index == 7_138 ? "needle" : "word-\(index)",
                bookID: index < 7_000 ? "book-a" : "book-b",
                bookTitle: index < 7_000 ? "Book A" : "Book B",
                category: index < 7_000 ? .word : .phrase,
                addedAt: now.addingTimeInterval(-Double(index))
            )
            entries.append(item)
        }
        entries[7_138].isInLearnList = true
        entries[7_138].reviewCount = 1
        entries[7_138].reviewIntervalDays = 3
        entries[7_138].nextReview = now.addingTimeInterval(-1)

        let projection = VocabularyFilterProjection.make(
            entries: entries,
            query: "needle",
            bookFilter: "book-b",
            category: .phrase,
            at: now
        )

        #expect(projection.books.map { $0.id } == ["book-a", "book-b"])
        #expect(projection.allCategoryCount == 139)
        #expect(projection.categoryCounts[VocabCategory.phrase] == 139)
        #expect(projection.filtered.map { $0.id } == ["entry-7138"])
        #expect(projection.due.map { $0.id } == ["entry-7138"])
        #expect(projection.learnListCount == 1)
    }

    @Test("Saved and scheduler-owned lists remain distinct and book-filterable")
    func vocabularyListScopes() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var savedNew = entry(id: "saved-new", bookID: "book-a", bookTitle: "Book A")
        savedNew.isInLearnList = true
        let learningDue = reviewedEntry(
            id: "learning-due",
            bookID: "book-a",
            interval: 3,
            nextReview: now.addingTimeInterval(-60)
        )
        let learningLater = reviewedEntry(
            id: "learning-later",
            bookID: "book-a",
            interval: 3,
            nextReview: now.addingTimeInterval(86_400)
        )
        let reviewDue = reviewedEntry(
            id: "review-due",
            bookID: "book-b",
            interval: 14,
            nextReview: now.addingTimeInterval(-60)
        )
        let reviewLater = reviewedEntry(
            id: "review-later",
            bookID: "book-b",
            interval: 14,
            nextReview: now.addingTimeInterval(86_400)
        )
        let entries = [savedNew, learningDue, learningLater, reviewDue, reviewLater]

        func ids(_ list: VocabularyListFilter, book: String = "all") -> [String] {
            VocabularyFilterProjection.make(
                entries: entries,
                query: "",
                bookFilter: book,
                category: nil,
                list: list,
                at: now
            ).filtered.map(\.id)
        }

        #expect(ids(.saved) == ["saved-new"])
        #expect(ids(.new) == ["saved-new"])
        #expect(ids(.learning) == ["learning-due", "learning-later"])
        #expect(ids(.review) == ["review-due", "review-later"])
        #expect(ids(.due) == ["learning-due", "review-due"])
        #expect(ids(.due, book: "book-a") == ["learning-due"])

        let bookA = VocabularyFilterProjection.make(
            entries: entries,
            query: "",
            bookFilter: "book-a",
            category: nil,
            list: .all,
            at: now
        )
        #expect(bookA.listCounts[.all] == 3)
        #expect(bookA.listCounts[.saved] == 1)
        #expect(bookA.listCounts[.due] == 1)
        #expect(bookA.listCounts[.new] == 1)
        #expect(bookA.listCounts[.learning] == 2)
        #expect(bookA.listCounts[.review] == 0)
    }

    @Test("Today's study summary explains its due and new-card composition")
    func studySessionBreakdown() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let due = reviewedEntry(
            id: "due",
            bookID: "book-a",
            interval: 3,
            nextReview: now.addingTimeInterval(-60)
        )
        let queue = VocabularyLearningAnalytics.queue(
            entries: [due, entry(id: "new-a"), entry(id: "new-b")],
            at: now
        )

        #expect(queue.sessionBreakdown.dueCount == 1)
        #expect(queue.sessionBreakdown.newCount == 2)
        #expect(queue.sessionBreakdown.totalCount == 3)
    }

    @Test("The Words projection preserves every item for the virtualized list")
    func completeVocabularyListProjection() {
        let entries = (0..<7_139).map { entry(id: "entry-\($0)") }
        let projection = VocabularyFilterProjection.make(
            entries: entries,
            query: "",
            bookFilter: "all",
            category: nil,
            at: Date(timeIntervalSince1970: 2_000_000)
        )

        #expect(projection.filtered.count == entries.count)
        #expect(projection.filtered.last?.id == "entry-7138")
    }

    @Test("Vocabulary pages expose every rich card without one unbounded scroll layout")
    func boundedVocabularyPages() {
        let entries = (0..<7_139).map { entry(id: "entry-\($0)") }

        let first = VocabularyPage(entries: entries, requestedIndex: 0)
        let last = VocabularyPage(entries: entries, requestedIndex: .max)

        #expect(first.entries.count == VocabularyPage.defaultSize)
        #expect(first.rangeDescription == "1–80 of 7,139")
        #expect(first.pageCount == 90)
        #expect(last.index == 89)
        #expect(last.entries.last?.id == "entry-7138")
        #expect(last.rangeDescription == "7,121–7,139 of 7,139")
    }

    @Test("Review setup summarizes every scope in one reusable projection")
    func reviewSetupProjection() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var bookAWord = entry(id: "a-word", bookID: "book-a", bookTitle: "Book A", category: .word)
        bookAWord.isInLearnList = true
        var bookAPhrase = entry(id: "a-phrase", bookID: "book-a", bookTitle: "Book A", category: .phrase)
        bookAPhrase.reviewCount = 1
        bookAPhrase.reviewIntervalDays = 3
        bookAPhrase.nextReview = now.addingTimeInterval(60)
        var bookBSentence = entry(id: "b-sentence", bookID: "book-b", bookTitle: "Book B", category: .sentence)
        bookBSentence.isInLearnList = true

        let projection = VocabularyReviewSetupProjection.make(
            entries: [bookAPhrase, bookBSentence, bookAWord],
            at: now
        )

        #expect(projection.books.map(\.id) == ["book-a", "book-b"])
        #expect(projection.learnListBooks.map(\.id) == ["book-a", "book-b"])
        #expect(projection.categories(in: "book-a") == [.word, .phrase])
        #expect(projection.categoryOptions(in: "book-a").map(\.id) == ["book-a::word", "book-a::phrase"])
        #expect(projection.categoryOptions(in: "book-b").map(\.id) == ["book-b::sentence"])
        #expect(projection.summary(for: .book("book-a")).itemCount == 2)
        #expect(projection.summary(for: .book("book-a")).dueIDs.isEmpty)
        #expect(projection.summary(for: .book("book-a")).sessionIDs == ["a-word"])
        #expect(Set(projection.summary(for: .learnList).sessionIDs) == ["a-word", "b-sentence"])
        #expect(projection.summary(for: .learnListBook("book-b")).itemCount == 1)
    }

    @MainActor
    @Test("Review and learn-list schedule changes do not rebuild the chapter study index")
    func scheduleChangesSkipStudyIndexRefresh() async {
        let vocabulary = RecordingVocabularyRepository(entries: [entry(id: "reviewed")])
        let state = AppState(composition: AppComposition(
            vocabulary: vocabulary,
            knownLemmas: InMemoryKnownLemmaRepository(),
            reviewEvents: InMemoryReviewEventRepository()
        ))
        let initialRefreshCount = state.studyIndexRefreshCount

        state.setVocabularyLearnList("reviewed", included: true)
        #expect(state.studyIndexRefreshCount == initialRefreshCount)

        #expect(await state.reviewVocabulary("reviewed", quality: .remember, at: Date(timeIntervalSince1970: 2_000_000)))
        #expect(state.studyIndexRefreshCount == initialRefreshCount)
    }

    @MainActor
    @Test("A slow review write does not block the main actor")
    func slowReviewWriteKeepsMainActorResponsive() async {
        let reviews = SlowReviewEventRepository(delay: 0.25)
        let state = AppState(composition: AppComposition(
            vocabulary: InMemoryVocabularyRepository(),
            knownLemmas: InMemoryKnownLemmaRepository(),
            reviewEvents: reviews
        ))
        state.vocab = [entry(id: "reviewed")]

        let save = Task { @MainActor in
            await state.reviewVocabulary("reviewed", quality: .remember)
        }
        while !reviews.hasStarted { await Task.yield() }
        let startedAt = ContinuousClock.now
        await Task.yield()
        let heartbeatElapsed = startedAt.duration(to: .now)

        #expect(heartbeatElapsed < .milliseconds(100))
        #expect(await save.value)
    }

    @MainActor
    @Test("A slow review save preserves a concurrent My list edit")
    func slowReviewSavePreservesConcurrentLearnListEdit() async throws {
        let original = entry(id: "reviewed")
        let vocabulary = RecordingVocabularyRepository(entries: [original])
        let reviews = SlowReviewEventRepository(delay: 0.25)
        let state = AppState(composition: AppComposition(
            vocabulary: vocabulary,
            knownLemmas: InMemoryKnownLemmaRepository(),
            reviewEvents: reviews
        ))
        state.vocab = [original]

        let save = Task { @MainActor in
            await state.reviewVocabulary("reviewed", quality: .remember)
        }
        while !reviews.hasStarted { await Task.yield() }
        state.setVocabularyLearnList("reviewed", included: true)

        #expect(await save.value)
        let current = try #require(state.vocab.first)
        let stored = try #require(vocabulary.storedEntry(id: current.id))
        #expect(current.isInLearnList)
        #expect(stored.isInLearnList)
        #expect(current.reviewCount == 1)
        #expect(stored.reviewCount == 1)
    }

    @Test("The large review picker projection preserves every scope without render-time scans")
    func largeReviewSetupProjection() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let entries = (0..<7_139).map { index in
            entry(
                id: "entry-\(index)",
                bookID: "book-\(index % 5)",
                bookTitle: "Book \(index % 5)",
                category: VocabCategory.allCases[index % VocabCategory.allCases.count]
            )
        }

        let projection = try VocabularyReviewSetupProjection.makeCancellable(entries: entries, at: now)

        #expect(projection.books.count == 5)
        #expect(projection.summary(for: .book("book-0")).itemCount == 1_428)
    }

    @Test("Scoped study choices distinguish due reviews and cap new cards")
    func scopedStudyChoiceBreakdown() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let newEntries = (0..<25).map { index in
            entry(
                id: String(format: "new-%02d", index),
                bookID: "book-a",
                bookTitle: "Book A",
                addedAt: now.addingTimeInterval(Double(index))
            )
        }
        let due = reviewedEntry(
            id: "due",
            bookID: "book-a",
            interval: 14,
            nextReview: now.addingTimeInterval(-60)
        )

        let summary = VocabularyReviewSetupProjection.make(
            entries: newEntries + [due],
            at: now
        ).summary(for: .book("book-a"))

        #expect(summary.itemCount == 26)
        #expect(summary.dueIDs == ["due"])
        #expect(summary.newCount == 25)
        #expect(summary.sessionDueCount == 1)
        #expect(summary.sessionNewCount == VocabularyLearningPolicy.dailyNewCardLimit)
        #expect(summary.sessionIDs.count == 21)
    }

    @Test("Cancelled projections stop before completing another full scan")
    func cancelledProjectionStops() async {
        let entries = (0..<7_139).map { entry(id: "entry-\($0)") }
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try VocabularyFilterProjection.makeCancellable(
                    entries: entries,
                    query: "",
                    bookFilter: "all",
                    category: nil,
                    at: Date()
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(cancelled)
    }

    @Test("Dashboard analytics poll cancellation after work has started")
    func dashboardAnalyticsPollCancellationMidFlight() {
        let entries = (0..<7_139).map { entry(id: "entry-\($0)") }
        var checks = 0
        var cancelled = false

        do {
            _ = try VocabularyLearningAnalytics.snapshotCheckingCancellation(
                entries: entries,
                events: [],
                at: Date()
            ) {
                checks += 1
                if checks == 32 { throw CancellationError() }
            }
        } catch is CancellationError {
            cancelled = true
        } catch {}

        #expect(cancelled)
        #expect(checks == 32)
    }

    @MainActor
    @Test("Deleting one card uses one repository delete instead of replacing all vocabulary")
    func deletionIsSingleRow() {
        let vocabulary = RecordingVocabularyRepository(entries: [entry(id: "deleted"), entry(id: "kept")])
        let state = AppState(composition: AppComposition(
            vocabulary: vocabulary,
            knownLemmas: InMemoryKnownLemmaRepository(),
            reviewEvents: InMemoryReviewEventRepository()
        ))
        vocabulary.resetRecordedWrites()

        state.removeVocab(entry(id: "deleted"))

        #expect(vocabulary.deletedIDs == [VocabularyOccurrenceID(rawValue: "deleted")])
        #expect(vocabulary.saveCount == 0)
        #expect(state.vocab.map(\.id) == ["kept"])
    }

    private func entry(
        id: String,
        word: String = "word",
        bookID: String = "book",
        bookTitle: String = "Book",
        category: VocabCategory = .word,
        addedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> VocabEntry {
        VocabEntry(
            id: id,
            word: word,
            category: category,
            definition: "definition",
            context: "Context containing \(word).",
            bookID: bookID,
            bookTitle: bookTitle,
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 0,
            addedAt: addedAt
        )
    }

    private func reviewedEntry(
        id: String,
        bookID: String,
        interval: Double,
        nextReview: Date
    ) -> VocabEntry {
        var result = entry(id: id, bookID: bookID, bookTitle: bookID == "book-a" ? "Book A" : "Book B")
        result.reviewCount = 2
        result.reviewIntervalDays = interval
        result.nextReview = nextReview
        return result
    }
}

private final class SlowReviewEventRepository: ReviewEventRepository, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var started = false
    private var events: [StoredReviewEvent] = []

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func loadReviewEvents() throws -> [StoredReviewEvent] {
        lock.withLock { events }
    }

    func appendReviewEvent(_ event: StoredReviewEvent) throws {
        lock.withLock { started = true }
        Thread.sleep(forTimeInterval: delay)
        lock.withLock { events.append(event) }
    }
}

private final class RecordingVocabularyRepository: VocabularyRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [StoredVocabularyOccurrence]
    private(set) var saveCount = 0
    private(set) var deletedIDs: [VocabularyOccurrenceID] = []

    init(entries: [VocabEntry]) {
        self.entries = entries.map(StoredVocabularyOccurrence.init)
    }

    func loadVocabulary() throws -> [StoredVocabularyOccurrence] {
        lock.withLock { entries }
    }

    func storedEntry(id: String) -> StoredVocabularyOccurrence? {
        lock.withLock { entries.first { $0.id.rawValue == id } }
    }

    func saveVocabulary(_ entries: [StoredVocabularyOccurrence]) throws {
        lock.withLock {
            saveCount += 1
            self.entries = entries
        }
    }

    func upsertVocabulary(_ entries: [StoredVocabularyOccurrence]) throws {
        lock.withLock {
            var byID = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.id, $0) })
            for entry in entries { byID[entry.id] = entry }
            self.entries = Array(byID.values)
        }
    }

    func updateVocabularyReviewSchedule(_ schedule: StoredVocabularyReviewSchedule) throws {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == schedule.vocabularyID }) else { return }
            entries[index] = schedule.merging(into: entries[index])
        }
    }

    func updateVocabularyLearnList(id: VocabularyOccurrenceID, included: Bool) throws {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].isInLearnList = included
        }
    }

    func deleteVocabulary(id: VocabularyOccurrenceID) throws {
        lock.withLock {
            deletedIDs.append(id)
            entries.removeAll { $0.id == id }
        }
    }

    func resetRecordedWrites() {
        lock.withLock {
            saveCount = 0
            deletedIDs = []
        }
    }
}
