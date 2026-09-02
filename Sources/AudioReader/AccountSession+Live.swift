import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
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
        let sqlite = LocalSQLiteStore(fileURL: Persistence.databaseURL)
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
                assetUploads: AccountSyncApplicator.assetUploads,
                applyPage: { changes, versions, cursor in
                    try AccountSyncApplicator.applyPage(
                        changes,
                        versions: versions,
                        cursor: cursor,
                        to: sqlite
                    )
                },
                handleConflict: AccountSyncApplicator.retainSyncConflict,
                reviewConflicts: {
                    Array(
                        repeating: .readerProgress,
                        count: try sqlite.readerProgressConflictCount()
                    ) + Array(
                        repeating: .transcriptCorrection,
                        count: try sqlite.transcriptOverlayConflictCount()
                    )
                }
            )
        )
    }
}

enum AccountSyncApplicator {
    static let settingsEntityID = "00000000-0000-4000-8000-00000000000a"
    private static let syncLog = Logger(
        subsystem: "com.johnsonzhang.AudioReader",
        category: "account-sync-apply"
    )

    /// Full local snapshot. `drainSync` enqueues only rows whose payload differs
    /// from the last applied `entity_versions` row; mutation IDs are new solely
    /// for those dirty rows.
    static func snapshot() throws -> [OutboxMutation] {
        let sqlite = LocalSQLiteStore(fileURL: Persistence.databaseURL)
        return try snapshot(
            settings: Persistence.loadSettings(),
            vocabulary: Persistence.loadVocab(),
            lemmas: Persistence.loadKnownLemmas(),
            deletedLemmas: (try? sqlite.loadDeletedKnownLemmas()) ?? [],
            books: (try? sqlite.loadBooks()) ?? [],
            transcripts: (try? sqlite.loadTranscripts()) ?? [],
            overlays: (try? sqlite.loadAllTranscriptOverlays()) ?? [],
            readerProgress: (try? sqlite.loadAllReaderProgress()) ?? [],
            reviews: (try? sqlite.loadReviewEvents()) ?? [],
            assistantResults: (try? sqlite.loadAssistantResults()) ?? [],
            studyActivityDays: (try? sqlite.loadStudyActivityDays()) ?? []
        )
    }

    /// All generated upload files must remain inside the publisher-owned staging directory.
    static func assetUploads(stagingDirectory: URL) throws -> [SyncAssetUpload] {
        try assetUploads(
            database: LocalSQLiteStore(fileURL: Persistence.databaseURL),
            stagingDirectory: stagingDirectory
        )
    }

    /// A caller-supplied store keeps upload candidate selection testable without opening live app data.
    static func assetUploads(
        database sqlite: LocalSQLiteStore,
        stagingDirectory: URL
    ) throws -> [SyncAssetUpload] {
        let transcriptCandidates = try sqlite.loadActiveSyncTranscriptCandidates()
        // A durable catalog tombstone is authoritative even when immutable child rows remain locally.
        let transcripts: [SyncAssetUpload] = try transcriptCandidates.map { candidate in
            let transcript = candidate.transcript
            let data = try JSONEncoder.iso.encode(Transcript(transcript))
            let fileURL = stagingDirectory
                .appendingPathComponent("AudioReader-\(UUID().uuidString).transcript.json")
            try data.write(to: fileURL, options: .atomic)
            let digest = try SyncAssetFileIO.digest(fileURL: fileURL)
            let localChapterID = transcript.chapterID.rawValue
            let chapterID = syncEntityID(localChapterID, kind: "chapter")
            return SyncAssetUpload(
                revisionID: syncEntityID("\(localChapterID):\(digest.sha256)", kind: "transcript-revision"),
                bookID: syncEntityID(candidate.bookID.rawValue, kind: "book"),
                chapterID: chapterID,
                sha256: digest.sha256,
                originalBytes: digest.byteCount,
                segmentCount: transcript.segments.count,
                fileURL: fileURL,
                compressedBytes: digest.byteCount,
                deleteFileAfterUpload: true
            )
        }
        // Operator storage availability is not user consent. This release exposes only
        // learning-data sync, so audio, EPUB, and cover rows must remain device-local.
        return transcripts
    }

