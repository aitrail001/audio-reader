import Foundation

public enum LocalStoreError: Error, Equatable, Sendable {
    case saveFailed
    case unsupportedAssistantResultKind
}

public protocol SettingsRepository: Sendable {
    func loadSettings() throws -> StoredSettings
    func saveSettings(_ settings: StoredSettings) throws
}

public protocol BookRepository: Sendable {
    func loadBooks() throws -> [StoredBook]
    func loadDeletedBookIDs() throws -> [BookID]
    func saveBook(_ book: StoredBook) throws
    func deleteBook(id: BookID) throws
    func loadAssets(bookID: BookID) throws -> [StoredLocalAsset]
    func saveAssets(_ assets: [StoredLocalAsset], bookID: BookID) throws
    func deleteAssets(bookID: BookID) throws
}

public protocol TranscriptRepository: Sendable {
    func loadTranscript(chapterID: ChapterID) throws -> StoredTranscript?
    func saveTranscript(_ transcript: StoredTranscript) throws
    func loadAllTranscripts() throws -> [StoredTranscript]
    func loadTranscriptSegments(chapterID: ChapterID, range: Range<Int>) throws -> [StoredTranscriptSegment]
    func updateTranscriptSegment(chapterID: ChapterID, segment: StoredTranscriptSegment) throws
}

public extension TranscriptRepository {
    func loadTranscriptSegments(chapterID: ChapterID, range: Range<Int>) throws -> [StoredTranscriptSegment] {
        guard let transcript = try loadTranscript(chapterID: chapterID) else { return [] }
        return Array(transcript.segments.dropFirst(range.lowerBound).prefix(range.count))
    }

    func updateTranscriptSegment(chapterID: ChapterID, segment: StoredTranscriptSegment) throws {
        guard var transcript = try loadTranscript(chapterID: chapterID),
              let index = transcript.segments.firstIndex(where: { $0.id == segment.id })
        else { return }
        transcript.segments[index] = segment
        try saveTranscript(transcript)
    }
}

public protocol VocabularyRepository: Sendable {
    func loadVocabulary() throws -> [StoredVocabularyOccurrence]
    func saveVocabulary(_ entries: [StoredVocabularyOccurrence]) throws
    func upsertVocabulary(_ entries: [StoredVocabularyOccurrence]) throws
    func updateVocabularyReviewSchedule(_ schedule: StoredVocabularyReviewSchedule) throws
    func updateVocabularyReviewSchedules(_ schedules: [StoredVocabularyReviewSchedule]) throws
    func updateVocabularyLearnList(id: VocabularyOccurrenceID, included: Bool) throws
    func deleteVocabulary(id: VocabularyOccurrenceID) throws
}

public extension VocabularyRepository {
    /// Compatibility implementation for repositories without a native partial
    /// update. Production stores override this to make the merge atomic.
    func updateVocabularyReviewSchedule(_ schedule: StoredVocabularyReviewSchedule) throws {
        guard let current = try loadVocabulary().first(where: { $0.id == schedule.vocabularyID }) else { return }
        try upsertVocabulary([schedule.merging(into: current)])
    }

    func updateVocabularyReviewSchedules(_ schedules: [StoredVocabularyReviewSchedule]) throws {
        for schedule in schedules { try updateVocabularyReviewSchedule(schedule) }
    }

    func updateVocabularyLearnList(id: VocabularyOccurrenceID, included: Bool) throws {
        guard var current = try loadVocabulary().first(where: { $0.id == id }) else { return }
        current.isInLearnList = included
        try upsertVocabulary([current])
    }
}

public protocol KnownLemmaRepository: Sendable {
    func loadKnownLemmas() throws -> [StoredKnownLemma]
    func saveKnownLemmas(_ lemmas: [StoredKnownLemma]) throws
}

public protocol ReviewEventRepository: Sendable {
    func loadReviewEvents() throws -> [StoredReviewEvent]
    func loadReviewVocabularySnapshot() throws -> [StoredVocabularyOccurrence]?
    func appendReviewEvent(_ event: StoredReviewEvent) throws
    func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabulary: StoredVocabularyOccurrence
    ) throws
    func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabularies: [StoredVocabularyOccurrence]
    ) throws
}

public extension ReviewEventRepository {
    func loadReviewVocabularySnapshot() throws -> [StoredVocabularyOccurrence]? { nil }

    /// Repositories that do not enforce relational vocabulary ownership can
    /// store the additive event directly; SQLite overrides this to upsert the
    /// reviewed card and its local parent rows in the same transaction.
    func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabulary: StoredVocabularyOccurrence
    ) throws {
        try appendReviewEvent(event)
    }

    func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabularies: [StoredVocabularyOccurrence]
    ) throws {
        guard let vocabulary = vocabularies.first else {
            try appendReviewEvent(event)
            return
        }
        try appendReviewEvent(event, vocabulary: vocabulary)
    }
}

public protocol AssistantResultRepository: Sendable {
    func loadAssistantResults() throws -> [StoredAssistantResult]
    func loadAssistantResultHistory(resultID: String) throws -> [StoredAssistantResultHistory]
    func saveAssistantResult(_ result: StoredAssistantResult) throws
    func replaceAssistantResults(_ results: [StoredAssistantResult]) throws
}

public protocol SyncOutboxRepository: Sendable {
    func enqueue(_ mutation: OutboxMutation) throws
    func pendingMutations() throws -> [OutboxMutation]
    func markAcknowledged(id: MutationID) throws
    func markAcknowledged(ids: [MutationID]) throws
    func updatePending(_ mutation: OutboxMutation) throws
}

public extension SyncOutboxRepository {
    func markAcknowledged(ids: [MutationID]) throws {
        for id in ids {
            try markAcknowledged(id: id)
        }
    }
}

public protocol SyncCursorStoring: Sendable {
    func loadCursor() throws -> String
    func saveCursor(_ cursor: String) throws
}

public protocol SyncEntityVersionStoring: Sendable {
    func loadVersion(entityType: String, entityID: String) throws -> SyncEntityVersion?
    func saveVersion(_ version: SyncEntityVersion) throws
}
