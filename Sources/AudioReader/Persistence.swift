import Foundation
import OSLog
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

enum Persistence {
    static let transcriptPageSize = 200
    private static let overlayLog = Logger(subsystem: "com.johnsonzhang.AudioReader", category: "transcript-overlay")
    private static let durabilityLog = Logger(subsystem: "com.johnsonzhang.AudioReader", category: "persistence")
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AudioReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// This identity is the hard boundary that prevents an older branch from
    /// opening or repairing the current schema.
    static var databaseURL: URL { root.appendingPathComponent("library-vNext.sqlite") }
    static let localMediaReimportNotice = "Local media from earlier versions is not migrated. Re-import audio or EPUB files to use them in this clean library."
    static let store = LocalSQLiteStore(fileURL: databaseURL)

    static var importedBooksURL: URL {
        let dir = defaultImportedBooksURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolves the platform path without creating it. In-memory AppState
    /// construction uses this default and must not touch Application Support.
    static var defaultImportedBooksURL: URL {
#if os(iOS)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("ImportedBooks-vNext", isDirectory: true)
#else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("AudioReader", isDirectory: true)
            .appendingPathComponent("ImportedBooks-vNext", isDirectory: true)
#endif
    }

    /// A scan publishes only changed catalog metadata. Media paths remain on
    /// the filesystem and are never copied into the sync payload.
    static func saveCatalogBooks(
        _ books: [Book],
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        let existing = Dictionary(uniqueKeysWithValues: try database.loadBooks().map { ($0.id, $0) })
        for book in books {
            let stored = StoredBook(book)
            let existingAssets = try database.loadAssets(bookID: stored.id)
            let assets = StoredLocalAsset.snapshots(for: book, reusing: existingAssets)
            if existing[stored.id] == stored {
                if existingAssets != assets { try database.saveAssets(assets, bookID: stored.id) }
                continue
            }
            let entityID = AccountSyncApplicator.syncEntityID(stored.id.rawValue, kind: "book")
            let revision = try database.loadVersion(entityType: OutboxEntityType.book.rawValue, entityID: entityID)
                .map { ServerVersion($0.serverVersion) } ?? .zero
            try database.saveBook(
                stored,
                assets: assets,
                mutation: AccountSyncApplicator.bookMutation(for: stored, baseRevision: revision)
            )
        }
    }

    static func loadCatalogBooks(database: LocalSQLiteStore = Persistence.store) throws -> [Book] {
        try database.loadBooks().map { stored in
            let assets = try database.loadAssets(bookID: stored.id)
            let repaired = try repairMissingEbookSectionIndices(
                in: stored,
                assets: assets,
                database: database
            )
            return Book(repaired, assets: assets)
        }
    }

    /// Repairs only legacy EPUB-only rows: paired/audio catalogs use a different
    /// chapter contract and must never inherit EPUB spine positions by proximity.
    private static func repairMissingEbookSectionIndices(
        in stored: StoredBook,
        assets: [StoredLocalAsset],
        database: LocalSQLiteStore
    ) throws -> StoredBook {
        guard !stored.chapters.isEmpty,
              stored.chapters.allSatisfy({ $0.ebookSectionIndex == nil }),
              !assets.contains(where: { $0.kind == "audio" }),
              let ebookPath = assets.first(where: { $0.kind == "epub" })?.localMediaKey,
              let document = EPUBParser.document(from: ebookPath),
              document.sections.count == stored.chapters.count,
              Set(stored.chapters.map(\.index)) == Set(document.sections.indices),
              Set(stored.chapters.map(\.index)).count == stored.chapters.count
        else { return stored }

        var repaired = stored
        for chapterOffset in repaired.chapters.indices {
            repaired.chapters[chapterOffset].ebookSectionIndex = repaired.chapters[chapterOffset].index
        }

        let entityID = AccountSyncApplicator.syncEntityID(repaired.id.rawValue, kind: "book")
        let revision = try database.loadVersion(
            entityType: OutboxEntityType.book.rawValue,
            entityID: entityID
        ).map { ServerVersion($0.serverVersion) } ?? .zero
        try database.saveBook(
            repaired,
            mutation: AccountSyncApplicator.bookMutation(for: repaired, baseRevision: revision)
        )
        durabilityLog.info(
            "message=catalog.epub_section_repair component=persistence outcome=success bookId=\(repaired.id.rawValue, privacy: .public) chapters=\(repaired.chapters.count, privacy: .public)"
        )
        return repaired
    }

    /// Durable catalog tombstones win over filesystem discovery. This leaves
    /// unmanaged media untouched while ensuring rescans never enqueue a new upsert.
    static func reconcileScannedBooks(
        _ scanned: [Book],
        database: LocalSQLiteStore = Persistence.store
    ) throws -> [Book] {
        let visible = try filterSuppressedBooks(scanned, database: database)
        try saveCatalogBooks(visible, database: database)
        let scannedIDs = Set(visible.map(\.id))
        return visible + (try loadCatalogBooks(database: database)).filter { !scannedIDs.contains($0.id) }
    }

    static func filterSuppressedBooks(
        _ scanned: [Book],
        database: LocalSQLiteStore = Persistence.store
    ) throws -> [Book] {
        let suppressed = Set(try database.loadDeletedBookIDs().map(\.rawValue))
        return scanned.filter { !suppressed.contains($0.id) }
    }

    /// Media is staged inside the managed root before SQLite commits. A failed
    /// tombstone restores the folder; after commit, deleting the staging folder
    /// cannot make the catalog row reappear on the next scan.
    static func deleteBook(
        _ book: Book,
        mediaRoot: URL,
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        let storedID = BookID(rawValue: book.id)
        let entityID = AccountSyncApplicator.syncEntityID(book.id, kind: "book")
        let revision = try database.loadVersion(
            entityType: OutboxEntityType.book.rawValue,
            entityID: entityID
        ).map { ServerVersion($0.serverVersion) } ?? .zero
        let mutation = try AccountSyncApplicator.bookDeletionMutation(
            localID: book.id,
            baseRevision: revision
        )
        let root = mediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        let folder = book.folderPath.isEmpty
            ? nil
            : URL(fileURLWithPath: book.folderPath, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
        var staged: URL?
        if let folder, FileManager.default.fileExists(atPath: folder.path) {
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard folder.path.hasPrefix(rootPrefix), folder.path != root.path else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let destination = root.appendingPathComponent(".deleting-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: folder, to: destination)
            staged = destination
        }
        do {
            _ = try database.deleteBook(id: storedID, mutation: mutation)
        } catch {
            if let staged, let folder { try? FileManager.default.moveItem(at: staged, to: folder) }
            throw error
        }
        if let staged { try FileManager.default.removeItem(at: staged) }
    }

    static func loadTranscript(
        chapterID: String,
        database: any TranscriptRepository = Persistence.store
    ) -> Transcript? {
        try? database.loadTranscript(chapterID: ChapterID(rawValue: chapterID)).map(Transcript.init)
    }

    static func loadTranscriptPage(
        chapterID: String,
        range: Range<Int>,
        database: LocalSQLiteStore = Persistence.store
    ) -> Transcript? {
        try? database.loadTranscript(
            chapterID: ChapterID(rawValue: chapterID),
            range: range
        ).map(Transcript.init)
    }

    static func transcriptSegmentCount(
        chapterID: String,
        database: LocalSQLiteStore = Persistence.store
    ) -> Int {
        (try? database.transcriptSegmentCount(chapterID: ChapterID(rawValue: chapterID))) ?? 0
    }

    static func loadTranscriptPage(
        for chapter: Chapter,
        range: Range<Int>,
        database: LocalSQLiteStore = Persistence.store
    ) -> Transcript? {
        guard let transcript = loadTranscriptPage(chapterID: chapter.id, range: range, database: database),
              transcript.belongs(to: chapter)
        else { return nil }
        return transcript
    }

    /// Assistant jobs deliberately opt into the complete revision, assembled
    /// by SQLite in bounded pages rather than reusing the reader's visible page.
    static func loadCompleteTranscript(
        for chapter: Chapter,
        database: LocalSQLiteStore = Persistence.store
    ) -> Transcript? {
        guard let transcript = try? database.loadCompleteTranscript(
            chapterID: ChapterID(rawValue: chapter.id),
            pageSize: transcriptPageSize
        ), Transcript(transcript).belongs(to: chapter) else { return nil }
        return Transcript(transcript)
    }

    static func loadTranscript(
        for chapter: Chapter,
        database: any TranscriptRepository = Persistence.store
    ) -> Transcript? {
        guard let transcript = loadTranscript(chapterID: chapter.id, database: database),
              transcript.belongs(to: chapter)
        else { return nil }
        return transcript
    }

    static func loadAllTranscripts() -> [Transcript] {
        ((try? store.loadAllTranscripts()) ?? []).map(Transcript.init)
    }

    static func readyChapterIDs(
        in books: [Book],
        database: LocalSQLiteStore = Persistence.store
    ) -> Set<String> {
        let persisted = (try? database.activeTranscriptChapterIDs()) ?? []
        return Set(books.flatMap(\.chapters).compactMap { chapter in
            chapter.hasAudio && persisted.contains(ChapterID(rawValue: chapter.id)) ? chapter.id : nil
        })
    }

    static func saveTranscript(
        _ transcript: Transcript,
        database: any TranscriptRepository = Persistence.store
    ) throws {
        durabilityLog.info("message=transcript.save component=persistence outcome=start chapter=\(transcript.chapterID, privacy: .public) segments=\(transcript.segments.count, privacy: .public)")
        do {
            try database.saveTranscript(StoredTranscript(transcript))
            durabilityLog.info("message=transcript.save component=persistence outcome=success chapter=\(transcript.chapterID, privacy: .public) segments=\(transcript.segments.count, privacy: .public)")
        } catch {
            durabilityLog.error("message=transcript.save component=persistence outcome=failure chapter=\(transcript.chapterID, privacy: .public)")
            throw error
        }
    }

    static func loadTranscriptOverlays(
        chapterID: String,
        database: LocalSQLiteStore = Persistence.store
    ) -> [StoredTranscriptOverlay] {
        (try? database.loadTranscriptOverlays(chapterID: ChapterID(rawValue: chapterID))) ?? []
    }

    static func loadAllTranscriptOverlays() -> [StoredTranscriptOverlay] {
        (try? store.loadAllTranscriptOverlays()) ?? []
    }

    static func loadTranscriptOverlayState(
        chapterID: String,
        segmentID: String,
        database: LocalSQLiteStore = Persistence.store
    ) -> StoredTranscriptOverlayState? {
        return try? database.loadTranscriptOverlayState(
            chapterID: ChapterID(rawValue: chapterID),
            segmentID: segmentID
        )
    }

    static func resolvedTranscript(
        _ transcript: Transcript,
        chapterDuration: TimeInterval? = nil,
        database: LocalSQLiteStore = Persistence.store
    ) -> ResolvedTranscript {
        TranscriptOverlayResolver.resolve(
            base: StoredTranscript(transcript),
            overlays: loadTranscriptOverlays(chapterID: transcript.chapterID, database: database),
            chapterDuration: chapterDuration
        )
    }

    /// Local edits validate against the immutable base before persistence and
    /// enqueue only IDs/timing plus encoded overlay data—never book text in logs.
    static func saveTranscriptOverlay(
        _ overlay: StoredTranscriptOverlay,
        base: Transcript,
        chapterDuration: TimeInterval? = nil,
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        let resolution = TranscriptOverlayResolver.resolve(
            base: StoredTranscript(base),
            overlays: [overlay],
            chapterDuration: chapterDuration
        )
        guard resolution.statuses[overlay.id] == .applied else {
            let status = resolution.statuses[overlay.id]
            overlayLog.warning("message=overlay.save component=transcript-overlay outcome=rejected chapter=\(overlay.chapterID.rawValue, privacy: .public) segment=\(overlay.segmentID, privacy: .public) status=\(String(describing: status), privacy: .public)")
            switch status {
            case .staleBase:
                throw TranscriptOverlaySaveError.staleBase
            case .invalid(let error):
                throw TranscriptOverlaySaveError.invalid(error)
            default:
                throw TranscriptOverlaySaveError.invalid(.missingSegment)
            }
        }

        let state = try database.loadTranscriptOverlayState(
            chapterID: overlay.chapterID,
            segmentID: overlay.segmentID
        )
        let baseRevision = state?.current.revision ?? 0
        _ = try database.mergeTranscriptOverlay(
            overlay,
            revision: baseRevision,
            mutation: overlayMutation(overlay, operation: .upsert, baseRevision: baseRevision)
        )

        if let baseSegment = base.segments.first(where: { $0.id == overlay.segmentID }) {
            let priorGlosses = loadGlosses(database: database)
            let glosses = GlossEntry.stalingAcceptedSentenceTranslations(
                priorGlosses,
                chapterID: base.chapterID,
                source: baseSegment.displayText
            )
            let priorByID = Dictionary(uniqueKeysWithValues: priorGlosses.map { ($0.id, $0.status) })
            try saveGlossUpdates(
                glosses.filter { priorByID[$0.id] != $0.status },
                allItems: glosses,
                database: database
            )
        }
        overlayLog.info("message=overlay.save component=transcript-overlay outcome=success chapter=\(overlay.chapterID.rawValue, privacy: .public) segment=\(overlay.segmentID, privacy: .public)")
    }

    /// Restore is represented as a sync tombstone before local deletion so a
    /// crash cannot silently revive the correction on another device.
    static func restoreOriginalTranscriptSegment(
        overlayID: String,
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        guard let overlay = try database.loadAllTranscriptOverlays().first(where: { $0.id == overlayID }) else {
            return
        }
        let baseRevision = try database.loadTranscriptOverlayState(
            chapterID: overlay.chapterID,
            segmentID: overlay.segmentID
        )?.current.revision ?? 0
        try database.deleteTranscriptOverlay(
            id: overlayID,
            mutation: overlayMutation(overlay, operation: .delete, baseRevision: baseRevision)
        )
        overlayLog.info("message=overlay.restore component=transcript-overlay outcome=success chapter=\(overlay.chapterID.rawValue, privacy: .public) segment=\(overlay.segmentID, privacy: .public)")
    }

    /// Explicit resolution is the only path that discards competing candidates.
    /// The chosen payload is re-enqueued against the observed server revision.
    @discardableResult
    static func resolveTranscriptOverlay(
        chapterID: String,
        segmentID: String,
        choosing candidateID: String,
        database: LocalSQLiteStore = Persistence.store
    ) throws -> StoredTranscriptOverlay? {
        let domainChapterID = ChapterID(rawValue: chapterID)
        guard let state = try database.loadTranscriptOverlayState(
            chapterID: domainChapterID,
            segmentID: segmentID
        ) else { return nil }
        let choices = [state.current] + state.conflicts
        guard let chosen = choices.first(where: { $0.id == candidateID }) else { return nil }
        try database.resolveTranscriptOverlay(
            chapterID: domainChapterID,
            segmentID: segmentID,
            choosing: candidateID,
            mutation: overlayMutation(
                chosen.overlay,
                operation: .upsert,
                baseRevision: state.current.revision
            )
        )
        overlayLog.info("message=overlay.resolve component=transcript-overlay outcome=success chapter=\(chapterID, privacy: .public) segment=\(segmentID, privacy: .public) candidate=\(candidateID, privacy: .public)")
        return chosen.overlay
    }

    static func loadReaderProgress(
        bookID: String,
        database: LocalSQLiteStore = Persistence.store
    ) -> StoredReaderProgressState? {
        try? database.loadReaderProgress(bookID: BookID(rawValue: bookID))
    }

    /// Stores chapter-relative fractional seconds without rounding. Sync
    /// snapshots use the same record so resume remains exact across devices.
    @discardableResult
    static func saveReaderProgress(
        _ progress: StoredReaderProgress,
        database: LocalSQLiteStore = Persistence.store
    ) throws -> ReaderProgressMergeOutcome {
        guard progress.relativeSeconds.isFinite, progress.relativeSeconds >= 0 else {
            throw ReaderProgressSaveError.invalidSeconds
        }
        let outcome = try database.mergeReaderProgress(progress)
        overlayLog.info("message=reader_progress.save component=reader-progress outcome=\(String(describing: outcome), privacy: .public) book=\(progress.bookID.rawValue, privacy: .public) chapter=\(progress.chapterID.rawValue, privacy: .public) device=\(progress.deviceID, privacy: .public)")
        return outcome
    }

    static func resolveReaderProgress(
        bookID: String,
        choosing candidateID: String,
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        try database.resolveReaderProgress(bookID: BookID(rawValue: bookID), choosing: candidateID)
        overlayLog.info("message=reader_progress.resolve component=reader-progress outcome=success book=\(bookID, privacy: .public) candidate=\(candidateID, privacy: .public)")
    }

    private static func overlayMutation(
        _ overlay: StoredTranscriptOverlay,
        operation: OutboxOperation,
        baseRevision: Int64
    ) throws -> OutboxMutation {
        let overlayJSON = String(data: try JSONEncoder.iso.encode(overlay), encoding: .utf8) ?? "{}"
        let payload = try JSONEncoder().encode([
            "chapterId": AccountSyncApplicator.syncEntityID(overlay.chapterID.rawValue, kind: "chapter"),
            "localChapterId": overlay.chapterID.rawValue,
            "localOverlayId": overlay.id,
            "segmentId": overlay.segmentID,
            "overlayJSON": overlayJSON,
        ])
        return OutboxMutation(
            id: MutationID.generate(),
            entityType: .transcriptOverlay,
            entityID: AccountSyncApplicator.syncEntityID(overlay.id, kind: "overlay"),
            operation: operation,
            baseRevision: ServerVersion(baseRevision),
            occurredAt: overlay.updatedAt,
            payload: payload
        )
    }

    static func loadVocab() -> [VocabEntry] {
        ((try? store.loadVocabulary()) ?? []).map(VocabEntry.init)
    }

    static func saveVocab(_ items: [VocabEntry]) {
        try? store.saveVocabulary(items.map(StoredVocabularyOccurrence.init))
    }

    static func loadKnownLemmas() -> [KnownLemmaRecord] {
        ((try? store.loadKnownLemmas()) ?? []).map(KnownLemmaRecord.init)
    }

    @discardableResult
    static func saveKnownLemmas(_ items: [KnownLemmaRecord]) -> Bool {
        do {
            try store.saveKnownLemmas(items.map(StoredKnownLemma.init))
            return true
        } catch {
            return false
        }
    }

    static func loadStudyActivityLog(database: LocalSQLiteStore = Persistence.store) -> StudyActivityLog {
        StudyActivityLog(days: (try? database.loadStudyActivityDays()) ?? [])
    }

    static func saveStudyActivityLog(
        _ log: StudyActivityLog,
        database: LocalSQLiteStore = Persistence.store
    ) {
        try? database.saveStudyActivityDays(log.days)
    }

    static func loadSettings(database: LocalSQLiteStore = Persistence.store) -> AppSettings {
        var settings = AppSettings.default
        if let stored = try? database.loadSettings() { settings.apply(stored) }
        return settings
    }

    @discardableResult
    static func saveSettings(
        _ settings: AppSettings,
        database: LocalSQLiteStore = Persistence.store
    ) -> Bool {
        do {
            try database.saveSettings(StoredSettings(settings))
            return true
        } catch {
            return false
        }
    }

    static func loadGlosses(database: LocalSQLiteStore = Persistence.store) -> [GlossEntry] {
        ((try? database.loadAssistantResults()) ?? []).compactMap { try? GlossEntry($0) }
    }

    static func saveGlosses(_ items: [GlossEntry]) {
        let durable = ((try? store.loadAssistantResults()) ?? []).filter {
            $0.kind == .chapterSummary || $0.kind == .chapterTranslation
        }
        try? store.replaceAssistantResults(durable + items.map(StoredAssistantResult.init))
    }

    /// Generated results commit as one batch. Callers must publish them only
    /// after this returns so an SQLite failure cannot masquerade as a saved translation.
    static func saveGlossUpdates(
        _ updates: [GlossEntry],
        allItems: [GlossEntry],
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        durabilityLog.info("message=translation.generated.save component=persistence outcome=start count=\(updates.count, privacy: .public)")
        do {
            try database.performSyncPageTransaction {
                try persistGlossUpdates(updates, database: database)
            }
            durabilityLog.info("message=translation.generated.save component=persistence outcome=success count=\(updates.count, privacy: .public)")
        } catch {
            durabilityLog.error("message=translation.generated.save component=persistence outcome=failure count=\(updates.count, privacy: .public)")
            throw error
        }
    }

    private static func persistGlossUpdates(
        _ updates: [GlossEntry],
        database: LocalSQLiteStore
    ) throws {
        for update in updates {
            let result = StoredAssistantResult(update)
            if update.status == .stale || update.status == .edited || update.status == .replaced,
               UUID(uuidString: result.id) != nil {
                try saveAssistantResultLifecycle(result, database: database)
            } else {
                try database.saveAssistantResult(result)
            }
        }
    }

    /// Non-acceptance lifecycle changes retain the server-issued assistant result UUID.
    private static func saveAssistantResultLifecycle(
        _ result: StoredAssistantResult,
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        let entityID = result.id
        let baseRevision = try database.loadVersion(
            entityType: OutboxEntityType.assistantResult.rawValue,
            entityID: entityID
        )?.serverVersion ?? 0
        try database.updateAssistantResult(
            result,
            mutation: OutboxMutation(
                id: MutationID.generate(),
                entityType: .assistantResult,
                entityID: entityID,
                operation: .upsert,
                baseRevision: ServerVersion(baseRevision),
                occurredAt: result.decidedAt ?? Date(),
                payload: try JSONEncoder.iso.encode(
                    StoredAssistantDecisionPayload(result: result, vocabulary: [])
                )
            )
        )
    }

    /// Live acceptance has one owner: SQLite commits the decision, derived
    /// learning rows, and upload intent together before AppState publishes it.
    static func acceptGlosses(
        _ items: [GlossEntry],
        vocabulary: [VocabEntry],
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        let storedVocabulary = vocabulary.map(StoredVocabularyOccurrence.init)
        let results = items.map(StoredAssistantResult.init)
        let mutations = try zip(items, results).map { item, result in
            let source = GlossEntry.normalize(item.source)
            let related = zip(vocabulary, storedVocabulary).compactMap { entry, stored in
                GlossEntry.normalize(entry.context) == source ? stored : nil
            }
            let payload = try JSONEncoder.iso.encode(
                StoredAssistantDecisionPayload(result: result, vocabulary: related)
            )
            let entityID = UUID(uuidString: result.id) == nil
                ? AccountSyncApplicator.syncEntityID(result.id, kind: "assistant-result")
                : result.id.lowercased()
            let baseRevision = try database.loadVersion(
                entityType: OutboxEntityType.assistantResult.rawValue,
                entityID: entityID
            )?.serverVersion ?? 0
            return OutboxMutation(
                id: MutationID.generate(),
                entityType: .assistantResult,
                entityID: entityID,
                operation: .upsert,
                baseRevision: ServerVersion(baseRevision),
                occurredAt: result.decidedAt ?? result.createdAt,
                payload: payload
            )
        }
        try database.acceptAssistantResults(results, vocabulary: storedVocabulary, mutations: mutations)
    }

    /// A rejection removes only unreviewed assistant-derived learning rows and
    /// records the portable decision in the same SQLite transaction.
    static func rejectGloss(
        _ item: GlossEntry,
        derivedVocabulary: [VocabEntry],
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        let result = StoredAssistantResult(item)
        let removedIDs = derivedVocabulary.map { StoredVocabularyOccurrence($0).id }
        let payload = try JSONEncoder.iso.encode(StoredAssistantDecisionPayload(
            result: result,
            vocabulary: [],
            removedVocabularyIDs: removedIDs
        ))
        let entityID = UUID(uuidString: result.id) == nil
            ? AccountSyncApplicator.syncEntityID(result.id, kind: "assistant-result")
            : result.id.lowercased()
        let baseRevision = try database.loadVersion(
            entityType: OutboxEntityType.assistantResult.rawValue,
            entityID: entityID
        )?.serverVersion ?? 0
        try database.rejectAssistantResult(
            result,
            derivedVocabularyIDs: removedIDs,
            mutation: OutboxMutation(
                id: MutationID.generate(),
                entityType: .assistantResult,
                entityID: entityID,
                operation: .upsert,
                baseRevision: ServerVersion(baseRevision),
                occurredAt: result.decidedAt ?? result.createdAt,
                payload: payload
            )
        )
    }

    static func loadChapterTranslationCheckpoints(
        database: LocalSQLiteStore = Persistence.store
    ) -> [ChapterTranslationCheckpoint] {
        ((try? database.loadTranslationCheckpoints()) ?? []).compactMap { checkpoint in
            guard let mode = ChapterTranslationMode(rawValue: checkpoint.mode),
                  let status = ChapterTranslationStatus(rawValue: checkpoint.status)
            else { return nil }
            return ChapterTranslationCheckpoint(
                chapterID: checkpoint.chapterID.rawValue,
                language: checkpoint.language,
                mode: mode,
                nextSegmentIndex: checkpoint.completedSegmentCount,
                totalSentences: checkpoint.totalSegmentCount,
                status: status,
                updatedAt: checkpoint.updatedAt
            )
        }
    }

    /// Upserts only one chapter/language checkpoint. Other devices may have
    /// synchronized unrelated checkpoints that this caller has never loaded.
    static func saveChapterTranslationCheckpoint(
        _ checkpoint: ChapterTranslationCheckpoint,
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        durabilityLog.info("message=translation.checkpoint.save component=persistence outcome=start chapter=\(checkpoint.chapterID, privacy: .public)")
        do {
            try database.saveTranslationCheckpoint(storedCheckpoint(checkpoint))
            durabilityLog.info("message=translation.checkpoint.save component=persistence outcome=success chapter=\(checkpoint.chapterID, privacy: .public)")
        } catch {
            durabilityLog.error("message=translation.checkpoint.save component=persistence outcome=failure chapter=\(checkpoint.chapterID, privacy: .public)")
            throw error
        }
    }

    /// Draft rows and their resume position are one durable unit. Publishing
    /// either before this commits would make a failed checkpoint look resumable.
    static func saveGeneratedTranslationDrafts(
        _ drafts: [GlossEntry],
        checkpoint: ChapterTranslationCheckpoint,
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        durabilityLog.info("message=translation.drafts.checkpoint.save component=persistence outcome=start chapter=\(checkpoint.chapterID, privacy: .public) count=\(drafts.count, privacy: .public)")
        do {
            try database.performSyncPageTransaction {
                try persistGlossUpdates(drafts, database: database)
                try database.saveTranslationCheckpoint(storedCheckpoint(checkpoint))
            }
            durabilityLog.info("message=translation.drafts.checkpoint.save component=persistence outcome=success chapter=\(checkpoint.chapterID, privacy: .public) count=\(drafts.count, privacy: .public)")
        } catch {
            durabilityLog.error("message=translation.drafts.checkpoint.save component=persistence outcome=failure chapter=\(checkpoint.chapterID, privacy: .public) count=\(drafts.count, privacy: .public)")
            throw error
        }
    }

    private static func storedCheckpoint(
        _ checkpoint: ChapterTranslationCheckpoint
    ) -> StoredTranslationCheckpoint {
        StoredTranslationCheckpoint(
            chapterID: ChapterID(rawValue: checkpoint.chapterID),
            language: checkpoint.language,
            mode: checkpoint.mode.rawValue,
            completedSegmentCount: checkpoint.nextSegmentIndex,
            totalSegmentCount: checkpoint.totalSentences,
            status: checkpoint.status.rawValue,
            updatedAt: checkpoint.updatedAt
        )
    }

    static func loadChapterSummaries(database: LocalSQLiteStore = Persistence.store) -> [ChapterSummaryRecord] {
        ((try? database.loadAssistantResults()) ?? [])
            .filter { $0.kind == .chapterSummary }
            .compactMap(chapterSummary(from:))
    }

    /// Summary lifecycle completion must not be published until this durable write succeeds.
    static func saveChapterSummaryUpdate(
        _ summary: ChapterSummaryRecord,
        database: LocalSQLiteStore = Persistence.store
    ) throws {
        let result = try storedSummary(from: summary)
        if summary.status != .pending, UUID(uuidString: result.id) != nil {
            try saveAssistantResultLifecycle(result, database: database)
        } else {
            try database.saveAssistantResult(result)
        }
    }

    private static func storedSummary(from record: ChapterSummaryRecord) throws -> StoredAssistantResult {
        let summary = String(decoding: try JSONEncoder.iso.encode(record.summary), as: UTF8.self)
        let replaced = try record.replacedSummary.map {
            String(decoding: try JSONEncoder.iso.encode($0), as: UTF8.self)
        }
        return StoredAssistantResult(
            id: record.id,
            kind: .chapterSummary,
            status: AssistantResultStatus(rawValue: record.status.rawValue) ?? .pending,
            language: record.language,
            model: record.model,
            promptVersion: record.promptVersion,
            modelPolicyHash: record.modelPolicyHash,
            bookID: record.bookID.map(BookID.init(rawValue:)),
            bookTitle: record.bookTitle,
            chapterID: ChapterID(rawValue: record.chapterID),
            chapterTitle: record.chapterTitle,
            source: record.chapterTitle,
            text: summary,
            createdAt: record.createdAt,
            decidedAt: record.decidedAt,
            replacedText: replaced,
            replacedModel: record.replacedModel,
            sharedCacheEntryID: record.sharedCacheEntryID
        )
    }

    private static func chapterSummary(from result: StoredAssistantResult) -> ChapterSummaryRecord? {
        guard let summary = try? JSONDecoder.iso.decode(
            ChapterSummaryPresentation.self,
            from: Data(result.text.utf8)
        ), let chapterID = result.chapterID?.rawValue else { return nil }
        let replaced = result.replacedText.flatMap {
            try? JSONDecoder.iso.decode(ChapterSummaryPresentation.self, from: Data($0.utf8))
        }
        return ChapterSummaryRecord(
            id: result.id,
            summary: summary,
            language: result.language,
            status: GlossStatus(rawValue: result.status.rawValue) ?? .pending,
            model: result.model,
            promptVersion: result.promptVersion,
            modelPolicyHash: result.modelPolicyHash,
            sharedCacheEntryID: result.sharedCacheEntryID,
            bookID: result.bookID?.rawValue,
            bookTitle: result.bookTitle ?? "",
            chapterID: chapterID,
            chapterTitle: result.chapterTitle ?? "",
            createdAt: result.createdAt,
            decidedAt: result.decidedAt,
            replacedSummary: replaced,
            replacedModel: result.replacedModel
        )
    }
}

enum TranscriptOverlaySaveError: Error, Equatable {
    case staleBase
    case invalid(TranscriptOverlayValidationError)
}

enum ReaderProgressSaveError: Error, Equatable {
    case invalidSeconds
}

struct AppSettings: Codable, Equatable {
    var libraryPath: String
    var playbackRate: Double
    var textSource: String
    var skipSeconds: Double
    var transcriptionLanguage: String
    var bookTranscriptionLanguages: [String: String]
    var readerLanguageLevel: String
    var targetLanguage: String
    var llmProvider: String
    var grokAuthentication: String
    var grokEndpoint: String
    var grokModel: String
    var grokEffort: String
    var qwenEndpoint: String
    var qwenModel: String
    var qwenThinking: Bool
    var qwenEffort: String
    var qwenEffortPolicyVersion: Int
    var openAIAuthentication: String
    var openAIEndpoint: String
    var openAIModel: String
    var openAIEffort: String
    var sentenceContextCount: Int
    var chapterTranslationBlockSize: Int
    var chatContextCount: Int
    var autoTranslate: Bool
    var playOnSelect: Bool
    var deepReadingMode: Bool
    var showStudyOverlay: Bool
    var vocabReviewPrompt: String
    var appearance: String
    var preferredDictionary: String
    var lookupPanelWidth: Double
    var readerFontScale: Double
    var readerFont: String
    var readerBold: Bool
    var readerLineSpacing: Double
    var readerWordSpacing: Double
    var readerMargin: Double

    static var `default`: AppSettings {
        AppSettings(
            libraryPath: defaultLibraryPath,
            playbackRate: 1.0,
            textSource: TextSource.spoken.rawValue,
            skipSeconds: 5,
            transcriptionLanguage: TranscriptionLanguage.englishUS.rawValue,
            bookTranscriptionLanguages: [:],
            readerLanguageLevel: ReaderLanguageLevel.intermediate.rawValue,
            targetLanguage: StudyLanguage.zhHans.rawValue,
            llmProvider: LLMProvider.grok.rawValue,
            grokAuthentication: GrokAuthentication.grokBuild.rawValue,
            grokEndpoint: LLMProvider.grok.defaultEndpoint,
            grokModel: "grok-4.6",
            grokEffort: GrokEffort.low.rawValue,
            qwenEndpoint: LLMProvider.qwenCloud.defaultEndpoint,
            qwenModel: "qwen3.7-flash",
            qwenThinking: true,
            qwenEffort: QwenEffort.none.rawValue,
            qwenEffortPolicyVersion: 1,
            openAIAuthentication: OpenAIAuthentication.chatGPT.rawValue,
            openAIEndpoint: LLMProvider.openAI.defaultEndpoint,
            openAIModel: OpenAIModel.gpt56Luna.rawValue,
            openAIEffort: OpenAIEffort.medium.rawValue,
            sentenceContextCount: 2,
            chapterTranslationBlockSize: 5,
            chatContextCount: 3,
            autoTranslate: false,
            playOnSelect: true,
            deepReadingMode: false,
            showStudyOverlay: false,
            vocabReviewPrompt: VocabReviewPrompt.recognition.rawValue,
            appearance: AppAppearance.system.rawValue,
            preferredDictionary: "牛津英汉汉英词典",
            lookupPanelWidth: 420,
            readerFontScale: 1.0,
            readerFont: ReaderFontChoice.newYork.rawValue,
            readerBold: false,
            readerLineSpacing: 1.0,
            readerWordSpacing: 2.0,
            readerMargin: 32
        )
    }

    private static var defaultLibraryPath: String {
        Persistence.defaultImportedBooksURL.path
    }

    init(
        libraryPath: String,
        playbackRate: Double,
        textSource: String,
        skipSeconds: Double,
        transcriptionLanguage: String,
        bookTranscriptionLanguages: [String: String],
        readerLanguageLevel: String,
        targetLanguage: String,
        llmProvider: String,
        grokAuthentication: String,
        grokEndpoint: String,
        grokModel: String,
        grokEffort: String,
        qwenEndpoint: String,
        qwenModel: String,
        qwenThinking: Bool,
        qwenEffort: String,
        qwenEffortPolicyVersion: Int,
        openAIAuthentication: String,
        openAIEndpoint: String,
        openAIModel: String,
        openAIEffort: String,
        sentenceContextCount: Int,
        chapterTranslationBlockSize: Int,
        chatContextCount: Int,
        autoTranslate: Bool,
        playOnSelect: Bool,
        deepReadingMode: Bool,
        showStudyOverlay: Bool,
        vocabReviewPrompt: String,
        appearance: String,
        preferredDictionary: String,
        lookupPanelWidth: Double,
        readerFontScale: Double,
        readerFont: String,
        readerBold: Bool,
        readerLineSpacing: Double,
        readerWordSpacing: Double,
        readerMargin: Double
    ) {
        self.libraryPath = libraryPath
        self.playbackRate = playbackRate
        self.textSource = textSource
        self.skipSeconds = skipSeconds
        self.transcriptionLanguage = transcriptionLanguage
        self.bookTranscriptionLanguages = bookTranscriptionLanguages
        self.readerLanguageLevel = readerLanguageLevel
        self.targetLanguage = targetLanguage
        self.llmProvider = llmProvider
        self.grokAuthentication = grokAuthentication
        self.grokEndpoint = grokEndpoint
        self.grokModel = grokModel
        self.grokEffort = grokEffort
        self.qwenEndpoint = qwenEndpoint
        self.qwenModel = qwenModel
        self.qwenThinking = qwenThinking
        self.qwenEffort = qwenEffort
        self.qwenEffortPolicyVersion = qwenEffortPolicyVersion
        self.openAIAuthentication = openAIAuthentication
        self.openAIEndpoint = openAIEndpoint
        self.openAIModel = openAIModel
        self.openAIEffort = openAIEffort
        self.sentenceContextCount = sentenceContextCount
        self.chapterTranslationBlockSize = chapterTranslationBlockSize
        self.chatContextCount = chatContextCount
        self.autoTranslate = autoTranslate
        self.playOnSelect = playOnSelect
        self.deepReadingMode = deepReadingMode
        self.showStudyOverlay = showStudyOverlay
        self.vocabReviewPrompt = vocabReviewPrompt
        self.appearance = appearance
        self.preferredDictionary = preferredDictionary
        self.lookupPanelWidth = lookupPanelWidth
        self.readerFontScale = readerFontScale
        self.readerFont = readerFont
        self.readerBold = readerBold
        self.readerLineSpacing = readerLineSpacing
        self.readerWordSpacing = readerWordSpacing
        self.readerMargin = readerMargin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        libraryPath = try c.decodeIfPresent(String.self, forKey: .libraryPath) ?? d.libraryPath
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? d.playbackRate
        textSource = try c.decodeIfPresent(String.self, forKey: .textSource) ?? d.textSource
        skipSeconds = try c.decodeIfPresent(Double.self, forKey: .skipSeconds) ?? d.skipSeconds
        transcriptionLanguage = try c.decodeIfPresent(String.self, forKey: .transcriptionLanguage) ?? d.transcriptionLanguage
        bookTranscriptionLanguages = try c.decodeIfPresent([String: String].self, forKey: .bookTranscriptionLanguages) ?? d.bookTranscriptionLanguages
        readerLanguageLevel = try c.decodeIfPresent(String.self, forKey: .readerLanguageLevel) ?? d.readerLanguageLevel
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? d.llmProvider
        grokAuthentication = try c.decodeIfPresent(String.self, forKey: .grokAuthentication) ?? d.grokAuthentication
        grokEndpoint = try c.decodeIfPresent(String.self, forKey: .grokEndpoint) ?? d.grokEndpoint
        grokModel = try c.decodeIfPresent(String.self, forKey: .grokModel) ?? d.grokModel
        grokEffort = try c.decodeIfPresent(String.self, forKey: .grokEffort) ?? d.grokEffort
        qwenEndpoint = try c.decodeIfPresent(String.self, forKey: .qwenEndpoint) ?? d.qwenEndpoint
        qwenModel = try c.decodeIfPresent(String.self, forKey: .qwenModel) ?? d.qwenModel
        qwenThinking = try c.decodeIfPresent(Bool.self, forKey: .qwenThinking) ?? d.qwenThinking
        let savedEffortPolicyVersion = try c.decodeIfPresent(Int.self, forKey: .qwenEffortPolicyVersion) ?? 0
        qwenEffort = savedEffortPolicyVersion >= 1
            ? (try c.decodeIfPresent(String.self, forKey: .qwenEffort) ?? d.qwenEffort)
            : QwenEffort.none.rawValue
        qwenEffortPolicyVersion = 1
        openAIAuthentication = try c.decodeIfPresent(String.self, forKey: .openAIAuthentication) ?? d.openAIAuthentication
        openAIEndpoint = try c.decodeIfPresent(String.self, forKey: .openAIEndpoint) ?? d.openAIEndpoint
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        openAIEffort = try c.decodeIfPresent(String.self, forKey: .openAIEffort) ?? d.openAIEffort
        sentenceContextCount = try c.decodeIfPresent(Int.self, forKey: .sentenceContextCount) ?? d.sentenceContextCount
        chapterTranslationBlockSize = try c.decodeIfPresent(Int.self, forKey: .chapterTranslationBlockSize) ?? d.chapterTranslationBlockSize
        chatContextCount = try c.decodeIfPresent(Int.self, forKey: .chatContextCount) ?? d.chatContextCount
        autoTranslate = try c.decodeIfPresent(Bool.self, forKey: .autoTranslate) ?? d.autoTranslate
        playOnSelect = try c.decodeIfPresent(Bool.self, forKey: .playOnSelect) ?? d.playOnSelect
        deepReadingMode = try c.decodeIfPresent(Bool.self, forKey: .deepReadingMode) ?? d.deepReadingMode
        showStudyOverlay = try c.decodeIfPresent(Bool.self, forKey: .showStudyOverlay) ?? d.showStudyOverlay
        vocabReviewPrompt = try c.decodeIfPresent(String.self, forKey: .vocabReviewPrompt) ?? d.vocabReviewPrompt
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        preferredDictionary = try c.decodeIfPresent(String.self, forKey: .preferredDictionary) ?? d.preferredDictionary
        lookupPanelWidth = try c.decodeIfPresent(Double.self, forKey: .lookupPanelWidth) ?? d.lookupPanelWidth
        readerFontScale = try c.decodeIfPresent(Double.self, forKey: .readerFontScale) ?? d.readerFontScale
        readerFont = try c.decodeIfPresent(String.self, forKey: .readerFont) ?? d.readerFont
        readerBold = try c.decodeIfPresent(Bool.self, forKey: .readerBold) ?? d.readerBold
        readerLineSpacing = try c.decodeIfPresent(Double.self, forKey: .readerLineSpacing) ?? d.readerLineSpacing
        readerWordSpacing = try c.decodeIfPresent(Double.self, forKey: .readerWordSpacing) ?? d.readerWordSpacing
        readerMargin = try c.decodeIfPresent(Double.self, forKey: .readerMargin) ?? d.readerMargin
    }

    func endpoint(for provider: LLMProvider) -> String {
        switch provider {
        case .managedQwen: ""
        case .grok: grokEndpoint
        case .qwenCloud: qwenEndpoint
        case .openAI: openAIEndpoint
        case .appleFoundation: ""
        }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension StoredSettings {
    init(_ settings: AppSettings) {
        self.init(
            libraryPath: settings.libraryPath,
            playbackRate: settings.playbackRate,
            textSource: settings.textSource,
            skipSeconds: settings.skipSeconds,
            transcriptionLanguage: settings.transcriptionLanguage,
            bookTranscriptionLanguages: settings.bookTranscriptionLanguages,
            readerLanguageLevel: settings.readerLanguageLevel,
            targetLanguage: settings.targetLanguage,
            llmProvider: settings.llmProvider,
            grokAuthentication: settings.grokAuthentication,
            grokEndpoint: settings.grokEndpoint,
            grokModel: settings.grokModel,
            grokEffort: settings.grokEffort,
            qwenEndpoint: settings.qwenEndpoint,
            qwenModel: settings.qwenModel,
            qwenThinking: settings.qwenThinking,
            qwenEffort: settings.qwenEffort,
            qwenEffortPolicyVersion: settings.qwenEffortPolicyVersion,
            openAIAuthentication: settings.openAIAuthentication,
            openAIEndpoint: settings.openAIEndpoint,
            openAIModel: settings.openAIModel,
            openAIEffort: settings.openAIEffort,
            sentenceContextCount: settings.sentenceContextCount,
            chapterTranslationBlockSize: settings.chapterTranslationBlockSize,
            chatContextCount: settings.chatContextCount,
            autoTranslate: settings.autoTranslate,
            playOnSelect: settings.playOnSelect,
            deepReadingMode: settings.deepReadingMode,
            showStudyOverlay: settings.showStudyOverlay,
            vocabReviewPrompt: settings.vocabReviewPrompt,
            appearance: settings.appearance,
            preferredDictionary: settings.preferredDictionary,
            lookupPanelWidth: settings.lookupPanelWidth,
            readerFontScale: settings.readerFontScale,
            readerFont: settings.readerFont,
            readerBold: settings.readerBold,
            readerLineSpacing: settings.readerLineSpacing,
            readerWordSpacing: settings.readerWordSpacing,
            readerMargin: settings.readerMargin
        )
    }
}

extension AppSettings {
    mutating func apply(_ stored: StoredSettings) {
        if !stored.libraryPath.isEmpty { libraryPath = stored.libraryPath }
        playbackRate = stored.playbackRate
        textSource = stored.textSource
        skipSeconds = stored.skipSeconds
        transcriptionLanguage = stored.transcriptionLanguage
        if let value = stored.bookTranscriptionLanguages { bookTranscriptionLanguages = value }
        readerLanguageLevel = stored.readerLanguageLevel
        targetLanguage = stored.targetLanguage
        if let value = stored.llmProvider { llmProvider = value }
        if let value = stored.grokAuthentication { grokAuthentication = value }
        if let value = stored.grokEndpoint { grokEndpoint = value }
        if let value = stored.grokModel { grokModel = value }
        if let value = stored.grokEffort { grokEffort = value }
        if let value = stored.qwenEndpoint { qwenEndpoint = value }
        if let value = stored.qwenModel { qwenModel = value }
        if let value = stored.qwenThinking { qwenThinking = value }
        if let value = stored.qwenEffort { qwenEffort = value }
        if let value = stored.qwenEffortPolicyVersion { qwenEffortPolicyVersion = value }
        if let value = stored.openAIAuthentication { openAIAuthentication = value }
        if let value = stored.openAIEndpoint { openAIEndpoint = value }
        if let value = stored.openAIModel { openAIModel = value }
        if let value = stored.openAIEffort { openAIEffort = value }
        sentenceContextCount = stored.sentenceContextCount
        chapterTranslationBlockSize = stored.chapterTranslationBlockSize
        chatContextCount = stored.chatContextCount
        autoTranslate = stored.autoTranslate
        playOnSelect = stored.playOnSelect
        deepReadingMode = stored.deepReadingMode
        showStudyOverlay = stored.showStudyOverlay
        vocabReviewPrompt = stored.vocabReviewPrompt
        appearance = stored.appearance
        preferredDictionary = stored.preferredDictionary
        lookupPanelWidth = stored.lookupPanelWidth
        readerFontScale = stored.readerFontScale
        readerFont = stored.readerFont
        readerBold = stored.readerBold
        readerLineSpacing = stored.readerLineSpacing
        readerWordSpacing = stored.readerWordSpacing
        readerMargin = stored.readerMargin
    }
}

extension StoredKnownLemma {
    init(_ record: KnownLemmaRecord) {
        self.init(language: record.language, form: record.form, updatedAt: record.updatedAt)
    }
}

extension KnownLemmaRecord {
    init(_ stored: StoredKnownLemma) {
        self.init(language: stored.language, form: stored.form, updatedAt: stored.updatedAt)
    }
}
