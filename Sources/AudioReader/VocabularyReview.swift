import Foundation

enum VocabReviewQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case forgot
    case vague
    case remember

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forgot: "Forgot"
        case .vague: "Vague"
        case .remember: "Remember"
        }
    }
}

enum VocabReviewScope: Hashable, Sendable {
    case book(String)
    case bookCategory(String, VocabCategory)
    case learnList
    case learnListBook(String)

    func includes(_ entry: VocabEntry) -> Bool {
        switch self {
        case .book(let bookID):
            entry.bookID == bookID
        case .bookCategory(let bookID, let category):
            entry.bookID == bookID && entry.category == category
        case .learnList:
            entry.isInLearnList
        case .learnListBook(let bookID):
            entry.isInLearnList && entry.bookID == bookID
        }
    }
}

enum VocabReviewScheduler {
    private static let secondsPerDay: TimeInterval = 86_400

    static func isDue(_ entry: VocabEntry, at date: Date) -> Bool {
        guard let nextReview = entry.nextReview else { return true }
        return nextReview <= date
    }

    static func dueEntries(in entries: [VocabEntry], at date: Date) -> [VocabEntry] {
        entries
            .filter { isDue($0, at: date) }
            .sorted {
                let lhsDue = $0.nextReview ?? .distantPast
                let rhsDue = $1.nextReview ?? .distantPast
                if lhsDue != rhsDue { return lhsDue < rhsDue }
                return $0.addedAt < $1.addedAt
            }
    }

    static func dueEntries(
        in entries: [VocabEntry],
        scope: VocabReviewScope,
        at date: Date
    ) -> [VocabEntry] {
        dueEntries(in: scopedEntries(in: entries, scope: scope), at: date)
    }

    static func scopedEntries(
        in entries: [VocabEntry],
        scope: VocabReviewScope
    ) -> [VocabEntry] {
        entries.filter(scope.includes)
    }

    static func nextReviewDate(in entries: [VocabEntry], after date: Date) -> Date? {
        entries.compactMap(\.nextReview).filter { $0 > date }.min()
    }

    static func nextReviewDate(
        in entries: [VocabEntry],
        scope: VocabReviewScope,
        after date: Date
    ) -> Date? {
        nextReviewDate(in: entries.filter(scope.includes), after: date)
    }

    static func applying(
        _ quality: VocabReviewQuality,
        to entry: VocabEntry,
        at date: Date
    ) -> VocabEntry {
        var reviewed = entry
        let interval = nextIntervalDays(for: quality, entry: entry)
        reviewed.reviewCount += 1
        reviewed.lastReviewedAt = date
        reviewed.lastReviewQuality = quality
        reviewed.reviewIntervalDays = interval
        reviewed.reviewEaseFactor = nextEaseFactor(for: quality, current: entry.reviewEaseFactor)
        reviewed.nextReview = date.addingTimeInterval(interval * secondsPerDay)
        return reviewed
    }

    static func nextIntervalDays(for quality: VocabReviewQuality, entry: VocabEntry) -> Double {
        guard entry.reviewCount > 0, entry.reviewIntervalDays > 0 else {
            return switch quality {
            case .forgot: 1
            case .vague: 3
            case .remember: 7
            }
        }

        return switch quality {
        case .forgot:
            1
        case .vague:
            max(3, rounded(entry.reviewIntervalDays * 1.75))
        case .remember:
            max(7, rounded(entry.reviewIntervalDays * entry.reviewEaseFactor))
        }
    }

    private static func nextEaseFactor(for quality: VocabReviewQuality, current: Double) -> Double {
        let adjustment = switch quality {
        case .forgot: -0.2
        case .vague: -0.05
        case .remember: 0.05
        }
        return min(3, max(1.3, rounded(current + adjustment)))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
