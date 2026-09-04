import Foundation

enum VocabularyLearningStage: String, CaseIterable, Identifiable, Sendable {
    case new
    case learning
    case review

    var id: String { rawValue }

    static func resolve(_ entry: VocabEntry) -> Self {
        guard entry.reviewCount > 0 else { return .new }
        return entry.reviewIntervalDays < 7 ? .learning : .review
    }

    static func resolve(_ card: VocabularyStudyCard) -> Self {
        resolve(card.studyEntry)
    }
}

/// User-facing Words views keep the manual saved list separate from the
/// scheduler-owned stages, which must only change through review outcomes.
enum VocabularyListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case saved
    case due
    case new
    case learning
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All vocabulary"
        case .saved: "My list"
        case .due: "Due now"
        case .new: "New"
        case .learning: "Learning stage"
        case .review: "Review"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .saved: "star.fill"
        case .due: "clock"
        case .new: "sparkles"
        case .learning: "brain.head.profile"
        case .review: "checkmark.seal"
        }
    }

    func includes(_ entry: VocabEntry, at date: Date) -> Bool {
        switch self {
        case .all:
            true
        case .saved:
            entry.isInLearnList
        case .due:
            entry.reviewEligible && entry.reviewCount > 0 && VocabReviewScheduler.isDue(entry, at: date)
        case .new:
            entry.reviewEligible && VocabularyLearningStage.resolve(entry) == .new
        case .learning:
            entry.reviewEligible && VocabularyLearningStage.resolve(entry) == .learning
        case .review:
            entry.reviewEligible && VocabularyLearningStage.resolve(entry) == .review
        }
    }
}

struct VocabularyStudySessionBreakdown: Equatable, Sendable {
    let dueCount: Int
    let newCount: Int

    var totalCount: Int { dueCount + newCount }
}

struct VocabularyLearningQueue: Equatable, Sendable {
    let new: [VocabularyStudyCard]
    let learning: [VocabularyStudyCard]
    let due: [VocabularyStudyCard]
    let session: [VocabularyStudyCard]

    var sessionBreakdown: VocabularyStudySessionBreakdown {
        VocabularyStudySessionBreakdown(
            dueCount: min(due.count, session.count),
            newCount: max(0, session.count - due.count)
        )
    }
}

struct VocabularyDueForecast: Identifiable, Equatable, Sendable {
    let day: Date
    let count: Int

    var id: Date { day }
}

struct VocabularyBookLearningDistribution: Identifiable, Equatable, Sendable {
    let bookID: String
    let bookTitle: String
    let totalCount: Int
    let newCount: Int
    let learningCount: Int
    let reviewCount: Int
    let dueCount: Int
    let reviewedToday: Int

    var id: String { bookID }
}

struct VocabularyLearningSnapshot: Equatable, Sendable {
    let queue: VocabularyLearningQueue
    let todayReviewCount: Int
    let streakDays: Int
    let retention: Double?
    let forecast: [VocabularyDueForecast]
    let books: [VocabularyBookLearningDistribution]

    static let empty = VocabularyLearningSnapshot(
        queue: VocabularyLearningQueue(new: [], learning: [], due: [], session: []),
        todayReviewCount: 0,
        streakDays: 0,
        retention: nil,
        forecast: [],
        books: []
    )
}

struct VocabularyFilterBook: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

