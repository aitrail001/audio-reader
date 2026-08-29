import AuthenticationServices
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
#if canImport(AudioReaderNetworking)
import AudioReaderNetworking
#endif
#if canImport(AudioReaderLocalStore)
import AudioReaderLocalStore
#endif

extension AccountSession {
    static func live() -> AccountSession {
        let sqlite = LocalSQLiteStore(fileURL: Persistence.root.appendingPathComponent("library.sqlite"))
        let http = LiveHTTPClient(baseURL: ProductAPI.resolvedBaseURL)
        return AccountSession(
            client: ProductAuthClient(http: http, baseURL: ProductAPI.resolvedBaseURL),
            store: EncryptedFileAuthSessionStore(directory: Persistence.root, legacy: nil),
            oauth: ASWebOAuthBrowserSession(),
            environment: .current(),
            syncRuntime: AccountSyncRuntime(
                client: ProductSyncClient(http: http, baseURL: ProductAPI.resolvedBaseURL),
                outbox: sqlite,
                cursor: sqlite,
                versions: sqlite,
                snapshot: AccountSyncApplicator.snapshot,
                applyChange: AccountSyncApplicator.apply,
                handleConflict: AccountSyncApplicator.retainSyncConflict
            )
        )
    }
}

enum AccountSyncApplicator {
    static let settingsEntityID = "00000000-0000-4000-8000-00000000000a"

    /// Full local snapshot. `drainSync` enqueues only rows whose payload differs
    /// from the last applied `entity_versions` row; mutation IDs are new solely
    /// for those dirty rows.
    static func snapshot() throws -> [OutboxMutation] {
        let sqlite = LocalSQLiteStore(fileURL: Persistence.root.appendingPathComponent("library.sqlite"))
        return try snapshot(
            settings: Persistence.loadSettings(),
            vocabulary: Persistence.loadVocab(),
            lemmas: Persistence.loadKnownLemmas(),
            books: (try? sqlite.loadBooks()) ?? [],
            transcripts: (try? sqlite.loadTranscripts()) ?? [],
            overlays: (try? sqlite.loadAllTranscriptOverlays()) ?? [],
            readerProgress: (try? sqlite.loadAllReaderProgress()) ?? [],
            reviews: (try? sqlite.loadReviewEvents()) ?? []
        )
    }

