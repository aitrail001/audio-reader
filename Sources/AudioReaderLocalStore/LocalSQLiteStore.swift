import Foundation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

public final class LocalSQLiteStore: SyncOutboxRepository, SyncCursorStoring, SyncEntityVersionStoring, TranscriptOverlayRepository, ReaderProgressRepository, ReviewEventRepository, @unchecked Sendable {
    public let url: URL
    #if DEBUG
    var interruptAfterTable: String?
    #endif

    private let lock = NSRecursiveLock()
    private let connection: SQLiteConnection

    public init(fileURL: URL) {
        url = fileURL
        connection = SQLiteConnection(fileURL: fileURL)
        lock.lock()
        defer { lock.unlock() }
        try? applySchemaUnlocked()
    }

    public func migrateLegacyData(from sources: LegacyLocalDataSources) throws -> LocalMigrationReceipt {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        if let receipt = try loadReceiptUnlocked() {
            return receipt
        }
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            if let receipt = try loadReceiptUnlocked() {
                try connection.exec("COMMIT")
                return receipt
            }
            try clearMigratedDataUnlocked()
            let payload = try LegacyImportLoader.load(sources: sources, connection: connection, storeURL: url)
            try insertPayload(payload)
            let receipt = LocalMigrationReceipt(
                schemaVersion: LocalSchemaV2.version,
                completedAt: Date(),
                bookCount: payload.books.count,
                assetCount: payload.assets.count,
                chapterCount: payload.chapters.count,
                transcriptRevisionCount: payload.transcripts.count,
                vocabularyCount: payload.vocabulary.count,
                knownLemmaCount: payload.knownLemmas.count,
                reviewCardCount: payload.reviewCards.count,
                reviewEventCount: payload.reviewEvents.count,
                assistantResultCount: payload.assistantResults.count
            )
            try insertReceipt(receipt)
            try connection.exec("COMMIT")
            return try loadReceiptUnlocked() ?? receipt
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func loadReceipt() throws -> LocalMigrationReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return try loadReceiptUnlocked()
    }

