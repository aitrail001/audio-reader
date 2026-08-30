import Foundation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

public struct InMemoryLocalStore: Sendable {
    public let settings: InMemorySettingsRepository
    public let books: InMemoryBookRepository
    public let transcripts: InMemoryTranscriptRepository
    public let transcriptOverlays: InMemoryTranscriptOverlayRepository
    public let readerProgress: InMemoryReaderProgressRepository
    public let vocabulary: InMemoryVocabularyRepository
    public let knownLemmas: InMemoryKnownLemmaRepository
    public let reviewEvents: InMemoryReviewEventRepository
    public let assistantResults: InMemoryAssistantResultRepository
    public let outbox: InMemorySyncOutboxRepository

    public init() {
        settings = InMemorySettingsRepository()
        books = InMemoryBookRepository()
        transcripts = InMemoryTranscriptRepository()
        transcriptOverlays = InMemoryTranscriptOverlayRepository()
        readerProgress = InMemoryReaderProgressRepository()
        vocabulary = InMemoryVocabularyRepository()
        knownLemmas = InMemoryKnownLemmaRepository()
        reviewEvents = InMemoryReviewEventRepository()
        assistantResults = InMemoryAssistantResultRepository()
        outbox = InMemorySyncOutboxRepository()
    }
}

public final class InMemoryReaderProgressRepository: ReaderProgressRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [BookID: StoredReaderProgressState] = [:]

    public init() {}

    public func loadReaderProgress(bookID: BookID) throws -> StoredReaderProgressState? {
        lock.lock()
        defer { lock.unlock() }
        return states[bookID]
    }

    public func loadAllReaderProgress() throws -> [StoredReaderProgress] {
        lock.lock()
        defer { lock.unlock() }
        return states.values.map(\.current).sorted { $0.bookID.rawValue < $1.bookID.rawValue }
    }

    @discardableResult
    public func mergeReaderProgress(_ progress: StoredReaderProgress) throws -> ReaderProgressMergeOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var state = states[progress.bookID] else {
            states[progress.bookID] = .init(current: progress, conflicts: [])
            return .inserted
        }
        if state.current == progress || state.conflicts.contains(progress) { return .unchanged }
        if state.current.chapterID == progress.chapterID,
           abs(state.current.relativeSeconds - progress.relativeSeconds) < 0.001,
           state.current.revision == progress.revision {
            return .unchanged
        }
        if progress.deviceID == state.current.deviceID || progress.revision > state.current.revision {
            let supersedes = progress.revision > state.current.revision
            state.current = progress
            if supersedes { state.conflicts = [] }
            states[progress.bookID] = state
            return .replacedCurrent
        }
        state.conflicts.append(progress)
        state.conflicts.sort { $0.id < $1.id }
        states[progress.bookID] = state
        return .conflictRetained
    }

    public func resolveReaderProgress(bookID: BookID, choosing candidateID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var state = states[bookID] else { return }
        let choices = [state.current] + state.conflicts
        guard let chosen = choices.first(where: { $0.id == candidateID }) else { return }
        state.current = chosen
        state.conflicts = []
        states[bookID] = state
    }
}

public final class InMemoryTranscriptOverlayRepository: TranscriptOverlayRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: StoredTranscriptOverlayState] = [:]

    public init() {}

    public func loadTranscriptOverlays(chapterID: ChapterID) throws -> [StoredTranscriptOverlay] {
        lock.lock()
        defer { lock.unlock() }
        return sorted(states.values.map(\.current.overlay).filter { $0.chapterID == chapterID })
    }

    public func loadAllTranscriptOverlays() throws -> [StoredTranscriptOverlay] {
        lock.lock()
        defer { lock.unlock() }
        return sorted(states.values.map(\.current.overlay))
    }

    public func loadTranscriptOverlayState(
        chapterID: ChapterID,
        segmentID: String
    ) throws -> StoredTranscriptOverlayState? {
        lock.lock()
        defer { lock.unlock() }
        return states[key(chapterID: chapterID, segmentID: segmentID)]
    }

    public func saveTranscriptOverlay(_ overlay: StoredTranscriptOverlay) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = mergeUnlocked(overlay, revision: 0)
    }

    @discardableResult
    public func mergeTranscriptOverlay(
        _ overlay: StoredTranscriptOverlay,
        revision: Int64
    ) throws -> TranscriptOverlayMergeOutcome {
        lock.lock()
        defer { lock.unlock() }
        return mergeUnlocked(overlay, revision: revision)
    }

    public func resolveTranscriptOverlay(
        chapterID: ChapterID,
        segmentID: String,
        choosing candidateID: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let stateKey = key(chapterID: chapterID, segmentID: segmentID)
        guard let state = states[stateKey] else { return }
        let choices = [state.current] + state.conflicts
        guard let chosen = choices.first(where: { $0.id == candidateID }) else { return }
        states[stateKey] = .init(current: chosen, conflicts: [])
    }

    public func deleteTranscriptOverlay(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        states = states.filter { $0.value.current.overlay.id != id }
    }

    private func mergeUnlocked(
        _ overlay: StoredTranscriptOverlay,
        revision: Int64
    ) -> TranscriptOverlayMergeOutcome {
        let stateKey = key(chapterID: overlay.chapterID, segmentID: overlay.segmentID)
        let candidate = StoredTranscriptOverlayCandidate(overlay: overlay, revision: revision)
        guard var state = states[stateKey] else {
            states[stateKey] = .init(current: candidate, conflicts: [])
            return .inserted
        }
        if state.current == candidate || state.conflicts.contains(candidate) { return .unchanged }
        if state.current.overlay == overlay {
            state.current = .init(overlay: overlay, revision: max(revision, state.current.revision))
            states[stateKey] = state
            return .replacedCurrent
        }
        if overlay.provenance.deviceID == state.current.overlay.provenance.deviceID,
           revision < state.current.revision {
            return .unchanged
        }
        if overlay.provenance.deviceID == state.current.overlay.provenance.deviceID
            || revision > state.current.revision {
            if revision > state.current.revision { state.conflicts = [] }
            state.current = candidate
            states[stateKey] = state
            return .replacedCurrent
        }
        state.conflicts.append(candidate)
        state.conflicts.sort { $0.id < $1.id }
        states[stateKey] = state
        return .conflictRetained
    }

    private func key(chapterID: ChapterID, segmentID: String) -> String {
        StoredTranscriptOverlay.stableID(chapterID: chapterID, segmentID: segmentID)
    }

    private func sorted(_ values: [StoredTranscriptOverlay]) -> [StoredTranscriptOverlay] {
        values.sorted { lhs, rhs in
            if lhs.chapterID != rhs.chapterID { return lhs.chapterID.rawValue < rhs.chapterID.rawValue }
            if lhs.segmentID != rhs.segmentID { return lhs.segmentID < rhs.segmentID }
            return lhs.id < rhs.id
        }
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

    public func updateVocabularyReviewSchedule(_ schedule: StoredVocabularyReviewSchedule) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let current = items[schedule.vocabularyID] else { return }
        items[schedule.vocabularyID] = schedule.merging(into: current)
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

    public func loadReviewVocabularySnapshot() throws -> [StoredVocabularyOccurrence]? {
        lock.lock()
        defer { lock.unlock() }
        return Array(reviewedVocabulary.values)
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