    static func snapshot(
        settings: AppSettings,
        vocabulary: [VocabEntry],
        lemmas: [KnownLemmaRecord],
        books: [StoredBook] = [],
        transcripts: [StoredTranscript] = [],
        overlays: [StoredTranscriptOverlay] = [],
        readerProgress: [StoredReaderProgress] = [],
        reviews: [StoredReviewEvent] = []
    ) throws -> [OutboxMutation] {
        var mutations: [OutboxMutation] = [
            OutboxMutation(
                id: MutationID.generate(),
                entityType: .settings,
                entityID: settingsEntityID,
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(),
                payload: try encodePayload(
                    PortableLearningSettings(
                        sourceLanguage: settings.transcriptionLanguage,
                        targetLanguage: settings.targetLanguage,
                        readerLevel: settings.readerLanguageLevel,
                        playbackRate: settings.playbackRate,
                        skipSeconds: settings.skipSeconds,
                        appearance: settings.appearance
                    )
                )
            )
        ]
        for book in books {
            let entityID = syncEntityID(book.id.rawValue, kind: "book")
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .book,
                    entityID: entityID,
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: Date(),
                    payload: try encodePayload(
                        PortableBook(
                            localId: book.id.rawValue,
                            title: book.title,
                            author: book.author,
                            source: book.source,
                            chapters: book.chapters.map {
                                PortableChapter(
                                    localId: $0.id.rawValue,
                                    index: $0.index,
                                    title: $0.title,
                                    duration: $0.duration,
                                    startTime: $0.startTime
                                )
                            }
                        )
                    )
                )
            )
        }
        var seenChapters = Set<String>()
        for transcript in transcripts {
            let localID = transcript.chapterID.rawValue
            seenChapters.insert(localID)
            let chapterID = syncEntityID(localID, kind: "chapter")
            let json = String(data: try JSONEncoder.iso.encode(transcript), encoding: .utf8) ?? "{}"
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .transcript,
                    entityID: chapterID,
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: transcript.createdAt,
                    payload: try encodePayload(
                        PortableTranscript(
                            chapterId: chapterID,
                            localChapterId: localID,
                            locale: transcript.locale,
                            source: transcript.source,
                            ebookAligned: transcript.ebookAligned,
                            segmentCount: transcript.segments.count,
                            transcriptJSON: json
                        )
                    )
                )
            )
        }
        for transcript in Persistence.loadAllTranscripts() where seenChapters.insert(transcript.chapterID).inserted {
            let chapterID = syncEntityID(transcript.chapterID, kind: "chapter")
            let json = String(data: try JSONEncoder.iso.encode(transcript), encoding: .utf8) ?? "{}"
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .transcript,
                    entityID: chapterID,
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: transcript.createdAt,
                    payload: try encodePayload(
                        PortableTranscript(
                            chapterId: chapterID,
                            localChapterId: transcript.chapterID,
                            locale: transcript.locale,
                            source: transcript.source,
                            ebookAligned: transcript.ebookAligned,
                            segmentCount: transcript.segments.count,
                            transcriptJSON: json
                        )
                    )
                )
            )
        }
        for overlay in overlays {
            let entityID = syncEntityID(overlay.id, kind: "overlay")
            let chapterID = syncEntityID(overlay.chapterID.rawValue, kind: "chapter")
            let json = String(data: try JSONEncoder.iso.encode(overlay), encoding: .utf8) ?? "{}"
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .transcriptOverlay,
                    entityID: entityID,
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: overlay.updatedAt,
                    payload: try encodePayload(
                        PortableTranscriptOverlay(
                            chapterId: chapterID,
                            localChapterId: overlay.chapterID.rawValue,
                            segmentId: overlay.segmentID,
                            overlayJSON: json
                        )
                    )
                )
            )
        }
        for progress in readerProgress {
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .progress,
                    entityID: syncEntityID(progress.bookID.rawValue, kind: "reader-progress"),
                    operation: .upsert,
                    baseRevision: ServerVersion(progress.revision),
                    occurredAt: progress.updatedAt,
                    payload: try encodePayload(
                        PortableReaderProgress(
                            progressKind: "reader",
                            localProgressId: progress.id,
                            bookId: syncEntityID(progress.bookID.rawValue, kind: "book"),
                            chapterId: syncEntityID(progress.chapterID.rawValue, kind: "chapter"),
                            localBookId: progress.bookID.rawValue,
                            localChapterId: progress.chapterID.rawValue,
                            relativeSeconds: progress.relativeSeconds,
                            updatedAt: isoString(progress.updatedAt),
                            deviceId: progress.deviceID,
                            revision: progress.revision
                        )
                    )
                )
            )
        }
        for review in reviews {
            let entityID = syncEntityID(review.id.rawValue, kind: "review")
            let vocabularyID = syncEntityID(review.vocabularyID.rawValue, kind: "vocab")
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .reviewEvent,
                    entityID: entityID,
                    operation: .append,
                    baseRevision: .zero,
                    occurredAt: review.reviewedAt,
                    payload: try encodePayload(
                        PortableReview(
                            vocabularyId: vocabularyID,
                            face: review.face,
                            rating: review.rating,
                            reviewedAt: isoString(review.reviewedAt)
                        )
                    )
                )
            )
        }
        for entry in vocabulary where entry.reviewCount > 0 {
            let vocabID = syncEntityID(entry.id, kind: "vocab")
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .progress,
                    entityID: vocabID,
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: entry.lastReviewedAt ?? entry.addedAt,
                    payload: try encodePayload(
                        PortableProgress(
                            vocabularyId: vocabID,
                            reviewCount: entry.reviewCount,
                            nextReview: entry.nextReview.map(isoString),
                            lastReviewedAt: entry.lastReviewedAt.map(isoString),
                            lastReviewQuality: entry.lastReviewQuality?.rawValue
                        )
                    )
                )
            )
        }
        for entry in vocabulary {
            let vocabID = syncEntityID(entry.id, kind: "vocab")
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .vocabulary,
                    entityID: vocabID,
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: entry.addedAt,
                    payload: try encodePayload(
                        PortableVocabulary(
                            bookId: syncEntityID(entry.bookID, kind: "book"),
                            chapterId: syncEntityID(entry.chapterID, kind: "chapter"),
                            localBookId: entry.bookID,
                            localChapterId: entry.chapterID,
                            bookTitle: entry.bookTitle,
                            chapterTitle: entry.chapterTitle,
                            surface: entry.word,
                            lemma: entry.word,
                            category: entry.category.rawValue,
                            context: entry.context,
                            timestampSeconds: entry.timestamp,
                            state: entry.isInLearnList ? "learning" : "unknown",
                            definition: entry.definition,
                            note: entry.translation,
                            segmentId: entry.segmentID,
                            wordId: entry.wordID,
                            spokenText: entry.spokenText,
                            ebookText: entry.ebookText,
                            translationLanguage: entry.translationLanguage,
                            translationModel: entry.translationModel,
                            sourceLanguage: entry.sourceLanguage
                        )
                    )
                )
            )
        }
        for lemma in lemmas {
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .lexemeState,
                    entityID: uuidForLemma(language: lemma.language, form: lemma.form),
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: lemma.updatedAt,
                    payload: try encodePayload(
                        PortableLemma(language: lemma.language, lemma: lemma.form, state: "known")
                    )
                )
            )
        }
        return mutations
    }

    /// Apply one pulled change. Caller must feed books/vocabulary before
    /// progress/reviews (`SyncPulledChange.applying`).
    static func apply(_ change: SyncPulledChange) throws {
        switch change.entityType {
        case OutboxEntityType.settings.rawValue:
            applySettings(change)
        case OutboxEntityType.vocabulary.rawValue:
            applyVocabulary(change)
        case OutboxEntityType.lexemeState.rawValue:
            applyLemma(change)
        case OutboxEntityType.transcript.rawValue:
            applyTranscript(change)
        case OutboxEntityType.transcriptOverlay.rawValue:
            applyTranscriptOverlay(change)
        case OutboxEntityType.progress.rawValue:
            applyProgress(change)
        case OutboxEntityType.reviewEvent.rawValue:
            applyReview(change)
        case OutboxEntityType.book.rawValue:
            // Media stays on-device. Hashed book IDs plus localId/title travel
            // on vocabulary rows so learning data does not use the settings UUID.
            break
        default:
            break
        }
    }

    private static func applySettings(_ change: SyncPulledChange) {
        var settings = Persistence.loadSettings()
        if let target = change.payload["targetLanguage"]?.stringValue, !target.isEmpty {
            settings.targetLanguage = target
        }
        if let source = change.payload["sourceLanguage"]?.stringValue, !source.isEmpty {
            settings.transcriptionLanguage = source
        }
        if let level = change.payload["readerLevel"]?.stringValue, !level.isEmpty {
            settings.readerLanguageLevel = level
        }
        if let rate = change.payload["playbackRate"]?.numberValue {
            settings.playbackRate = rate
        }
        if let skip = change.payload["skipSeconds"]?.numberValue {
            settings.skipSeconds = skip
        }
        if let appearance = change.payload["appearance"]?.stringValue, !appearance.isEmpty {
            settings.appearance = appearance
        }
        Persistence.saveSettings(settings)
    }

    private static func applyVocabulary(_ change: SyncPulledChange) {
        var items = Persistence.loadVocab()
        if change.operation == OutboxOperation.delete.rawValue {
            items.removeAll { $0.id.caseInsensitiveCompare(change.entityId) == .orderedSame }
            Persistence.saveVocab(items)
            return
        }
        let localBook = change.payload["localBookId"]?.stringValue
        let localChapter = change.payload["localChapterId"]?.stringValue
        let incoming = VocabEntry(
            id: change.entityId,
            word: change.payload["surface"]?.stringValue ?? change.payload["lemma"]?.stringValue ?? "",
            category: VocabCategory(rawValue: change.payload["category"]?.stringValue ?? "word") ?? .word,
            definition: change.payload["definition"]?.stringValue,
            translation: change.payload["note"]?.stringValue,
            translationLanguage: change.payload["translationLanguage"]?.stringValue,
            translationModel: change.payload["translationModel"]?.stringValue,
            sourceLanguage: change.payload["sourceLanguage"]?.stringValue,
            context: change.payload["context"]?.stringValue ?? "",
            spokenText: change.payload["spokenText"]?.stringValue,
            ebookText: change.payload["ebookText"]?.stringValue,
            bookID: nonempty(localBook) ?? change.payload["bookId"]?.stringValue ?? "",
            bookTitle: change.payload["bookTitle"]?.stringValue ?? "",
            chapterID: nonempty(localChapter) ?? change.payload["chapterId"]?.stringValue ?? "",
            chapterTitle: change.payload["chapterTitle"]?.stringValue ?? "",
            segmentID: change.payload["segmentId"]?.stringValue,
            wordID: change.payload["wordId"]?.stringValue,
            timestamp: change.payload["timestampSeconds"]?.numberValue ?? 0,
            addedAt: isoDate(change.changedAt) ?? Date(),
            isInLearnList: change.payload["state"]?.stringValue == "learning"
        )
        if let index = items.firstIndex(where: {
            $0.id.caseInsensitiveCompare(change.entityId) == .orderedSame
        }) {
            items[index] = mergingVocabulary(existing: items[index], incoming: incoming)
        } else {
            items.append(incoming)
        }
        Persistence.saveVocab(items)
    }

    static func mergingVocabulary(existing: VocabEntry, incoming: VocabEntry) -> VocabEntry {
        var merged = incoming
        if merged.reviewCount == 0 { merged.reviewCount = existing.reviewCount }
        if merged.nextReview == nil { merged.nextReview = existing.nextReview }
        if merged.lastReviewedAt == nil { merged.lastReviewedAt = existing.lastReviewedAt }
        if merged.lastReviewQuality == nil { merged.lastReviewQuality = existing.lastReviewQuality }
        if merged.reviewIntervalDays == 0 { merged.reviewIntervalDays = existing.reviewIntervalDays }
        if merged.reviewEaseFactor == 2.5 { merged.reviewEaseFactor = existing.reviewEaseFactor }
        if merged.bookTitle.isEmpty { merged.bookTitle = existing.bookTitle }
        if merged.chapterTitle.isEmpty { merged.chapterTitle = existing.chapterTitle }
        if merged.bookID.isEmpty { merged.bookID = existing.bookID }
        if merged.chapterID.isEmpty { merged.chapterID = existing.chapterID }
        return merged
    }

    private static func applyLemma(_ change: SyncPulledChange) {
        guard let language = change.payload["language"]?.stringValue,
              let form = change.payload["lemma"]?.stringValue ?? change.payload["form"]?.stringValue
        else { return }
        var lemmas = Persistence.loadKnownLemmas()
        let record = KnownLemmaRecord(language: language, form: form, updatedAt: Date())
        if let index = lemmas.firstIndex(where: { $0.language == language && $0.form == form }) {
            lemmas[index] = record
        } else {
            lemmas.append(record)
        }
        Persistence.saveKnownLemmas(lemmas)
    }

    static func isUUID(_ value: String) -> Bool {
        let pattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        return value.wholeMatch(of: pattern) != nil
    }

    private static func applyTranscript(_ change: SyncPulledChange) {
        guard let json = change.payload["transcriptJSON"]?.stringValue,
              let data = json.data(using: .utf8),
              var transcript = try? JSONDecoder.iso.decode(Transcript.self, from: data)
        else { return }
        if let localID = change.payload["localChapterId"]?.stringValue, !localID.isEmpty {
            transcript.chapterID = localID
        }
        try? Persistence.saveTranscript(transcript)
    }

    /// Pulled overlays bypass the local mutation enqueue path; otherwise every
    /// remote correction would echo back as a new local mutation.
    private static func applyTranscriptOverlay(_ change: SyncPulledChange) {
        let sqlite = LocalSQLiteStore(fileURL: Persistence.root.appendingPathComponent("library.sqlite"))
        if change.operation == OutboxOperation.delete.rawValue {
            if let localID = change.payload["localOverlayId"]?.stringValue {
                try? sqlite.deleteTranscriptOverlay(id: localID)
            }
            return
        }
        guard let json = change.payload["overlayJSON"]?.stringValue,
              let data = json.data(using: .utf8),
              var overlay = try? JSONDecoder.iso.decode(StoredTranscriptOverlay.self, from: data)
        else { return }
        if let localChapterID = change.payload["localChapterId"]?.stringValue, !localChapterID.isEmpty {
            overlay.chapterID = ChapterID(rawValue: localChapterID)
        }
        _ = try? sqlite.mergeTranscriptOverlay(overlay, revision: Int64(change.revision))
    }

    private static func applyProgress(_ change: SyncPulledChange) {
        if change.payload["progressKind"]?.stringValue == "reader" {
            applyReaderProgress(change)
            return
        }
        guard let vocabularyId = change.payload["vocabularyId"]?.stringValue else { return }
        var items = Persistence.loadVocab()
        guard let index = items.firstIndex(where: { $0.id.caseInsensitiveCompare(vocabularyId) == .orderedSame }) else {
            return
        }
        if let count = change.payload["reviewCount"]?.numberValue {
            items[index].reviewCount = Int(count)
        }
        if let quality = change.payload["lastReviewQuality"]?.stringValue {
            items[index].lastReviewQuality = VocabReviewQuality(rawValue: quality)
        }
        if let next = change.payload["nextReview"]?.stringValue {
            items[index].nextReview = isoDate(next)
        }
        if let last = change.payload["lastReviewedAt"]?.stringValue {
            items[index].lastReviewedAt = isoDate(last)
        }
        Persistence.saveVocab(items)
    }

    private static func applyReaderProgress(_ change: SyncPulledChange) {
        guard let bookID = change.payload["localBookId"]?.stringValue,
              let chapterID = change.payload["localChapterId"]?.stringValue,
              let seconds = change.payload["relativeSeconds"]?.numberValue,
              let deviceID = change.payload["deviceId"]?.stringValue
        else { return }
        let progress = StoredReaderProgress(
            id: change.payload["localProgressId"]?.stringValue ?? "remote:\(change.entityId):\(change.revision)",
            bookID: BookID(rawValue: bookID),
            chapterID: ChapterID(rawValue: chapterID),
            relativeSeconds: seconds,
            updatedAt: isoDate(change.payload["updatedAt"]?.stringValue ?? change.changedAt) ?? Date(),
            deviceID: deviceID,
            revision: Int64(change.revision)
        )
        let sqlite = LocalSQLiteStore(fileURL: Persistence.root.appendingPathComponent("library.sqlite"))
        _ = try? sqlite.mergeReaderProgress(progress)
    }

    /// A reader-position push conflict promotes the local candidate to the
    /// server revision. The next pull then lands as a same-revision peer and is
    /// retained for explicit user choice instead of silently winning.
    static func retainReaderProgressConflict(_ mutation: OutboxMutation, serverRevision: Int64) throws {
        guard mutation.entityType == .progress,
              let payload = try? JSONDecoder().decode([String: SyncJSONValue].self, from: mutation.payload),
              payload["progressKind"]?.stringValue == "reader",
              let bookID = payload["localBookId"]?.stringValue
        else { return }
        let sqlite = LocalSQLiteStore(fileURL: Persistence.root.appendingPathComponent("library.sqlite"))
        guard var current = try sqlite.loadReaderProgress(bookID: BookID(rawValue: bookID))?.current else { return }
        current.revision = serverRevision
        _ = try sqlite.mergeReaderProgress(current)
    }

    /// Conflict promotion makes the local and subsequently pulled remote edit
    /// peers at one revision, allowing the repository to retain both candidates.
    static func retainTranscriptOverlayConflict(
        _ mutation: OutboxMutation,
        serverRevision: Int64
    ) throws {
        guard mutation.entityType == .transcriptOverlay,
              let payload = try? JSONDecoder().decode([String: SyncJSONValue].self, from: mutation.payload),
              let chapterID = payload["localChapterId"]?.stringValue,
              let segmentID = payload["segmentId"]?.stringValue
        else { return }
        let sqlite = LocalSQLiteStore(fileURL: Persistence.root.appendingPathComponent("library.sqlite"))
        guard let current = try sqlite.loadTranscriptOverlayState(
            chapterID: ChapterID(rawValue: chapterID),
            segmentID: segmentID
        )?.current.overlay else { return }
        _ = try sqlite.mergeTranscriptOverlay(current, revision: serverRevision)
    }

    static func retainSyncConflict(_ mutation: OutboxMutation, serverRevision: Int64) throws {
        try retainReaderProgressConflict(mutation, serverRevision: serverRevision)
        try retainTranscriptOverlayConflict(mutation, serverRevision: serverRevision)
    }

    private static func applyReview(_ change: SyncPulledChange) {
        guard let vocabularyId = change.payload["vocabularyId"]?.stringValue else { return }
        var items = Persistence.loadVocab()
        guard let index = items.firstIndex(where: { $0.id.caseInsensitiveCompare(vocabularyId) == .orderedSame }) else {
            return
        }
        if let reviewed = isoDate(change.payload["reviewedAt"]?.stringValue ?? change.changedAt) {
            items[index].lastReviewedAt = reviewed
        }
        if let rating = change.payload["rating"]?.stringValue {
            items[index].lastReviewQuality = VocabReviewQuality(rawValue: rating)
        }
        Persistence.saveVocab(items)
    }

    static func uuidForLemma(language: String, form: String) -> String {
        uuidForStableKey("lemma:\(language):\(form)")
    }

    static func syncEntityID(_ localID: String, kind: String) -> String {
        isUUID(localID) ? localID.lowercased() : uuidForStableKey("\(kind):\(localID)")
    }

    private static func encodePayload<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func isoDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func uuidForStableKey(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let start = hex.startIndex
        func slice(_ offset: Int, _ count: Int) -> String {
            let from = hex.index(start, offsetBy: offset)
            let to = hex.index(from, offsetBy: count)
            return String(hex[from..<to])
        }
        return "\(slice(0, 8))-\(slice(8, 4))-\(slice(12, 4))-\(slice(16, 4))-\(slice(20, 12))"
    }
}