    public func tableNames() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return try connection.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        ).compactMap { $0["name"] }
    }

    public func rowCount(_ table: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try SQLiteConnection.validateIdentifier(table)
        let rows = try connection.query("SELECT COUNT(*) AS c FROM \(table)")
        return rows.first?.int("c") ?? 0
    }

    public func currentSchemaVersion() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query("PRAGMA user_version").first?.int("user_version") ?? 0
    }

    public func enqueue(_ mutation: OutboxMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let existing = try connection.query(
            "SELECT id FROM sync_outbox WHERE id = ? LIMIT 1"
        ) { [connection] stmt in
            connection.bind(stmt, 1, mutation.id.rawValue)
        }
        if !existing.isEmpty { return }
        try connection.run(
            """
            INSERT INTO sync_outbox(
              id, entity_type, entity_id, operation, base_revision, occurred_at, payload, status
            ) VALUES (?,?,?,?,?,?,?,?)
            """
        ) { [connection] stmt in
            connection.bind(stmt, 1, mutation.id.rawValue)
            connection.bind(stmt, 2, mutation.entityType.rawValue)
            connection.bind(stmt, 3, mutation.entityID)
            connection.bind(stmt, 4, mutation.operation.rawValue)
            connection.bind(stmt, 5, Int(mutation.baseRevision.rawValue))
            connection.bindDate(stmt, 6, mutation.occurredAt)
            connection.bind(stmt, 7, mutation.payload)
            connection.bind(stmt, 8, OutboxMutationStatus.pending.rawValue)
        }
    }

    public func pendingMutations() throws -> [OutboxMutation] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let rows = try connection.query(
            "SELECT * FROM sync_outbox WHERE status = 'pending' ORDER BY occurred_at, id"
        )
        return try rows.map { row in
            OutboxMutation(
                id: MutationID(rawValue: try row.required("id")),
                entityType: OutboxEntityType(rawValue: try row.required("entity_type")) ?? .studyActivity,
                entityID: try row.required("entity_id"),
                operation: OutboxOperation(rawValue: try row.required("operation")) ?? .upsert,
                baseRevision: ServerVersion(Int64(row.int("base_revision"))),
                occurredAt: row.date("occurred_at"),
                payload: Data((row.string("payload") ?? "{}").utf8),
                status: .pending
            )
        }
    }

    public func markAcknowledged(id: MutationID) throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.run("UPDATE sync_outbox SET status = ? WHERE id = ?") { [connection] stmt in
            connection.bind(stmt, 1, OutboxMutationStatus.acknowledged.rawValue)
            connection.bind(stmt, 2, id.rawValue)
        }
    }

    public func updatePending(_ mutation: OutboxMutation) throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.run(
            """
            UPDATE sync_outbox
            SET entity_type = ?, entity_id = ?, operation = ?, base_revision = ?, occurred_at = ?, payload = ?
            WHERE id = ? AND status = ?
            """
        ) { [connection] stmt in
            connection.bind(stmt, 1, mutation.entityType.rawValue)
            connection.bind(stmt, 2, mutation.entityID)
            connection.bind(stmt, 3, mutation.operation.rawValue)
            connection.bind(stmt, 4, Int(mutation.baseRevision.rawValue))
            connection.bindDate(stmt, 5, mutation.occurredAt)
            connection.bind(stmt, 6, mutation.payload)
            connection.bind(stmt, 7, mutation.id.rawValue)
            connection.bind(stmt, 8, OutboxMutationStatus.pending.rawValue)
        }
    }

    public func loadVersion(entityType: String, entityID: String) throws -> SyncEntityVersion? {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let rows = try connection.query(
            """
            SELECT server_version, payload_json, last_mutation_id
            FROM entity_versions WHERE entity_type = ? AND entity_id = ? LIMIT 1
            """
        ) { [connection] stmt in
            connection.bind(stmt, 1, entityType)
            connection.bind(stmt, 2, entityID)
        }
        guard let row = rows.first else { return nil }
        return SyncEntityVersion(
            entityType: entityType,
            entityID: entityID,
            serverVersion: Int64(row.int("server_version")),
            payload: Data((row.string("payload_json") ?? "{}").utf8),
            lastMutationID: row.string("last_mutation_id")
        )
    }

    public func saveVersion(_ version: SyncEntityVersion) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let json = String(data: version.payload, encoding: .utf8) ?? "{}"
        try connection.run(
            """
            INSERT INTO entity_versions(
              entity_type, entity_id, server_version, updated_at, last_mutation_id, payload_json
            ) VALUES (?,?,?,?,?,?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
              server_version = excluded.server_version,
              updated_at = excluded.updated_at,
              last_mutation_id = excluded.last_mutation_id,
              payload_json = excluded.payload_json
            """
        ) { [connection] stmt in
            connection.bind(stmt, 1, version.entityType)
            connection.bind(stmt, 2, version.entityID)
            connection.bind(stmt, 3, Int(version.serverVersion))
            connection.bindDate(stmt, 4, Date())
            connection.bind(stmt, 5, version.lastMutationID)
            connection.bind(stmt, 6, json)
        }
    }

    public func loadCursor() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let rows = try connection.query("SELECT cursor FROM sync_state WHERE id = 'local' LIMIT 1")
        let cursor = rows.first?.string("cursor")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cursor.isEmpty ? "0" : cursor
    }

    public func saveCursor(_ cursor: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let existing = try connection.query("SELECT id FROM sync_state WHERE id = 'local' LIMIT 1")
        if existing.isEmpty {
            try connection.run(
                "INSERT INTO sync_state(id, cursor, last_pull_at, last_push_at, payload_json) VALUES ('local', ?, ?, ?, '{}')"
            ) { [connection] stmt in
                connection.bind(stmt, 1, cursor)
                connection.bindDate(stmt, 2, Date())
                connection.bindDate(stmt, 3, Date())
            }
            return
        }
        try connection.run(
            "UPDATE sync_state SET cursor = ?, last_pull_at = ? WHERE id = 'local'"
        ) { [connection] stmt in
            connection.bind(stmt, 1, cursor)
            connection.bindDate(stmt, 2, Date())
        }
    }

    public func loadBooks() throws -> [StoredBook] {
        lock.lock()
        defer { lock.unlock() }
        let bookRows = try connection.query("SELECT * FROM local_books ORDER BY title, id")
        let chapterRows = try connection.query("SELECT * FROM local_chapters ORDER BY book_id, position, id")
        let chaptersByBook = Dictionary(grouping: chapterRows) { $0["book_id"] ?? "" }
        return try bookRows.map { row in
            let id = try row.required("id")
            let chapters = try (chaptersByBook[id] ?? []).map { chapter in
                StoredChapter(
                    id: ChapterID(rawValue: try chapter.required("id")),
                    index: chapter.int("position"),
                    title: try chapter.required("title"),
                    duration: chapter.optionalDouble("duration"),
                    startTime: chapter.optionalDouble("start_time")
                )
            }
            return StoredBook(
                id: BookID(rawValue: id),
                title: try row.required("title"),
                author: row.string("author"),
                source: try row.required("source"),
                chapters: chapters
            )
        }
    }

    public func loadAssets() throws -> [StoredLocalAsset] {
        lock.lock()
        defer { lock.unlock() }
        return try connection.query("SELECT * FROM local_assets ORDER BY id").map { row in
            StoredLocalAsset(
                id: AssetID(rawValue: try row.required("id")),
                bookID: BookID(rawValue: try row.required("book_id")),
                kind: try row.required("kind"),
                localMediaKey: try row.required("local_media_key")
            )
        }
    }

    public func loadTranscripts() throws -> [StoredTranscript] {
        lock.lock()
        defer { lock.unlock() }
        return try connection.query(
            "SELECT * FROM local_transcript_revisions WHERE is_active = 1 ORDER BY chapter_id"
        ).map(Self.transcript(from:))
    }

    public func loadTranscriptOverlays(chapterID: ChapterID) throws -> [StoredTranscriptOverlay] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query(
            "SELECT * FROM local_transcript_overlays WHERE chapter_id = ? AND deleted_at IS NULL ORDER BY segment_id, id",
            bind: { [connection] stmt in connection.bind(stmt, 1, chapterID.rawValue) }
        ).map(Self.transcriptOverlay(from:))
    }

    public func loadAllTranscriptOverlays() throws -> [StoredTranscriptOverlay] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query(
            "SELECT * FROM local_transcript_overlays WHERE deleted_at IS NULL ORDER BY chapter_id, segment_id, id"
        ).map(Self.transcriptOverlay(from:))
    }

    public func loadTranscriptOverlayState(
        chapterID: ChapterID,
        segmentID: String
    ) throws -> StoredTranscriptOverlayState? {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try loadTranscriptOverlayStateUnlocked(chapterID: chapterID, segmentID: segmentID)
    }

    /// Upsert is keyed by stable chapter/segment identity. The previous value is
    /// replaced, while stale-base content remains present until explicit restore.
    public func saveTranscriptOverlay(_ overlay: StoredTranscriptOverlay) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        _ = try mergeTranscriptOverlayUnlocked(overlay, revision: 0)
    }

    @discardableResult
    public func mergeTranscriptOverlay(
        _ overlay: StoredTranscriptOverlay,
        revision: Int64
    ) throws -> TranscriptOverlayMergeOutcome {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try mergeTranscriptOverlayUnlocked(overlay, revision: revision)
    }

    /// Resolution promotes exactly one candidate and clears competing values;
    /// the immutable transcript and stale candidate payload are never rewritten.
    public func resolveTranscriptOverlay(
        chapterID: ChapterID,
        segmentID: String,
        choosing candidateID: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        guard let state = try loadTranscriptOverlayStateUnlocked(chapterID: chapterID, segmentID: segmentID) else {
            return
        }
        let choices = [state.current] + state.conflicts
        guard let chosen = choices.first(where: { $0.id == candidateID }) else { return }
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            try upsertCurrentTranscriptOverlay(chosen.overlay, revision: chosen.revision)
            try deleteTranscriptOverlayConflicts(chapterID: chapterID, segmentID: segmentID)
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    private func mergeTranscriptOverlayUnlocked(
        _ overlay: StoredTranscriptOverlay,
        revision: Int64
    ) throws -> TranscriptOverlayMergeOutcome {
        let candidate = StoredTranscriptOverlayCandidate(overlay: overlay, revision: revision)
        guard let state = try loadTranscriptOverlayStateUnlocked(
            chapterID: overlay.chapterID,
            segmentID: overlay.segmentID
        ) else {
            try upsertCurrentTranscriptOverlay(overlay, revision: revision)
            return .inserted
        }
        if state.current == candidate || state.conflicts.contains(candidate) {
            return .unchanged
        }
        if state.current.overlay == overlay {
            try upsertCurrentTranscriptOverlay(overlay, revision: max(revision, state.current.revision))
            return .replacedCurrent
        }
        if overlay.provenance.deviceID == state.current.overlay.provenance.deviceID,
           revision < state.current.revision {
            return .unchanged
        }
        if overlay.provenance.deviceID == state.current.overlay.provenance.deviceID
            || revision > state.current.revision {
            try connection.exec("BEGIN IMMEDIATE TRANSACTION")
            do {
                try upsertCurrentTranscriptOverlay(overlay, revision: revision)
                if revision > state.current.revision {
                    try deleteTranscriptOverlayConflicts(
                        chapterID: overlay.chapterID,
                        segmentID: overlay.segmentID
                    )
                }
                try connection.exec("COMMIT")
                return .replacedCurrent
            } catch {
                try? connection.exec("ROLLBACK")
                throw error
            }
        }
        try insertTranscriptOverlayConflict(candidate)
        return .conflictRetained
    }

    private func upsertCurrentTranscriptOverlay(
        _ overlay: StoredTranscriptOverlay,
        revision: Int64
    ) throws {
        try connection.run(
            """
            INSERT INTO local_transcript_overlays(
              id, chapter_id, segment_id, base_fingerprint, corrected_text,
              corrected_start, corrected_end, provenance_json, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(chapter_id, segment_id) DO UPDATE SET
              id = excluded.id,
              base_fingerprint = excluded.base_fingerprint,
              corrected_text = excluded.corrected_text,
              corrected_start = excluded.corrected_start,
              corrected_end = excluded.corrected_end,
              provenance_json = excluded.provenance_json,
              updated_at = excluded.updated_at,
              server_version = excluded.server_version,
              deleted_at = NULL
            """
        ) { [connection] stmt in
            connection.bind(stmt, 1, overlay.id)
            connection.bind(stmt, 2, overlay.chapterID.rawValue)
            connection.bind(stmt, 3, overlay.segmentID)
            connection.bind(stmt, 4, overlay.baseFingerprint)
            connection.bind(stmt, 5, overlay.correctedText)
            connection.bind(stmt, 6, overlay.correctedStart)
            connection.bind(stmt, 7, overlay.correctedEnd)
            connection.bind(stmt, 8, try LocalJSON.encode(overlay.provenance))
            connection.bindDate(stmt, 9, overlay.updatedAt)
            connection.bind(stmt, 10, Int(revision))
        }
    }

    public func deleteTranscriptOverlay(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let current = try connection.query(
            "SELECT chapter_id, segment_id FROM local_transcript_overlays WHERE id = ? LIMIT 1",
            bind: { [connection] stmt in connection.bind(stmt, 1, id) }
        ).first
        try connection.run("DELETE FROM local_transcript_overlays WHERE id = ?") { [connection] stmt in
            connection.bind(stmt, 1, id)
        }
        if let current,
           let chapterID = current["chapter_id"],
           let segmentID = current["segment_id"] {
            try deleteTranscriptOverlayConflicts(
                chapterID: ChapterID(rawValue: chapterID),
                segmentID: segmentID
            )
        }
    }

    public func loadReaderProgress(bookID: BookID) throws -> StoredReaderProgressState? {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try loadReaderProgressUnlocked(bookID: bookID)
    }

    /// Callers must hold `lock`; keeping reads on this path prevents progress
    /// merges from recursively acquiring the store lock.
    private func loadReaderProgressUnlocked(bookID: BookID) throws -> StoredReaderProgressState? {
        let values = try connection.query(
            "SELECT * FROM local_reader_progress WHERE book_id = ? ORDER BY is_current DESC, updated_at DESC, id",
            bind: { [connection] stmt in connection.bind(stmt, 1, bookID.rawValue) }
        ).map(Self.readerProgress(from:))
        guard let current = values.first(where: { $0.isCurrent }) else { return nil }
        return StoredReaderProgressState(
            current: current.value,
            conflicts: values.filter { !$0.isCurrent }.map(\.value)
        )
    }

    public func loadAllReaderProgress() throws -> [StoredReaderProgress] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query(
            "SELECT * FROM local_reader_progress WHERE is_current = 1 ORDER BY book_id, id"
        ).map(Self.readerProgress(from:)).map(\.value)
    }

    /// Same-revision updates from another device remain as explicit conflicts;
    /// a higher server revision supersedes resolved history deterministically.
    @discardableResult
    public func mergeReaderProgress(_ progress: StoredReaderProgress) throws -> ReaderProgressMergeOutcome {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let existing = try loadReaderProgressUnlocked(bookID: progress.bookID)
        guard let existing else {
            try insertReaderProgress(progress, isCurrent: true)
            return .inserted
        }
        if existing.current == progress || existing.conflicts.contains(progress) {
            return .unchanged
        }
        if existing.current.chapterID == progress.chapterID,
           abs(existing.current.relativeSeconds - progress.relativeSeconds) < 0.001,
           existing.current.revision == progress.revision {
            return .unchanged
        }
        if progress.deviceID == existing.current.deviceID || progress.revision > existing.current.revision {
            try connection.exec("BEGIN IMMEDIATE TRANSACTION")
            do {
                if progress.revision > existing.current.revision {
                    try connection.run("DELETE FROM local_reader_progress WHERE book_id = ?") { [connection] stmt in
                        connection.bind(stmt, 1, progress.bookID.rawValue)
                    }
                } else {
                    try connection.run("UPDATE local_reader_progress SET is_current = 0 WHERE book_id = ?") { [connection] stmt in
                        connection.bind(stmt, 1, progress.bookID.rawValue)
                    }
                }
                try insertReaderProgress(progress, isCurrent: true)
                try connection.exec("COMMIT")
                return .replacedCurrent
            } catch {
                try? connection.exec("ROLLBACK")
                throw error
            }
        }
        try insertReaderProgress(progress, isCurrent: false)
        return .conflictRetained
    }

    public func resolveReaderProgress(bookID: BookID, choosing candidateID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let chosen = try connection.query(
            "SELECT id FROM local_reader_progress WHERE book_id = ? AND id = ? LIMIT 1",
            bind: { [connection] stmt in
                connection.bind(stmt, 1, bookID.rawValue)
                connection.bind(stmt, 2, candidateID)
            }
        )
        guard !chosen.isEmpty else { return }
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            try connection.run("DELETE FROM local_reader_progress WHERE book_id = ? AND id != ?") { [connection] stmt in
                connection.bind(stmt, 1, bookID.rawValue)
                connection.bind(stmt, 2, candidateID)
            }
            try connection.run("UPDATE local_reader_progress SET is_current = 1 WHERE id = ?") { [connection] stmt in
                connection.bind(stmt, 1, candidateID)
            }
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func loadVocabulary() throws -> [StoredVocabularyOccurrence] {
        lock.lock()
        defer { lock.unlock() }
        return try connection.query(
            "SELECT * FROM local_vocabulary_occurrences ORDER BY added_at DESC, id"
        ).map(Self.vocabulary(from:))
    }

    /// Sync writes the vocabulary row and its lightweight relational parents in
    /// one transaction so dependent progress and review events can be retried safely.
    public func upsertVocabulary(_ vocabulary: StoredVocabularyOccurrence) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            try ensureLearningParents(for: vocabulary, at: vocabulary.addedAt)
            try insertVocabulary([vocabulary])
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func loadKnownLemmas() throws -> [StoredKnownLemma] {
        lock.lock()
        defer { lock.unlock() }
        return try connection.query(
            "SELECT * FROM local_known_lemmas ORDER BY language, form"
        ).map { row in
            StoredKnownLemma(
                language: try row.required("language"),
                form: try row.required("form"),
                updatedAt: row.date("updated_at")
            )
        }
    }

    public func loadReviewCards() throws -> [StoredLocalReviewCard] {
        lock.lock()
        defer { lock.unlock() }
        return try connection.query("SELECT * FROM local_review_cards ORDER BY id").map { row in
            StoredLocalReviewCard(
                id: try row.required("id"),
                vocabularyID: VocabularyOccurrenceID(rawValue: try row.required("vocabulary_id")),
                face: try row.required("face"),
                reviewCount: row.int("review_count"),
                nextReview: row.optionalDate("next_review"),
                lastReviewedAt: row.optionalDate("last_reviewed_at"),
                lastReviewQuality: row.string("last_review_quality"),
                reviewIntervalDays: row.double("review_interval_days"),
                reviewEaseFactor: row.double("review_ease_factor")
            )
        }
    }

    public func loadReviewEvents() throws -> [StoredReviewEvent] {
        lock.lock()
        defer { lock.unlock() }
        return try connection.query(
            "SELECT * FROM local_review_events ORDER BY reviewed_at, id"
        ).map { row in
            StoredReviewEvent(
                id: ReviewEventID(rawValue: try row.required("id")),
                vocabularyID: VocabularyOccurrenceID(rawValue: try row.required("vocabulary_id")),
                face: try row.required("face"),
                rating: try row.required("rating"),
                reviewedAt: row.date("reviewed_at")
            )
        }
    }

    public func containsReviewEvent(id: ReviewEventID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try reviewEventExistsUnlocked(id)
    }

    public func appendReviewEvent(_ event: StoredReviewEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try insertReviewEvents([event], includeCard: false)
    }

    /// A review is one local transaction: ensure its lightweight relational
    /// parents, update the shared card schedule, then append immutable history.
    public func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabulary: StoredVocabularyOccurrence
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            if try reviewEventExistsUnlocked(event.id) {
                try connection.exec("COMMIT")
                return
            }
            try ensureLearningParents(for: vocabulary, at: event.reviewedAt)
            try insertVocabulary([vocabulary])
            try insertReviewCards([
                StoredLocalReviewCard(
                    id: "card:\(vocabulary.id.rawValue):\(event.face)",
                    vocabularyID: vocabulary.id,
                    face: event.face,
                    reviewCount: vocabulary.reviewCount,
                    nextReview: vocabulary.nextReview,
                    lastReviewedAt: vocabulary.lastReviewedAt,
                    lastReviewQuality: vocabulary.lastReviewQuality,
                    reviewIntervalDays: vocabulary.reviewIntervalDays,
                    reviewEaseFactor: vocabulary.reviewEaseFactor
                )
            ])
            try insertReviewEvents([event], includeCard: true)
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func loadAssistantResults() throws -> [StoredAssistantResult] {
        lock.lock()
        defer { lock.unlock() }
        return try connection.query(
            "SELECT * FROM local_assistant_results ORDER BY created_at DESC, id"
        ).map(Self.assistantResult(from:))
    }

    public func loadStudyActivityDays() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rows = try connection.query(
            "SELECT payload_json FROM entity_versions WHERE entity_type = ? AND entity_id = ? LIMIT 1",
            bind: { stmt in
                self.connection.bind(stmt, 1, OutboxEntityType.studyActivity.rawValue)
                self.connection.bind(stmt, 2, "local")
            }
        )
        guard let json = rows.first?["payload_json"],
              let activity = try? LocalJSON.decode(LegacyActivityJSON.self, from: json)
        else { return [] }
        return activity.days
    }

    public func loadMigratedSettings() throws -> StoredSettings? {
        lock.lock()
        defer { lock.unlock() }
        let rows = try connection.query(
            "SELECT payload_json FROM entity_versions WHERE entity_type = ? AND entity_id = ? LIMIT 1",
            bind: { stmt in
                self.connection.bind(stmt, 1, OutboxEntityType.settings.rawValue)
                self.connection.bind(stmt, 2, "local")
            }
        )
        guard let json = rows.first?["payload_json"] else { return nil }
        return try LocalJSON.decode(StoredSettings.self, from: json)
    }

    private func applySchemaUnlocked() throws {
        for sql in LocalSchemaV3.createStatements {
            try connection.exec(sql)
        }
        try connection.exec("PRAGMA user_version = \(LocalSchemaV3.version)")
    }

    private func loadReceiptUnlocked() throws -> LocalMigrationReceipt? {
        let rows = try connection.query(
            "SELECT * FROM local_migration_receipts WHERE schema_version = ? LIMIT 1",
            bind: { stmt in self.connection.bind(stmt, 1, LocalSchemaV2.version) }
        )
        guard let row = rows.first else { return nil }
        return LocalMigrationReceipt(
            schemaVersion: row.int("schema_version"),
            completedAt: row.date("completed_at"),
            bookCount: row.int("book_count"),
            assetCount: row.int("asset_count"),
            chapterCount: row.int("chapter_count"),
            transcriptRevisionCount: row.int("transcript_revision_count"),
            vocabularyCount: row.int("vocabulary_count"),
            knownLemmaCount: row.int("known_lemma_count"),
            reviewCardCount: row.int("review_card_count"),
            reviewEventCount: row.int("review_event_count"),
            assistantResultCount: row.int("assistant_result_count")
        )
    }

    private func clearMigratedDataUnlocked() throws {
        for table in LocalSchemaV2.dataTablesInDeleteOrder {
            try SQLiteConnection.validateIdentifier(table)
            try connection.exec("DELETE FROM \(table)")
        }
    }

    private func insertPayload(_ payload: LegacyImportPayload) throws {
        try insertBooks(payload.books)
        try interruptIfNeeded("local_books")
        try insertAssets(payload.assets)
        try interruptIfNeeded("local_assets")
        try insertChapters(payload.chapters)
        try interruptIfNeeded("local_chapters")
        try insertTranscripts(payload.transcripts)
        try interruptIfNeeded("local_transcript_revisions")
        try insertVocabulary(payload.vocabulary)
        try interruptIfNeeded("local_vocabulary_occurrences")
        try insertKnownLemmas(payload.knownLemmas)
        try interruptIfNeeded("local_known_lemmas")
        try insertReviewCards(payload.reviewCards)
        try interruptIfNeeded("local_review_cards")
        try insertReviewEvents(payload.reviewEvents)
        try interruptIfNeeded("local_review_events")
        try insertAssistantResults(payload.assistantResults)
        try interruptIfNeeded("local_assistant_results")
        try insertSyncState(payload)
        try interruptIfNeeded("sync_state")
        try insertEntityVersions(payload)
        try interruptIfNeeded("entity_versions")
    }

    #if DEBUG
    private func interruptIfNeeded(_ table: String) throws {
        if interruptAfterTable == table {
            throw LocalMigrationError.interrupted(table: table)
        }
    }
    #else
    private func interruptIfNeeded(_: String) throws {}
    #endif

    private func insertBooks(_ books: [BookDraft]) throws {
        let sql = """
            INSERT INTO local_books(id, title, author, source, created_at, updated_at, server_version)
            VALUES (?,?,?,?,?,?,0)
            """
        for book in books {
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, book.id)
                connection.bind(stmt, 2, book.title)
                connection.bind(stmt, 3, book.author)
                connection.bind(stmt, 4, book.source)
                connection.bindDate(stmt, 5, book.createdAt)
                connection.bindDate(stmt, 6, book.createdAt)
            }
        }
    }

    private func insertAssets(_ assets: [AssetDraft]) throws {
        let sql = """
            INSERT INTO local_assets(id, book_id, kind, local_media_key, created_at, updated_at, server_version)
            VALUES (?,?,?,?,?,?,0)
            """
        for asset in assets {
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, asset.id)
                connection.bind(stmt, 2, asset.bookID)
                connection.bind(stmt, 3, asset.kind)
                connection.bind(stmt, 4, asset.localMediaKey)
                connection.bindDate(stmt, 5, asset.createdAt)
                connection.bindDate(stmt, 6, asset.createdAt)
            }
        }
    }

    private func insertChapters(_ chapters: [ChapterDraft]) throws {
        let sql = """
            INSERT INTO local_chapters(
              id, book_id, asset_id, position, title, duration, start_time,
              created_at, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,0)
            """
        for chapter in chapters {
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, chapter.id)
                connection.bind(stmt, 2, chapter.bookID)
                connection.bind(stmt, 3, chapter.assetID)
                connection.bind(stmt, 4, chapter.position)
                connection.bind(stmt, 5, chapter.title)
                connection.bind(stmt, 6, chapter.duration)
                connection.bind(stmt, 7, chapter.startTime)
                connection.bindDate(stmt, 8, chapter.createdAt)
                connection.bindDate(stmt, 9, chapter.createdAt)
            }
        }
    }

    private func insertTranscripts(_ transcripts: [StoredTranscript]) throws {
        let sql = """
            INSERT INTO local_transcript_revisions(
              id, chapter_id, local_media_key, chapter_start, created_at, locale, source,
              ebook_aligned, ebook_alignment_json, ebook_use_override, segments_json,
              is_active, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,1,0)
            """
        for transcript in transcripts {
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, "revision:\(transcript.chapterID.rawValue)")
                connection.bind(stmt, 2, transcript.chapterID.rawValue)
                connection.bind(stmt, 3, transcript.localMediaKey)
                connection.bind(stmt, 4, transcript.chapterStart)
                connection.bindDate(stmt, 5, transcript.createdAt)
                connection.bind(stmt, 6, transcript.locale)
                connection.bind(stmt, 7, transcript.source)
                connection.bind(stmt, 8, transcript.ebookAligned ? 1 : 0)
                connection.bind(stmt, 9, try transcript.ebookAlignment.map(LocalJSON.encode))
                connection.bind(stmt, 10, transcript.ebookUseOverride)
                connection.bind(stmt, 11, try LocalJSON.encode(transcript.segments))
            }
        }
    }

    private func insertVocabulary(_ entries: [StoredVocabularyOccurrence]) throws {
        let sql = """
            INSERT INTO local_vocabulary_occurrences(
              id, surface, category, definition, dictionary_name, dictionary_html,
              translation, translation_language, translation_model, source_language,
              context, spoken_text, ebook_text, book_id, book_title, chapter_id, chapter_title,
              segment_id, word_id, timestamp, added_at, review_count, next_review,
              last_reviewed_at, last_review_quality, review_interval_days, review_ease_factor,
              is_in_learn_list, created_at, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
            ON CONFLICT(id) DO UPDATE SET
              surface=excluded.surface,
              category=excluded.category,
              definition=excluded.definition,
              dictionary_name=excluded.dictionary_name,
              dictionary_html=excluded.dictionary_html,
              translation=excluded.translation,
              translation_language=excluded.translation_language,
              translation_model=excluded.translation_model,
              source_language=excluded.source_language,
              context=excluded.context,
              spoken_text=excluded.spoken_text,
              ebook_text=excluded.ebook_text,
              book_id=excluded.book_id,
              book_title=excluded.book_title,
              chapter_id=excluded.chapter_id,
              chapter_title=excluded.chapter_title,
              segment_id=excluded.segment_id,
              word_id=excluded.word_id,
              timestamp=excluded.timestamp,
              review_count=excluded.review_count,
              next_review=excluded.next_review,
              last_reviewed_at=excluded.last_reviewed_at,
              last_review_quality=excluded.last_review_quality,
              review_interval_days=excluded.review_interval_days,
              review_ease_factor=excluded.review_ease_factor,
              is_in_learn_list=excluded.is_in_learn_list,
              updated_at=excluded.updated_at
            """
        for entry in entries {
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, entry.id.rawValue)
                connection.bind(stmt, 2, entry.surface)
                connection.bind(stmt, 3, entry.category)
                connection.bind(stmt, 4, entry.definition)
                connection.bind(stmt, 5, entry.dictionaryName)
                connection.bind(stmt, 6, entry.dictionaryHTML)
                connection.bind(stmt, 7, entry.translation)
                connection.bind(stmt, 8, entry.translationLanguage)
                connection.bind(stmt, 9, entry.translationModel)
                connection.bind(stmt, 10, entry.sourceLanguage)
                connection.bind(stmt, 11, entry.context)
                connection.bind(stmt, 12, entry.spokenText)
                connection.bind(stmt, 13, entry.ebookText)
                connection.bind(stmt, 14, entry.bookID.rawValue)
                connection.bind(stmt, 15, entry.bookTitle)
                connection.bind(stmt, 16, entry.chapterID.rawValue)
                connection.bind(stmt, 17, entry.chapterTitle)
                connection.bind(stmt, 18, entry.segmentID)
                connection.bind(stmt, 19, entry.wordID)
                connection.bind(stmt, 20, entry.timestamp)
                connection.bindDate(stmt, 21, entry.addedAt)
                connection.bind(stmt, 22, entry.reviewCount)
                connection.bindDate(stmt, 23, entry.nextReview)
                connection.bindDate(stmt, 24, entry.lastReviewedAt)
                connection.bind(stmt, 25, entry.lastReviewQuality)
                connection.bind(stmt, 26, entry.reviewIntervalDays)
                connection.bind(stmt, 27, entry.reviewEaseFactor)
                connection.bind(stmt, 28, entry.isInLearnList ? 1 : 0)
                connection.bindDate(stmt, 29, entry.addedAt)
                connection.bindDate(stmt, 30, entry.addedAt)
            }
        }
    }

    private func insertKnownLemmas(_ lemmas: [StoredKnownLemma]) throws {
        let sql = """
            INSERT INTO local_known_lemmas(language, form, updated_at, created_at, server_version)
            VALUES (?,?,?,?,0)
            """
        for lemma in lemmas {
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, lemma.language)
                connection.bind(stmt, 2, lemma.form)
                connection.bindDate(stmt, 3, lemma.updatedAt)
                connection.bindDate(stmt, 4, lemma.updatedAt)
            }
        }
    }

    private func insertReviewCards(_ cards: [StoredLocalReviewCard]) throws {
        let sql = """
            INSERT INTO local_review_cards(
              id, vocabulary_id, face, review_count, next_review, last_reviewed_at,
              last_review_quality, review_interval_days, review_ease_factor,
              created_at, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,0)
            ON CONFLICT(id) DO UPDATE SET
              review_count=excluded.review_count,
              next_review=excluded.next_review,
              last_reviewed_at=excluded.last_reviewed_at,
              last_review_quality=excluded.last_review_quality,
              review_interval_days=excluded.review_interval_days,
              review_ease_factor=excluded.review_ease_factor,
              updated_at=excluded.updated_at
            """
        for card in cards {
            let timestamp = card.lastReviewedAt ?? card.nextReview ?? Date(timeIntervalSince1970: 0)
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, card.id)
                connection.bind(stmt, 2, card.vocabularyID.rawValue)
                connection.bind(stmt, 3, card.face)
                connection.bind(stmt, 4, card.reviewCount)
                connection.bindDate(stmt, 5, card.nextReview)
                connection.bindDate(stmt, 6, card.lastReviewedAt)
                connection.bind(stmt, 7, card.lastReviewQuality)
                connection.bind(stmt, 8, card.reviewIntervalDays)
                connection.bind(stmt, 9, card.reviewEaseFactor)
                connection.bindDate(stmt, 10, timestamp)
                connection.bindDate(stmt, 11, timestamp)
            }
        }
    }

    private func insertReviewEvents(
        _ events: [StoredReviewEvent],
        includeCard: Bool = true
    ) throws {
        let sql = """
            INSERT OR IGNORE INTO local_review_events(
              id, vocabulary_id, card_id, face, rating, reviewed_at, created_at, server_version
            ) VALUES (?,?,?,?,?,?,?,0)
            """
        for event in events {
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, event.id.rawValue)
                connection.bind(stmt, 2, event.vocabularyID.rawValue)
                connection.bind(stmt, 3, includeCard ? "card:\(event.vocabularyID.rawValue):\(event.face)" : nil)
                connection.bind(stmt, 4, event.face)
                connection.bind(stmt, 5, event.rating)
                connection.bindDate(stmt, 6, event.reviewedAt)
                connection.bindDate(stmt, 7, event.reviewedAt)
            }
        }
    }

    private func reviewEventExistsUnlocked(_ id: ReviewEventID) throws -> Bool {
        try !connection.query(
            "SELECT id FROM local_review_events WHERE id = ? LIMIT 1"
        ) { [connection] stmt in
            connection.bind(stmt, 1, id.rawValue)
        }.isEmpty
    }

    private func ensureLearningParents(
        for vocabulary: StoredVocabularyOccurrence,
        at date: Date
    ) throws {
        try connection.run(
            """
            INSERT INTO local_books(id, title, source, created_at, updated_at, server_version)
            VALUES (?,?,?,?,?,0)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, updated_at=excluded.updated_at
            """
        ) { stmt in
            connection.bind(stmt, 1, vocabulary.bookID.rawValue)
            connection.bind(stmt, 2, vocabulary.bookTitle)
            connection.bind(stmt, 3, "local_learning")
            connection.bindDate(stmt, 4, vocabulary.addedAt)
            connection.bindDate(stmt, 5, date)
        }
        try connection.run(
            """
            INSERT INTO local_chapters(
              id, book_id, position, title, created_at, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,0)
            ON CONFLICT(id) DO UPDATE SET
              book_id=excluded.book_id,
              title=excluded.title,
              updated_at=excluded.updated_at
            """
        ) { stmt in
            connection.bind(stmt, 1, vocabulary.chapterID.rawValue)
            connection.bind(stmt, 2, vocabulary.bookID.rawValue)
            connection.bind(stmt, 3, 0)
            connection.bind(stmt, 4, vocabulary.chapterTitle)
            connection.bindDate(stmt, 5, vocabulary.addedAt)
            connection.bindDate(stmt, 6, date)
        }
    }

    private func insertAssistantResults(_ results: [StoredAssistantResult]) throws {
        let sql = """
            INSERT INTO local_assistant_results(
              id, kind, status, language, model, book_id, book_title, chapter_id, chapter_title,
              source, text, context, timestamp, created_at, decided_at, replaced_text,
              replaced_model, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
            """
        for result in results {
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, result.id)
                connection.bind(stmt, 2, result.kind.rawValue)
                connection.bind(stmt, 3, result.status.rawValue)
                connection.bind(stmt, 4, result.language)
                connection.bind(stmt, 5, result.model)
                connection.bind(stmt, 6, result.bookID?.rawValue)
                connection.bind(stmt, 7, result.bookTitle)
                connection.bind(stmt, 8, result.chapterID?.rawValue)
                connection.bind(stmt, 9, result.chapterTitle)
                connection.bind(stmt, 10, result.source)
                connection.bind(stmt, 11, result.text)
                connection.bind(stmt, 12, result.context)
                connection.bind(stmt, 13, result.timestamp)
                connection.bindDate(stmt, 14, result.createdAt)
                connection.bindDate(stmt, 15, result.decidedAt)
                connection.bind(stmt, 16, result.replacedText)
                connection.bind(stmt, 17, result.replacedModel)
                connection.bindDate(stmt, 18, result.decidedAt ?? result.createdAt)
            }
        }
    }

    private func insertSyncState(_ payload: LegacyImportPayload) throws {
        let body: [String: [String]] = ["studyActivityDays": payload.studyActivityDays]
        try connection.run(
            "INSERT INTO sync_state(id, cursor, last_pull_at, last_push_at, payload_json) VALUES ('local', NULL, NULL, NULL, ?)"
        ) { stmt in
            connection.bind(stmt, 1, try LocalJSON.encode(body))
        }
    }

    private func insertEntityVersions(_ payload: LegacyImportPayload) throws {
        let now = Date()
        try upsertEntityVersion(
            OutboxEntityType.settings.rawValue,
            "local",
            at: now,
            json: try LocalJSON.encode(payload.settings ?? StoredSettings.default)
        )
        try upsertEntityVersion(
            OutboxEntityType.studyActivity.rawValue,
            "local",
            at: now,
            json: try LocalJSON.encode(LegacyActivityJSON(days: payload.studyActivityDays))
        )
        for book in payload.books {
            try upsertEntityVersion(OutboxEntityType.book.rawValue, book.id, at: book.createdAt, json: nil)
        }
        for chapter in payload.chapters {
            try upsertEntityVersion(OutboxEntityType.chapter.rawValue, chapter.id, at: chapter.createdAt, json: nil)
        }
        for transcript in payload.transcripts {
            try upsertEntityVersion(
                OutboxEntityType.transcript.rawValue,
                transcript.chapterID.rawValue,
                at: transcript.createdAt,
                json: nil
            )
        }
        for entry in payload.vocabulary {
            try upsertEntityVersion(
                OutboxEntityType.vocabulary.rawValue,
                entry.id.rawValue,
                at: entry.addedAt,
                json: nil
            )
        }
        for lemma in payload.knownLemmas {
            try upsertEntityVersion(
                OutboxEntityType.lexemeState.rawValue,
                "\(lemma.language):\(lemma.form)",
                at: lemma.updatedAt,
                json: nil
            )
        }
        for event in payload.reviewEvents {
            try upsertEntityVersion(
                OutboxEntityType.reviewEvent.rawValue,
                event.id.rawValue,
                at: event.reviewedAt,
                json: nil
            )
        }
        for result in payload.assistantResults {
            let type: OutboxEntityType
            switch result.kind {
            case .chapterSummary: type = .summaryDecision
            case .chapterTranslation: type = .translationDecision
            case .sentenceGloss, .wordGloss: type = .translationDecision
            }
            try upsertEntityVersion(type.rawValue, result.id, at: result.createdAt, json: nil)
        }
    }

    private func upsertEntityVersion(_ type: String, _ id: String, at date: Date, json: String?) throws {
        try connection.run(
            """
            INSERT INTO entity_versions(entity_type, entity_id, server_version, updated_at, last_mutation_id, payload_json)
            VALUES (?,?,0,?,NULL,?)
            """
        ) { stmt in
            connection.bind(stmt, 1, type)
            connection.bind(stmt, 2, id)
            connection.bindDate(stmt, 3, date)
            connection.bind(stmt, 4, json)
        }
    }

    private func insertReceipt(_ receipt: LocalMigrationReceipt) throws {
        try connection.run(
            """
            INSERT INTO local_migration_receipts(
              schema_version, completed_at, book_count, asset_count, chapter_count,
              transcript_revision_count, vocabulary_count, known_lemma_count,
              review_card_count, review_event_count, assistant_result_count
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """
        ) { stmt in
            connection.bind(stmt, 1, receipt.schemaVersion)
            connection.bindDate(stmt, 2, receipt.completedAt)
            connection.bind(stmt, 3, receipt.bookCount)
            connection.bind(stmt, 4, receipt.assetCount)
            connection.bind(stmt, 5, receipt.chapterCount)
            connection.bind(stmt, 6, receipt.transcriptRevisionCount)
            connection.bind(stmt, 7, receipt.vocabularyCount)
            connection.bind(stmt, 8, receipt.knownLemmaCount)
            connection.bind(stmt, 9, receipt.reviewCardCount)
            connection.bind(stmt, 10, receipt.reviewEventCount)
            connection.bind(stmt, 11, receipt.assistantResultCount)
        }
    }

    private static func transcript(from row: [String: String]) throws -> StoredTranscript {
        let segmentsJSON = try row.required("segments_json")
        let alignmentJSON = row.string("ebook_alignment_json")
        return StoredTranscript(
            chapterID: ChapterID(rawValue: try row.required("chapter_id")),
            localMediaKey: try row.required("local_media_key"),
            chapterStart: row.optionalDouble("chapter_start"),
            createdAt: row.date("created_at"),
            locale: try row.required("locale"),
            source: try row.required("source"),
            ebookAligned: row.bool("ebook_aligned"),
            ebookAlignment: try alignmentJSON.map { try LocalJSON.decode(StoredEPUBAlignment.self, from: $0) },
            ebookUseOverride: row.optionalBool("ebook_use_override"),
            segments: try LocalJSON.decode([StoredTranscriptSegment].self, from: segmentsJSON)
        )
    }

    private static func transcriptOverlay(from row: [String: String]) throws -> StoredTranscriptOverlay {
        StoredTranscriptOverlay(
            id: try row.required("id"),
            chapterID: ChapterID(rawValue: try row.required("chapter_id")),
            segmentID: try row.required("segment_id"),
            baseFingerprint: try row.required("base_fingerprint"),
            correctedText: try row.required("corrected_text"),
            correctedStart: row.double("corrected_start"),
            correctedEnd: row.double("corrected_end"),
            provenance: try LocalJSON.decode(
                TranscriptOverlayProvenance.self,
                from: try row.required("provenance_json")
            ),
            updatedAt: row.date("updated_at")
        )
    }

    /// Caller owns the store lock so merge/resolve can inspect and mutate one
    /// candidate set atomically without recursively entering public APIs.
    private func loadTranscriptOverlayStateUnlocked(
        chapterID: ChapterID,
        segmentID: String
    ) throws -> StoredTranscriptOverlayState? {
        let currentRows = try connection.query(
            "SELECT * FROM local_transcript_overlays WHERE chapter_id = ? AND segment_id = ? AND deleted_at IS NULL LIMIT 1"
        ) { [connection] stmt in
            connection.bind(stmt, 1, chapterID.rawValue)
            connection.bind(stmt, 2, segmentID)
        }
        guard let currentRow = currentRows.first else { return nil }
        let currentOverlay = try Self.transcriptOverlay(from: currentRow)
        let current = StoredTranscriptOverlayCandidate(
            overlay: currentOverlay,
            revision: Int64(currentRow.int("server_version"))
        )
        let conflicts = try connection.query(
            "SELECT * FROM local_transcript_overlay_conflicts WHERE chapter_id = ? AND segment_id = ? ORDER BY updated_at, candidate_id"
        ) { [connection] stmt in
            connection.bind(stmt, 1, chapterID.rawValue)
            connection.bind(stmt, 2, segmentID)
        }.map { row in
            StoredTranscriptOverlayCandidate(
                overlay: try LocalJSON.decode(
                    StoredTranscriptOverlay.self,
                    from: try row.required("overlay_json")
                ),
                revision: Int64(row.int("server_revision")),
                id: try row.required("candidate_id")
            )
        }
        return StoredTranscriptOverlayState(current: current, conflicts: conflicts)
    }

    private func insertTranscriptOverlayConflict(
        _ candidate: StoredTranscriptOverlayCandidate
    ) throws {
        try connection.run(
            """
            INSERT OR IGNORE INTO local_transcript_overlay_conflicts(
              candidate_id, chapter_id, segment_id, overlay_json, server_revision, updated_at
            ) VALUES (?,?,?,?,?,?)
            """
        ) { [connection] stmt in
            connection.bind(stmt, 1, candidate.id)
            connection.bind(stmt, 2, candidate.overlay.chapterID.rawValue)
            connection.bind(stmt, 3, candidate.overlay.segmentID)
            connection.bind(stmt, 4, try LocalJSON.encode(candidate.overlay))
            connection.bind(stmt, 5, Int(candidate.revision))
            connection.bindDate(stmt, 6, candidate.overlay.updatedAt)
        }
    }

    private func deleteTranscriptOverlayConflicts(
        chapterID: ChapterID,
        segmentID: String
    ) throws {
        try connection.run(
            "DELETE FROM local_transcript_overlay_conflicts WHERE chapter_id = ? AND segment_id = ?"
        ) { [connection] stmt in
            connection.bind(stmt, 1, chapterID.rawValue)
            connection.bind(stmt, 2, segmentID)
        }
    }

    private func insertReaderProgress(_ progress: StoredReaderProgress, isCurrent: Bool) throws {
        try connection.run(
            """
            INSERT INTO local_reader_progress(
              id, book_id, chapter_id, relative_seconds, updated_at, device_id, revision, is_current
            ) VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              book_id = excluded.book_id,
              chapter_id = excluded.chapter_id,
              relative_seconds = excluded.relative_seconds,
              updated_at = excluded.updated_at,
              device_id = excluded.device_id,
              revision = excluded.revision,
              is_current = excluded.is_current
            """
        ) { [connection] stmt in
            connection.bind(stmt, 1, progress.id)
            connection.bind(stmt, 2, progress.bookID.rawValue)
            connection.bind(stmt, 3, progress.chapterID.rawValue)
            connection.bind(stmt, 4, progress.relativeSeconds)
            connection.bindDate(stmt, 5, progress.updatedAt)
            connection.bind(stmt, 6, progress.deviceID)
            connection.bind(stmt, 7, Int(progress.revision))
            connection.bind(stmt, 8, isCurrent ? 1 : 0)
        }
    }

    private static func readerProgress(from row: [String: String]) throws -> (value: StoredReaderProgress, isCurrent: Bool) {
        (
            StoredReaderProgress(
                id: try row.required("id"),
                bookID: BookID(rawValue: try row.required("book_id")),
                chapterID: ChapterID(rawValue: try row.required("chapter_id")),
                relativeSeconds: row.double("relative_seconds"),
                updatedAt: row.date("updated_at"),
                deviceID: try row.required("device_id"),
                revision: Int64(row.int("revision"))
            ),
            row.bool("is_current")
        )
    }

    private static func vocabulary(from row: [String: String]) throws -> StoredVocabularyOccurrence {
        StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: try row.required("id")),
            surface: try row.required("surface"),
            category: try row.required("category"),
            definition: row.string("definition"),
            dictionaryName: row.string("dictionary_name"),
            dictionaryHTML: row.string("dictionary_html"),
            translation: row.string("translation"),
            translationLanguage: row.string("translation_language"),
            translationModel: row.string("translation_model"),
            sourceLanguage: row.string("source_language"),
            context: try row.required("context"),
            spokenText: row.string("spoken_text"),
            ebookText: row.string("ebook_text"),
            bookID: BookID(rawValue: try row.required("book_id")),
            bookTitle: try row.required("book_title"),
            chapterID: ChapterID(rawValue: try row.required("chapter_id")),
            chapterTitle: try row.required("chapter_title"),
            segmentID: row.string("segment_id"),
            wordID: row.string("word_id"),
            timestamp: row.double("timestamp"),
            addedAt: row.date("added_at"),
            reviewCount: row.int("review_count"),
            nextReview: row.optionalDate("next_review"),
            lastReviewedAt: row.optionalDate("last_reviewed_at"),
            lastReviewQuality: row.string("last_review_quality"),
            reviewIntervalDays: row.double("review_interval_days"),
            reviewEaseFactor: row.double("review_ease_factor"),
            isInLearnList: row.bool("is_in_learn_list")
        )
    }

    private static func assistantResult(from row: [String: String]) throws -> StoredAssistantResult {
        StoredAssistantResult(
            id: try row.required("id"),
            kind: AssistantResultKind(rawValue: try row.required("kind")) ?? .sentenceGloss,
            status: AssistantResultStatus(rawValue: try row.required("status")) ?? .pending,
            language: try row.required("language"),
            model: try row.required("model"),
            bookID: row.string("book_id").map(BookID.init(rawValue:)),
            bookTitle: row.string("book_title"),
            chapterID: row.string("chapter_id").map(ChapterID.init(rawValue:)),
            chapterTitle: row.string("chapter_title"),
            source: try row.required("source"),
            text: try row.required("text"),
            context: row.string("context"),
            timestamp: row.optionalDouble("timestamp"),
            createdAt: row.date("created_at"),
            decidedAt: row.optionalDate("decided_at"),
            replacedText: row.string("replaced_text"),
            replacedModel: row.string("replaced_model")
        )
    }

}