enum VocabularySortOrder: String, CaseIterable, Hashable, Identifiable, Sendable {
    case recentlyAdded
    case oldestAdded
    case alphabetical
    case mostCommon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "Recently added"
        case .oldestAdded: "Oldest added"
        case .alphabetical: "A–Z"
        case .mostCommon: "Most common"
        }
    }

    func sorted(_ entries: [VocabEntry]) -> [VocabEntry] {
        entries.enumerated().sorted { indexedLHS, indexedRHS in
            let lhs = indexedLHS.element
            let rhs = indexedRHS.element
            switch self {
            case .recentlyAdded:
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return indexedLHS.offset < indexedRHS.offset
            case .oldestAdded:
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
                return indexedLHS.offset < indexedRHS.offset
            case .alphabetical:
                break
            case .mostCommon:
                let lhsRank = Self.commonRank(form: lhs.studyForm, language: lhs.sourceLanguage)
                let rhsRank = Self.commonRank(form: rhs.studyForm, language: rhs.sourceLanguage)
                if lhsRank != rhsRank { return (lhsRank ?? .max) < (rhsRank ?? .max) }
            }
            let wordOrder = lhs.word.localizedStandardCompare(rhs.word)
            if wordOrder != .orderedSame { return wordOrder == .orderedAscending }
            return lhs.id < rhs.id
        }.map(\.element)
    }

    func sorted(_ records: [KnownLemmaRecord]) -> [KnownLemmaRecord] {
        records.sorted { lhs, rhs in
            switch self {
            case .recentlyAdded:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            case .oldestAdded:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            case .alphabetical:
                break
            case .mostCommon:
                let lhsRank = Self.commonRank(form: lhs.form, language: lhs.language)
                let rhsRank = Self.commonRank(form: rhs.form, language: rhs.language)
                if lhsRank != rhsRank { return (lhsRank ?? .max) < (rhsRank ?? .max) }
            }
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            return lhs.form.localizedStandardCompare(rhs.form) == .orderedAscending
        }
    }

    private static func commonRank(form: String, language: String?) -> Int? {
        if let language, !language.lowercased().hasPrefix("en") { return nil }
        return CommonEnglishWordCatalog.shared.rank(for: form)
    }
}

/// A single projection owns all filter-derived Words data so SwiftUI rendering
/// never repeats full-library scans for labels, controls, and the row collection.
struct VocabularyFilterProjection: Equatable, Sendable {
    let books: [VocabularyFilterBook]
    let filtered: [VocabEntry]
    let categoryCounts: [VocabCategory: Int]
    let allCategoryCount: Int
    let learnListCount: Int
    let listCounts: [VocabularyListFilter: Int]
    let due: [VocabularyStudyCard]

    static let empty = VocabularyFilterProjection(
        books: [],
        filtered: [],
        categoryCounts: [:],
        allCategoryCount: 0,
        learnListCount: 0,
        listCounts: [:],
        due: []
    )

    static func make(
        entries: [VocabEntry],
        query: String,
        bookFilter: String,
        category: VocabCategory?,
        list: VocabularyListFilter = .all,
        sort: VocabularySortOrder = .recentlyAdded,
        at date: Date
    ) -> VocabularyFilterProjection {
        // The synchronous entry point keeps model tests and non-UI callers simple.
        let neverCancelled: () throws -> Void = {}
        return try! build(
            entries: entries,
            query: query,
            bookFilter: bookFilter,
            category: category,
            list: list,
            sort: sort,
            at: date,
            checkCancellation: neverCancelled
        )
    }

    static func makeCancellable(
        entries: [VocabEntry],
        query: String,
        bookFilter: String,
        category: VocabCategory?,
        list: VocabularyListFilter = .all,
        sort: VocabularySortOrder = .recentlyAdded,
        at date: Date
    ) throws -> VocabularyFilterProjection {
        try build(
            entries: entries,
            query: query,
            bookFilter: bookFilter,
            category: category,
            list: list,
            sort: sort,
            at: date,
            checkCancellation: Task.checkCancellation
        )
    }

