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
}

struct VocabularyLearningQueue: Equatable, Sendable {
    let new: [VocabEntry]
    let learning: [VocabEntry]
    let due: [VocabEntry]
    let session: [VocabEntry]
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
        let new = entries
            .filter { VocabularyLearningStage.resolve($0) == .new }
            .sorted { $0.addedAt < $1.addedAt }
        let learning = entries
            .filter { VocabularyLearningStage.resolve($0) == .learning }
            .sorted(by: scheduledBefore)
        let dueLearning = learning.filter { VocabReviewScheduler.isDue($0, at: date) }
        let dueReview = entries
            .filter {
                VocabularyLearningStage.resolve($0) == .review
                    && VocabReviewScheduler.isDue($0, at: date)
            }
            .sorted(by: scheduledBefore)
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
        let queue = queue(entries: entries, at: date)
        let today = calendar.startOfDay(for: date)
        let eventsToday = events.filter { calendar.isDate($0.reviewedAt, inSameDayAs: today) }
        let retentionEvents = recentEvents(events, today: today, calendar: calendar)
        let retained = retentionEvents.count {
            $0.rating == VocabReviewQuality.vague.rawValue
                || $0.rating == VocabReviewQuality.remember.rawValue
        }
        let retention = retentionEvents.isEmpty
            ? nil
            : Double(retained) / Double(retentionEvents.count)
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        return VocabularyLearningSnapshot(
            queue: queue,
            todayReviewCount: eventsToday.count,
            streakDays: streak(events: events, through: today, calendar: calendar),
            retention: retention,
            forecast: forecast(entries: entries, today: today, calendar: calendar),
            books: bookDistribution(
                entries: entries,
                eventsToday: eventsToday,
                entryByID: entryByID,
                at: date
            )
        )
    }

    private static func recentEvents(
        _ events: [StoredReviewEvent],
        today: Date,
        calendar: Calendar
    ) -> [StoredReviewEvent] {
        guard let start = calendar.date(byAdding: .day, value: -(retentionWindowDays - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today)
        else { return [] }
        return events.filter { $0.reviewedAt >= start && $0.reviewedAt < end }
    }

    private static func streak(
        events: [StoredReviewEvent],
        through today: Date,
        calendar: Calendar
    ) -> Int {
        let reviewedDays = Set(events.map { calendar.startOfDay(for: $0.reviewedAt) })
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
        calendar: Calendar
    ) -> [VocabularyDueForecast] {
        (0..<forecastDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            let count = entries.count { entry in
                guard entry.reviewCount > 0, let nextReview = entry.nextReview else { return false }
                if offset == 0 { return nextReview < nextDay }
                return nextReview >= day && nextReview < nextDay
            }
            return VocabularyDueForecast(day: day, count: count)
        }
    }

    private static func bookDistribution(
        entries: [VocabEntry],
        eventsToday: [StoredReviewEvent],
        entryByID: [String: VocabEntry],
        at date: Date
    ) -> [VocabularyBookLearningDistribution] {
        let reviewedTodayByBook = Dictionary(grouping: eventsToday.compactMap {
            entryByID[$0.vocabularyID.rawValue]?.bookID
        }, by: { $0 }).mapValues(\.count)

        return Dictionary(grouping: entries, by: \.bookID).compactMap { bookID, bookEntries in
            guard let first = bookEntries.first else { return nil }
            return VocabularyBookLearningDistribution(
                bookID: bookID,
                bookTitle: first.bookTitle,
                totalCount: bookEntries.count,
                newCount: bookEntries.count { VocabularyLearningStage.resolve($0) == .new },
                learningCount: bookEntries.count { VocabularyLearningStage.resolve($0) == .learning },
                reviewCount: bookEntries.count { VocabularyLearningStage.resolve($0) == .review },
                dueCount: bookEntries.count {
                    VocabularyLearningStage.resolve($0) != .new
                        && VocabReviewScheduler.isDue($0, at: date)
                },
                reviewedToday: reviewedTodayByBook[bookID, default: 0]
            )
        }
        .sorted {
            if $0.dueCount != $1.dueCount { return $0.dueCount > $1.dueCount }
            if $0.totalCount != $1.totalCount { return $0.totalCount > $1.totalCount }
            return $0.bookTitle.localizedStandardCompare($1.bookTitle) == .orderedAscending
        }
    }

    private static func scheduledBefore(_ lhs: VocabEntry, _ rhs: VocabEntry) -> Bool {
        let lhsDate = lhs.nextReview ?? .distantPast
        let rhsDate = rhs.nextReview ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.addedAt < rhs.addedAt
    }
}
