import Foundation
import OSLog
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

private enum LocalSQLiteStoreError: Error {
    case missingReviewVocabulary
    case invalidAssistantDecisionMutation
    case invalidBookMutation
    case invalidTranscriptOverlayMutation
    case missingTranscriptCatalogParent
}

public final class LocalSQLiteStore: SettingsRepository, BookRepository, TranscriptRepository, VocabularyRepository, KnownLemmaRepository, AssistantResultRepository, TranslationCheckpointRepository, StudyActivityRepository, SyncOutboxRepository, SyncCursorStoring, SyncEntityVersionStoring, TranscriptOverlayRepository, ReaderProgressRepository, ReviewEventRepository, @unchecked Sendable {
    /// An uploadable transcript paired with the active catalog owner observed in the same snapshot.
    public struct ActiveSyncTranscriptCandidate: Equatable, Sendable {
        public let bookID: BookID
        public let transcript: StoredTranscript

        init(bookID: BookID, transcript: StoredTranscript) {
            self.bookID = bookID
            self.transcript = transcript
        }
    }

    private static let schemaLog = Logger(
        subsystem: "com.johnsonzhang.AudioReader",
        category: "local-schema"
    )

    private struct VocabularyRepairCandidate {
        var occurrence: StoredVocabularyOccurrence
        var updatedAt: Date
    }

    private struct ReviewCardRepairCandidate {
        var card: StoredLocalReviewCard
        var updatedAt: Date
    }

    private struct VocabularyReviewState {
        var schedule: StoredVocabularyReviewSchedule
        var updatedAt: Date
        var stableID: String
    }

    public let url: URL

    private let lock = NSRecursiveLock()
    private let connection: SQLiteConnection
    private var schemaIsReady = false
    private var syncPageTransactionDepth = 0
    private(set) var schemaApplicationCount = 0
    public private(set) var lastTranscriptSegmentQueryCount = 0
    public private(set) var maximumTranscriptSegmentQueryCount = 0

    public init(fileURL: URL) {
        url = fileURL
        connection = SQLiteConnection(fileURL: fileURL)
        lock.lock()
        defer { lock.unlock() }
        do {
            try applySchemaUnlocked()
        } catch {
            connection.failClosed(with: error)
        }
    }