struct BookDraft {
    var id: String
    var title: String
    var author: String?
    var source: String
    var createdAt: Date
}

struct AssetDraft {
    var id: String
    var bookID: String
    var kind: String
    var localMediaKey: String
    var createdAt: Date
}

struct ChapterDraft {
    var id: String
    var bookID: String
    var title: String
    var duration: TimeInterval?
    var startTime: TimeInterval?
    var assetID: String?
    var position: Int
    var createdAt: Date
}

struct LegacyImportPayload {
    var books: [BookDraft] = []
    var assets: [AssetDraft] = []
    var chapters: [ChapterDraft] = []
    var transcripts: [StoredTranscript] = []
    var vocabulary: [StoredVocabularyOccurrence] = []
    var knownLemmas: [StoredKnownLemma] = []
    var reviewCards: [StoredLocalReviewCard] = []
    var reviewEvents: [StoredReviewEvent] = []
    var assistantResults: [StoredAssistantResult] = []
    var settings: StoredSettings?
    var studyActivityDays: [String] = []
}

enum LegacyImportLoader {
    static func load(
        sources: LegacyLocalDataSources,
        connection: SQLiteConnection,
        storeURL: URL
    ) throws -> LegacyImportPayload {
        let sqliteConnection: SQLiteConnection
        let closeExtra: Bool
        if sources.sqliteURL.standardizedFileURL.path == storeURL.standardizedFileURL.path {
            sqliteConnection = connection
            closeExtra = false
        } else {
            sqliteConnection = SQLiteConnection(fileURL: sources.sqliteURL)
            closeExtra = true
        }
        defer { _ = closeExtra }

        let sqliteTranscripts = try decodeList(
            LegacyTranscriptJSON.self,
            fromSQLite: sqliteConnection,
            table: "transcripts"
        ).map { $0.stored() }
        let sqliteVocab = try decodeList(
            LegacyVocabJSON.self,
            fromSQLite: sqliteConnection,
            table: "vocab"
        ).map { $0.stored() }
        let sqliteGlosses = try decodeList(
            LegacyGlossJSON.self,
            fromSQLite: sqliteConnection,
            table: "glosses"
        ).compactMap { $0.stored() }

        let jsonTranscripts = try loadTranscriptFiles(in: sources.transcriptsDirectory)
        let jsonVocab = (LocalJSON.decodeFile([LegacyVocabJSON].self, at: sources.vocabJSON) ?? []).map { $0.stored() }
        let jsonGlosses = (LocalJSON.decodeFile([LegacyGlossJSON].self, at: sources.glossesJSON) ?? []).compactMap { $0.stored() }
        let lemmas = (LocalJSON.decodeFile([LegacyLemmaJSON].self, at: sources.lexiconJSON) ?? []).map { $0.stored() }
        let activity = LocalJSON.decodeFile(LegacyActivityJSON.self, at: sources.studyActivityJSON)?.days ?? []
        let settings = decodeSettings(at: sources.settingsJSON)
        let summaries = try (LocalJSON.decodeFile([LegacySummaryJSON].self, at: sources.summariesJSON) ?? []).map { try $0.stored() }
        let checkpoints = try (LocalJSON.decodeFile([LegacyCheckpointJSON].self, at: sources.checkpointsJSON) ?? []).map { try $0.stored() }

        var transcriptsByChapter: [String: StoredTranscript] = [:]
        for transcript in sqliteTranscripts {
            transcriptsByChapter[transcript.chapterID.rawValue] = transcript
        }
        for transcript in jsonTranscripts where transcriptsByChapter[transcript.chapterID.rawValue] == nil {
            transcriptsByChapter[transcript.chapterID.rawValue] = transcript
        }

        let vocabulary = sqliteVocab.isEmpty ? jsonVocab : sqliteVocab
        let glosses = sqliteGlosses.isEmpty ? jsonGlosses : sqliteGlosses
        let assistantResults = glosses + summaries + checkpoints
        let face = settings?.vocabReviewPrompt ?? StoredSettings.default.vocabReviewPrompt

        var catalog = CatalogBuilder()
        for entry in vocabulary {
            catalog.ensureBook(id: entry.bookID.rawValue, title: entry.bookTitle, at: entry.addedAt)
            catalog.ensureChapter(
                id: entry.chapterID.rawValue,
                bookID: entry.bookID.rawValue,
                title: entry.chapterTitle,
                at: entry.addedAt
            )
        }
        for result in assistantResults {
            if let bookID = result.bookID {
                catalog.ensureBook(
                    id: bookID.rawValue,
                    title: result.bookTitle ?? "Untitled",
                    at: result.createdAt
                )
            }
            if let chapterID = result.chapterID {
                let bookID = result.bookID?.rawValue ?? catalog.inferredBookID(
                    mediaKey: nil,
                    chapterID: chapterID.rawValue,
                    at: result.createdAt
                )
                catalog.ensureChapter(
                    id: chapterID.rawValue,
                    bookID: bookID,
                    title: result.chapterTitle ?? chapterID.rawValue,
                    at: result.createdAt
                )
            }
        }
        for transcript in transcriptsByChapter.values {
            let bookID = catalog.inferredBookID(
                mediaKey: transcript.localMediaKey,
                chapterID: transcript.chapterID.rawValue,
                at: transcript.createdAt
            )
            catalog.ensureChapter(
                id: transcript.chapterID.rawValue,
                bookID: bookID,
                title: catalog.chapters[transcript.chapterID.rawValue]?.title ?? transcript.chapterID.rawValue,
                at: transcript.createdAt
            )
            let assetID = catalog.ensureAsset(
                bookID: bookID,
                mediaKey: transcript.localMediaKey,
                at: transcript.createdAt
            )
            catalog.chapters[transcript.chapterID.rawValue]?.assetID = assetID
            catalog.chapters[transcript.chapterID.rawValue]?.startTime = transcript.chapterStart
        }
        catalog.assignPositions()

        let cards: [StoredLocalReviewCard] = vocabulary.map { entry in
            StoredLocalReviewCard(
                id: "card:\(entry.id.rawValue):\(face)",
                vocabularyID: entry.id,
                face: face,
                reviewCount: entry.reviewCount,
                nextReview: entry.nextReview,
                lastReviewedAt: entry.lastReviewedAt,
                lastReviewQuality: entry.lastReviewQuality,
                reviewIntervalDays: entry.reviewIntervalDays,
                reviewEaseFactor: entry.reviewEaseFactor
            )
        }
        let events: [StoredReviewEvent] = vocabulary.compactMap { entry in
            guard let reviewedAt = entry.lastReviewedAt, let rating = entry.lastReviewQuality else {
                return nil
            }
            return StoredReviewEvent(
                id: ReviewEventID(rawValue: "event:\(entry.id.rawValue):last"),
                vocabularyID: entry.id,
                face: face,
                rating: rating,
                reviewedAt: reviewedAt
            )
        }

        return LegacyImportPayload(
            books: catalog.books.values.sorted { $0.id < $1.id },
            assets: catalog.assets.values.sorted { $0.id < $1.id },
            chapters: catalog.chapters.values.sorted { $0.id < $1.id },
            transcripts: transcriptsByChapter.values.sorted { $0.chapterID.rawValue < $1.chapterID.rawValue },
            vocabulary: vocabulary,
            knownLemmas: lemmas,
            reviewCards: cards,
            reviewEvents: events,
            assistantResults: assistantResults,
            settings: settings,
            studyActivityDays: activity
        )
    }