    private static func build(
        entries: [VocabEntry],
        query: String,
        bookFilter: String,
        category: VocabCategory?,
        list: VocabularyListFilter,
        sort: VocabularySortOrder,
        at date: Date,
        checkCancellation: () throws -> Void
    ) rethrows -> VocabularyFilterProjection {
        var bookTitles: [String: String] = [:]
        var categoryCounts: [VocabCategory: Int] = [:]
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)

        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            if bookTitles[entry.bookID] == nil {
                bookTitles[entry.bookID] = entry.bookTitle
            }
        }
        let scopedOccurrences = entries.filter { bookFilter == "all" || $0.bookID == bookFilter }
        let studyCards = VocabularyStudyCards.cards(scopedOccurrences)
        var listCounts = Dictionary(uniqueKeysWithValues: VocabularyListFilter.allCases.map { ($0, 0) })
        listCounts[.all] = scopedOccurrences.count
        listCounts[.saved] = scopedOccurrences.count(where: \.isInLearnList)
        for card in studyCards {
            let entry = card.studyEntry
            switch VocabularyLearningStage.resolve(card) {
            case .new: listCounts[.new, default: 0] += 1
            case .learning: listCounts[.learning, default: 0] += 1
            case .review: listCounts[.review, default: 0] += 1
            }
            if entry.reviewCount > 0, VocabReviewScheduler.isDue(entry, at: date) {
                listCounts[.due, default: 0] += 1
            }
        }
        let listEntries: [VocabEntry] = switch list {
        case .all: scopedOccurrences
        case .saved: scopedOccurrences.filter(\.isInLearnList)
        case .due, .new, .learning, .review: studyCards
            .filter { list.includes($0.studyEntry, at: date) }
            .map(\.studyEntry)
        }
        var filtered: [VocabEntry] = []
        for (index, entry) in listEntries.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            categoryCounts[entry.category, default: 0] += 1
            guard category == nil || entry.category == category else { continue }
            guard search.isEmpty || matchesSearch(entry, query: search) else { continue }
            filtered.append(entry)
        }

        let books = bookTitles.map { VocabularyFilterBook(id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        try checkCancellation()
        return VocabularyFilterProjection(
            books: books,
            filtered: sort.sorted(filtered),
            categoryCounts: categoryCounts,
            allCategoryCount: categoryCounts.values.reduce(0, +),
            learnListCount: entries.count(where: \.isInLearnList),
            listCounts: listCounts,
            due: try VocabularyLearningAnalytics.buildQueue(
                entries: filtered,
                at: date,
                checkCancellation: checkCancellation
            ).due
        )
    }

    private static func matchesSearch(_ entry: VocabEntry, query: String) -> Bool {
        entry.word.localizedCaseInsensitiveContains(query)
            || entry.context.localizedCaseInsensitiveContains(query)
            || entry.bookTitle.localizedCaseInsensitiveContains(query)
            || (entry.translation?.localizedCaseInsensitiveContains(query) ?? false)
            || (entry.definition?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

/// Prepares the potentially large Known collection away from SwiftUI rendering.
struct VocabularyKnownWordProjection: Equatable, Sendable {
    let filtered: [KnownLemmaRecord]

    static func make(
        records: [KnownLemmaRecord],
        query: String,
        sort: VocabularySortOrder
    ) -> Self {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = records.filter {
            search.isEmpty || $0.form.localizedCaseInsensitiveContains(search)
        }
        return Self(filtered: sort.sorted(matches))
    }
}

/// Bounds rich vocabulary-card rendering while keeping the complete filtered
/// collection searchable and directly reachable by page.
struct VocabularyPage: Equatable, Sendable {
    static let defaultSize = 80

    let entries: [VocabEntry]
    let index: Int
    let pageCount: Int
    let lowerBound: Int
    let upperBound: Int
    let totalCount: Int

    init(entries: [VocabEntry], requestedIndex: Int, size: Int = defaultSize) {
        precondition(size > 0)
        totalCount = entries.count
        pageCount = entries.isEmpty ? 0 : (entries.count + size - 1) / size
        index = pageCount == 0 ? 0 : min(max(0, requestedIndex), pageCount - 1)
        lowerBound = min(index * size, entries.count)
        upperBound = min(lowerBound + size, entries.count)
        self.entries = Array(entries[lowerBound..<upperBound])
    }

    var rangeDescription: String {
        guard totalCount > 0 else { return "0 of 0" }
        return "\(Self.grouped(lowerBound + 1))–\(Self.grouped(upperBound)) of \(Self.grouped(totalCount))"
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index).isMultiple(of: 3) {
                result.append(",")
            }
            result.append(digit)
        }
        return result
    }
}

struct VocabularyKnownWordPage: Equatable, Sendable {
    static let defaultSize = VocabularyPage.defaultSize

    let records: [KnownLemmaRecord]
    let index: Int
    let pageCount: Int
    let lowerBound: Int
    let upperBound: Int
    let totalCount: Int

    init(records: [KnownLemmaRecord], requestedIndex: Int, size: Int = defaultSize) {
        precondition(size > 0)
        totalCount = records.count
        pageCount = records.isEmpty ? 0 : (records.count + size - 1) / size
        index = pageCount == 0 ? 0 : min(max(0, requestedIndex), pageCount - 1)
        lowerBound = min(index * size, records.count)
        upperBound = min(lowerBound + size, records.count)
        self.records = Array(records[lowerBound..<upperBound])
    }

    var rangeDescription: String {
        guard totalCount > 0 else { return "0 of 0" }
        return "\(Self.grouped(lowerBound + 1))–\(Self.grouped(upperBound)) of \(Self.grouped(totalCount))"
    }

    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

struct VocabularyReviewScopeSummary: Equatable, Sendable {
    let itemCount: Int
    let dueIDs: [String]
    let newCount: Int
    let sessionIDs: [String]

    var sessionDueCount: Int { dueIDs.count }
    var sessionNewCount: Int { max(0, sessionIDs.count - dueIDs.count) }

    static let empty = VocabularyReviewScopeSummary(
        itemCount: 0,
        dueIDs: [],
        newCount: 0,
        sessionIDs: []
    )
}

struct VocabularyReviewCategoryOption: Identifiable, Equatable, Sendable {
    let bookID: String
    let category: VocabCategory

    var id: String { "\(bookID)::\(category.rawValue)" }
}

/// Precomputes review-picker scope totals and due IDs once, rather than
/// refiltering the complete vocabulary collection for every visible row.
struct VocabularyReviewSetupProjection: Equatable, Sendable {
    let books: [VocabularyFilterBook]
    let learnListBooks: [VocabularyFilterBook]
    private let categoriesByBook: [String: Set<VocabCategory>]
    private let summaries: [VocabReviewScope: VocabularyReviewScopeSummary]

    static let empty = VocabularyReviewSetupProjection(
        books: [],
        learnListBooks: [],
        categoriesByBook: [:],
        summaries: [:]
    )

    static func make(entries: [VocabEntry], at date: Date) -> Self {
        let neverCancelled: () throws -> Void = {}
        return try! build(entries: entries, at: date, checkCancellation: neverCancelled)
    }

    static func makeCancellable(entries: [VocabEntry], at date: Date) throws -> Self {
        try build(entries: entries, at: date, checkCancellation: Task.checkCancellation)
    }

    private static func build(
        entries: [VocabEntry],
        at date: Date,
        checkCancellation: () throws -> Void
    ) rethrows -> Self {
        let cards = VocabularyStudyCards.cards(entries)
        var bookTitles: [String: String] = [:]
        var categoriesByBook: [String: Set<VocabCategory>] = [:]
        var learnListBookIDs = Set<String>()
        var itemCounts: [VocabReviewScope: Int] = [:]
        var dueEntries: [VocabReviewScope: [VocabularyStudyCard]] = [:]
        var newEntries: [VocabReviewScope: [VocabularyStudyCard]] = [:]

        for (index, card) in cards.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            for occurrence in card.occurrences {
                bookTitles[occurrence.bookID] = bookTitles[occurrence.bookID] ?? occurrence.bookTitle
                categoriesByBook[occurrence.bookID, default: []].insert(occurrence.category)
                if occurrence.isInLearnList { learnListBookIDs.insert(occurrence.bookID) }
            }
            let entryScopes = scopes(for: card)
            for scope in entryScopes {
                itemCounts[scope, default: 0] += 1
            }
            switch VocabularyLearningStage.resolve(card) {
            case .new:
                for scope in entryScopes { newEntries[scope, default: []].append(card) }
            case .learning, .review:
                guard VocabReviewScheduler.isDue(card.studyEntry, at: date) else { continue }
                for scope in entryScopes { dueEntries[scope, default: []].append(card) }
            }
        }

        let books = bookTitles.map { VocabularyFilterBook(id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var summaries: [VocabReviewScope: VocabularyReviewScopeSummary] = [:]
        for (scope, itemCount) in itemCounts {
            try checkCancellation()
            let due = dueEntries[scope, default: []].sorted(by: scheduledBefore)
            let new = newEntries[scope, default: []].sorted { $0.addedAt < $1.addedAt }
            let newSession = new.prefix(VocabularyLearningPolicy.dailyNewCardLimit)
            summaries[scope] = VocabularyReviewScopeSummary(
                itemCount: itemCount,
                dueIDs: due.map(\.id),
                newCount: new.count,
                sessionIDs: due.map(\.id) + newSession.map(\.id)
            )
        }
        try checkCancellation()
        return VocabularyReviewSetupProjection(
            books: books,
            learnListBooks: books.filter { learnListBookIDs.contains($0.id) },
            categoriesByBook: categoriesByBook,
            summaries: summaries
        )
    }

    func categories(in bookID: String) -> [VocabCategory] {
        VocabCategory.allCases.filter { categoriesByBook[bookID, default: []].contains($0) }
    }

    func categoryOptions(in bookID: String) -> [VocabularyReviewCategoryOption] {
        categories(in: bookID).map {
            VocabularyReviewCategoryOption(bookID: bookID, category: $0)
        }
    }

    func summary(for scope: VocabReviewScope) -> VocabularyReviewScopeSummary {
        summaries[scope] ?? .empty
    }

    private static func scopes(for card: VocabularyStudyCard) -> Set<VocabReviewScope> {
        var result = Set<VocabReviewScope>()
        for occurrence in card.occurrences {
            result.insert(.book(occurrence.bookID))
            result.insert(.bookCategory(occurrence.bookID, occurrence.category))
            if occurrence.isInLearnList {
                result.insert(.learnList)
                result.insert(.learnListBook(occurrence.bookID))
            }
        }
        return result
    }

    private static func scheduledBefore(_ lhs: VocabularyStudyCard, _ rhs: VocabularyStudyCard) -> Bool {
        let lhsDate = lhs.nextReview ?? .distantPast
        let rhsDate = rhs.nextReview ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.addedAt < rhs.addedAt
    }
}

struct VocabularyDictionaryPresentation: Equatable, Sendable {
    let summary: [String]
    let html: String?

    static let empty = VocabularyDictionaryPresentation(summary: [], html: nil)

    private init(summary: [String], html: String?) {
        self.summary = summary
        self.html = html
    }

    init(entry: VocabEntry) {
        summary = DictionaryLookup.concisePreview(
            definition: entry.definition,
            html: entry.dictionaryHTML,
            limit: 3
        )
        let source = entry.dictionaryHTML
            ?? (entry.definition.flatMap { DictionaryLookup.looksLikeMarkup($0) ? $0 : nil })
        html = source.flatMap { $0.isEmpty ? nil : DictionaryLookup.displayHTML($0) }
    }
}

enum VocabularyLearningPolicy {
    /// A bounded default keeps a saved-word backlog from turning one daily session into an endurance task.
    static let dailyNewCardLimit = 20
}

enum VocabularyLearningAnalytics {
    private static let retentionWindowDays = 30
    private static let forecastDays = 7

    /// Keeps existing intervals and grades, while presenting due learning cards,
    /// mature reviews, then new cards as one deterministic study session.
    static func queue(entries: [VocabEntry], at date: Date) -> VocabularyLearningQueue {
        let neverCancelled: () throws -> Void = {}
        return try! buildQueue(entries: entries, at: date, checkCancellation: neverCancelled)
    }

    fileprivate static func buildQueue(
        entries: [VocabEntry],
        at date: Date,
        checkCancellation: () throws -> Void
    ) rethrows -> VocabularyLearningQueue {
        let cards = VocabularyStudyCards.cards(entries)
        var new: [VocabularyStudyCard] = []
        var learning: [VocabularyStudyCard] = []
        var dueReview: [VocabularyStudyCard] = []
        for (index, card) in cards.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            switch VocabularyLearningStage.resolve(card) {
            case .new:
                new.append(card)
            case .learning:
                learning.append(card)
            case .review:
                if VocabReviewScheduler.isDue(card.studyEntry, at: date) { dueReview.append(card) }
            }
        }
        new.sort { $0.addedAt < $1.addedAt }
        learning.sort(by: scheduledBefore)
        dueReview.sort(by: scheduledBefore)
        try checkCancellation()
        let dueLearning = learning.filter { VocabReviewScheduler.isDue($0.studyEntry, at: date) }
        let due = dueLearning + dueReview
        return VocabularyLearningQueue(
            new: new,
            learning: learning,
            due: due,
            session: due + new.prefix(VocabularyLearningPolicy.dailyNewCardLimit)
        )
    }

    /// Derives dashboard facts from additive local review history and the
    /// current card schedule; it never requires an account or network.
    static func snapshot(
        entries: [VocabEntry],
        events: [StoredReviewEvent],
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> VocabularyLearningSnapshot {
        let neverCancelled: () throws -> Void = {}
        return try! buildSnapshot(
            entries: entries,
            events: events,
            at: date,
            calendar: calendar,
            checkCancellation: neverCancelled
        )
    }

    private static func buildSnapshot(
        entries: [VocabEntry],
        events: [StoredReviewEvent],
        at date: Date,
        calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> VocabularyLearningSnapshot {
        let queue = try buildQueue(entries: entries, at: date, checkCancellation: checkCancellation)
        let today = calendar.startOfDay(for: date)
        let retentionStart = calendar.date(
            byAdding: .day,
            value: -(retentionWindowDays - 1),
            to: today
        ) ?? .distantPast
        let retentionEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? .distantFuture
        var eventsToday: [StoredReviewEvent] = []
        var retentionCount = 0
        var retainedCount = 0
        var reviewedDays = Set<Date>()
        for (index, event) in events.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let day = calendar.startOfDay(for: event.reviewedAt)
            reviewedDays.insert(day)
            if day == today { eventsToday.append(event) }
            if event.reviewedAt >= retentionStart, event.reviewedAt < retentionEnd {
                retentionCount += 1
                if event.rating == VocabReviewQuality.vague.rawValue
                    || event.rating == VocabReviewQuality.remember.rawValue {
                    retainedCount += 1
                }
            }
        }
        let retention = retentionCount == 0 ? nil : Double(retainedCount) / Double(retentionCount)

        let studyCards = VocabularyStudyCards.cards(entries)
        var entryByID: [String: VocabEntry] = [:]
        var entriesByBook: [String: [VocabEntry]] = [:]
        for (index, card) in studyCards.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            for occurrence in card.occurrences { entryByID[occurrence.id] = occurrence }
            for bookID in Set(card.occurrences.map(\.bookID)) {
                guard let occurrence = card.occurrence(inBook: bookID) else { continue }
                entriesByBook[bookID, default: []].append(
                    occurrence.applyingStudySchedule(card.schedule)
                )
            }
        }
        try checkCancellation()

        return VocabularyLearningSnapshot(
            queue: queue,
            todayReviewCount: eventsToday.count,
            streakDays: streak(reviewedDays: reviewedDays, through: today, calendar: calendar),
            retention: retention,
            forecast: try forecast(
                entries: studyCards.map(\.studyEntry),
                today: today,
                calendar: calendar,
                checkCancellation: checkCancellation
            ),
            books: try bookDistribution(
                entriesByBook: entriesByBook,
                eventsToday: eventsToday,
                entryByID: entryByID,
                at: date,
                checkCancellation: checkCancellation
            )
        )
    }

    private static func streak(
        reviewedDays: Set<Date>,
        through today: Date,
        calendar: Calendar
    ) -> Int {
        var count = 0
        var candidate = today
        while reviewedDays.contains(candidate) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: candidate) else { break }
            candidate = previous
        }
        return count
    }

    private static func forecast(
        entries: [VocabEntry],
        today: Date,
        calendar: Calendar,
        checkCancellation: () throws -> Void
    ) rethrows -> [VocabularyDueForecast] {
        var result: [VocabularyDueForecast] = []
        for offset in 0..<forecastDays {
            try checkCancellation()
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day)
            else { continue }
            var count = 0
            for (index, entry) in entries.enumerated() {
                if index.isMultiple(of: 256) { try checkCancellation() }
                guard entry.reviewCount > 0, let nextReview = entry.nextReview else { continue }
                if offset == 0 ? nextReview < nextDay : nextReview >= day && nextReview < nextDay {
                    count += 1
                }
            }
            result.append(VocabularyDueForecast(day: day, count: count))
        }
        return result
    }

    private static func bookDistribution(
        entriesByBook: [String: [VocabEntry]],
        eventsToday: [StoredReviewEvent],
        entryByID: [String: VocabEntry],
        at date: Date,
        checkCancellation: () throws -> Void
    ) rethrows -> [VocabularyBookLearningDistribution] {
        let reviewedTodayByBook = Dictionary(grouping: eventsToday.compactMap {
            entryByID[$0.vocabularyID.rawValue]?.bookID
        }, by: { $0 }).mapValues(\.count)

        var result: [VocabularyBookLearningDistribution] = []
        for (bookID, bookEntries) in entriesByBook {
            try checkCancellation()
            guard let first = bookEntries.first else { continue }
            var newCount = 0
            var learningCount = 0
            var reviewCount = 0
            var dueCount = 0
            for (index, entry) in bookEntries.enumerated() {
                if index.isMultiple(of: 256) { try checkCancellation() }
                switch VocabularyLearningStage.resolve(entry) {
                case .new: newCount += 1
                case .learning: learningCount += 1
                case .review: reviewCount += 1
                }
                if entry.reviewCount > 0, VocabReviewScheduler.isDue(entry, at: date) { dueCount += 1 }
            }
            result.append(VocabularyBookLearningDistribution(
                bookID: bookID,
                bookTitle: first.bookTitle,
                totalCount: bookEntries.count,
                newCount: newCount,
                learningCount: learningCount,
                reviewCount: reviewCount,
                dueCount: dueCount,
                reviewedToday: reviewedTodayByBook[bookID, default: 0]
            ))
        }
        return result.sorted {
            if $0.dueCount != $1.dueCount { return $0.dueCount > $1.dueCount }
            if $0.totalCount != $1.totalCount { return $0.totalCount > $1.totalCount }
            return $0.bookTitle.localizedStandardCompare($1.bookTitle) == .orderedAscending
        }
    }

    private static func scheduledBefore(_ lhs: VocabularyStudyCard, _ rhs: VocabularyStudyCard) -> Bool {
        let lhsDate = lhs.nextReview ?? .distantPast
        let rhsDate = rhs.nextReview ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.addedAt < rhs.addedAt
    }

    static func snapshotCancellable(
        entries: [VocabEntry],
        events: [StoredReviewEvent],
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> VocabularyLearningSnapshot {
        try buildSnapshot(
            entries: entries,
            events: events,
            at: date,
            calendar: calendar,
            checkCancellation: Task.checkCancellation
        )
    }

    static func snapshotCheckingCancellation(
        entries: [VocabEntry],
        events: [StoredReviewEvent],
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        checkCancellation: () throws -> Void
    ) rethrows -> VocabularyLearningSnapshot {
        try buildSnapshot(
            entries: entries,
            events: events,
            at: date,
            calendar: calendar,
            checkCancellation: checkCancellation
        )
    }
}

