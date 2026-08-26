import Foundation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

public struct InMemoryLocalStore: Sendable {
    public let settings: InMemorySettingsRepository
    public let books: InMemoryBookRepository
    public let transcripts: InMemoryTranscriptRepository
    public let vocabulary: InMemoryVocabularyRepository
    public let knownLemmas: InMemoryKnownLemmaRepository
    public let reviewEvents: InMemoryReviewEventRepository
    public let assistantResults: InMemoryAssistantResultRepository
    public let outbox: InMemorySyncOutboxRepository

    public init() {
        settings = InMemorySettingsRepository()
        books = InMemoryBookRepository()
        transcripts = InMemoryTranscriptRepository()
        vocabulary = InMemoryVocabularyRepository()
        knownLemmas = InMemoryKnownLemmaRepository()
        reviewEvents = InMemoryReviewEventRepository()
        assistantResults = InMemoryAssistantResultRepository()
        outbox = InMemorySyncOutboxRepository()
    }
}

public final class InMemorySettingsRepository: SettingsRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: StoredSettings?

    public init(settings: StoredSettings? = nil) {
        self.settings = settings
    }

    public func loadSettings() throws -> StoredSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings ?? .default
    }

    public func saveSettings(_ settings: StoredSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
    }
}

public final class InMemoryBookRepository: BookRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var order: [BookID] = []
    private var items: [BookID: StoredBook] = [:]

    public init() {}

    public func loadBooks() throws -> [StoredBook] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { items[$0] }
    }

    public func saveBook(_ book: StoredBook) throws {
        lock.lock()
        defer { lock.unlock() }
        if items[book.id] == nil {
            order.append(book.id)
        }
        items[book.id] = book
    }

    public func deleteBook(id: BookID) throws {
        lock.lock()
        defer { lock.unlock() }
        items[id] = nil
        order.removeAll { $0 == id }
    }
}

public final class InMemoryTranscriptRepository: TranscriptRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var order: [ChapterID] = []
    private var items: [ChapterID: StoredTranscript] = [:]

    public init() {}

    public func loadTranscript(chapterID: ChapterID) throws -> StoredTranscript? {
        lock.lock()
        defer { lock.unlock() }
        return items[chapterID]
    }

    public func saveTranscript(_ transcript: StoredTranscript) throws {
        lock.lock()
        defer { lock.unlock() }
        if items[transcript.chapterID] == nil {
            order.append(transcript.chapterID)
        }
        items[transcript.chapterID] = transcript
    }

    public func loadAllTranscripts() throws -> [StoredTranscript] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { items[$0] }
    }
}

public final class InMemoryVocabularyRepository: VocabularyRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VocabularyOccurrenceID: StoredVocabularyOccurrence] = [:]

    public init() {}

    public func loadVocabulary() throws -> [StoredVocabularyOccurrence] {
        lock.lock()
        defer { lock.unlock() }
        return items.values.sorted { lhs, rhs in
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    public func saveVocabulary(_ entries: [StoredVocabularyOccurrence]) throws {
        lock.lock()
        defer { lock.unlock() }
        items = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func upsertVocabulary(_ entries: [StoredVocabularyOccurrence]) throws {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries {
            items[entry.id] = entry
        }
    }

    public func deleteVocabulary(id: VocabularyOccurrenceID) throws {
        lock.lock()
        defer { lock.unlock() }
        items[id] = nil
    }
}

public final class InMemoryKnownLemmaRepository: KnownLemmaRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoredKnownLemma] = []

    public init() {}

    public func loadKnownLemmas() throws -> [StoredKnownLemma] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func saveKnownLemmas(_ lemmas: [StoredKnownLemma]) throws {
        lock.lock()
        defer { lock.unlock() }
        items = lemmas
    }
}

public final class InMemoryReviewEventRepository: ReviewEventRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoredReviewEvent] = []

    public init() {}

    public func loadReviewEvents() throws -> [StoredReviewEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func appendReviewEvent(_ event: StoredReviewEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !items.contains(where: { $0.id == event.id }) else { return }
        items.append(event)
    }
}

public final class InMemoryAssistantResultRepository: AssistantResultRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: StoredAssistantResult] = [:]

    public init() {}

    public func loadAssistantResults() throws -> [StoredAssistantResult] {
        lock.lock()
        defer { lock.unlock() }
        return items.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    public func saveAssistantResult(_ result: StoredAssistantResult) throws {
        lock.lock()
        defer { lock.unlock() }
        items[result.id] = result
    }

    public func replaceAssistantResults(_ results: [StoredAssistantResult]) throws {
        lock.lock()
        defer { lock.unlock() }
        items = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }
}

public final class InMemorySyncOutboxRepository: SyncOutboxRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OutboxMutation] = []

    public init() {}

    public func enqueue(_ mutation: OutboxMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !items.contains(where: { $0.id == mutation.id }) else { return }
        var pending = mutation
        pending.status = .pending
        items.append(pending)
    }

    public func pendingMutations() throws -> [OutboxMutation] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { $0.status == .pending }
    }

    public func markAcknowledged(id: MutationID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .acknowledged
    }
}