    private static func decodeList<Value: Decodable>(
        _ type: Value.Type,
        fromSQLite connection: SQLiteConnection,
        table: String
    ) throws -> [Value] {
        try SQLiteConnection.validateIdentifier(table)
        guard try tableExists(table, connection: connection) else { return [] }
        let rows = try connection.query("SELECT json FROM \(table)")
        return rows.compactMap { row in
            guard let json = row["json"] else { return nil }
            do {
                return try LocalJSON.decode(type, from: json)
            } catch {
                NSLog(
                    "AudioReader local schema v2: skipped undecodable %@ row: %@",
                    table,
                    String(describing: error)
                )
                return nil
            }
        }
    }

    private static func tableExists(_ name: String, connection: SQLiteConnection) throws -> Bool {
        let rows = try connection.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            bind: { stmt in connection.bind(stmt, 1, name) }
        )
        return !rows.isEmpty
    }

    private static func loadTranscriptFiles(in directory: URL) throws -> [StoredTranscript] {
        guard FileManager.default.fileExists(atPath: directory.path),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              )
        else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                do {
                    return try LocalJSON.decoder.decode(LegacyTranscriptJSON.self, from: data).stored()
                } catch {
                    NSLog(
                        "AudioReader local schema v2: skipped undecodable transcript %@: %@",
                        url.lastPathComponent,
                        String(describing: error)
                    )
                    return nil
                }
            }
    }

    private static func decodeSettings(at url: URL) -> StoredSettings? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(LegacySettingsJSON.self, from: data).stored()
    }
}