enum VocabularyReviewHistoryReconciler {
    /// Review history is the durable recovery log when the legacy vocabulary
    /// mirror cannot be updated after the relational review transaction.
    static func reconcile(
        entries: [VocabEntry],
        events: [StoredReviewEvent],
        authoritativeSchedules: [StoredVocabularyOccurrence] = []
    ) -> [VocabEntry] {
        let eventsByVocabulary = Dictionary(grouping: events, by: { $0.vocabularyID.rawValue })
        let scheduleByVocabulary = Dictionary(
            authoritativeSchedules.map { ($0.id.rawValue, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.reviewCount > current.reviewCount ? candidate : current
            }
        )
        return entries.map { original in
            var entry = original
            if let schedule = scheduleByVocabulary[entry.id], schedule.reviewCount > entry.reviewCount {
                entry.reviewCount = schedule.reviewCount
                entry.nextReview = schedule.nextReview
                entry.lastReviewedAt = schedule.lastReviewedAt
                entry.lastReviewQuality = schedule.lastReviewQuality.flatMap(VocabReviewQuality.init(rawValue:))
                entry.reviewIntervalDays = schedule.reviewIntervalDays
                entry.reviewEaseFactor = schedule.reviewEaseFactor
            }
            let pending = eventsByVocabulary[entry.id, default: []]
                .sorted {
                    if $0.reviewedAt != $1.reviewedAt { return $0.reviewedAt < $1.reviewedAt }
                    return $0.id.rawValue < $1.id.rawValue
                }
                .filter { event in
                    guard let lastReviewedAt = entry.lastReviewedAt else { return true }
                    return event.reviewedAt > lastReviewedAt
                }
            for event in pending {
                guard let quality = VocabReviewQuality(rawValue: event.rating) else { continue }
                entry = VocabReviewScheduler.applying(quality, to: entry, at: event.reviewedAt)
            }
            return entry
        }
    }
}