private struct PortableLearningSettings: Encodable {
    var sourceLanguage: String
    var targetLanguage: String
    var readerLevel: String
    var playbackRate: Double
    var skipSeconds: Double
    var appearance: String
}

private struct PortableVocabulary: Encodable {
    var bookId: String
    var chapterId: String
    var localBookId: String
    var localChapterId: String
    var bookTitle: String
    var chapterTitle: String
    var surface: String
    var lemma: String
    var category: String
    var context: String
    var timestampSeconds: Double
    var state: String
    var definition: String?
    var note: String?
    var segmentId: String?
    var wordId: String?
    var spokenText: String?
    var ebookText: String?
    var translationLanguage: String?
    var translationModel: String?
    var sourceLanguage: String?
}

private struct PortableLemma: Encodable {
    var language: String
    var lemma: String
    var state: String
}

private struct PortableBook: Encodable {
    var localId: String
    var title: String
    var author: String?
    var source: String
    var chapters: [PortableChapter]
}

private struct PortableChapter: Encodable {
    var localId: String
    var index: Int
    var title: String
    var duration: Double?
    var startTime: Double?
}

private struct PortableTranscript: Encodable {
    var chapterId: String
    var localChapterId: String
    var locale: String
    var source: String
    var ebookAligned: Bool
    var segmentCount: Int
    var transcriptJSON: String
}

