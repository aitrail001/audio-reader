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
    func saveBook(_ book: StoredBook) throws
    func deleteBook(id: BookID) throws
}

public protocol TranscriptRepository: Sendable {
    func loadTranscript(chapterID: ChapterID) throws -> StoredTranscript?
    func saveTranscript(_ transcript: StoredTranscript) throws
    func loadAllTranscripts() throws -> [StoredTranscript]
}

public protocol TranscriptOverlayRepository: Sendable {
    func loadTranscriptOverlays(chapterID: ChapterID) throws -> [StoredTranscriptOverlay]
    func loadAllTranscriptOverlays() throws -> [StoredTranscriptOverlay]
    func loadTranscriptOverlayState(chapterID: ChapterID, segmentID: String) throws -> StoredTranscriptOverlayState?
    func saveTranscriptOverlay(_ overlay: StoredTranscriptOverlay) throws
    @discardableResult
    func mergeTranscriptOverlay(_ overlay: StoredTranscriptOverlay, revision: Int64) throws -> TranscriptOverlayMergeOutcome
    func resolveTranscriptOverlay(chapterID: ChapterID, segmentID: String, choosing candidateID: String) throws
    func deleteTranscriptOverlay(id: String) throws
}

public protocol ReaderProgressRepository: Sendable {
    func loadReaderProgress(bookID: BookID) throws -> StoredReaderProgressState?
    func loadAllReaderProgress() throws -> [StoredReaderProgress]
    @discardableResult
    func mergeReaderProgress(_ progress: StoredReaderProgress) throws -> ReaderProgressMergeOutcome
    func resolveReaderProgress(bookID: BookID, choosing candidateID: String) throws
}

public protocol VocabularyRepository: Sendable {
    func loadVocabulary() throws -> [StoredVocabularyOccurrence]
    func saveVocabulary(_ entries: [StoredVocabularyOccurrence]) throws
    func upsertVocabulary(_ entries: [StoredVocabularyOccurrence]) throws
    func deleteVocabulary(id: VocabularyOccurrenceID) throws
}

public protocol KnownLemmaRepository: Sendable {
    func loadKnownLemmas() throws -> [StoredKnownLemma]
    func saveKnownLemmas(_ lemmas: [StoredKnownLemma]) throws
}

public protocol ReviewEventRepository: Sendable {
    func loadReviewEvents() throws -> [StoredReviewEvent]
    func appendReviewEvent(_ event: StoredReviewEvent) throws
    func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabulary: StoredVocabularyOccurrence
    ) throws
}

public extension ReviewEventRepository {
    /// Repositories that do not enforce relational vocabulary ownership can
    /// store the additive event directly; SQLite overrides this to upsert the
    /// reviewed card and its local parent rows in the same transaction.
    func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabulary: StoredVocabularyOccurrence
    ) throws {
        try appendReviewEvent(event)
    }
}

public protocol AssistantResultRepository: Sendable {
    func loadAssistantResults() throws -> [StoredAssistantResult]
    func saveAssistantResult(_ result: StoredAssistantResult) throws
    func replaceAssistantResults(_ results: [StoredAssistantResult]) throws
}

public protocol SyncOutboxRepository: Sendable {
    func enqueue(_ mutation: OutboxMutation) throws
    func pendingMutations() throws -> [OutboxMutation]
    func markAcknowledged(id: MutationID) throws
    func updatePending(_ mutation: OutboxMutation) throws
}

public protocol SyncCursorStoring: Sendable {
    func loadCursor() throws -> String
    func saveCursor(_ cursor: String) throws
}

public protocol SyncEntityVersionStoring: Sendable {
    func loadVersion(entityType: String, entityID: String) throws -> SyncEntityVersion?
    func saveVersion(_ version: SyncEntityVersion) throws
}