    /// Canonical sync rows, entity versions, and the acknowledgement cursor commit together.
    /// Recursive repository calls share this transaction rather than starting autocommits.
    public func performSyncPageTransaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        if syncPageTransactionDepth > 0 {
            try body()
            return
        }
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        syncPageTransactionDepth += 1
        do {
            try body()
            try connection.exec("COMMIT")
            syncPageTransactionDepth -= 1
        } catch {
            syncPageTransactionDepth -= 1
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func tableNames() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rows = try connection.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        ).compactMap { $0["name"] }
        return rows
    }

    /// Exposes SQLite durability mode without opening a second connection that
    /// could perturb the WAL under acceptance test.
    public func journalMode() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query("PRAGMA journal_mode").first?.required("journal_mode") ?? ""
    }

    /// Counts rows changed by this connection so segment-edit tests can prove
    /// an isolated update does not rewrite the surrounding transcript.
    public var totalChangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connection.totalChangeCount
    }

    public func columnNames(in table: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        try SQLiteConnection.validateIdentifier(table)
        return try connection.query("PRAGMA table_info(\(table))").compactMap { $0["name"] }
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

    /// Marks duplicate snapshot rows in bounded SQL chunks so a large legacy backlog is
    /// compacted in one transaction instead of issuing tens of thousands of autocommits.
    public func markAcknowledged(ids: [MutationID]) throws {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try connection.run(
                    "UPDATE sync_outbox SET status = ? WHERE status = ? AND id IN (\(placeholders))"
                ) { [connection] stmt in
                    connection.bind(stmt, 1, OutboxMutationStatus.acknowledged.rawValue)
                    connection.bind(stmt, 2, OutboxMutationStatus.pending.rawValue)
                    for (offset, id) in chunk.enumerated() {
                        connection.bind(stmt, Int32(offset + 3), id.rawValue)
                    }
                }
            }
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
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

    public func loadSettings() throws -> StoredSettings {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        guard let json = try connection.query(
            "SELECT payload_json FROM local_settings WHERE id = 'local' LIMIT 1"
        ).first?["payload_json"] else { return .default }
        return try LocalJSON.decode(StoredSettings.self, from: json)
    }

    public func saveSettings(_ settings: StoredSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.run(
            """
            INSERT INTO local_settings(id, payload_json, updated_at) VALUES ('local', ?, ?)
            ON CONFLICT(id) DO UPDATE SET payload_json=excluded.payload_json, updated_at=excluded.updated_at
            """
        ) { [connection] statement in
            connection.bind(statement, 1, try LocalJSON.encode(settings))
            connection.bindDate(statement, 2, Date())
        }
    }

    public func loadBooks() throws -> [StoredBook] {
        lock.lock()
        defer { lock.unlock() }
        let bookRows = try connection.query("SELECT * FROM local_books WHERE deleted_at IS NULL ORDER BY title, id")
        let chapterRows = try connection.query("SELECT * FROM local_chapters WHERE deleted_at IS NULL ORDER BY book_id, position, id")
        let chaptersByBook = Dictionary(grouping: chapterRows) { $0["book_id"] ?? "" }
        return try bookRows.map { row in
            let id = try row.required("id")
            let chapters = try (chaptersByBook[id] ?? []).map { chapter in
                StoredChapter(
                    id: ChapterID(rawValue: try chapter.required("id")),
                    index: chapter.int("position"),
                    title: try chapter.required("title"),
                    duration: chapter.optionalDouble("duration"),
                    startTime: chapter.optionalDouble("start_time"),
                    ebookSectionIndex: chapter["ebook_section_index"].flatMap(Int.init)
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

    /// Soft-deleted catalog IDs suppress scan resurrection without touching
    /// unmanaged media that may still exist outside AudioReader's managed root.
    public func loadDeletedBookIDs() throws -> [BookID] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query(
            """
            SELECT book_id AS id FROM local_book_tombstones
            UNION SELECT id FROM local_books WHERE deleted_at IS NOT NULL
            ORDER BY id
            """
        ).compactMap { $0["id"] }
            .map(BookID.init(rawValue:))
    }

    public func saveBook(_ book: StoredBook) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let now = Date()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            try connection.run(
                """
                INSERT INTO local_books(id, title, author, source, created_at, updated_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, author=excluded.author,
                  source=excluded.source, updated_at=excluded.updated_at, deleted_at=NULL
                """
            ) { [connection] statement in
                connection.bind(statement, 1, book.id.rawValue)
                connection.bind(statement, 2, book.title)
                connection.bind(statement, 3, book.author)
                connection.bind(statement, 4, book.source)
                connection.bindDate(statement, 5, now)
                connection.bindDate(statement, 6, now)
            }
            try connection.run("DELETE FROM local_book_tombstones WHERE book_id = ?") { [connection] statement in
                connection.bind(statement, 1, book.id.rawValue)
            }
            for chapter in book.chapters {
                try connection.run(
                    """
                    INSERT INTO local_chapters(
                      id, book_id, position, title, duration, start_time, ebook_section_index,
                      created_at, updated_at
                    ) VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET book_id=excluded.book_id, position=excluded.position,
                      title=excluded.title, duration=excluded.duration, start_time=excluded.start_time,
                      ebook_section_index=excluded.ebook_section_index,
                      updated_at=excluded.updated_at, deleted_at=NULL
                    """
                ) { [connection] statement in
                    connection.bind(statement, 1, chapter.id.rawValue)
                    connection.bind(statement, 2, book.id.rawValue)
                    connection.bind(statement, 3, chapter.index)
                    connection.bind(statement, 4, chapter.title)
                    connection.bind(statement, 5, chapter.duration)
                    connection.bind(statement, 6, chapter.startTime)
                    connection.bind(statement, 7, chapter.ebookSectionIndex)
                    connection.bindDate(statement, 8, now)
                    connection.bindDate(statement, 9, now)
                }
            }
            let retainedChapterIDs = Set(book.chapters.map(\.id.rawValue))
            let staleChapterIDs = try connection.query(
                "SELECT id FROM local_chapters WHERE book_id = ? AND deleted_at IS NULL",
                bind: { [connection] statement in connection.bind(statement, 1, book.id.rawValue) }
            ).compactMap { $0["id"] }.filter { !retainedChapterIDs.contains($0) }
            for chapterID in staleChapterIDs {
                try connection.run(
                    "UPDATE local_chapters SET deleted_at = ?, updated_at = ? WHERE id = ?"
                ) { [connection] statement in
                    connection.bindDate(statement, 1, now)
                    connection.bindDate(statement, 2, now)
                    connection.bind(statement, 3, chapterID)
                }
            }
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    /// Catalog metadata and its upload intent are a single local-import commit.
    public func saveBook(_ book: StoredBook, mutation: OutboxMutation) throws {
        try saveBook(book, assets: nil, mutation: mutation)
    }

    public func saveBook(
        _ book: StoredBook,
        assets: [StoredLocalAsset]?,
        mutation: OutboxMutation
    ) throws {
        try performSyncPageTransaction {
            try saveBook(book)
            if let assets { try saveAssets(assets, bookID: book.id) }
            guard mutation.entityType == .book else { throw LocalSQLiteStoreError.invalidBookMutation }
            try enqueue(mutation)
        }
    }

    public func deleteBook(id: BookID) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            let deletedAt = Date()
            try connection.run(
                """
                INSERT INTO local_book_tombstones(book_id, deleted_at) VALUES (?,?)
                ON CONFLICT(book_id) DO UPDATE SET deleted_at=excluded.deleted_at
                """
            ) { [connection] statement in
                connection.bind(statement, 1, id.rawValue)
                connection.bindDate(statement, 2, deletedAt)
            }
            try deleteAssets(bookID: id)
            try connection.run("UPDATE local_chapters SET deleted_at = ?, updated_at = ? WHERE book_id = ?") { [connection] statement in
                connection.bindDate(statement, 1, deletedAt)
                connection.bindDate(statement, 2, deletedAt)
                connection.bind(statement, 3, id.rawValue)
            }
            try connection.run("UPDATE local_books SET deleted_at = ?, updated_at = ? WHERE id = ?") { [connection] statement in
                connection.bindDate(statement, 1, deletedAt)
                connection.bindDate(statement, 2, deletedAt)
                connection.bind(statement, 3, id.rawValue)
            }
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    /// Catalog disappearance, local asset removal, and the cloud tombstone are
    /// committed together; filesystem cleanup is performed by the app bridge.
    @discardableResult
    public func deleteBook(id: BookID, mutation: OutboxMutation) throws -> [StoredLocalAsset] {
        var removedAssets: [StoredLocalAsset] = []
        try performSyncPageTransaction {
            guard mutation.entityType == .book, mutation.operation == .delete else {
                throw LocalSQLiteStoreError.invalidBookMutation
            }
            removedAssets = try loadAssets(bookID: id)
            try connection.run(
                "UPDATE sync_outbox SET status = ? WHERE status = ? AND entity_type = ? AND entity_id = ?"
            ) { [connection] statement in
                connection.bind(statement, 1, OutboxMutationStatus.acknowledged.rawValue)
                connection.bind(statement, 2, OutboxMutationStatus.pending.rawValue)
                connection.bind(statement, 3, OutboxEntityType.book.rawValue)
                connection.bind(statement, 4, mutation.entityID)
            }
            try deleteBook(id: id)
            try enqueue(mutation)
        }
        return removedAssets
    }

    public func loadAssets() throws -> [StoredLocalAsset] {
        lock.lock()
        defer { lock.unlock() }
        return try loadAssetsUnlocked(bookID: nil)
    }

    public func loadSyncAssetManifests() throws -> [StoredSyncAssetManifest] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query("SELECT * FROM local_sync_asset_manifests ORDER BY kind, id").map { row in
            StoredSyncAssetManifest(
                id: try row.required("id"), kind: try row.required("kind"),
                revisionID: row.string("revision_id"), bookID: row.string("book_id"),
                chapterID: row.string("chapter_id"), contentType: try row.required("content_type"),
                encoding: try row.required("encoding"), sha256: try row.required("sha256"),
                compressedBytes: Int64(try row.required("compressed_bytes")) ?? 0,
                originalBytes: Int64(try row.required("original_bytes")) ?? 0,
                segmentCount: row.string("segment_count").flatMap(Int.init),
                localObjectPath: try row.required("local_object_path")
            )
        }
    }

    /// Persists only the verified manifest/path; immutable bytes remain in the filesystem.
    public func saveSyncAssetManifest(_ asset: StoredSyncAssetManifest) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.run(
            """
            INSERT INTO local_sync_asset_manifests(
              id, kind, revision_id, book_id, chapter_id, content_type, encoding, sha256,
              compressed_bytes, original_bytes, segment_count, local_object_path, created_at, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              kind=excluded.kind, revision_id=excluded.revision_id, book_id=excluded.book_id,
              chapter_id=excluded.chapter_id, content_type=excluded.content_type,
              encoding=excluded.encoding, sha256=excluded.sha256,
              compressed_bytes=excluded.compressed_bytes, original_bytes=excluded.original_bytes,
              segment_count=excluded.segment_count, local_object_path=excluded.local_object_path,
              updated_at=excluded.updated_at
            """
        ) { [connection] statement in
            connection.bind(statement, 1, asset.id); connection.bind(statement, 2, asset.kind)
            connection.bind(statement, 3, asset.revisionID); connection.bind(statement, 4, asset.bookID)
            connection.bind(statement, 5, asset.chapterID); connection.bind(statement, 6, asset.contentType)
            connection.bind(statement, 7, asset.encoding); connection.bind(statement, 8, asset.sha256)
            connection.bind(statement, 9, Int(clamping: asset.compressedBytes))
            connection.bind(statement, 10, Int(clamping: asset.originalBytes))
            connection.bind(statement, 11, asset.segmentCount); connection.bind(statement, 12, asset.localObjectPath)
            connection.bindDate(statement, 13, Date()); connection.bindDate(statement, 14, Date())
        }
    }

    public func loadAssets(bookID: BookID) throws -> [StoredLocalAsset] {
        lock.lock()
        defer { lock.unlock() }
        return try loadAssetsUnlocked(bookID: bookID)
    }

    public func saveAssets(_ assets: [StoredLocalAsset], bookID: BookID) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            let now = Date()
            for asset in assets {
                guard asset.bookID == bookID else { throw LocalSQLiteStoreError.invalidBookMutation }
                try connection.run(
                    """
                    INSERT INTO local_assets(
                      id, book_id, kind, local_media_key, content_hash, byte_count,
                      metadata_json, created_at, updated_at
                    ) VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      book_id=excluded.book_id, kind=excluded.kind,
                      local_media_key=excluded.local_media_key,
                      content_hash=excluded.content_hash, byte_count=excluded.byte_count,
                      metadata_json=excluded.metadata_json, updated_at=excluded.updated_at,
                      deleted_at=NULL
                    """
                ) { [connection] statement in
                    connection.bind(statement, 1, asset.id.rawValue)
                    connection.bind(statement, 2, asset.bookID.rawValue)
                    connection.bind(statement, 3, asset.kind)
                    connection.bind(statement, 4, asset.localMediaKey)
                    connection.bind(statement, 5, asset.contentHash)
                    connection.bind(statement, 6, asset.byteCount.map { Int(clamping: $0) })
                    connection.bind(statement, 7, try LocalJSON.encode(asset.metadata))
                    connection.bindDate(statement, 8, now)
                    connection.bindDate(statement, 9, now)
                }
            }
            let retained = Set(assets.map(\.id.rawValue))
            let stale = try connection.query(
                "SELECT id FROM local_assets WHERE book_id = ? AND deleted_at IS NULL",
                bind: { [connection] statement in connection.bind(statement, 1, bookID.rawValue) }
            ).compactMap { $0["id"] }.filter { !retained.contains($0) }
            try connection.run("UPDATE local_chapters SET asset_id = NULL WHERE book_id = ?") { [connection] statement in
                connection.bind(statement, 1, bookID.rawValue)
            }
            for asset in assets where asset.kind == "audio" {
                guard let chapterID = asset.metadata["chapterID"] else { continue }
                try connection.run(
                    "UPDATE local_chapters SET asset_id = ? WHERE id = ? AND book_id = ?"
                ) { [connection] statement in
                    connection.bind(statement, 1, asset.id.rawValue)
                    connection.bind(statement, 2, chapterID)
                    connection.bind(statement, 3, bookID.rawValue)
                }
            }
            for id in stale {
                try connection.run("DELETE FROM local_assets WHERE id = ?") { [connection] statement in
                    connection.bind(statement, 1, id)
                }
            }
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    public func deleteAssets(bookID: BookID) throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.run("UPDATE local_chapters SET asset_id = NULL WHERE book_id = ?") { [connection] statement in
            connection.bind(statement, 1, bookID.rawValue)
        }
        try connection.run("DELETE FROM local_assets WHERE book_id = ?") { [connection] statement in
            connection.bind(statement, 1, bookID.rawValue)
        }
    }

    private func loadAssetsUnlocked(bookID: BookID?) throws -> [StoredLocalAsset] {
        let rows: [[String: String]]
        if let bookID {
            rows = try connection.query(
                "SELECT * FROM local_assets WHERE book_id = ? AND deleted_at IS NULL ORDER BY id",
                bind: { [connection] statement in connection.bind(statement, 1, bookID.rawValue) }
            )
        } else {
            rows = try connection.query("SELECT * FROM local_assets WHERE deleted_at IS NULL ORDER BY id")
        }
        return try rows.map { row in
            StoredLocalAsset(
                id: AssetID(rawValue: try row.required("id")),
                bookID: BookID(rawValue: try row.required("book_id")),
                kind: try row.required("kind"),
                localMediaKey: try row.required("local_media_key"),
                contentHash: row.string("content_hash"),
                byteCount: row.string("byte_count").flatMap(Int64.init),
                metadata: try LocalJSON.decode([String: String].self, from: row.string("metadata_json") ?? "{}")
            )
        }
    }

    public func loadTranscripts() throws -> [StoredTranscript] {
        lock.lock()
        defer { lock.unlock() }
        let rows = try connection.query(
            "SELECT * FROM local_transcript_revisions WHERE is_active = 1 ORDER BY chapter_id"
        ).map { try loadTranscriptUnlocked(from: $0) }
        return rows
    }

    /// Fails closed unless the book, chapter, and active transcript all coexist in one SQLite snapshot.
    public func loadActiveSyncTranscriptCandidates() throws -> [ActiveSyncTranscriptCandidate] {
        try loadActiveSyncTranscriptCandidates(interleavingAfterCandidateQuery: nil)
    }

    /// The internal interleave seam lets tests commit a WAL writer after this read snapshot is established.
    func loadActiveSyncTranscriptCandidates(
        interleavingAfterCandidateQuery: (() throws -> Void)?
    ) throws -> [ActiveSyncTranscriptCandidate] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN DEFERRED TRANSACTION") }
        do {
            let rows = try connection.query(
                """
                SELECT revision.*, chapter.book_id AS sync_book_id
                FROM local_transcript_revisions AS revision
                JOIN local_chapters AS chapter
                  ON chapter.id = revision.chapter_id AND chapter.deleted_at IS NULL
                JOIN local_books AS book
                  ON book.id = chapter.book_id AND book.deleted_at IS NULL
                WHERE revision.is_active = 1 AND revision.deleted_at IS NULL
                ORDER BY revision.chapter_id
                """
            )
            try interleavingAfterCandidateQuery?()
            let candidates = try rows.map { row in
                ActiveSyncTranscriptCandidate(
                    bookID: BookID(rawValue: try row.required("sync_book_id")),
                    transcript: try loadTranscriptUnlocked(from: row)
                )
            }
            if ownsTransaction { try connection.exec("COMMIT") }
            return candidates
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    public func loadAllTranscripts() throws -> [StoredTranscript] {
        try loadTranscripts()
    }

    public func activeTranscriptChapterIDs() throws -> Set<ChapterID> {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return Set(try connection.query(
            "SELECT chapter_id FROM local_transcript_revisions WHERE is_active = 1 AND deleted_at IS NULL"
        ).compactMap { $0["chapter_id"].map(ChapterID.init(rawValue:)) })
    }

    public func loadTranscript(chapterID: ChapterID) throws -> StoredTranscript? {
        try loadTranscript(chapterID: chapterID, range: nil)
    }

    /// A remote transcript tombstone hides the active immutable revision without requiring
    /// its already-deleted object. An unknown chapter is an idempotent no-op.
    public func deleteTranscript(chapterID: ChapterID) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            try connection.run(
                "UPDATE local_transcript_revisions SET is_active = 0, deleted_at = ? WHERE chapter_id = ? AND is_active = 1"
            ) { [connection] statement in
                connection.bindDate(statement, 1, Date())
                connection.bind(statement, 2, chapterID.rawValue)
            }
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    /// Reader-facing loads request a bounded sequence range; a nil range is
    /// reserved for background workflows that explicitly require a full revision.
    public func loadTranscript(
        chapterID: ChapterID,
        range: Range<Int>?
    ) throws -> StoredTranscript? {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        guard let row = try connection.query(
            "SELECT * FROM local_transcript_revisions WHERE chapter_id = ? AND is_active = 1 ORDER BY created_at DESC, id LIMIT 1",
            bind: { [connection] statement in connection.bind(statement, 1, chapterID.rawValue) }
        ).first else { return nil }
        return try loadTranscriptUnlocked(from: row, range: range)
    }

    public func transcriptSegmentCount(chapterID: ChapterID) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query(
            """
            SELECT COUNT(*) AS count FROM local_transcript_segments AS segment
            JOIN local_transcript_revisions AS revision ON revision.id = segment.revision_id
            WHERE segment.chapter_id = ? AND revision.is_active = 1
            """,
            bind: { [connection] statement in connection.bind(statement, 1, chapterID.rawValue) }
        ).first?.int("count") ?? 0
    }

    /// Whole-chapter jobs assemble the revision through bounded range queries;
    /// reader-facing callers continue to request only the visible page.
    public func loadCompleteTranscript(
        chapterID: ChapterID,
        pageSize: Int
    ) throws -> StoredTranscript? {
        precondition(pageSize > 0)
        lock.lock()
        defer { lock.unlock() }
        maximumTranscriptSegmentQueryCount = 0
        let total = try transcriptSegmentCount(chapterID: chapterID)
        var complete: StoredTranscript?
        var start = 0
        repeat {
            let end = min(start + pageSize, total)
            guard let page = try loadTranscript(chapterID: chapterID, range: start..<end) else {
                return nil
            }
            if complete == nil {
                complete = page
            } else {
                complete?.segments.append(contentsOf: page.segments)
            }
            start = end
        } while start < total
        return complete
    }

    /// Saving a generated revision is atomic, while later corrections can use
    /// `updateTranscriptSegment` to avoid rewriting unrelated segment rows.
    public func saveTranscript(_ transcript: StoredTranscript) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            try ensureTranscriptParent(for: transcript)
            let revisionID = Self.revisionID(for: transcript.chapterID)
            try connection.run(
                "UPDATE local_transcript_revisions SET is_active = 0 WHERE chapter_id = ?"
            ) { [connection] statement in
                connection.bind(statement, 1, transcript.chapterID.rawValue)
            }
            try connection.run(
                """
                INSERT INTO local_transcript_revisions(
                  id, chapter_id, local_media_key, chapter_start, created_at, locale, source,
                  ebook_aligned, ebook_use_override, alignment_status, alignment_reason,
                  alignment_extracted_word_count, alignment_extracted_sentence_count,
                  alignment_sampled_anchor_count, alignment_matched_anchor_count,
                  alignment_matched_coverage, alignment_median_score, alignment_lower_percentile_score,
                  alignment_backward_jumps, alignment_longest_unmatched_passage,
                  alignment_title_similarity, alignment_author_similarity,
                  alignment_candidate_comparisons, alignment_detailed_performed,
                  is_active, server_version
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,0)
                ON CONFLICT(id) DO UPDATE SET
                  local_media_key=excluded.local_media_key, chapter_start=excluded.chapter_start,
                  created_at=excluded.created_at, locale=excluded.locale, source=excluded.source,
                  ebook_aligned=excluded.ebook_aligned, ebook_use_override=excluded.ebook_use_override,
                  alignment_status=excluded.alignment_status, alignment_reason=excluded.alignment_reason,
                  alignment_extracted_word_count=excluded.alignment_extracted_word_count,
                  alignment_extracted_sentence_count=excluded.alignment_extracted_sentence_count,
                  alignment_sampled_anchor_count=excluded.alignment_sampled_anchor_count,
                  alignment_matched_anchor_count=excluded.alignment_matched_anchor_count,
                  alignment_matched_coverage=excluded.alignment_matched_coverage,
                  alignment_median_score=excluded.alignment_median_score,
                  alignment_lower_percentile_score=excluded.alignment_lower_percentile_score,
                  alignment_backward_jumps=excluded.alignment_backward_jumps,
                  alignment_longest_unmatched_passage=excluded.alignment_longest_unmatched_passage,
                  alignment_title_similarity=excluded.alignment_title_similarity,
                  alignment_author_similarity=excluded.alignment_author_similarity,
                  alignment_candidate_comparisons=excluded.alignment_candidate_comparisons,
                  alignment_detailed_performed=excluded.alignment_detailed_performed,
                  is_active=1, deleted_at=NULL
                """
            ) { [connection] statement in
                connection.bind(statement, 1, revisionID)
                connection.bind(statement, 2, transcript.chapterID.rawValue)
                connection.bind(statement, 3, transcript.localMediaKey)
                connection.bind(statement, 4, transcript.chapterStart)
                connection.bindDate(statement, 5, transcript.createdAt)
                connection.bind(statement, 6, transcript.locale)
                connection.bind(statement, 7, transcript.source)
                connection.bind(statement, 8, transcript.ebookAligned ? 1 : 0)
                connection.bind(statement, 9, transcript.ebookUseOverride)
                Self.bindAlignment(transcript.ebookAlignment, to: statement, startingAt: 10, connection: connection)
            }
            try connection.run("DELETE FROM local_transcript_segments WHERE revision_id = ?") { [connection] statement in
                connection.bind(statement, 1, revisionID)
            }
            try insertTranscriptSegments(transcript.segments, chapterID: transcript.chapterID, revisionID: revisionID)
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    /// A generated revision and its first correction share one commit so a crash
    /// cannot expose an overlay without the immutable base it targets.
    public func saveTranscript(
        _ transcript: StoredTranscript,
        merging overlay: StoredTranscriptOverlay,
        revision: Int64
    ) throws {
        try performSyncPageTransaction {
            try saveTranscript(transcript)
            _ = try mergeTranscriptOverlay(overlay, revision: revision)
        }
    }

    /// Range loading is expressed in segment sequence so callers do not decode
    /// or allocate the remainder of a large chapter.
    public func loadTranscriptSegments(
        chapterID: ChapterID,
        range: Range<Int>
    ) throws -> [StoredTranscriptSegment] {
        guard !range.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let rows = try connection.query(
            """
            SELECT segment.* FROM local_transcript_segments AS segment
            JOIN local_transcript_revisions AS revision ON revision.id = segment.revision_id
            WHERE segment.chapter_id = ? AND revision.is_active = 1
              AND segment.sequence >= ? AND segment.sequence < ?
            ORDER BY segment.sequence
            """,
            bind: { [connection] statement in
                connection.bind(statement, 1, chapterID.rawValue)
                connection.bind(statement, 2, range.lowerBound)
                connection.bind(statement, 3, range.upperBound)
            }
        )
        lastTranscriptSegmentQueryCount = rows.count
        return try rows.map(Self.transcriptSegment(from:))
    }

    /// A correction to generated segment data updates one row and leaves all
    /// other sequences untouched, bounding WAL growth to the changed record.
    public func updateTranscriptSegment(
        chapterID: ChapterID,
        segment: StoredTranscriptSegment
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        guard let revisionID = try activeRevisionID(chapterID: chapterID) else { return }
        try updateTranscriptSegment(segment, chapterID: chapterID, revisionID: revisionID)
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

    /// A user edit and its sync mutation are indivisible, including conflict retention.
    @discardableResult
    public func mergeTranscriptOverlay(
        _ overlay: StoredTranscriptOverlay,
        revision: Int64,
        mutation: OutboxMutation
    ) throws -> TranscriptOverlayMergeOutcome {
        var outcome = TranscriptOverlayMergeOutcome.unchanged
        try performSyncPageTransaction {
            outcome = try mergeTranscriptOverlay(overlay, revision: revision)
            guard mutation.entityType == .transcriptOverlay else {
                throw LocalSQLiteStoreError.invalidTranscriptOverlayMutation
            }
            try enqueue(mutation)
        }
        return outcome
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
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            try upsertCurrentTranscriptOverlay(chosen.overlay, revision: chosen.revision)
            try deleteTranscriptOverlayConflicts(chapterID: chapterID, segmentID: segmentID)
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    /// Conflict selection and the replacement upload intent share one commit.
    public func resolveTranscriptOverlay(
        chapterID: ChapterID,
        segmentID: String,
        choosing candidateID: String,
        mutation: OutboxMutation
    ) throws {
        try performSyncPageTransaction {
            try resolveTranscriptOverlay(chapterID: chapterID, segmentID: segmentID, choosing: candidateID)
            guard mutation.entityType == .transcriptOverlay else {
                throw LocalSQLiteStoreError.invalidTranscriptOverlayMutation
            }
            try enqueue(mutation)
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
            let ownsTransaction = syncPageTransactionDepth == 0
            if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
            do {
                try upsertCurrentTranscriptOverlay(overlay, revision: revision)
                if revision > state.current.revision {
                    try deleteTranscriptOverlayConflicts(
                        chapterID: overlay.chapterID,
                        segmentID: overlay.segmentID
                    )
                }
                if ownsTransaction { try connection.exec("COMMIT") }
                return .replacedCurrent
            } catch {
                if ownsTransaction { try? connection.exec("ROLLBACK") }
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

    /// Restore deletion and its tombstone cannot be observed separately.
    public func deleteTranscriptOverlay(id: String, mutation: OutboxMutation) throws {
        try performSyncPageTransaction {
            guard mutation.entityType == .transcriptOverlay else {
                throw LocalSQLiteStoreError.invalidTranscriptOverlayMutation
            }
            let pending = try connection.query(
                """
                SELECT base_revision, occurred_at FROM sync_outbox
                WHERE status = ? AND entity_type = ? AND entity_id = ?
                ORDER BY occurred_at DESC, id DESC
                """,
                bind: { [connection] statement in
                    connection.bind(statement, 1, OutboxMutationStatus.pending.rawValue)
                    connection.bind(statement, 2, OutboxEntityType.transcriptOverlay.rawValue)
                    connection.bind(statement, 3, mutation.entityID)
                }
            )
            var tombstone = mutation
            if let latest = pending.first {
                tombstone.baseRevision = max(
                    tombstone.baseRevision,
                    ServerVersion(Int64(latest.int("base_revision")))
                )
                let latestDate = latest.date("occurred_at")
                if tombstone.occurredAt <= latestDate {
                    tombstone.occurredAt = latestDate.addingTimeInterval(0.001)
                }
            }
            try connection.run(
                "UPDATE sync_outbox SET status = ? WHERE status = ? AND entity_type = ? AND entity_id = ?"
            ) { [connection] statement in
                connection.bind(statement, 1, OutboxMutationStatus.acknowledged.rawValue)
                connection.bind(statement, 2, OutboxMutationStatus.pending.rawValue)
                connection.bind(statement, 3, OutboxEntityType.transcriptOverlay.rawValue)
                connection.bind(statement, 4, mutation.entityID)
            }
            try deleteTranscriptOverlay(id: id)
            try enqueue(tombstone)
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
            let ownsTransaction = syncPageTransactionDepth == 0
            if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
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
                if ownsTransaction { try connection.exec("COMMIT") }
                return .replacedCurrent
            } catch {
                if ownsTransaction { try? connection.exec("ROLLBACK") }
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

    public func saveVocabulary(_ entries: [StoredVocabularyOccurrence]) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            let existing = Dictionary(
                uniqueKeysWithValues: try connection.query(
                    "SELECT * FROM local_vocabulary_occurrences"
                ).map(Self.vocabulary(from:)).map { ($0.id, $0) }
            )
            let merged = entries.map { entry in
                guard let current = existing[entry.id] else { return entry }
                return StoredVocabularyReviewSchedule(current).merging(into: entry)
            }
            for entry in merged { try ensureLearningParents(for: entry, at: entry.addedAt) }
            try insertVocabulary(merged)
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func updateVocabularyReviewSchedule(_ schedule: StoredVocabularyReviewSchedule) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try updateVocabularyReviewScheduleUnlocked(schedule)
    }

    public func updateVocabularyReviewSchedules(_ schedules: [StoredVocabularyReviewSchedule]) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            for schedule in schedules { try updateVocabularyReviewScheduleUnlocked(schedule) }
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func updateVocabularyLearnList(id: VocabularyOccurrenceID, included: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.run(
            "UPDATE local_vocabulary_occurrences SET is_in_learn_list = ?, updated_at = ? WHERE id = ?"
        ) { [connection] statement in
            connection.bind(statement, 1, included ? 1 : 0)
            connection.bindDate(statement, 2, Date())
            connection.bind(statement, 3, id.rawValue)
        }
    }

    public func deleteVocabulary(id: VocabularyOccurrenceID) throws {
        try deleteVocabularyAndEnqueueTombstone(localID: id, entityID: id.rawValue)
    }

    /// Sync writes the vocabulary row and its lightweight relational parents in
    /// one transaction so dependent progress and review events can be retried safely.
    public func upsertVocabulary(_ vocabulary: StoredVocabularyOccurrence) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            try ensureLearningParents(for: vocabulary, at: vocabulary.addedAt)
            try insertVocabulary([vocabulary])
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    /// Initial sync writes a page of vocabulary with one parent pass and no per-row transaction.
    public func upsertVocabulary(_ vocabulary: [StoredVocabularyOccurrence]) throws {
        guard !vocabulary.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            for entry in vocabulary { try ensureLearningParents(for: entry, at: entry.addedAt) }
            try insertVocabulary(vocabulary)
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    /// Local removal and its outbox tombstone share one SQLite transaction so a crash cannot
    /// leave review children or a stale upsert capable of reviving the vocabulary row.
    public func deleteVocabularyAndEnqueueTombstone(
        localID: VocabularyOccurrenceID,
        entityID: String,
        occurredAt: Date = Date()
    ) throws {
        let payload = try JSONSerialization.data(
            withJSONObject: ["_deleted": true, "localId": localID.rawValue],
            options: [.sortedKeys]
        )
        try deleteVocabularyGraph(
            localID: localID,
            entityID: entityID,
            tombstone: OutboxMutation(
                id: MutationID.generate(),
                entityType: .vocabulary,
                entityID: entityID,
                operation: .delete,
                baseRevision: .zero,
                occurredAt: occurredAt,
                payload: payload
            )
        )
    }

    /// Pulled tombstones use the same relational delete without echoing a new mutation.
    public func applyVocabularyTombstone(localID: VocabularyOccurrenceID, entityID: String) throws {
        try deleteVocabularyGraph(localID: localID, entityID: entityID, tombstone: nil)
    }

    /// An explicit last-applied marker distinguishes deletion from legacy empty version rows.
    public func isVocabularyTombstoned(entityID: String) throws -> Bool {
        guard let version = try loadVersion(
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityID: entityID
        ) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: version.payload) as? [String: Any]
        else { return false }
        return object["_deleted"] as? Bool == true
    }

    private func deleteVocabularyGraph(
        localID: VocabularyOccurrenceID,
        entityID: String,
        tombstone: OutboxMutation?
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let version = try connection.query(
            "SELECT server_version FROM entity_versions WHERE entity_type = ? AND entity_id = ? LIMIT 1",
            bind: { [connection] stmt in
                connection.bind(stmt, 1, OutboxEntityType.vocabulary.rawValue)
                connection.bind(stmt, 2, entityID)
            }
        ).first?.int("server_version") ?? 0
        let pendingRevision = try connection.query(
            "SELECT MAX(base_revision) AS revision FROM sync_outbox WHERE status = ? AND entity_type = ? AND entity_id = ?",
            bind: { [connection] stmt in
                connection.bind(stmt, 1, OutboxMutationStatus.pending.rawValue)
                connection.bind(stmt, 2, OutboxEntityType.vocabulary.rawValue)
                connection.bind(stmt, 3, entityID)
            }
        ).first?.int("revision") ?? 0

        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            try connection.run("DELETE FROM local_review_events WHERE vocabulary_id = ?") { [connection] stmt in
                connection.bind(stmt, 1, localID.rawValue)
            }
            try connection.run("DELETE FROM local_review_cards WHERE vocabulary_id = ?") { [connection] stmt in
                connection.bind(stmt, 1, localID.rawValue)
            }
            try connection.run("DELETE FROM local_vocabulary_occurrences WHERE id = ?") { [connection] stmt in
                connection.bind(stmt, 1, localID.rawValue)
            }
            if var tombstone {
                try connection.run(
                    "UPDATE sync_outbox SET status = ? WHERE status = ? AND entity_type = ? AND entity_id = ?"
                ) { [connection] stmt in
                    connection.bind(stmt, 1, OutboxMutationStatus.acknowledged.rawValue)
                    connection.bind(stmt, 2, OutboxMutationStatus.pending.rawValue)
                    connection.bind(stmt, 3, OutboxEntityType.vocabulary.rawValue)
                    connection.bind(stmt, 4, entityID)
                }
                tombstone.baseRevision = ServerVersion(Int64(max(version, pendingRevision)))
                try connection.run(
                    """
                    INSERT INTO sync_outbox(
                      id, entity_type, entity_id, operation, base_revision, occurred_at, payload, status
                    ) VALUES (?,?,?,?,?,?,?,?)
                    """
                ) { [connection] stmt in
                    connection.bind(stmt, 1, tombstone.id.rawValue)
                    connection.bind(stmt, 2, tombstone.entityType.rawValue)
                    connection.bind(stmt, 3, tombstone.entityID)
                    connection.bind(stmt, 4, tombstone.operation.rawValue)
                    connection.bind(stmt, 5, Int(tombstone.baseRevision.rawValue))
                    connection.bindDate(stmt, 6, tombstone.occurredAt)
                    connection.bind(stmt, 7, tombstone.payload)
                    connection.bind(stmt, 8, OutboxMutationStatus.pending.rawValue)
                }
            }
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
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

    public func saveKnownLemmas(_ lemmas: [StoredKnownLemma]) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            try connection.exec("DELETE FROM local_known_lemmas")
            try insertKnownLemmas(lemmas)
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    /// Remote lemma pages merge one row without replacing unrelated local knowledge.
    public func upsertKnownLemma(_ lemma: StoredKnownLemma) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try insertKnownLemmas([lemma])
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
                cardID: row.string("card_id"),
                face: try row.required("face"),
                rating: try row.required("rating"),
                reviewedAt: row.date("reviewed_at")
            )
        }
    }

    /// The relational vocabulary row is the canonical review schedule used to
    /// repair a failed legacy mirror without relying on timestamp ordering.
    public func loadReviewVocabularySnapshot() throws -> [StoredVocabularyOccurrence]? {
        try loadVocabulary()
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
        try appendReviewEvent(event, vocabularies: [vocabulary])
    }

    /// Canonical reviews update every occurrence schedule and append one event
    /// attributed to the shared card, without removing any location row.
    public func appendReviewEvent(
        _ event: StoredReviewEvent,
        vocabularies: [StoredVocabularyOccurrence]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            if try reviewEventExistsUnlocked(event.id) {
                if ownsTransaction { try connection.exec("COMMIT") }
                return
            }
            for vocabulary in vocabularies {
                try ensureLearningParents(for: vocabulary, at: event.reviewedAt)
                try upsertVocabularyReviewSchedule(vocabulary)
            }
            guard let vocabulary = vocabularies.first(where: { $0.id == event.vocabularyID })
                ?? vocabularies.first
            else { throw LocalSQLiteStoreError.missingReviewVocabulary }
            let cardID = event.cardID ?? "card:\(vocabulary.id.rawValue):\(event.face)"
            let cardMapping = try insertReviewCards([
                StoredLocalReviewCard(
                    id: cardID,
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
            var persistedEvent = event
            if event.cardID != nil {
                persistedEvent.cardID = cardMapping[cardID] ?? cardID
            }
            try insertReviewEvents([persistedEvent], includeCard: true)
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
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

    public func loadAssistantResultHistory(resultID: String) throws -> [StoredAssistantResultHistory] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query(
            "SELECT * FROM local_assistant_result_history WHERE result_id = ? ORDER BY sequence",
            bind: { statement in self.connection.bind(statement, 1, resultID) }
        ).map { row in
            StoredAssistantResultHistory(
                resultID: try row.required("result_id"),
                sequence: Int64(row.int("sequence")),
                status: AssistantResultStatus(rawValue: try row.required("status")) ?? .pending,
                text: try row.required("text"),
                model: try row.required("model"),
                promptVersion: try row.required("prompt_version"),
                modelPolicyHash: try row.required("model_policy_hash"),
                recordedAt: row.date("recorded_at"),
                sharedCacheEntryID: row.string("shared_cache_entry_id")
            )
        }
    }

    public func saveAssistantResult(_ result: StoredAssistantResult) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try insertAssistantResults([result])
    }

    /// A lifecycle transition and its v2 upload intent commit together so cloud history cannot lag local state.
    public func updateAssistantResult(_ result: StoredAssistantResult, mutation: OutboxMutation) throws {
        try performSyncPageTransaction {
            guard mutation.entityType == .assistantResult, mutation.entityID == result.id else {
                throw LocalSQLiteStoreError.invalidAssistantDecisionMutation
            }
            try insertAssistantResults([result])
            try enqueue(mutation)
        }
    }

    /// Accepting generated text is one durable decision: the result status,
    /// derived vocabulary occurrences, and upload intent cannot diverge.
    public func acceptAssistantResult(
        _ result: StoredAssistantResult,
        vocabulary: [StoredVocabularyOccurrence],
        mutation: OutboxMutation
    ) throws {
        try acceptAssistantResults([result], vocabulary: vocabulary, mutations: [mutation])
    }

    /// Decision rows, derived learning rows, and their sync intent are one
    /// commit; callers must not perform any of these writes separately.
    public func acceptAssistantResults(
        _ results: [StoredAssistantResult],
        vocabulary: [StoredVocabularyOccurrence],
        mutations: [OutboxMutation]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            try insertAssistantResults(results)
            let mergedVocabulary = try vocabularyPreservingNewerReviewState(vocabulary)
            for entry in mergedVocabulary { try ensureLearningParents(for: entry, at: entry.addedAt) }
            try insertVocabulary(mergedVocabulary)
            try insertReviewCards(mergedVocabulary.map(Self.reviewCard(for:)))
            guard mutations.allSatisfy({ $0.entityType == .assistantResult }) else {
                throw LocalSQLiteStoreError.invalidAssistantDecisionMutation
            }
            for mutation in mutations { try enqueue(mutation) }
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    /// Pulled decisions share the same canonical transaction but never enqueue
    /// a new mutation back to the originating device.
    public func applyAssistantResults(
        _ results: [StoredAssistantResult],
        vocabulary: [StoredVocabularyOccurrence],
        removingVocabularyIDs: [VocabularyOccurrenceID] = []
    ) throws {
        try performSyncPageTransaction {
            try insertAssistantResults(results)
            try deleteUnreviewedDerivedVocabulary(ids: removingVocabularyIDs)
            let mergedVocabulary = try vocabularyPreservingNewerReviewState(vocabulary)
            for entry in mergedVocabulary { try ensureLearningParents(for: entry, at: entry.addedAt) }
            try insertVocabulary(mergedVocabulary)
            try insertReviewCards(mergedVocabulary.map(Self.reviewCard(for:)))
        }
    }

    /// Rejection status, safe derived-row removal, and its portable decision
    /// are one commit. Reviewed or explicitly captured vocabulary is retained.
    public func rejectAssistantResult(
        _ result: StoredAssistantResult,
        derivedVocabularyIDs: [VocabularyOccurrenceID],
        mutation: OutboxMutation
    ) throws {
        try performSyncPageTransaction {
            try insertAssistantResults([result])
            try deleteUnreviewedDerivedVocabulary(ids: derivedVocabularyIDs)
            guard mutation.entityType == .assistantResult else {
                throw LocalSQLiteStoreError.invalidAssistantDecisionMutation
            }
            try enqueue(mutation)
        }
    }

    public func replaceAssistantResults(_ results: [StoredAssistantResult]) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            try connection.exec("DELETE FROM local_assistant_results")
            try insertAssistantResults(results)
            try connection.exec("COMMIT")
        } catch {
            try? connection.exec("ROLLBACK")
            throw error
        }
    }

    public func loadTranslationCheckpoints() throws -> [StoredTranslationCheckpoint] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query(
            "SELECT * FROM local_translation_checkpoints ORDER BY chapter_id, language"
        ).map { row in
            StoredTranslationCheckpoint(
                chapterID: ChapterID(rawValue: try row.required("chapter_id")),
                language: try row.required("language"),
                mode: try row.required("mode"),
                completedSegmentCount: row.int("completed_segment_count"),
                totalSegmentCount: row.int("total_segment_count"),
                status: try row.required("status"),
                updatedAt: row.date("updated_at")
            )
        }
    }

    public func saveTranslationCheckpoint(_ checkpoint: StoredTranslationCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.run(
            """
            INSERT INTO local_translation_checkpoints(
              chapter_id, language, mode, completed_segment_count, total_segment_count, status, updated_at
            ) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(chapter_id, language) DO UPDATE SET
              mode=excluded.mode, completed_segment_count=excluded.completed_segment_count,
              total_segment_count=excluded.total_segment_count, status=excluded.status,
              updated_at=excluded.updated_at
            """
        ) { [connection] statement in
            connection.bind(statement, 1, checkpoint.chapterID.rawValue)
            connection.bind(statement, 2, checkpoint.language)
            connection.bind(statement, 3, checkpoint.mode)
            connection.bind(statement, 4, checkpoint.completedSegmentCount)
            connection.bind(statement, 5, checkpoint.totalSegmentCount)
            connection.bind(statement, 6, checkpoint.status)
            connection.bindDate(statement, 7, checkpoint.updatedAt)
        }
    }

    public func deleteTranslationCheckpoint(chapterID: ChapterID, language: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        try connection.run(
            "DELETE FROM local_translation_checkpoints WHERE chapter_id = ? AND language = ?"
        ) { [connection] statement in
            connection.bind(statement, 1, chapterID.rawValue)
            connection.bind(statement, 2, language)
        }
    }

    public func loadStudyActivityDays() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        return try connection.query("SELECT day FROM local_study_activity ORDER BY day").compactMap { $0["day"] }
    }

    public func saveStudyActivityDays(_ days: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        try applySchemaUnlocked()
        let ownsTransaction = syncPageTransactionDepth == 0
        if ownsTransaction { try connection.exec("BEGIN IMMEDIATE TRANSACTION") }
        do {
            try connection.exec("DELETE FROM local_study_activity")
            for day in Set(days) {
                try connection.run("INSERT INTO local_study_activity(day, created_at) VALUES (?,?)") { [connection] statement in
                    connection.bind(statement, 1, day)
                    connection.bindDate(statement, 2, Date())
                }
            }
            if ownsTransaction { try connection.exec("COMMIT") }
        } catch {
            if ownsTransaction { try? connection.exec("ROLLBACK") }
            throw error
        }
    }

    private func applySchemaUnlocked() throws {
        guard !schemaIsReady else { return }
        var previousVersion: Int?
        do {
            // Take the write reservation before inspecting the version so no
            // other connection can advance the schema behind this decision.
            try connection.exec("BEGIN IMMEDIATE TRANSACTION")
            let storedVersion = try connection.query("PRAGMA user_version").first?.int("user_version") ?? 0
            previousVersion = storedVersion
            guard storedVersion <= LocalSchemaVNext.version else {
                throw LocalSQLiteError.sqlite(
                    "unsupported schema version \(storedVersion); current version is \(LocalSchemaVNext.version)"
                )
            }
            if storedVersion > 0, storedVersion < LocalSchemaVNext.version {
                Self.schemaLog.info("message=schema.migrate component=local-store outcome=start from=\(storedVersion, privacy: .public) to=\(LocalSchemaVNext.version, privacy: .public)")
            }
            for sql in LocalSchemaVNext.createStatements {
                try connection.exec(sql)
            }
            if storedVersion < 2 {
                for addition in LocalSchemaVNext.version2ColumnAdditions {
                    let columns = try connection.query("PRAGMA table_info(\(addition.table))")
                    guard !columns.contains(where: { $0["name"] == addition.column }) else { continue }
                    try connection.exec(addition.sql)
                }
            }
            if storedVersion < 3 {
                for addition in LocalSchemaVNext.version3ColumnAdditions {
                    let columns = try connection.query("PRAGMA table_info(\(addition.table))")
                    guard !columns.contains(where: { $0["name"] == addition.column }) else { continue }
                    try connection.exec(addition.sql)
                }
            }
            try repairCaseVariantVocabularyIDsUnlocked()
            if storedVersion < LocalSchemaVNext.version {
                try connection.exec("PRAGMA user_version = \(LocalSchemaVNext.version)")
            }
            try connection.exec("COMMIT")
            if storedVersion > 0, storedVersion < LocalSchemaVNext.version {
                Self.schemaLog.info("message=schema.migrate component=local-store outcome=success from=\(storedVersion, privacy: .public) to=\(LocalSchemaVNext.version, privacy: .public)")
            }
        } catch {
            try? connection.exec("ROLLBACK")
            Self.schemaLog.error("message=schema.migrate component=local-store outcome=failure from=\(previousVersion ?? -1, privacy: .public) to=\(LocalSchemaVNext.version, privacy: .public) error=\(String(describing: error), privacy: .private)")
            throw error
        }
        schemaIsReady = true
        schemaApplicationCount += 1
    }

    /// Sync UUID identity is case-insensitive, while SQLite text primary keys are not. Repair
    /// legacy aliases inside the store-open transaction before callers build ID-keyed snapshots.
    private func repairCaseVariantVocabularyIDsUnlocked() throws {
        let candidates = try connection.query(
            "SELECT * FROM local_vocabulary_occurrences ORDER BY id"
        ).map { row in
            VocabularyRepairCandidate(
                occurrence: try Self.vocabulary(from: row),
                updatedAt: row.date("updated_at")
            )
        }
        let duplicateGroups = Dictionary(grouping: candidates) {
            $0.occurrence.id.rawValue.lowercased()
        }.filter { canonicalID, rows in
            rows.count > 1 && UUID(uuidString: canonicalID) != nil
        }
        guard !duplicateGroups.isEmpty else { return }

        for canonicalID in duplicateGroups.keys.sorted() {
            guard let rows = duplicateGroups[canonicalID] else { continue }
            try repairCaseVariantVocabularyGroupUnlocked(rows, canonicalID: canonicalID)
        }
        Self.schemaLog.info(
            "message=vocabulary.case_alias_repair component=local-store outcome=success groups=\(duplicateGroups.count, privacy: .public)"
        )
    }

    /// Ongoing sync checks only the IDs in its current batch. The expression index keeps this
    /// lookup bounded instead of rescanning the full vocabulary library for each row.
    private func repairCaseVariantVocabularyIDUnlocked(_ rawID: String) throws {
        let canonicalID = rawID.lowercased()
        guard UUID(uuidString: canonicalID) != nil else { return }
        let rows = try connection.query(
            "SELECT * FROM local_vocabulary_occurrences WHERE lower(id) = ? ORDER BY id",
            bind: { [connection] statement in connection.bind(statement, 1, canonicalID) }
        ).map { row in
            VocabularyRepairCandidate(
                occurrence: try Self.vocabulary(from: row),
                updatedAt: row.date("updated_at")
            )
        }
        guard rows.count > 1 else { return }
        try repairCaseVariantVocabularyGroupUnlocked(rows, canonicalID: canonicalID)
        Self.schemaLog.info(
            "message=vocabulary.case_alias_repair component=local-store outcome=success groups=1"
        )
    }

    private func repairCaseVariantVocabularyGroupUnlocked(
        _ rows: [VocabularyRepairCandidate],
        canonicalID: String
    ) throws {
        let cards = try reviewCardRepairCandidates(vocabularyID: canonicalID)
        let merged = Self.mergeCaseVariantVocabulary(rows, cards: cards, canonicalID: canonicalID)

        // Insert the canonical parent first so child reparenting remains foreign-key safe.
        try insertVocabulary([merged], repairingCaseAliases: false)
        for table in ["local_review_events", "local_review_cards"] {
            try connection.run(
                "UPDATE \(table) SET vocabulary_id = ? WHERE lower(vocabulary_id) = ?"
            ) { [connection] statement in
                connection.bind(statement, 1, canonicalID)
                connection.bind(statement, 2, canonicalID)
            }
        }
        try consolidateReviewCardsUnlocked(
            cards,
            vocabularyID: canonicalID,
            schedule: StoredVocabularyReviewSchedule(merged)
        )
        try connection.run(
            "DELETE FROM local_vocabulary_occurrences WHERE lower(id) = ? AND id != ?"
        ) { [connection] statement in
            connection.bind(statement, 1, canonicalID)
            connection.bind(statement, 2, canonicalID)
        }
        try connection.run(
            "UPDATE local_vocabulary_occurrences SET updated_at = ? WHERE id = ?"
        ) { [connection] statement in
            connection.bindDate(statement, 1, rows.map(\.updatedAt).max() ?? merged.addedAt)
            connection.bind(statement, 2, canonicalID)
        }
    }

    /// Newest durable content wins with stable tie-breaking; optional enrichment is additive,
    /// capture time is earliest, and scheduler/learn-list state is never reduced.
    private static func mergeCaseVariantVocabulary(
        _ candidates: [VocabularyRepairCandidate],
        cards: [ReviewCardRepairCandidate],
        canonicalID: String
    ) -> StoredVocabularyOccurrence {
        let newestFirst = candidates.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            let lhsIsCanonical = lhs.occurrence.id.rawValue == canonicalID
            let rhsIsCanonical = rhs.occurrence.id.rawValue == canonicalID
            if lhsIsCanonical != rhsIsCanonical { return lhsIsCanonical }
            return lhs.occurrence.id.rawValue < rhs.occurrence.id.rawValue
        }
        var merged = newestFirst[0].occurrence
        merged.id = VocabularyOccurrenceID(rawValue: canonicalID)
        merged.addedAt = candidates.map(\.occurrence.addedAt).min() ?? merged.addedAt
        merged.reviewEligible = candidates.contains { $0.occurrence.reviewEligible }
        merged.isInLearnList = candidates.contains { $0.occurrence.isInLearnList }

        for candidate in newestFirst.dropFirst().map(\.occurrence) {
            if merged.senseID == nil { merged.senseID = candidate.senseID }
            if merged.canonicalizationTraceID == nil {
                merged.canonicalizationTraceID = candidate.canonicalizationTraceID
            }
            if merged.definition == nil { merged.definition = candidate.definition }
            if merged.dictionaryName == nil { merged.dictionaryName = candidate.dictionaryName }
            if merged.dictionaryHTML == nil { merged.dictionaryHTML = candidate.dictionaryHTML }
            if merged.translation == nil { merged.translation = candidate.translation }
            if merged.translationLanguage == nil {
                merged.translationLanguage = candidate.translationLanguage
            }
            if merged.translationModel == nil { merged.translationModel = candidate.translationModel }
            if merged.sourceLanguage == nil { merged.sourceLanguage = candidate.sourceLanguage }
            if merged.spokenText == nil { merged.spokenText = candidate.spokenText }
            if merged.ebookText == nil { merged.ebookText = candidate.ebookText }
            if merged.segmentID == nil { merged.segmentID = candidate.segmentID }
            if merged.wordID == nil { merged.wordID = candidate.wordID }
        }

        let occurrenceStates = candidates.map {
            VocabularyReviewState(
                schedule: StoredVocabularyReviewSchedule($0.occurrence),
                updatedAt: $0.updatedAt,
                stableID: $0.occurrence.id.rawValue
            )
        }
        let cardStates = cards.map { cardReviewState($0, vocabularyID: canonicalID) }
        if let strongest = (occurrenceStates + cardStates).sorted(by: reviewStateIsStronger).first {
            merged = strongest.schedule.merging(into: merged)
        }
        if merged.reviewCount > 0 { merged.reviewEligible = true }
        return merged
    }

    private static func reviewStateIsStronger(
        _ lhs: VocabularyReviewState,
        _ rhs: VocabularyReviewState
    ) -> Bool {
        if lhs.schedule.reviewCount != rhs.schedule.reviewCount {
            return lhs.schedule.reviewCount > rhs.schedule.reviewCount
        }
        let lhsReviewedAt = lhs.schedule.lastReviewedAt ?? .distantPast
        let rhsReviewedAt = rhs.schedule.lastReviewedAt ?? .distantPast
        if lhsReviewedAt != rhsReviewedAt { return lhsReviewedAt > rhsReviewedAt }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.stableID < rhs.stableID
    }

    private static func cardReviewState(
        _ candidate: ReviewCardRepairCandidate,
        vocabularyID: String
    ) -> VocabularyReviewState {
        VocabularyReviewState(
            schedule: StoredVocabularyReviewSchedule(
                vocabularyID: VocabularyOccurrenceID(rawValue: vocabularyID),
                reviewCount: candidate.card.reviewCount,
                nextReview: candidate.card.nextReview,
                lastReviewedAt: candidate.card.lastReviewedAt,
                lastReviewQuality: candidate.card.lastReviewQuality,
                reviewIntervalDays: candidate.card.reviewIntervalDays,
                reviewEaseFactor: candidate.card.reviewEaseFactor
            ),
            updatedAt: candidate.updatedAt,
            stableID: candidate.card.id
        )
    }

    private func reviewCardRepairCandidates(
        vocabularyID: String
    ) throws -> [ReviewCardRepairCandidate] {
        try connection.query(
            "SELECT * FROM local_review_cards WHERE lower(vocabulary_id) = ? ORDER BY id",
            bind: { [connection] statement in connection.bind(statement, 1, vocabularyID) }
        ).map { row in
            ReviewCardRepairCandidate(
                card: StoredLocalReviewCard(
                    id: try row.required("id"),
                    vocabularyID: VocabularyOccurrenceID(rawValue: try row.required("vocabulary_id")),
                    face: try row.required("face"),
                    reviewCount: row.int("review_count"),
                    nextReview: row.optionalDate("next_review"),
                    lastReviewedAt: row.optionalDate("last_reviewed_at"),
                    lastReviewQuality: row.string("last_review_quality"),
                    reviewIntervalDays: row.double("review_interval_days"),
                    reviewEaseFactor: row.double("review_ease_factor")
                ),
                updatedAt: row.date("updated_at")
            )
        }
    }

    private func reviewCardRepairCandidates(
        vocabularyID: String,
        face: String
    ) throws -> [ReviewCardRepairCandidate] {
        try connection.query(
            "SELECT * FROM local_review_cards WHERE vocabulary_id = ? AND face = ? ORDER BY id",
            bind: { [connection] statement in
                connection.bind(statement, 1, vocabularyID)
                connection.bind(statement, 2, face)
            }
        ).map { row in
            ReviewCardRepairCandidate(
                card: StoredLocalReviewCard(
                    id: try row.required("id"),
                    vocabularyID: VocabularyOccurrenceID(rawValue: try row.required("vocabulary_id")),
                    face: try row.required("face"),
                    reviewCount: row.int("review_count"),
                    nextReview: row.optionalDate("next_review"),
                    lastReviewedAt: row.optionalDate("last_reviewed_at"),
                    lastReviewQuality: row.string("last_review_quality"),
                    reviewIntervalDays: row.double("review_interval_days"),
                    reviewEaseFactor: row.double("review_ease_factor")
                ),
                updatedAt: row.date("updated_at")
            )
        }
    }

    /// Review events remain immutable; mutable card mirrors collapse to the strongest schedule
    /// per face, and every historical event is retargeted before a superseded card is removed.
    private func consolidateReviewCardsUnlocked(
        _ cards: [ReviewCardRepairCandidate],
        vocabularyID: String,
        schedule: StoredVocabularyReviewSchedule
    ) throws {
        for face in Set(cards.map(\.card.face)).sorted() {
            let faceCards = cards.filter { $0.card.face == face }
            _ = try consolidateReviewCardFaceUnlocked(
                faceCards,
                vocabularyID: vocabularyID,
                face: face,
                schedule: schedule
            )
        }
    }

    /// One mutable card owns each persisted parent and face. Immutable events are reparented
    /// before losers are removed, while the strongest schedule is copied onto the survivor.
    private func consolidateReviewCardFaceUnlocked(
        _ cards: [ReviewCardRepairCandidate],
        vocabularyID: String,
        face: String,
        schedule override: StoredVocabularyReviewSchedule? = nil
    ) throws -> String? {
        guard let strongest = cards.sorted(by: {
            Self.reviewStateIsStronger(
                Self.cardReviewState($0, vocabularyID: vocabularyID),
                Self.cardReviewState($1, vocabularyID: vocabularyID)
            )
        }).first else { return nil }
        let canonicalGeneratedID = "card:\(vocabularyID):\(face)"
        let winner = cards.first { $0.card.id == canonicalGeneratedID } ?? strongest
        let schedule = override ?? Self.cardReviewState(strongest, vocabularyID: vocabularyID).schedule
        for loser in cards where loser.card.id != winner.card.id {
            try connection.run("UPDATE local_review_events SET card_id = ? WHERE card_id = ?") {
                [connection] statement in
                connection.bind(statement, 1, winner.card.id)
                connection.bind(statement, 2, loser.card.id)
            }
            try connection.run("DELETE FROM local_review_cards WHERE id = ?") {
                [connection] statement in connection.bind(statement, 1, loser.card.id)
            }
        }
        try connection.run(
            """
            UPDATE local_review_cards SET vocabulary_id = ?, review_count = ?, next_review = ?,
              last_reviewed_at = ?, last_review_quality = ?, review_interval_days = ?,
              review_ease_factor = ?, updated_at = ? WHERE id = ?
            """
        ) { [connection] statement in
            connection.bind(statement, 1, vocabularyID)
            connection.bind(statement, 2, schedule.reviewCount)
            connection.bindDate(statement, 3, schedule.nextReview)
            connection.bindDate(statement, 4, schedule.lastReviewedAt)
            connection.bind(statement, 5, schedule.lastReviewQuality)
            connection.bind(statement, 6, schedule.reviewIntervalDays)
            connection.bind(statement, 7, schedule.reviewEaseFactor)
            connection.bindDate(
                statement,
                8,
                [schedule.lastReviewedAt, strongest.updatedAt, winner.updatedAt].compactMap { $0 }.max()
            )
            connection.bind(statement, 9, winner.card.id)
        }
        return winner.card.id
    }

    private func insertTranscriptSegments(
        _ segments: [StoredTranscriptSegment],
        chapterID: ChapterID,
        revisionID: String
    ) throws {
        let sql = """
            INSERT INTO local_transcript_segments(
              revision_id, chapter_id, sequence, segment_id, start_time, end_time,
              spoken_text, words_json, ebook_text, sentence_hash, alignment_score,
              individual_ebook_match_trusted, document_ebook_use_allowed
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        for (sequence, segment) in segments.enumerated() {
            try connection.run(sql) { statement in
                connection.bind(statement, 1, revisionID)
                connection.bind(statement, 2, chapterID.rawValue)
                connection.bind(statement, 3, sequence)
                connection.bind(statement, 4, segment.id)
                connection.bind(statement, 5, segment.start)
                connection.bind(statement, 6, segment.end)
                connection.bind(statement, 7, Self.spokenText(for: segment))
                connection.bind(statement, 8, try LocalJSON.encode(segment.words))
                connection.bind(statement, 9, segment.ebookText)
                connection.bind(statement, 10, Self.sentenceHash(for: segment))
                connection.bind(statement, 11, segment.alignmentScore)
                connection.bind(statement, 12, segment.individualEbookMatchTrusted ?? false)
                connection.bind(statement, 13, segment.documentEbookUseAllowed ?? false)
            }
        }
    }

    private func updateTranscriptSegment(
        _ segment: StoredTranscriptSegment,
        chapterID: ChapterID,
        revisionID: String
    ) throws {
        try connection.run(
            """
            UPDATE local_transcript_segments SET
              start_time=?, end_time=?, spoken_text=?, words_json=?, ebook_text=?,
              sentence_hash=?, alignment_score=?, individual_ebook_match_trusted=?,
              document_ebook_use_allowed=?
            WHERE revision_id=? AND chapter_id=? AND segment_id=?
            """
        ) { [connection] statement in
            connection.bind(statement, 1, segment.start)
            connection.bind(statement, 2, segment.end)
            connection.bind(statement, 3, Self.spokenText(for: segment))
            connection.bind(statement, 4, try LocalJSON.encode(segment.words))
            connection.bind(statement, 5, segment.ebookText)
            connection.bind(statement, 6, Self.sentenceHash(for: segment))
            connection.bind(statement, 7, segment.alignmentScore)
            connection.bind(statement, 8, segment.individualEbookMatchTrusted ?? false)
            connection.bind(statement, 9, segment.documentEbookUseAllowed ?? false)
            connection.bind(statement, 10, revisionID)
            connection.bind(statement, 11, chapterID.rawValue)
            connection.bind(statement, 12, segment.id)
        }
    }

    private func activeRevisionID(chapterID: ChapterID) throws -> String? {
        try connection.query(
            "SELECT id FROM local_transcript_revisions WHERE chapter_id=? AND is_active=1 ORDER BY created_at DESC, id LIMIT 1",
            bind: { [connection] statement in connection.bind(statement, 1, chapterID.rawValue) }
        ).first?["id"]
    }

    private func ensureTranscriptParent(for transcript: StoredTranscript) throws {
        let hasChapter = try !connection.query(
            "SELECT id FROM local_chapters WHERE id = ? AND deleted_at IS NULL LIMIT 1",
            bind: { [connection] statement in connection.bind(statement, 1, transcript.chapterID.rawValue) }
        ).isEmpty
        guard hasChapter else { throw LocalSQLiteStoreError.missingTranscriptCatalogParent }
    }

    private static func revisionID(for chapterID: ChapterID) -> String {
        "revision:\(chapterID.rawValue)"
    }

    private static func spokenText(for segment: StoredTranscriptSegment) -> String {
        segment.words.map(\.text).joined(separator: " ")
    }

    private static func sentenceHash(for segment: StoredTranscriptSegment) -> String {
        String(spokenText(for: segment).utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }, radix: 16)
    }

    private static func bindAlignment(
        _ alignment: StoredEPUBAlignment?,
        to statement: OpaquePointer,
        startingAt start: Int32,
        connection: SQLiteConnection
    ) {
        connection.bind(statement, start, alignment?.status)
        connection.bind(statement, start + 1, alignment?.reason)
        connection.bind(statement, start + 2, alignment?.metrics.extractedWordCount)
        connection.bind(statement, start + 3, alignment?.metrics.extractedSentenceCount)
        connection.bind(statement, start + 4, alignment?.metrics.sampledAnchorCount)
        connection.bind(statement, start + 5, alignment?.metrics.matchedAnchorCount)
        connection.bind(statement, start + 6, alignment?.metrics.matchedCoverage)
        connection.bind(statement, start + 7, alignment?.metrics.medianScore)
        connection.bind(statement, start + 8, alignment?.metrics.lowerPercentileScore)
        connection.bind(statement, start + 9, alignment?.metrics.backwardJumps)
        connection.bind(statement, start + 10, alignment?.metrics.longestUnmatchedPassage)
        connection.bind(statement, start + 11, alignment?.metrics.titleSimilarity)
        connection.bind(statement, start + 12, alignment?.metrics.authorSimilarity)
        connection.bind(statement, start + 13, alignment?.metrics.candidateComparisons)
        connection.bind(statement, start + 14, alignment?.metrics.detailedAlignmentPerformed)
    }

    /// Every vocabulary writer passes through this boundary inside its owning transaction. Alias
    /// repair is disabled only for the repair's own canonical insert to prevent recursion.
    private func insertVocabulary(
        _ entries: [StoredVocabularyOccurrence],
        repairingCaseAliases: Bool = true
    ) throws {
        let sql = """
            INSERT INTO local_vocabulary_occurrences(
              id, surface, canonical_form, part_of_speech, sense_id,
              canonicalization_source, canonicalization_confidence, canonicalization_status, canonicalization_trace_id,
              capture_source, review_eligible, category, definition, dictionary_name, dictionary_html,
              translation, translation_language, translation_model, source_language,
              context, spoken_text, ebook_text, book_id, book_title, chapter_id, chapter_title,
              segment_id, word_id, timestamp, added_at, review_count, next_review,
              last_reviewed_at, last_review_quality, review_interval_days, review_ease_factor,
              is_in_learn_list, created_at, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
            ON CONFLICT(id) DO UPDATE SET
              surface=excluded.surface,
              canonical_form=excluded.canonical_form,
              part_of_speech=excluded.part_of_speech,
              sense_id=excluded.sense_id,
              canonicalization_source=excluded.canonicalization_source,
              canonicalization_confidence=excluded.canonicalization_confidence,
              canonicalization_status=excluded.canonicalization_status,
              canonicalization_trace_id=excluded.canonicalization_trace_id,
              capture_source=excluded.capture_source,
              review_eligible=excluded.review_eligible,
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
              added_at=MIN(local_vocabulary_occurrences.added_at, excluded.added_at),
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
                connection.bind(stmt, 3, entry.canonicalForm)
                connection.bind(stmt, 4, entry.partOfSpeech)
                connection.bind(stmt, 5, entry.senseID)
                connection.bind(stmt, 6, entry.canonicalizationSource)
                connection.bind(stmt, 7, entry.canonicalizationConfidence)
                connection.bind(stmt, 8, entry.canonicalizationStatus)
                connection.bind(stmt, 9, entry.canonicalizationTraceID)
                connection.bind(stmt, 10, entry.captureSource)
                connection.bind(stmt, 11, entry.reviewEligible ? 1 : 0)
                connection.bind(stmt, 12, entry.category)
                connection.bind(stmt, 13, entry.definition)
                connection.bind(stmt, 14, entry.dictionaryName)
                connection.bind(stmt, 15, entry.dictionaryHTML)
                connection.bind(stmt, 16, entry.translation)
                connection.bind(stmt, 17, entry.translationLanguage)
                connection.bind(stmt, 18, entry.translationModel)
                connection.bind(stmt, 19, entry.sourceLanguage)
                connection.bind(stmt, 20, entry.context)
                connection.bind(stmt, 21, entry.spokenText)
                connection.bind(stmt, 22, entry.ebookText)
                connection.bind(stmt, 23, entry.bookID.rawValue)
                connection.bind(stmt, 24, entry.bookTitle)
                connection.bind(stmt, 25, entry.chapterID.rawValue)
                connection.bind(stmt, 26, entry.chapterTitle)
                connection.bind(stmt, 27, entry.segmentID)
                connection.bind(stmt, 28, entry.wordID)
                connection.bind(stmt, 29, entry.timestamp)
                connection.bindDate(stmt, 30, entry.addedAt)
                connection.bind(stmt, 31, entry.reviewCount)
                connection.bindDate(stmt, 32, entry.nextReview)
                connection.bindDate(stmt, 33, entry.lastReviewedAt)
                connection.bind(stmt, 34, entry.lastReviewQuality)
                connection.bind(stmt, 35, entry.reviewIntervalDays)
                connection.bind(stmt, 36, entry.reviewEaseFactor)
                connection.bind(stmt, 37, entry.isInLearnList ? 1 : 0)
                connection.bindDate(stmt, 38, entry.addedAt)
                connection.bindDate(stmt, 39, entry.addedAt)
            }
        }
        if repairingCaseAliases {
            for id in Set(entries.map { $0.id.rawValue.lowercased() }) {
                try repairCaseVariantVocabularyIDUnlocked(id)
            }
        }
    }

    private func vocabularyPreservingNewerReviewState(
        _ incoming: [StoredVocabularyOccurrence]
    ) throws -> [StoredVocabularyOccurrence] {
        let existing = Dictionary(uniqueKeysWithValues: try loadVocabulary().map {
            (Self.vocabularyIdentityKey($0.id.rawValue), $0)
        })
        let cards = Dictionary(grouping: try loadReviewCards()) {
            Self.vocabularyIdentityKey($0.vocabularyID.rawValue)
        }.mapValues { candidates in
            candidates.sorted { lhs, rhs in
                if lhs.reviewCount != rhs.reviewCount { return lhs.reviewCount > rhs.reviewCount }
                let lhsReviewedAt = lhs.lastReviewedAt ?? .distantPast
                let rhsReviewedAt = rhs.lastReviewedAt ?? .distantPast
                if lhsReviewedAt != rhsReviewedAt { return lhsReviewedAt > rhsReviewedAt }
                return lhs.id < rhs.id
            }.first!
        }
        return incoming.map { entry in
            let identityKey = Self.vocabularyIdentityKey(entry.id.rawValue)
            guard let local = existing[identityKey] else { return entry }
            var strongest = local
            if let card = cards[identityKey],
               card.reviewCount > strongest.reviewCount
                || (card.reviewCount == strongest.reviewCount
                    && (card.lastReviewedAt ?? .distantPast) > (strongest.lastReviewedAt ?? .distantPast)) {
                strongest.reviewCount = card.reviewCount
                strongest.nextReview = card.nextReview
                strongest.lastReviewedAt = card.lastReviewedAt
                strongest.lastReviewQuality = card.lastReviewQuality
                strongest.reviewIntervalDays = card.reviewIntervalDays
                strongest.reviewEaseFactor = card.reviewEaseFactor
            }
            let localIsNewer = strongest.reviewCount > entry.reviewCount
                || (strongest.reviewCount == entry.reviewCount
                    && (strongest.lastReviewedAt ?? .distantPast) > (entry.lastReviewedAt ?? .distantPast))
            var merged = localIsNewer
                ? StoredVocabularyReviewSchedule(strongest).merging(into: entry)
                : entry
            merged.isInLearnList = entry.isInLearnList || local.isInLearnList
            if merged.reviewCount > 0 { merged.reviewEligible = true }
            return merged
        }
    }

    private func deleteUnreviewedDerivedVocabulary(ids: [VocabularyOccurrenceID]) throws {
        for id in ids {
            let deletable = try !connection.query(
                """
                SELECT 1 FROM local_vocabulary_occurrences AS vocabulary
                WHERE vocabulary.id = ?
                  AND vocabulary.capture_source IN (?, ?)
                  AND vocabulary.review_count = 0
                  AND NOT EXISTS (
                    SELECT 1 FROM local_review_events AS event
                    WHERE event.vocabulary_id = vocabulary.id
                  )
                LIMIT 1
                """,
                bind: { [connection] statement in
                    connection.bind(statement, 1, id.rawValue)
                    connection.bind(statement, 2, VocabularyCaptureSource.acceptedSentenceTranslation.rawValue)
                    connection.bind(statement, 3, VocabularyCaptureSource.automaticPhraseSuggestion.rawValue)
                }
            ).isEmpty
            guard deletable else { continue }
            try connection.run("DELETE FROM local_review_cards WHERE vocabulary_id = ?") { [connection] statement in
                connection.bind(statement, 1, id.rawValue)
            }
            try connection.run("DELETE FROM local_vocabulary_occurrences WHERE id = ?") { [connection] statement in
                connection.bind(statement, 1, id.rawValue)
            }
        }
    }

    /// Existing vocabulary rows may have changed while a review save was in
    /// flight, so only scheduler-owned columns are updated on conflict.
    private func upsertVocabularyReviewSchedule(_ vocabulary: StoredVocabularyOccurrence) throws {
        let exists = try !connection.query(
            "SELECT 1 FROM local_vocabulary_occurrences WHERE id = ? LIMIT 1",
            bind: { [connection] stmt in
                connection.bind(stmt, 1, vocabulary.id.rawValue)
            }
        ).isEmpty
        guard exists else {
            try insertVocabulary([vocabulary])
            return
        }
        try connection.run(
            """
            UPDATE local_vocabulary_occurrences SET
              review_count = ?, next_review = ?, last_reviewed_at = ?,
              last_review_quality = ?, review_interval_days = ?, review_ease_factor = ?,
              updated_at = ?
            WHERE id = ?
            """
        ) { [connection] stmt in
            connection.bind(stmt, 1, vocabulary.reviewCount)
            connection.bindDate(stmt, 2, vocabulary.nextReview)
            connection.bindDate(stmt, 3, vocabulary.lastReviewedAt)
            connection.bind(stmt, 4, vocabulary.lastReviewQuality)
            connection.bind(stmt, 5, vocabulary.reviewIntervalDays)
            connection.bind(stmt, 6, vocabulary.reviewEaseFactor)
            connection.bindDate(stmt, 7, vocabulary.lastReviewedAt ?? vocabulary.addedAt)
            connection.bind(stmt, 8, vocabulary.id.rawValue)
        }
    }

    private func updateVocabularyReviewScheduleUnlocked(_ schedule: StoredVocabularyReviewSchedule) throws {
        try connection.run(
            """
            UPDATE local_vocabulary_occurrences SET
              review_count=?, next_review=?, last_reviewed_at=?, last_review_quality=?,
              review_interval_days=?, review_ease_factor=?, updated_at=?
            WHERE id=?
            """
        ) { [connection] statement in
            connection.bind(statement, 1, schedule.reviewCount)
            connection.bindDate(statement, 2, schedule.nextReview)
            connection.bindDate(statement, 3, schedule.lastReviewedAt)
            connection.bind(statement, 4, schedule.lastReviewQuality)
            connection.bind(statement, 5, schedule.reviewIntervalDays)
            connection.bind(statement, 6, schedule.reviewEaseFactor)
            connection.bindDate(statement, 7, schedule.lastReviewedAt ?? Date())
            connection.bind(statement, 8, schedule.vocabularyID.rawValue)
        }
    }

    private func insertKnownLemmas(_ lemmas: [StoredKnownLemma]) throws {
        let sql = """
            INSERT INTO local_known_lemmas(language, form, updated_at, created_at, server_version)
            VALUES (?,?,?,?,0)
            ON CONFLICT(language, form) DO UPDATE SET
              updated_at = MAX(local_known_lemmas.updated_at, excluded.updated_at),
              deleted_at = NULL
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

    /// Returns each supplied card ID's persisted survivor after enforcing one card per parent/face.
    @discardableResult
    private func insertReviewCards(_ cards: [StoredLocalReviewCard]) throws -> [String: String] {
        let sql = """
            INSERT INTO local_review_cards(
              id, vocabulary_id, face, review_count, next_review, last_reviewed_at,
              last_review_quality, review_interval_days, review_ease_factor,
              created_at, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,0)
            ON CONFLICT(id) DO UPDATE SET
              vocabulary_id=excluded.vocabulary_id,
              face=excluded.face,
              review_count=excluded.review_count,
              next_review=excluded.next_review,
              last_reviewed_at=excluded.last_reviewed_at,
              last_review_quality=excluded.last_review_quality,
              review_interval_days=excluded.review_interval_days,
              review_ease_factor=excluded.review_ease_factor,
              updated_at=excluded.updated_at
        """
        var survivingIDs: [String: String] = [:]
        var inserted: [(originalID: String, vocabularyID: String, face: String)] = []
        for card in cards {
            let timestamp = card.lastReviewedAt ?? card.nextReview ?? Date(timeIntervalSince1970: 0)
            let rawVocabularyID = card.vocabularyID.rawValue
            let identityKey = Self.vocabularyIdentityKey(rawVocabularyID)
            let vocabularyID: String
            if let survivingID = survivingIDs[identityKey] {
                vocabularyID = survivingID
            } else {
                vocabularyID = try survivingVocabularyIDUnlocked(rawVocabularyID)
                survivingIDs[identityKey] = vocabularyID
            }
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, card.id)
                connection.bind(stmt, 2, vocabularyID)
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
            inserted.append((card.id, vocabularyID, card.face))
        }
        var mappings: [String: String] = [:]
        let groups = Dictionary(grouping: inserted) { "\($0.vocabularyID)\u{0}\($0.face)" }
        for groupKey in groups.keys.sorted() {
            guard let items = groups[groupKey], let group = items.first else { continue }
            let candidates = try reviewCardRepairCandidates(
                vocabularyID: group.vocabularyID,
                face: group.face
            )
            guard let survivor = try consolidateReviewCardFaceUnlocked(
                candidates,
                vocabularyID: group.vocabularyID,
                face: group.face
            ) else { continue }
            for item in items {
                mappings[item.originalID] = survivor
            }
        }
        return mappings
    }

    private static func reviewCard(for vocabulary: StoredVocabularyOccurrence) -> StoredLocalReviewCard {
        StoredLocalReviewCard(
            id: "card:\(vocabulary.id.rawValue):recognition",
            vocabularyID: vocabulary.id,
            face: "recognition",
            reviewCount: vocabulary.reviewCount,
            nextReview: vocabulary.nextReview,
            lastReviewedAt: vocabulary.lastReviewedAt,
            lastReviewQuality: vocabulary.lastReviewQuality,
            reviewIntervalDays: vocabulary.reviewIntervalDays,
            reviewEaseFactor: vocabulary.reviewEaseFactor
        )
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
        var survivingIDs: [String: String] = [:]
        for event in events {
            let rawVocabularyID = event.vocabularyID.rawValue
            let identityKey = Self.vocabularyIdentityKey(rawVocabularyID)
            let vocabularyID: String
            if let survivingID = survivingIDs[identityKey] {
                vocabularyID = survivingID
            } else {
                vocabularyID = try survivingVocabularyIDUnlocked(rawVocabularyID)
                survivingIDs[identityKey] = vocabularyID
            }
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, event.id.rawValue)
                connection.bind(stmt, 2, vocabularyID)
                connection.bind(
                    stmt,
                    3,
                    includeCard ? event.cardID : nil
                )
                connection.bind(stmt, 4, event.face)
                connection.bind(stmt, 5, event.rating)
                connection.bindDate(stmt, 6, event.reviewedAt)
                connection.bindDate(stmt, 7, event.reviewedAt)
            }
        }
    }

    /// Alias repair can retain a legacy singleton's spelling or replace a duplicate group with
    /// lowercase. Child writes resolve the row that exists now instead of guessing either form.
    private func survivingVocabularyIDUnlocked(_ rawID: String) throws -> String {
        let canonicalID = rawID.lowercased()
        guard UUID(uuidString: canonicalID) != nil else { return rawID }
        return try connection.query(
            "SELECT id FROM local_vocabulary_occurrences WHERE lower(id) = ? ORDER BY id LIMIT 1",
            bind: { [connection] statement in connection.bind(statement, 1, canonicalID) }
        ).first?["id"] ?? rawID
    }

    private static func vocabularyIdentityKey(_ rawID: String) -> String {
        UUID(uuidString: rawID) == nil ? rawID : rawID.lowercased()
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
              id, kind, status, language, model, prompt_version, model_policy_hash,
              book_id, book_title, chapter_id, chapter_title,
              source, text, context, timestamp, created_at, decided_at, replaced_text,
              replaced_model, shared_cache_entry_id, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
            ON CONFLICT(id) DO UPDATE SET
              kind=excluded.kind, status=excluded.status, language=excluded.language,
              model=excluded.model, prompt_version=excluded.prompt_version,
              model_policy_hash=excluded.model_policy_hash,
              book_id=excluded.book_id, book_title=excluded.book_title,
              chapter_id=excluded.chapter_id, chapter_title=excluded.chapter_title,
              source=excluded.source, text=excluded.text, context=excluded.context,
              timestamp=excluded.timestamp, decided_at=excluded.decided_at,
              replaced_text=excluded.replaced_text, replaced_model=excluded.replaced_model,
              shared_cache_entry_id=excluded.shared_cache_entry_id,
              updated_at=excluded.updated_at, deleted_at=NULL
            """
        for result in results {
            try insertAssistantResultHistory(result)
            try connection.run(sql) { stmt in
                connection.bind(stmt, 1, result.id)
                connection.bind(stmt, 2, result.kind.rawValue)
                connection.bind(stmt, 3, result.status.rawValue)
                connection.bind(stmt, 4, result.language)
                connection.bind(stmt, 5, result.model)
                connection.bind(stmt, 6, result.promptVersion)
                connection.bind(stmt, 7, result.modelPolicyHash)
                connection.bind(stmt, 8, result.bookID?.rawValue)
                connection.bind(stmt, 9, result.bookTitle)
                connection.bind(stmt, 10, result.chapterID?.rawValue)
                connection.bind(stmt, 11, result.chapterTitle)
                connection.bind(stmt, 12, result.source)
                connection.bind(stmt, 13, result.text)
                connection.bind(stmt, 14, result.context)
                connection.bind(stmt, 15, result.timestamp)
                connection.bindDate(stmt, 16, result.createdAt)
                connection.bindDate(stmt, 17, result.decidedAt)
                connection.bind(stmt, 18, result.replacedText)
                connection.bind(stmt, 19, result.replacedModel)
                connection.bind(stmt, 20, result.sharedCacheEntryID)
                connection.bindDate(stmt, 21, result.decidedAt ?? result.createdAt)
            }
        }
    }

    /// Append-only snapshots preserve user decisions even when the current result row is replaced.
    private func insertAssistantResultHistory(_ result: StoredAssistantResult) throws {
        let latest = try connection.query(
            "SELECT * FROM local_assistant_result_history WHERE result_id = ? ORDER BY sequence DESC LIMIT 1",
            bind: { statement in self.connection.bind(statement, 1, result.id) }
        ).first
        if let latest,
           latest.string("status") == result.status.rawValue,
           latest.string("text") == result.text,
           latest.string("model") == result.model,
           latest.string("prompt_version") == result.promptVersion,
           latest.string("model_policy_hash") == result.modelPolicyHash,
           latest.string("shared_cache_entry_id") == result.sharedCacheEntryID {
            return
        }
        let sequence = Int64(latest?.int("sequence") ?? 0) + 1
        try connection.run(
            """
            INSERT INTO local_assistant_result_history(
              result_id, sequence, status, text, model, prompt_version, model_policy_hash,
              recorded_at, shared_cache_entry_id
            ) VALUES (?,?,?,?,?,?,?,?,?)
            """
        ) { statement in
            connection.bind(statement, 1, result.id)
            connection.bind(statement, 2, Int(sequence))
            connection.bind(statement, 3, result.status.rawValue)
            connection.bind(statement, 4, result.text)
            connection.bind(statement, 5, result.model)
            connection.bind(statement, 6, result.promptVersion)
            connection.bind(statement, 7, result.modelPolicyHash)
            connection.bindDate(statement, 8, result.decidedAt ?? result.createdAt)
            connection.bind(statement, 9, result.sharedCacheEntryID)
        }
    }

    private func loadTranscriptUnlocked(
        from row: [String: String],
        range: Range<Int>? = nil
    ) throws -> StoredTranscript {
        let revisionID = try row.required("id")
        let segmentRows: [[String: String]]
        if let range {
            guard !range.isEmpty else { segmentRows = []; lastTranscriptSegmentQueryCount = 0; return try transcript(from: row, segmentRows: segmentRows) }
            segmentRows = try connection.query(
                "SELECT * FROM local_transcript_segments WHERE revision_id = ? AND sequence >= ? AND sequence < ? ORDER BY sequence",
                bind: { [connection] statement in
                    connection.bind(statement, 1, revisionID)
                    connection.bind(statement, 2, range.lowerBound)
                    connection.bind(statement, 3, range.upperBound)
                }
            )
        } else {
            segmentRows = try connection.query(
                "SELECT * FROM local_transcript_segments WHERE revision_id = ? ORDER BY sequence",
                bind: { [connection] statement in connection.bind(statement, 1, revisionID) }
            )
        }
        lastTranscriptSegmentQueryCount = segmentRows.count
        maximumTranscriptSegmentQueryCount = max(maximumTranscriptSegmentQueryCount, segmentRows.count)
        return try transcript(from: row, segmentRows: segmentRows)
    }

    private func transcript(
        from row: [String: String],
        segmentRows: [[String: String]]
    ) throws -> StoredTranscript {
        let alignment: StoredEPUBAlignment?
        if let status = row.string("alignment_status"),
           let reason = row.string("alignment_reason") {
            alignment = StoredEPUBAlignment(
                status: status,
                reason: reason,
                metrics: StoredEPUBAlignmentMetrics(
                    extractedWordCount: row.int("alignment_extracted_word_count"),
                    extractedSentenceCount: row.int("alignment_extracted_sentence_count"),
                    sampledAnchorCount: row.int("alignment_sampled_anchor_count"),
                    matchedAnchorCount: row.int("alignment_matched_anchor_count"),
                    matchedCoverage: row.double("alignment_matched_coverage"),
                    medianScore: row.double("alignment_median_score"),
                    lowerPercentileScore: row.double("alignment_lower_percentile_score"),
                    backwardJumps: row.int("alignment_backward_jumps"),
                    longestUnmatchedPassage: row.int("alignment_longest_unmatched_passage"),
                    titleSimilarity: row.optionalDouble("alignment_title_similarity"),
                    authorSimilarity: row.optionalDouble("alignment_author_similarity"),
                    candidateComparisons: row.int("alignment_candidate_comparisons"),
                    detailedAlignmentPerformed: row.bool("alignment_detailed_performed")
                )
            )
        } else {
            alignment = nil
        }
        return StoredTranscript(
            chapterID: ChapterID(rawValue: try row.required("chapter_id")),
            localMediaKey: try row.required("local_media_key"),
            chapterStart: row.optionalDouble("chapter_start"),
            createdAt: row.date("created_at"),
            locale: try row.required("locale"),
            source: try row.required("source"),
            ebookAligned: row.bool("ebook_aligned"),
            ebookAlignment: alignment,
            ebookUseOverride: row.optionalBool("ebook_use_override"),
            segments: try segmentRows.map(Self.transcriptSegment(from:))
        )
    }

    private static func transcriptSegment(from row: [String: String]) throws -> StoredTranscriptSegment {
        StoredTranscriptSegment(
            id: try row.required("segment_id"),
            start: row.double("start_time"),
            end: row.double("end_time"),
            words: try LocalJSON.decode(
                [StoredTranscriptWord].self,
                from: try row.required("words_json")
            ),
            ebookText: row.string("ebook_text"),
            alignmentScore: row.optionalDouble("alignment_score"),
            individualEbookMatchTrusted: row.optionalBool("individual_ebook_match_trusted"),
            documentEbookUseAllowed: row.optionalBool("document_ebook_use_allowed")
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
            canonicalForm: try row.required("canonical_form"),
            partOfSpeech: try row.required("part_of_speech"),
            senseID: row.string("sense_id"),
            canonicalizationSource: try row.required("canonicalization_source"),
            canonicalizationConfidence: row.double("canonicalization_confidence"),
            canonicalizationStatus: try row.required("canonicalization_status"),
            canonicalizationTraceID: row.string("canonicalization_trace_id"),
            captureSource: try row.required("capture_source"),
            reviewEligible: row.bool("review_eligible"),
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
            promptVersion: try row.required("prompt_version"),
            modelPolicyHash: try row.required("model_policy_hash"),
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
            replacedModel: row.string("replaced_model"),
            sharedCacheEntryID: row.string("shared_cache_entry_id")
        )
    }

}