private struct PortableTranscriptOverlay: Encodable {
    var chapterId: String
    var localChapterId: String
    var segmentId: String
    var overlayJSON: String
}

private struct PortableReview: Encodable {
    var vocabularyId: String
    var face: String
    var rating: String
    var reviewedAt: String
}

private struct PortableProgress: Encodable {
    var vocabularyId: String
    var reviewCount: Int
    var nextReview: String?
    var lastReviewedAt: String?
    var lastReviewQuality: String?
}

private struct PortableReaderProgress: Encodable {
    var progressKind: String
    var localProgressId: String
    var bookId: String
    var chapterId: String
    var localBookId: String
    var localChapterId: String
    var relativeSeconds: Double
    var updatedAt: String
    var deviceId: String
    var revision: Int64
}

extension AccountDeviceEnvironment {
    @MainActor
    static func current() -> AccountDeviceEnvironment {
        AccountDeviceEnvironment(
            platform: currentPlatform,
            deviceName: currentDeviceName,
            appVersion: AppVersion.marketing,
            buildNumber: AppVersion.build,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier
        )
    }

    @MainActor
    private static var currentPlatform: ProductDevicePlatform {
#if os(macOS)
        .macos
#elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? .ios : .ipados
#else
        .macos
#endif
    }

    @MainActor
    private static var currentDeviceName: String {
#if os(macOS)
        Host.current().localizedName ?? "Mac"
#else
        UIDevice.current.name
#endif
    }
}