struct CatalogBuilder {
    var books: [String: BookDraft] = [:]
    var chapters: [String: ChapterDraft] = [:]
    var assets: [String: AssetDraft] = [:]

    mutating func ensureBook(id: String, title: String, at date: Date) {
        if var existing = books[id] {
            if existing.title == "Local media" || existing.title.isEmpty {
                existing.title = title
                books[id] = existing
            }
            return
        }
        books[id] = BookDraft(
            id: id,
            title: title.isEmpty ? "Untitled" : title,
            author: nil,
            source: "localFolder",
            createdAt: date
        )
    }

    mutating func ensureChapter(id: String, bookID: String, title: String, at date: Date) {
        ensureBook(id: bookID, title: "Local media", at: date)
        if var existing = chapters[id] {
            if existing.title == existing.id, title != existing.id {
                existing.title = title
            }
            chapters[id] = existing
            return
        }
        chapters[id] = ChapterDraft(
            id: id,
            bookID: bookID,
            title: title,
            duration: nil,
            startTime: nil,
            assetID: nil,
            position: 0,
            createdAt: date
        )
    }

    mutating func inferredBookID(mediaKey: String?, chapterID: String, at date: Date) -> String {
        if let chapter = chapters[chapterID] {
            return chapter.bookID
        }
        if let mediaKey {
            let folder = URL(fileURLWithPath: mediaKey).deletingLastPathComponent().lastPathComponent
            if let match = books.values.first(where: { $0.title == folder }) {
                return match.id
            }
            let inferred = folder.isEmpty ? "legacy-unassigned" : "legacy-folder:\(folder)"
            ensureBook(id: inferred, title: folder.isEmpty ? "Local media" : folder, at: date)
            return inferred
        }
        ensureBook(id: "legacy-unassigned", title: "Local media", at: date)
        return "legacy-unassigned"
    }

    mutating func ensureAsset(bookID: String, mediaKey: String, at date: Date) -> String {
        let id = "\(bookID)|audio|\(mediaKey)"
        assets[id] = AssetDraft(
            id: id,
            bookID: bookID,
            kind: "audio",
            localMediaKey: mediaKey,
            createdAt: date
        )
        return id
    }

    mutating func assignPositions() {
        let grouped = Dictionary(grouping: chapters.values) { $0.bookID }
        for (bookID, group) in grouped {
            let ordered = group.sorted {
                if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return $0.id < $1.id
            }
            for (index, chapter) in ordered.enumerated() {
                chapters[chapter.id]?.position = index
                chapters[chapter.id]?.bookID = bookID
            }
        }
    }
}
