import Foundation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

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
    private var assets: [BookID: [StoredLocalAsset]] = [:]
    private var deletedIDs: Set<BookID> = []

    public init() {}

    public func loadBooks() throws -> [StoredBook] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { items[$0] }
    }

    public func loadDeletedBookIDs() throws -> [BookID] {
        lock.lock()
        defer { lock.unlock() }
        return deletedIDs.sorted { $0.rawValue < $1.rawValue }
    }

    public func saveBook(_ book: StoredBook) throws {
        lock.lock()
        defer { lock.unlock() }
        if items[book.id] == nil {
            order.append(book.id)
        }
        items[book.id] = book
        deletedIDs.remove(book.id)
    }

    public func deleteBook(id: BookID) throws {
        lock.lock()
        defer { lock.unlock() }
        items[id] = nil
        assets[id] = nil
        deletedIDs.insert(id)
        order.removeAll { $0 == id }
    }

    public func loadAssets(bookID: BookID) throws -> [StoredLocalAsset] {
        lock.lock()
        defer { lock.unlock() }
        return assets[bookID] ?? []
    }

    public func saveAssets(_ assets: [StoredLocalAsset], bookID: BookID) throws {
        lock.lock()
        defer { lock.unlock() }
        self.assets[bookID] = assets
    }

    public func deleteAssets(bookID: BookID) throws {
        lock.lock()
        defer { lock.unlock() }
        assets[bookID] = nil
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

    public func updateVocabularyReviewSchedule(_ schedule: StoredVocabularyReviewSchedule) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let current = items[schedule.vocabularyID] else { return }
        items[schedule.vocabularyID] = schedule.merging(into: current)
    }

    public func updateVocabularyReviewSchedules(_ schedules: [StoredVocabularyReviewSchedule]) throws {
        lock.lock()
        defer { lock.unlock() }
        for schedule in schedules {
            guard let current = items[schedule.vocabularyID] else { continue }
            items[schedule.vocabularyID] = schedule.merging(into: current)
        }
    }

    public func updateVocabularyLearnList(id: VocabularyOccurrenceID, included: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var current = items[id] else { return }
        current.isInLearnList = included
        items[id] = current
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
    private var reviewedVocabulary: [VocabularyOccurrenceID: StoredVocabularyOccurrence] = [:]

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

    public func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabulary: StoredVocabularyOccurrence
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !items.contains(where: { $0.id == event.id }) else { return }
        items.append(event)
        reviewedVocabulary[vocabulary.id] = vocabulary
    }

    public func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabularies: [StoredVocabularyOccurrence]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !items.contains(where: { $0.id == event.id }) else { return }
        items.append(event)
        for vocabulary in vocabularies {
            reviewedVocabulary[vocabulary.id] = vocabulary
        }
    }

    public func loadReviewVocabularySnapshot() throws -> [StoredVocabularyOccurrence]? {
        lock.lock()
        defer { lock.unlock() }
        return Array(reviewedVocabulary.values)
    }
}

public final class InMemoryAssistantResultRepository: AssistantResultRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: StoredAssistantResult] = [:]
    private var history: [String: [StoredAssistantResultHistory]] = [:]

    public init() {}

    public func loadAssistantResults() throws -> [StoredAssistantResult] {
        lock.lock()
        defer { lock.unlock() }
        return items.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    public func loadAssistantResultHistory(resultID: String) throws -> [StoredAssistantResultHistory] {
        lock.lock()
        defer { lock.unlock() }
        return history[resultID] ?? []
    }

    public func saveAssistantResult(_ result: StoredAssistantResult) throws {
        lock.lock()
        defer { lock.unlock() }
        appendHistoryIfChanged(result)
        items[result.id] = result
    }

    public func replaceAssistantResults(_ results: [StoredAssistantResult]) throws {
        lock.lock()
        defer { lock.unlock() }
        for result in results { appendHistoryIfChanged(result) }
        items = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func appendHistoryIfChanged(_ result: StoredAssistantResult) {
        var entries = history[result.id] ?? []
        if let latest = entries.last,
           latest.status == result.status,
           latest.text == result.text,
           latest.model == result.model,
           latest.promptVersion == result.promptVersion,
           latest.modelPolicyHash == result.modelPolicyHash,
           latest.sharedCacheEntryID == result.sharedCacheEntryID {
            return
        }
        entries.append(StoredAssistantResultHistory(
            resultID: result.id,
            sequence: Int64(entries.count + 1),
            status: result.status,
            text: result.text,
            model: result.model,
            promptVersion: result.promptVersion,
            modelPolicyHash: result.modelPolicyHash,
            recordedAt: result.decidedAt ?? result.createdAt,
            sharedCacheEntryID: result.sharedCacheEntryID
        ))
        history[result.id] = entries
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

    public func markAcknowledged(ids: [MutationID]) throws {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for index in items.indices where idSet.contains(items[index].id) {
            items[index].status = .acknowledged
        }
    }

    public func updatePending(_ mutation: OutboxMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = items.firstIndex(where: { $0.id == mutation.id && $0.status == .pending }) else {
            return
        }
        var updated = mutation
        updated.status = .pending
        items[index] = updated
    }
}

public final class InMemorySyncEntityVersionStore: SyncEntityVersionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: SyncEntityVersion] = [:]

    public init() {}

    public func loadVersion(entityType: String, entityID: String) throws -> SyncEntityVersion? {
        lock.lock()
        defer { lock.unlock() }
        return items["\(entityType)|\(entityID)"]
    }

    public func saveVersion(_ version: SyncEntityVersion) throws {
        lock.lock()
        defer { lock.unlock() }
        items["\(version.entityType)|\(version.entityID)"] = version
    }
}

public final class InMemorySyncCursorStore: SyncCursorStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cursor: String

    public init(cursor: String = "0") {
        self.cursor = cursor
    }

    public func loadCursor() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return cursor
    }

    public func saveCursor(_ cursor: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.cursor = cursor
    }
}