final class ASWebOAuthBrowserSession: NSObject, OAuthBrowserSession, @unchecked Sendable {
    private let lock = NSLock()
    private var safari: ASWebAuthenticationSession?

    @concurrent
    func start(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        if LocalOAuthRedirect.isLocalComplete(authorizationURL) {
            return try await LocalOAuthRedirect.follow(authorizationURL)
        }
        return try await presentSafariSession(authorizationURL: authorizationURL, callbackScheme: callbackScheme)
    }

    @MainActor
    private func presentSafariSession(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let resume = OnceResume(continuation)
            let presenter = WebAuthPresenter()
            let session = WebAuthCallbacks.makeSession(
                url: authorizationURL,
                callbackScheme: callbackScheme,
                presenter: presenter,
                resume: resume,
                onComplete: { [weak self] in
                    self?.lock.lock()
                    self?.safari = nil
                    self?.lock.unlock()
                }
            )
            objc_setAssociatedObject(
                session,
                Unmanaged.passUnretained(session).toOpaque(),
                presenter,
                .OBJC_ASSOCIATION_RETAIN
            )
            lock.lock()
            safari = session
            lock.unlock()
            if !session.start() {
                lock.lock()
                safari = nil
                lock.unlock()
                resume.throwing(AuthClientError.cancelled)
            }
        }
    }
}