    static func snapshot(
        settings: AppSettings,
        vocabulary: [VocabEntry],
        lemmas: [KnownLemmaRecord],
        deletedLemmas: [StoredKnownLemma] = [],
        books: [StoredBook] = [],
        transcripts: [StoredTranscript] = [],
        overlays: [StoredTranscriptOverlay] = [],
        readerProgress: [StoredReaderProgress] = [],
        reviews: [StoredReviewEvent] = [],
        assistantResults: [StoredAssistantResult] = [],
        studyActivityDays: [String] = []
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
            mutations.append(try bookMutation(for: book))
        }
        _ = transcripts // Transcript revisions use `assetUploads`, never the JSON mutation outbox.
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
                            cardId: review.cardID,
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
                            lastReviewQuality: entry.lastReviewQuality?.rawValue,
                            reviewIntervalDays: entry.reviewIntervalDays,
                            reviewEaseFactor: entry.reviewEaseFactor
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
                            lemma: entry.canonicalForm,
                            partOfSpeech: entry.partOfSpeech.rawValue,
                            senseId: entry.senseID,
                            canonicalizationSource: entry.canonicalizationSource.rawValue,
                            canonicalizationConfidence: entry.canonicalizationConfidence,
                            canonicalizationStatus: entry.canonicalizationStatus.rawValue,
                            canonicalizationTraceId: entry.canonicalizationTraceID,
                            captureSource: entry.captureSource.rawValue,
                            reviewEligible: entry.reviewEligible,
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
        for lemma in deletedLemmas {
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .lexemeState,
                    entityID: uuidForLemma(language: lemma.language, form: lemma.form),
                    operation: .delete,
                    baseRevision: .zero,
                    occurredAt: lemma.updatedAt,
                    payload: try encodePayload(
                        PortableLemma(language: lemma.language, lemma: lemma.form, state: "unknown")
                    )
                )
            )
        }
        for result in assistantResults {
            var canonicalResult = result
            canonicalResult.createdAt = syncCanonicalAssistantDate(result.createdAt)
            canonicalResult.decidedAt = result.decidedAt.map(syncCanonicalAssistantDate)
            let entityID = UUID(uuidString: result.id) == nil
                ? syncEntityID(result.id, kind: "assistant-result")
                : result.id.lowercased()
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .assistantResult,
                    entityID: entityID,
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: result.decidedAt ?? result.createdAt,
                    payload: try encodePayload(
                        StoredAssistantDecisionPayload(result: canonicalResult, vocabulary: [])
                    )
                )
            )
        }
        for day in studyActivityDays {
            mutations.append(
                OutboxMutation(
                    id: MutationID.generate(),
                    entityType: .studyActivity,
                    entityID: syncEntityID(day, kind: "study-activity"),
                    operation: .upsert,
                    baseRevision: .zero,
                    occurredAt: Date(),
                    payload: try encodePayload(PortableStudyActivity(day: day))
                )
            )
        }
        return mutations
    }

    static func bookMutation(
        for book: StoredBook,
        baseRevision: ServerVersion = .zero,
        occurredAt: Date = Date()
    ) throws -> OutboxMutation {
        OutboxMutation(
            id: MutationID.generate(),
            entityType: .book,
            entityID: syncEntityID(book.id.rawValue, kind: "book"),
            operation: .upsert,
            baseRevision: baseRevision,
            occurredAt: occurredAt,
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
                            startTime: $0.startTime,
                            ebookSectionIndex: $0.ebookSectionIndex
                        )
                    }
                )
            )
        )
    }

    static func bookDeletionMutation(
        localID: String,
        baseRevision: ServerVersion = .zero,
        occurredAt: Date = Date()
    ) throws -> OutboxMutation {
        OutboxMutation(
            id: MutationID.generate(),
            entityType: .book,
            entityID: syncEntityID(localID, kind: "book"),
            operation: .delete,
            baseRevision: baseRevision,
            occurredAt: occurredAt,
            payload: try encodePayload(["localId": localID])
        )
    }

    /// Apply one pulled change. Caller must feed books/vocabulary before
    /// progress/reviews (`SyncPulledChange.applying`).
    static func apply(_ change: SyncPulledChange) throws {
        let sqlite = LocalSQLiteStore(fileURL: Persistence.databaseURL)
        try apply(change, to: sqlite)
    }

    /// The supplied store is the only durable boundary for downloaded state.
    static func apply(_ change: SyncPulledChange, to sqlite: LocalSQLiteStore) throws {
        switch change.entityType {
        case OutboxEntityType.settings.rawValue:
            try applySettings(change, to: sqlite)
        case OutboxEntityType.vocabulary.rawValue:
            _ = try applyLearning(change, to: sqlite)
        case OutboxEntityType.lexemeState.rawValue:
            try applyLemma(change, to: sqlite)
        case OutboxEntityType.transcript.rawValue:
            try applyTranscript(change, to: sqlite)
        case OutboxEntityType.asset.rawValue:
            try applyAsset(change, to: sqlite)
        case OutboxEntityType.transcriptOverlay.rawValue:
            try applyTranscriptOverlay(change, to: sqlite)
        case OutboxEntityType.assistantResult.rawValue:
            try applyAssistantDecision(change, to: sqlite)
        case OutboxEntityType.progress.rawValue:
            if change.payload["progressKind"]?.stringValue == "reader" {
                try applyReaderProgress(change, to: sqlite)
            } else {
                _ = try applyLearning(change, to: sqlite)
            }
        case OutboxEntityType.reviewEvent.rawValue:
            _ = try applyLearning(change, to: sqlite)
        case OutboxEntityType.book.rawValue:
            try applyBook(change, to: sqlite)
        case OutboxEntityType.chapter.rawValue:
            try applyChapter(change, to: sqlite)
        case OutboxEntityType.studyActivity.rawValue:
            try applyStudyActivity(change, to: sqlite)
        default:
            throw AccountSyncApplyError.invalidPayload(change.entityType)
        }
    }

    /// Every row, transcript eligibility decision, entity version, and cursor in a downloaded
    /// page shares the canonical SQLite transaction. The interleave seam lets WAL race tests
    /// commit a second connection immediately before this store takes its write reservation.
    static func applyPage(
        _ changes: [SyncPulledChange],
        versions: [SyncEntityVersion]? = nil,
        cursor: String,
        to sqlite: LocalSQLiteStore,
        interleavingBeforeTransaction: (() throws -> Void)? = nil
    ) throws {
        let allOrdered = SyncPulledChange.applying(changes)
        var pageVersions = versions ?? allOrdered.map { change in
            SyncEntityVersion(
                entityType: change.entityType,
                entityID: change.entityId,
                serverVersion: Int64(change.revision),
                payload: change.operation == OutboxOperation.delete.rawValue
                    ? SyncJSONCoding.tombstonePayload
                    : SyncJSONCoding.data(from: change.payload)
            )
        }
        for change in allOrdered where change.entityType == OutboxEntityType.assistantResult.rawValue {
            let decision = try assistantDecisionPayload(from: change)
            guard let index = pageVersions.firstIndex(where: {
                $0.entityType == change.entityType
                    && $0.entityID == change.entityId
                    && $0.serverVersion == Int64(change.revision)
            }) else { continue }
            // Derived vocabulary has its own snapshot entities. Keep applying it from the pulled
            // decision, but fingerprint the assistant result in the same shape as snapshot().
            pageVersions[index].payload = try encodePayload(
                StoredAssistantDecisionPayload(result: decision.result, vocabulary: [])
            )
        }
        for change in allOrdered where
            change.entityType == OutboxEntityType.progress.rawValue
                && change.payload["progressKind"]?.stringValue == "reader" {
            guard let index = pageVersions.firstIndex(where: {
                $0.entityType == change.entityType
                    && $0.entityID == change.entityId
                    && $0.serverVersion == Int64(change.revision)
            }) else { continue }
            var canonicalPayload = change.payload
            // Pull application promotes reader progress to the server revision. Persist the same
            // value in the version ledger so the next snapshot is not perpetually one revision ahead.
            canonicalPayload["revision"] = .number(Double(change.revision))
            pageVersions[index].payload = SyncJSONCoding.data(from: canonicalPayload)
        }
        var installedChanges = allOrdered
        let installedFiles = try installAssetFiles(in: &installedChanges)
        do {
            let vocabularyUpserts = installedChanges.filter {
                $0.entityType == OutboxEntityType.vocabulary.rawValue
                    && $0.operation != OutboxOperation.delete.rawValue
            }
            let existingVocabulary = Dictionary(
                uniqueKeysWithValues: try sqlite.loadVocabulary().map {
                    ($0.id.rawValue.lowercased(), VocabEntry($0))
                }
            )
            let vocabularyRows = try vocabularyUpserts.map { change -> StoredVocabularyOccurrence in
                let incoming = try vocabulary(from: change)
                let resolved = existingVocabulary[change.entityId.lowercased()]
                    .map {
                        mergingVocabulary(existing: $0, incoming: incoming, payload: change.payload)
                    } ?? incoming
                return StoredVocabularyOccurrence(resolved)
            }
            try interleavingBeforeTransaction?()
            var retainedInstalledPaths: Set<String> = []
            try sqlite.performSyncPageTransaction {
                let transcriptChapterIDs = try projectedTranscriptChapterIDs(
                    afterApplying: installedChanges,
                    sqlite: sqlite
                )
                let applicableChanges = installedChanges.compactMap { change in
                    transcriptChangeWithActiveCatalogParent(
                        change,
                        chapterIDs: transcriptChapterIDs
                    )
                }
                try sqlite.upsertVocabulary(vocabularyRows)
                for change in applicableChanges {
                    if change.entityType == OutboxEntityType.vocabulary.rawValue,
                       change.operation != OutboxOperation.delete.rawValue {
                        continue
                    }
                    try apply(change, to: sqlite)
                }
                for version in pageVersions { try sqlite.saveVersion(version) }
                try sqlite.saveCursor(cursor)
                retainedInstalledPaths = Set(
                    applicableChanges.compactMap { $0.payload["installedObjectPath"]?.stringValue }
                )
            }
            for url in installedFiles where !retainedInstalledPaths.contains(url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            for url in installedFiles { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Historical immutable revisions can outlive their catalog chapter. Only an active local
    /// chapter may own downloaded transcript bytes; skipped rows still commit their version/cursor.
    private static func transcriptChangeWithActiveCatalogParent(
        _ change: SyncPulledChange,
        chapterIDs: [ChapterID]
    ) -> SyncPulledChange? {
        guard change.entityType == OutboxEntityType.transcript.rawValue,
              change.operation != OutboxOperation.delete.rawValue else {
            return change
        }
        let localChapterID: ChapterID?
        if let remoteChapterID = nonempty(change.payload["chapterId"]?.stringValue) {
            localChapterID = chapterIDs.first {
                syncEntityID($0.rawValue, kind: "chapter")
                    .caseInsensitiveCompare(remoteChapterID) == .orderedSame
            }
        } else if let announcedLocalID = nonempty(change.payload["localChapterId"]?.stringValue) {
            localChapterID = chapterIDs.first { $0.rawValue == announcedLocalID }
        } else if let path = nonempty(
            change.payload["localObjectPath"]?.stringValue
                ?? change.payload["installedObjectPath"]?.stringValue
        ), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let transcript = try? JSONDecoder.iso.decode(Transcript.self, from: data) {
            localChapterID = chapterIDs.first { $0.rawValue == transcript.chapterID }
        } else {
            return change
        }
        guard let localChapterID else {
            Self.syncLog.info(
                "sync_transcript_revision_skipped message=sync_transcript_revision_skipped component=account-sync entityId=\(change.entityId, privacy: .public) outcome=orphan_catalog_parent"
            )
            return nil
        }
        var resolved = change
        resolved.payload["localChapterId"] = .string(localChapterID.rawValue)
        return resolved
    }

    /// Transcript eligibility observes catalog mutations from the same ordered page so a new
    /// device can install a revision immediately, while a same-page tombstone still wins.
    private static func projectedTranscriptChapterIDs(
        afterApplying changes: [SyncPulledChange],
        sqlite: LocalSQLiteStore
    ) throws -> [ChapterID] {
        guard changes.contains(where: {
            $0.entityType == OutboxEntityType.transcript.rawValue
                && $0.operation != OutboxOperation.delete.rawValue
        }) else { return [] }
        var chaptersByBook = Dictionary(uniqueKeysWithValues: try sqlite.loadBooks().map { book in
            (book.id.rawValue, Set(book.chapters.map { $0.id.rawValue }))
        })
        for change in changes {
            switch change.entityType {
            case OutboxEntityType.book.rawValue:
                if change.operation == OutboxOperation.delete.rawValue {
                    chaptersByBook.removeValue(forKey: change.payload["localId"]?.stringValue ?? change.entityId)
                } else {
                    guard let portable = try? JSONDecoder.iso.decode(
                        PortableBook.self,
                        from: SyncJSONCoding.data(from: change.payload)
                    ) else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
                    chaptersByBook[portable.localId] = Set(portable.chapters.map(\.localId))
                }
            case OutboxEntityType.chapter.rawValue:
                let bookID = try requiredString("localBookId", fallback: "bookId", in: change)
                guard var chapterIDs = chaptersByBook[bookID] else { continue }
                let chapterID = change.payload["localChapterId"]?.stringValue ?? change.entityId
                if change.operation == OutboxOperation.delete.rawValue {
                    chapterIDs.remove(chapterID)
                } else {
                    chapterIDs.insert(chapterID)
                }
                chaptersByBook[bookID] = chapterIDs
            default:
                continue
            }
        }
        return chaptersByBook.values.flatMap { $0 }.map(ChapterID.init(rawValue:))
    }

    /// Copies verified temporary objects to a content-addressed device path before the SQLite
    /// transaction. Newly created files are removed if any row/version/cursor write rolls back.
    private static func installAssetFiles(in changes: inout [SyncPulledChange]) throws -> [URL] {
        let root = Persistence.root.appendingPathComponent("SyncAssets-v2", isDirectory: true)
        var created: [URL] = []
        do {
            for index in changes.indices where changes[index].operation != OutboxOperation.delete.rawValue
                && (changes[index].entityType == OutboxEntityType.asset.rawValue
                    || changes[index].entityType == OutboxEntityType.transcript.rawValue) {
                guard let sourcePath = changes[index].payload["localObjectPath"]?.stringValue,
                      let kind = changes[index].payload["kind"]?.stringValue,
                      let sha256 = changes[index].payload["sha256"]?.stringValue
                else { throw AccountSyncApplyError.invalidPayload(changes[index].entityType) }
                let directory = root.appendingPathComponent(kind, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(sha256).appendingPathExtension("object")
                if !FileManager.default.fileExists(atPath: destination.path) {
                    let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: staging)
                    try FileManager.default.moveItem(at: staging, to: destination)
                    created.append(destination)
                }
                changes[index].payload["installedObjectPath"] = .string(destination.path)
            }
            return created
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func applySettings(_ change: SyncPulledChange, to sqlite: LocalSQLiteStore) throws {
        var settings = try sqlite.loadSettings()
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
        try sqlite.saveSettings(settings)
    }

    /// Applies vocabulary, SRS progress, and review history against the same
    /// SQLite parent graph. Missing parents throw so the page cursor is not advanced.
    static func applyLearning(
        _ change: SyncPulledChange,
        to store: LocalSQLiteStore
    ) throws -> VocabEntry? {
        switch change.entityType {
        case OutboxEntityType.vocabulary.rawValue:
            if change.operation == OutboxOperation.delete.rawValue {
                try store.applyVocabularyTombstone(
                    localID: vocabularyTombstoneLocalID(from: change),
                    entityID: change.entityId
                )
                return nil
            }
            let incoming = try vocabulary(from: change)
            let existing = try store.loadVocabulary().first {
                $0.id.rawValue.caseInsensitiveCompare(change.entityId) == .orderedSame
            }.map(VocabEntry.init)
            let resolved = existing.map {
                mergingVocabulary(existing: $0, incoming: incoming, payload: change.payload)
            } ?? incoming
            try store.upsertVocabulary(StoredVocabularyOccurrence(resolved))
            return resolved
        case OutboxEntityType.progress.rawValue:
            let vocabularyID = try requiredString("vocabularyId", in: change)
            guard let stored = try store.loadVocabulary().first(where: {
                $0.id.rawValue.caseInsensitiveCompare(vocabularyID) == .orderedSame
            }) else {
                if try store.isVocabularyTombstoned(entityID: vocabularyID) { return nil }
                throw AccountSyncApplyError.missingVocabularyParent(vocabularyID)
            }
            var entry = VocabEntry(stored)
            try applySRSProgress(change, to: &entry)
            try store.upsertVocabulary(StoredVocabularyOccurrence(entry))
            return entry
        case OutboxEntityType.reviewEvent.rawValue:
            let event = try reviewEvent(from: change)
            guard let stored = try store.loadVocabulary().first(where: {
                $0.id == event.vocabularyID
            }) else {
                if try store.isVocabularyTombstoned(entityID: event.vocabularyID.rawValue) { return nil }
                throw AccountSyncApplyError.missingVocabularyParent(event.vocabularyID.rawValue)
            }
            if try store.containsReviewEvent(id: event.id) {
                return VocabEntry(stored)
            }
            var entry = VocabEntry(stored)
            entry.lastReviewedAt = event.reviewedAt
            entry.lastReviewQuality = VocabReviewQuality(rawValue: event.rating)
            entry.reviewEligible = true
            try store.appendReviewEvent(event, vocabulary: StoredVocabularyOccurrence(entry))
            return entry
        default:
            throw AccountSyncApplyError.unsupportedLearningEntity(change.entityType)
        }
    }

    /// A legacy local vocabulary ID is accepted only when it maps back to the remote entity ID;
    /// this preserves cross-device deletion without allowing a payload to target another row.
    private static func vocabularyTombstoneLocalID(from change: SyncPulledChange) -> VocabularyOccurrenceID {
        if let rawLocalID = nonempty(change.payload["localId"]?.stringValue),
           let localID = VocabularyOccurrenceID.remote(rawValue: rawLocalID),
           syncEntityID(localID.rawValue, kind: "vocab").caseInsensitiveCompare(change.entityId) == .orderedSame {
            return localID
        }
        return VocabularyOccurrenceID(rawValue: change.entityId)
    }

    private static func vocabulary(from change: SyncPulledChange) throws -> VocabEntry {
        let localBook = change.payload["localBookId"]?.stringValue
        let localChapter = change.payload["localChapterId"]?.stringValue
        let word = try requiredString("surface", fallback: "lemma", in: change)
        let bookID: String
        if let localBook = nonempty(localBook) {
            bookID = localBook
        } else {
            bookID = try requiredString("bookId", in: change)
        }
        let chapterID: String
        if let localChapter = nonempty(localChapter) {
            chapterID = localChapter
        } else {
            chapterID = try requiredString("chapterId", in: change)
        }
        guard let changedAt = isoDate(change.changedAt) else {
            throw AccountSyncApplyError.invalidDate("changedAt")
        }
        let category = VocabCategory(rawValue: change.payload["category"]?.stringValue ?? "word") ?? .word
        let isManuallySaved = change.payload["state"]?.stringValue == "learning"
        let captureSource = change.payload["captureSource"]?.stringValue
            .flatMap(VocabularyCaptureSource.init(rawValue:))
            ?? inferredLegacyCaptureSource(category: category, isManuallySaved: isManuallySaved)
        let reviewEligible = change.payload["reviewEligible"].map { $0 == .bool(true) }
            ?? (isManuallySaved || captureSource.defaultSyncReviewEligibility)
        let canonicalizationSource = change.payload["canonicalizationSource"]?.stringValue
            .flatMap(VocabularyCanonicalizationSource.init(rawValue:)) ?? .normalized
        return VocabEntry(
            id: change.entityId,
            word: word,
            canonicalForm: change.payload["lemma"]?.stringValue ?? word,
            partOfSpeech: change.payload["partOfSpeech"]?.stringValue
                .flatMap(VocabularyPartOfSpeech.init(rawValue:)) ?? .unknown,
            senseID: change.payload["senseId"]?.stringValue,
            canonicalizationSource: canonicalizationSource,
            canonicalizationConfidence: change.payload["canonicalizationConfidence"]?.numberValue ?? 0.4,
            canonicalizationStatus: change.payload["canonicalizationStatus"]?.stringValue
                .flatMap(VocabularyCanonicalizationStatus.init(rawValue:)) ?? .needsReview,
            canonicalizationTraceID: canonicalizationSource == .userEdited
                ? nil
                : change.payload["canonicalizationTraceId"]?.stringValue,
            captureSource: captureSource,
            reviewEligible: reviewEligible,
            category: category,
            definition: change.payload["definition"]?.stringValue,
            translation: change.payload["note"]?.stringValue,
            translationLanguage: change.payload["translationLanguage"]?.stringValue,
            translationModel: change.payload["translationModel"]?.stringValue,
            sourceLanguage: change.payload["sourceLanguage"]?.stringValue,
            context: change.payload["context"]?.stringValue ?? "",
            spokenText: change.payload["spokenText"]?.stringValue,
            ebookText: change.payload["ebookText"]?.stringValue,
            bookID: bookID,
            bookTitle: change.payload["bookTitle"]?.stringValue ?? "",
            chapterID: chapterID,
            chapterTitle: change.payload["chapterTitle"]?.stringValue ?? "",
            segmentID: change.payload["segmentId"]?.stringValue,
            wordID: change.payload["wordId"]?.stringValue,
            timestamp: change.payload["timestampSeconds"]?.numberValue ?? 0,
            addedAt: changedAt,
            isInLearnList: isManuallySaved
        )
    }

    private static func inferredLegacyCaptureSource(
        category: VocabCategory,
        isManuallySaved: Bool
    ) -> VocabularyCaptureSource {
        switch category {
        case .word:
            .explicitWord
        case .phrase:
            isManuallySaved ? .explicitPhrase : .automaticPhraseSuggestion
        case .sentence:
            isManuallySaved ? .explicitSentence : .acceptedSentenceTranslation
        }
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

    /// Legacy payloads predate canonical/capture fields, so absence means
    /// preserve the local vNext classification rather than apply decoder defaults.
    private static func mergingVocabulary(
        existing: VocabEntry,
        incoming: VocabEntry,
        payload: [String: SyncJSONValue]
    ) -> VocabEntry {
        var merged = mergingVocabulary(existing: existing, incoming: incoming)
        let isVersionedPayload = (payload["vocabularySchemaVersion"]?.numberValue ?? 0) >= 1
        let hasCanonicalContract = [
            "partOfSpeech", "senseId", "canonicalizationSource",
            "canonicalizationConfidence", "canonicalizationStatus", "canonicalizationTraceId"
        ].contains { payload[$0] != nil }
        if !hasCanonicalContract {
            merged.canonicalForm = existing.canonicalForm
            merged.partOfSpeech = existing.partOfSpeech
            merged.senseID = existing.senseID
            merged.canonicalizationSource = existing.canonicalizationSource
            merged.canonicalizationConfidence = existing.canonicalizationConfidence
            merged.canonicalizationStatus = existing.canonicalizationStatus
            merged.canonicalizationTraceID = existing.canonicalizationTraceID
        } else {
            if payload["lemma"] == nil { merged.canonicalForm = existing.canonicalForm }
            if payload["partOfSpeech"] == nil { merged.partOfSpeech = existing.partOfSpeech }
            if !isVersionedPayload, payload["senseId"] == nil { merged.senseID = existing.senseID }
            if payload["canonicalizationSource"] == nil {
                merged.canonicalizationSource = existing.canonicalizationSource
            }
            if payload["canonicalizationConfidence"] == nil {
                merged.canonicalizationConfidence = existing.canonicalizationConfidence
            }
            if payload["canonicalizationStatus"] == nil {
                merged.canonicalizationStatus = existing.canonicalizationStatus
            }
            if !isVersionedPayload, payload["canonicalizationTraceId"] == nil {
                merged.canonicalizationTraceID = existing.canonicalizationTraceID
            }
        }
        if merged.canonicalizationSource == .userEdited { merged.canonicalizationTraceID = nil }
        if payload["captureSource"] == nil { merged.captureSource = existing.captureSource }
        if payload["reviewEligible"] == nil { merged.reviewEligible = existing.reviewEligible }
        return merged
    }

    private static func applyLemma(_ change: SyncPulledChange, to sqlite: LocalSQLiteStore) throws {
        guard let language = change.payload["language"]?.stringValue,
              let form = change.payload["lemma"]?.stringValue ?? change.payload["form"]?.stringValue
        else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        if change.operation == OutboxOperation.delete.rawValue {
            try sqlite.deleteKnownLemma(language: language, form: form)
        } else {
            try sqlite.upsertKnownLemma(
                StoredKnownLemma(language: language, form: form, updatedAt: Date())
            )
        }
    }

    static func isUUID(_ value: String) -> Bool {
        let pattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        return value.wholeMatch(of: pattern) != nil
    }

    private static func applyTranscript(_ change: SyncPulledChange, to sqlite: LocalSQLiteStore) throws {
        if change.operation == OutboxOperation.delete.rawValue {
            let localChapterID: ChapterID?
            if let localID = nonempty(change.payload["localChapterId"]?.stringValue) {
                localChapterID = ChapterID(rawValue: localID)
            } else if let remoteID = nonempty(change.payload["chapterId"]?.stringValue) {
                localChapterID = try sqlite.activeTranscriptChapterIDs().first {
                    syncEntityID($0.rawValue, kind: "chapter")
                        .caseInsensitiveCompare(remoteID) == .orderedSame
                }
            } else {
                localChapterID = nil
            }
            if let localChapterID {
                try sqlite.deleteTranscript(chapterID: localChapterID)
            }
            return
        }
        guard let path = change.payload["installedObjectPath"]?.stringValue,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var transcript = try? JSONDecoder.iso.decode(Transcript.self, from: data)
        else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        if let localID = change.payload["localChapterId"]?.stringValue, !localID.isEmpty {
            transcript.chapterID = localID
        }
        try sqlite.saveTranscript(StoredTranscript(transcript))
        try sqlite.saveSyncAssetManifest(try syncAssetManifest(from: change, localPath: path))
    }

    private static func applyAsset(_ change: SyncPulledChange, to sqlite: LocalSQLiteStore) throws {
        guard let path = change.payload["installedObjectPath"]?.stringValue,
              let kind = change.payload["kind"]?.stringValue
        else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        let manifest = try syncAssetManifest(from: change, localPath: path)
        try sqlite.saveSyncAssetManifest(manifest)

        guard let remoteBookID = manifest.bookID,
              let book = try sqlite.loadBooks().first(where: {
                  syncEntityID($0.id.rawValue, kind: "book").caseInsensitiveCompare(remoteBookID) == .orderedSame
              })
        else { return }
        let localChapterID = manifest.chapterID.flatMap { remoteChapterID in
            book.chapters.first(where: {
                syncEntityID($0.id.rawValue, kind: "chapter")
                    .caseInsensitiveCompare(remoteChapterID) == .orderedSame
            })?.id.rawValue
        }
        if kind == SyncAssetKind.audio.rawValue, manifest.chapterID != nil, localChapterID == nil {
            throw AccountSyncApplyError.invalidPayload(change.entityType)
        }
        let localKind = kind == SyncAssetKind.epubReadingPackage.rawValue
            ? SyncAssetKind.epub.rawValue : kind
        var assets = try sqlite.loadAssets(bookID: book.id)
        let local = StoredLocalAsset(
            id: AssetID(rawValue: manifest.id), bookID: book.id, kind: localKind,
            localMediaKey: path, contentHash: manifest.sha256,
            byteCount: manifest.compressedBytes,
            metadata: [
                "contentType": manifest.contentType,
                "encoding": manifest.encoding,
                "syncKind": kind,
            ].merging(localChapterID.map { ["chapterID": $0] } ?? [:]) { _, incoming in incoming }
        )
        assets.removeAll { $0.id == local.id }
        assets.append(local)
        try sqlite.saveAssets(assets, bookID: book.id)
    }

    private static func syncAssetManifest(
        from change: SyncPulledChange,
        localPath: String
    ) throws -> StoredSyncAssetManifest {
        guard let assetID = change.payload["assetId"]?.stringValue,
              let kind = change.payload["kind"]?.stringValue,
              let contentType = change.payload["contentType"]?.stringValue,
              let encoding = change.payload["encoding"]?.stringValue,
              let sha256 = change.payload["sha256"]?.stringValue,
              let compressed = change.payload["compressedBytes"]?.numberValue,
              let original = change.payload["originalBytes"]?.numberValue
        else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        return StoredSyncAssetManifest(
            id: assetID, kind: kind,
            revisionID: change.payload["revisionId"]?.stringValue,
            bookID: change.payload["bookId"]?.stringValue,
            chapterID: change.payload["chapterId"]?.stringValue,
            contentType: contentType, encoding: encoding, sha256: sha256,
            compressedBytes: Int64(compressed), originalBytes: Int64(original),
            segmentCount: change.payload["segmentCount"]?.numberValue.map(Int.init),
            localObjectPath: localPath
        )
    }

    private static func applyBook(_ change: SyncPulledChange, to sqlite: LocalSQLiteStore) throws {
        if change.operation == OutboxOperation.delete.rawValue {
            let localID = change.payload["localId"]?.stringValue ?? change.entityId
            try sqlite.deleteBook(id: BookID(rawValue: localID))
            return
        }
        guard let portable = try? JSONDecoder.iso.decode(
            PortableBook.self,
            from: SyncJSONCoding.data(from: change.payload)
        ) else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        try sqlite.saveBook(
            StoredBook(
                id: BookID(rawValue: portable.localId),
                title: portable.title,
                author: portable.author,
                source: portable.source,
                chapters: portable.chapters.map {
                    StoredChapter(
                        id: ChapterID(rawValue: $0.localId),
                        index: $0.index,
                        title: $0.title,
                        duration: $0.duration,
                        startTime: $0.startTime,
                        ebookSectionIndex: $0.ebookSectionIndex
                    )
                }
            )
        )
    }

    private static func applyChapter(_ change: SyncPulledChange, to sqlite: LocalSQLiteStore) throws {
        let bookID = try requiredString("localBookId", fallback: "bookId", in: change)
        let chapterID = change.payload["localChapterId"]?.stringValue ?? change.entityId
        guard var book = try sqlite.loadBooks().first(where: { $0.id.rawValue == bookID }) else {
            throw AccountSyncApplyError.invalidPayload(change.entityType)
        }
        if change.operation == OutboxOperation.delete.rawValue {
            book.chapters.removeAll { $0.id.rawValue == chapterID }
        } else {
            let chapter = StoredChapter(
                id: ChapterID(rawValue: chapterID),
                index: Int(change.payload["index"]?.numberValue ?? 0),
                title: try requiredString("title", in: change),
                duration: change.payload["duration"]?.numberValue,
                startTime: change.payload["startTime"]?.numberValue,
                ebookSectionIndex: change.payload["ebookSectionIndex"]?.numberValue.map(Int.init)
            )
            book.chapters.removeAll { $0.id == chapter.id }
            book.chapters.append(chapter)
        }
        try sqlite.saveBook(book)
    }

    private static func applyStudyActivity(_ change: SyncPulledChange, to sqlite: LocalSQLiteStore) throws {
        let day = try requiredString("day", in: change)
        var days = try sqlite.loadStudyActivityDays()
        if change.operation == OutboxOperation.delete.rawValue {
            days.removeAll { $0 == day }
        } else if !days.contains(day) {
            days.append(day)
        }
        try sqlite.saveStudyActivityDays(days.sorted())
    }

    /// Pulled overlays bypass the local mutation enqueue path; otherwise every
    /// remote correction would echo back as a new local mutation.
    private static func applyTranscriptOverlay(
        _ change: SyncPulledChange,
        to sqlite: LocalSQLiteStore
    ) throws {
        if change.operation == OutboxOperation.delete.rawValue {
            let localID = try requiredString("localOverlayId", in: change)
            try sqlite.deleteTranscriptOverlay(id: localID)
            return
        }
        guard let json = change.payload["overlayJSON"]?.stringValue,
              let data = json.data(using: .utf8),
              var overlay = try? JSONDecoder.iso.decode(StoredTranscriptOverlay.self, from: data)
        else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        if let localChapterID = change.payload["localChapterId"]?.stringValue, !localChapterID.isEmpty {
            overlay.chapterID = ChapterID(rawValue: localChapterID)
        }
        _ = try sqlite.mergeTranscriptOverlay(overlay, revision: Int64(change.revision))
    }

    private static func applyAssistantDecision(
        _ change: SyncPulledChange,
        to sqlite: LocalSQLiteStore
    ) throws {
        let payload = try assistantDecisionPayload(from: change)
        try sqlite.applyAssistantResults(
            [payload.result],
            vocabulary: payload.vocabulary,
            removingVocabularyIDs: payload.removedVocabularyIDs ?? []
        )
    }

    private static func assistantDecisionPayload(
        from change: SyncPulledChange
    ) throws -> StoredAssistantDecisionPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self), seconds.isFinite {
                // Historical outbox payloads used JSONEncoder's 2001 reference-date numbers.
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let raw = try value.decode(String.self)
            guard let date = isoDate(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: value,
                    debugDescription: "Expected an ISO-8601 or legacy reference-date value."
                )
            }
            return date
        }
        guard change.operation == OutboxOperation.upsert.rawValue,
              var payload = try? decoder.decode(
                  StoredAssistantDecisionPayload.self,
                  from: SyncJSONCoding.data(from: change.payload)
              )
        else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        // Assistant dates use whole-second wire precision. Normalize both legacy numeric and
        // current ISO payloads before the result and its entity version are written atomically.
        payload.result.createdAt = syncCanonicalAssistantDate(payload.result.createdAt)
        payload.result.decidedAt = payload.result.decidedAt.map(syncCanonicalAssistantDate)
        if payload.result.id.lowercased() == change.entityId.lowercased(),
           let glossKind = legacyGlossKind(payload.result.kind) {
            let legacyID = GlossEntry.makeID(
                kind: glossKind,
                language: payload.result.language,
                source: payload.result.source,
                context: payload.result.context
            )
            // v2 uses a UUID entity, but pre-v2 gloss rows keep their content-hash identity on
            // every device. Require the deterministic mapping before restoring that local ID.
            if syncEntityID(legacyID, kind: "assistant-result") == change.entityId.lowercased() {
                payload.result.id = legacyID
            }
        }
        return payload
    }

    private static func legacyGlossKind(_ kind: AssistantResultKind) -> GlossKind? {
        switch kind {
        case .sentenceGloss: .sentence
        case .wordGloss: .word
        case .chapterSummary, .chapterTranslation: nil
        }
    }

    private static func applySRSProgress(_ change: SyncPulledChange, to entry: inout VocabEntry) throws {
        if let count = change.payload["reviewCount"]?.numberValue {
            entry.reviewCount = Int(count)
            // A historical review is stronger evidence than legacy capture defaults; never hide it from study.
            if entry.reviewCount > 0 { entry.reviewEligible = true }
        }
        if let quality = change.payload["lastReviewQuality"]?.stringValue {
            entry.lastReviewQuality = VocabReviewQuality(rawValue: quality)
        }
        if let next = change.payload["nextReview"]?.stringValue {
            guard let date = isoDate(next) else { throw AccountSyncApplyError.invalidDate("nextReview") }
            entry.nextReview = date
        }
        if let last = change.payload["lastReviewedAt"]?.stringValue {
            guard let date = isoDate(last) else { throw AccountSyncApplyError.invalidDate("lastReviewedAt") }
            entry.lastReviewedAt = date
        }
        if let interval = change.payload["reviewIntervalDays"]?.numberValue {
            entry.reviewIntervalDays = interval
        }
        if let ease = change.payload["reviewEaseFactor"]?.numberValue {
            entry.reviewEaseFactor = ease
        }
    }

    private static func applyReaderProgress(
        _ change: SyncPulledChange,
        to sqlite: LocalSQLiteStore
    ) throws {
        guard let bookID = change.payload["localBookId"]?.stringValue,
              let chapterID = change.payload["localChapterId"]?.stringValue,
              let seconds = change.payload["relativeSeconds"]?.numberValue,
              let deviceID = change.payload["deviceId"]?.stringValue
        else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        guard let updatedAt = isoDate(change.payload["updatedAt"]?.stringValue ?? change.changedAt) else {
            throw AccountSyncApplyError.invalidDate("updatedAt")
        }
        let progress = StoredReaderProgress(
            id: change.payload["localProgressId"]?.stringValue ?? "remote:\(change.entityId):\(change.revision)",
            bookID: BookID(rawValue: bookID),
            chapterID: ChapterID(rawValue: chapterID),
            relativeSeconds: seconds,
            updatedAt: updatedAt,
            deviceID: deviceID,
            revision: Int64(change.revision)
        )
        _ = try sqlite.mergeReaderProgress(progress)
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
        let sqlite = LocalSQLiteStore(fileURL: Persistence.databaseURL)
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
        let sqlite = LocalSQLiteStore(fileURL: Persistence.databaseURL)
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

    private static func reviewEvent(from change: SyncPulledChange) throws -> StoredReviewEvent {
        guard change.entityType == OutboxEntityType.reviewEvent.rawValue,
              change.operation == OutboxOperation.append.rawValue
        else { throw AccountSyncApplyError.invalidPayload(change.entityType) }
        let vocabularyID = try requiredString("vocabularyId", in: change)
        let rating = try requiredString("rating", in: change)
        let rawReviewedAt = change.payload["reviewedAt"]?.stringValue ?? change.changedAt
        guard let reviewedAt = isoDate(rawReviewedAt) else {
            throw AccountSyncApplyError.invalidDate("reviewedAt")
        }
        return StoredReviewEvent(
            id: ReviewEventID(rawValue: change.entityId),
            vocabularyID: VocabularyOccurrenceID(rawValue: vocabularyID),
            cardID: change.payload["cardId"]?.stringValue,
            face: change.payload["face"]?.stringValue ?? "recognition",
            rating: rating,
            reviewedAt: reviewedAt
        )
    }

    static func uuidForLemma(language: String, form: String) -> String {
        uuidForStableKey("lemma:\(language):\(form)")
    }

    static func syncEntityID(_ localID: String, kind: String) -> String {
        isUUID(localID) ? localID.lowercased() : uuidForStableKey("\(kind):\(localID)")
    }

    private static func requiredString(
        _ key: String,
        fallback: String? = nil,
        in change: SyncPulledChange
    ) throws -> String {
        if let value = change.payload[key]?.stringValue, !value.isEmpty {
            return value
        }
        if let fallback,
           let value = change.payload[fallback]?.stringValue,
           !value.isEmpty {
            return value
        }
        throw AccountSyncApplyError.missingField(key, entityType: change.entityType)
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

    /// Assistant timestamps use second-precision ISO text on the wire. Snapshotting that same
    /// representation keeps an immutable local subsecond from looking like a new decision forever.
    private static func syncCanonicalAssistantDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
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

private enum AccountSyncApplyError: LocalizedError {
    case invalidDate(String)
    case invalidPayload(String)
    case missingField(String, entityType: String)
    case missingVocabularyParent(String)
    case persistenceFailed(String)
    case unsupportedLearningEntity(String)

    var errorDescription: String? {
        switch self {
        case .invalidDate(let field):
            "The sync change contains an invalid \(field) date."
        case .invalidPayload(let entityType):
            "The \(entityType) sync change is incomplete."
        case .missingField(let field, let entityType):
            "The \(entityType) sync change is missing \(field)."
        case .missingVocabularyParent:
            "A vocabulary item required by this sync change has not arrived yet."
        case .persistenceFailed(let resource):
            "The synced \(resource) could not be saved on this device."
        case .unsupportedLearningEntity(let entityType):
            "The \(entityType) change is not a learning-data change."
        }
    }
}

private extension VocabularyCaptureSource {
    var defaultSyncReviewEligibility: Bool {
        switch self {
        case .acceptedSentenceTranslation, .automaticPhraseSuggestion: false
        case .explicitWord, .explicitPhrase, .explicitSentence: true
        }
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
    // Versioned omission of optional canonical fields means intentional nil;
    // unversioned omission retains the rolling-upgrade legacy meaning of absent.
    var vocabularySchemaVersion = 1
    var bookId: String
    var chapterId: String
    var localBookId: String
    var localChapterId: String
    var bookTitle: String
    var chapterTitle: String
    var surface: String
    var lemma: String
    var partOfSpeech: String
    var senseId: String?
    var canonicalizationSource: String
    var canonicalizationConfidence: Double
    var canonicalizationStatus: String
    var canonicalizationTraceId: String?
    var captureSource: String
    var reviewEligible: Bool
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

private struct PortableStudyActivity: Encodable {
    var day: String
}

private struct PortableBook: Codable {
    var localId: String
    var title: String
    var author: String?
    var source: String
    var chapters: [PortableChapter]
}

private struct PortableChapter: Codable {
    var localId: String
    var index: Int
    var title: String
    var duration: Double?
    var startTime: Double?
    var ebookSectionIndex: Int?
}

private struct PortableTranscriptOverlay: Encodable {
    var chapterId: String
    var localChapterId: String
    var segmentId: String
    var overlayJSON: String
}

private struct PortableReview: Encodable {
    var vocabularyId: String
    var cardId: String?
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
    var reviewIntervalDays: Double
    var reviewEaseFactor: Double
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
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
            return window
        }
        guard let scene = scenes.first else {
            // Authentication can only be presented while the app owns an active scene.
            preconditionFailure("Web authentication requested without a window scene")
        }
        return ASPresentationAnchor(windowScene: scene)
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
