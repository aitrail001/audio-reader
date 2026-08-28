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