private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(macOS)
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
#else
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
#endif
    }
}

enum LocalOAuthRedirect {
    static func isLocalComplete(_ url: URL) -> Bool {
        url.path == "/v1/auth/oauth/local-complete"
    }

    static func follow(_ url: URL) async throws -> URL {
        let catcher = RedirectCatcher()
        let session = URLSession(configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("local-oauth", forHTTPHeaderField: "X-Request-Id")
        do {
            _ = try await session.data(for: request)
        } catch {
            if let location = catcher.location {
                return location
            }
            throw error
        }
        if let location = catcher.location {
            return location
        }
        throw AuthClientError.invalidResponse
    }
}

private final class RedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var location: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let header = response.value(forHTTPHeaderField: "Location"), let url = URL(string: header) {
            store(url)
            return nil
        }
        if let url = request.url, url.scheme == ProductAPI.callbackScheme {
            store(url)
            return nil
        }
        return request
    }

    private func store(_ url: URL) {
        lock.lock()
        stored = url
        lock.unlock()
    }
}

private enum WebAuthCallbacks {
    nonisolated static func makeSession(
        url: URL,
        callbackScheme: String,
        presenter: ASWebAuthenticationPresentationContextProviding,
        resume: OnceResume<URL>,
        onComplete: @escaping @Sendable () -> Void
    ) -> ASWebAuthenticationSession {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
            DispatchQueue.main.async {
                finish(resume: resume, url: callbackURL, error: error)
                onComplete()
            }
        }
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = true
        return session
    }

    nonisolated static func finish(resume: OnceResume<URL>, url: URL?, error: (any Error)?) {
        if let url {
            resume.returning(url)
        } else if let error {
            resume.throwing(error)
        } else {
            resume.throwing(AuthClientError.cancelled)
        }
    }
}

private final class OnceResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func returning(_ value: Value) {
        let pending = take()
        pending?.resume(returning: value)
    }

    func throwing(_ error: Error) {
        let pending = take()
        pending?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
