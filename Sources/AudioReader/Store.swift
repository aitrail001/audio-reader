import Foundation
import SQLite3
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif
#if canImport(AudioReaderLocalStore)
import AudioReaderLocalStore
#endif

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class LibraryStore: @unchecked Sendable {
    static let shared = LibraryStore()
    private let lock = NSRecursiveLock()

    private var db: OpaquePointer?

    let url: URL
    private let importLegacyJSON: Bool
    private let persistenceRoot: URL

    private convenience init() {
        let root = Persistence.root
        self.init(
            url: root.appendingPathComponent("library.sqlite"),
            importLegacyJSON: true,
            persistenceRoot: root
        )
    }

    convenience init(fileURL: URL) {
        self.init(
            url: fileURL,
            importLegacyJSON: false,
            persistenceRoot: fileURL.deletingLastPathComponent()
        )
    }

    #if DEBUG
    convenience init(fileURL: URL, importingLegacyJSONFrom persistenceRoot: URL) {
        self.init(
            url: fileURL,
            importLegacyJSON: true,
            persistenceRoot: persistenceRoot
        )
    }
    #endif

    private init(url: URL, importLegacyJSON: Bool, persistenceRoot: URL) {
        self.url = url
        self.importLegacyJSON = importLegacyJSON
        self.persistenceRoot = persistenceRoot
        open()
        migrateSchema()
        if importLegacyJSON {
            importLegacyJSONIfNeeded()
            migrateLocalSchemaV2()
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Transcripts

    func saveTranscript(_ transcript: Transcript) throws {
        lock.lock()
        defer { lock.unlock() }
        let json = try JSONEncoder.iso.encode(transcript)
        let sql = """
        INSERT INTO transcripts(chapter_id, audio_path, created_at, locale, source, ebook_aligned, json)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(chapter_id) DO UPDATE SET
          audio_path=excluded.audio_path,
          created_at=excluded.created_at,
          locale=excluded.locale,
          source=excluded.source,
          ebook_aligned=excluded.ebook_aligned,
          json=excluded.json;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, transcript.chapterID)
        bind(stmt, 2, transcript.audioPath)
        bind(stmt, 3, transcript.createdAt.timeIntervalSince1970)
        bind(stmt, 4, transcript.locale)
        bind(stmt, 5, transcript.source)
        bind(stmt, 6, transcript.ebookAligned ? 1 : 0)
        bind(stmt, 7, String(data: json, encoding: .utf8))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw storeError("save transcript")
        }
    }

    func loadTranscript(chapterID: String, audioPath: String? = nil) -> Transcript? {
        lock.lock()
        defer { lock.unlock() }
        if let row = query(
            "SELECT json FROM transcripts WHERE chapter_id = ? LIMIT 1",
            bind: { self.bind($0, 1, chapterID) }
        ).first, let data = row["json"]?.data(using: .utf8) {
            if var t = try? JSONDecoder.iso.decode(Transcript.self, from: data) {
                t.chapterID = chapterID
                return t
            }
        }
        if let audioPath {
            let rows = query(
                "SELECT chapter_id, json FROM transcripts WHERE audio_path = ? LIMIT 1",
                bind: { self.bind($0, 1, audioPath) }
            )
            if let row = rows.first, let data = row["json"]?.data(using: .utf8),
               var t = try? JSONDecoder.iso.decode(Transcript.self, from: data) {
                t.chapterID = chapterID
                try? saveTranscript(t)
                return t
            }
        }
        guard importLegacyJSON else { return nil }
        return Persistence.loadTranscriptJSON(chapterID: chapterID, audioPath: audioPath)
    }

    func loadAllTranscripts() -> [Transcript] {
        lock.lock()
        defer { lock.unlock() }
        return query("SELECT json FROM transcripts").compactMap { row in
            guard let data = row["json"]?.data(using: .utf8) else { return nil }
            return try? JSONDecoder.iso.decode(Transcript.self, from: data)
        }
    }

    // MARK: - Vocab

    func loadVocab() -> [VocabEntry] {
        lock.lock()
        defer { lock.unlock() }
        let rows = query("SELECT json FROM vocab ORDER BY added_at DESC")
        return rows.compactMap { row in
            guard let data = row["json"]?.data(using: .utf8) else { return nil }
            return try? JSONDecoder.iso.decode(VocabEntry.self, from: data)
        }
    }

    func upsertVocab(_ entry: VocabEntry) {
        lock.lock()
        defer { lock.unlock() }
        upsertVocabUnlocked(entry)
    }

    func upsertVocab(_ entries: [VocabEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        exec("BEGIN IMMEDIATE TRANSACTION")
        defer { exec("COMMIT") }
        for entry in entries { upsertVocabUnlocked(entry) }
    }

    private func upsertVocabUnlocked(_ entry: VocabEntry) {
        guard let json = try? JSONEncoder.iso.encode(entry),
              let jsonStr = String(data: json, encoding: .utf8)
        else { return }
        let sql = """
        INSERT INTO vocab(id, word, category, book_id, book_title, chapter_id, timestamp, added_at, json)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          word=excluded.word,
          category=excluded.category,
          book_id=excluded.book_id,
          book_title=excluded.book_title,
          chapter_id=excluded.chapter_id,
          timestamp=excluded.timestamp,
          json=excluded.json;
        """
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, entry.id)
        bind(stmt, 2, entry.word)
        bind(stmt, 3, entry.category.rawValue)
        bind(stmt, 4, entry.bookID)
        bind(stmt, 5, entry.bookTitle)
        bind(stmt, 6, entry.chapterID)
        bind(stmt, 7, entry.timestamp)
        bind(stmt, 8, entry.addedAt.timeIntervalSince1970)
        bind(stmt, 9, jsonStr)
        sqlite3_step(stmt)
    }

    func replaceVocab(_ items: [VocabEntry]) {
        lock.lock()
        defer { lock.unlock() }
        exec("BEGIN IMMEDIATE TRANSACTION")
        defer { exec("COMMIT") }
        exec("DELETE FROM vocab")
        for item in items { upsertVocabUnlocked(item) }
    }

    func deleteVocab(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepare("DELETE FROM vocab WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        sqlite3_step(stmt)
    }

    // MARK: - Glosses

    func loadGlosses() -> [GlossEntry] {
        lock.lock()
        defer { lock.unlock() }
        let rows = query("SELECT json FROM glosses ORDER BY created_at DESC")
        return rows.compactMap { row in
            guard let data = row["json"]?.data(using: .utf8) else { return nil }
            return try? JSONDecoder.iso.decode(GlossEntry.self, from: data)
        }
    }

    func upsertGloss(_ entry: GlossEntry) {
        lock.lock()
        defer { lock.unlock() }
        upsertGlossUnlocked(entry)
    }

    func upsertGloss(_ entries: [GlossEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        exec("BEGIN IMMEDIATE TRANSACTION")
        defer { exec("COMMIT") }
        for entry in entries { upsertGlossUnlocked(entry) }
    }

    private func upsertGlossUnlocked(_ entry: GlossEntry) {
        guard let json = try? JSONEncoder.iso.encode(entry),
              let jsonStr = String(data: json, encoding: .utf8)
        else { return }
        let sql = """
        INSERT INTO glosses(id, kind, language, status, book_id, chapter_id, created_at, json)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          status=excluded.status,
          json=excluded.json;
        """
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, entry.id)
        bind(stmt, 2, entry.kind.rawValue)
        bind(stmt, 3, entry.language)
        bind(stmt, 4, entry.status.rawValue)
        bind(stmt, 5, entry.bookID)
        bind(stmt, 6, entry.chapterID)
        bind(stmt, 7, entry.createdAt.timeIntervalSince1970)
        bind(stmt, 8, jsonStr)
        sqlite3_step(stmt)
    }

    func replaceGlosses(_ items: [GlossEntry]) {
        lock.lock()
        defer { lock.unlock() }
        exec("BEGIN IMMEDIATE TRANSACTION")
        defer { exec("COMMIT") }
        exec("DELETE FROM glosses")
        for item in items { upsertGlossUnlocked(item) }
    }

    func deleteGloss(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepare("DELETE FROM glosses WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        sqlite3_step(stmt)
    }

    // MARK: - Open

    private func open() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            db = nil
        }
        exec("PRAGMA foreign_keys = ON")
        exec("PRAGMA journal_mode = WAL")
    }

    private func migrateSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS transcripts (
          chapter_id TEXT PRIMARY KEY,
          audio_path TEXT,
          created_at REAL,
          locale TEXT,
          source TEXT,
          ebook_aligned INTEGER,
          json TEXT NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS vocab (
          id TEXT PRIMARY KEY,
          word TEXT NOT NULL,
          category TEXT NOT NULL DEFAULT 'word',
          book_id TEXT,
          book_title TEXT,
          chapter_id TEXT,
          timestamp REAL,
          added_at REAL,
          json TEXT NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS glosses (
          id TEXT PRIMARY KEY,
          kind TEXT,
          language TEXT,
          status TEXT,
          book_id TEXT,
          chapter_id TEXT,
          created_at REAL,
          json TEXT NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_vocab_book ON vocab(book_id, category)")
        exec("CREATE INDEX IF NOT EXISTS idx_glosses_book ON glosses(book_id, kind, status)")
        exec("CREATE INDEX IF NOT EXISTS idx_transcripts_audio ON transcripts(audio_path)")
    }

    private func importLegacyJSONIfNeeded() {
        let flag = persistenceRoot.appendingPathComponent(".sqlite-migrated-v1")
        guard !FileManager.default.fileExists(atPath: flag.path) else { return }

        if let data = try? Data(contentsOf: persistenceRoot.appendingPathComponent("vocab.json")),
           let vocab = try? JSONDecoder.iso.decode([VocabEntry].self, from: data),
           !vocab.isEmpty {
            replaceVocab(vocab)
        }

        if let data = try? Data(contentsOf: persistenceRoot.appendingPathComponent("glosses.json")),
           let glosses = try? JSONDecoder.iso.decode([GlossEntry].self, from: data),
           !glosses.isEmpty {
            replaceGlosses(glosses)
        }

        let transcriptsDir = persistenceRoot.appendingPathComponent("transcripts", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: nil
        ) {
            for url in files where url.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: url),
                   let transcript = try? JSONDecoder.iso.decode(Transcript.self, from: data) {
                    try? saveTranscript(transcript)
                }
            }
        }
        try? Data("ok".utf8).write(to: flag)
    }

    private func migrateLocalSchemaV2() {
        let sources = LegacyLocalDataSources(sqliteURL: url, persistenceRoot: persistenceRoot)
        do {
            _ = try LocalSQLiteStore(fileURL: url).migrateLegacyData(from: sources)
        } catch {
            NSLog("AudioReader schema v2 migration failed: %@", String(describing: error))
        }
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw storeError(sql)
        }
        return stmt
    }

    private func query(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) -> [[String: String]] {
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        var rows: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            let cols = sqlite3_column_count(stmt)
            for i in 0..<cols {
                let name = String(cString: sqlite3_column_name(stmt, i))
                if let cstr = sqlite3_column_text(stmt, i) {
                    row[name] = String(cString: cstr)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, sqlite3_int64(value))
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Data) {
        _ = value.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(value.count), sqliteTransient)
        }
    }

    private func storeError(_ context: String) -> NSError {
        let msg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        return NSError(domain: "AudioReader.Store", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "SQLite \(context): \(msg)"
        ])
    }
}

struct LibraryStoreTranscriptRepository: TranscriptRepository {
    let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    func loadTranscript(chapterID: ChapterID) throws -> StoredTranscript? {
        store.loadTranscript(chapterID: chapterID.rawValue).map(StoredTranscript.init)
    }

    func saveTranscript(_ transcript: StoredTranscript) throws {
        try store.saveTranscript(Transcript(transcript))
    }

    func loadAllTranscripts() throws -> [StoredTranscript] {
        store.loadAllTranscripts().map(StoredTranscript.init)
    }
}

struct LibraryStoreVocabularyRepository: VocabularyRepository {
    let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    func loadVocabulary() throws -> [StoredVocabularyOccurrence] {
        store.loadVocab().map(StoredVocabularyOccurrence.init)
    }

    func saveVocabulary(_ entries: [StoredVocabularyOccurrence]) throws {
        store.replaceVocab(entries.map(VocabEntry.init))
    }

    func upsertVocabulary(_ entries: [StoredVocabularyOccurrence]) throws {
        store.upsertVocab(entries.map(VocabEntry.init))
    }

    func deleteVocabulary(id: VocabularyOccurrenceID) throws {
        store.deleteVocab(id: id.rawValue)
    }
}

struct LibraryStoreAssistantResultRepository: AssistantResultRepository {
    let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    func loadAssistantResults() throws -> [StoredAssistantResult] {
        store.loadGlosses().map(StoredAssistantResult.init)
    }

    func saveAssistantResult(_ result: StoredAssistantResult) throws {
        store.upsertGloss(try GlossEntry(result))
    }

    func replaceAssistantResults(_ results: [StoredAssistantResult]) throws {
        store.replaceGlosses(try results.map(GlossEntry.init))
    }
}

extension StoredTranscript {
    init(_ transcript: Transcript) {
        self.init(
            chapterID: ChapterID(rawValue: transcript.chapterID),
            localMediaKey: transcript.audioPath,
            chapterStart: transcript.chapterStart,
            createdAt: transcript.createdAt,
            locale: transcript.locale,
            source: transcript.source,
            ebookAligned: transcript.ebookAligned,
            ebookAlignment: transcript.ebookAlignment.map(StoredEPUBAlignment.init),
            ebookUseOverride: transcript.ebookUseOverride,
            segments: transcript.segments.map(StoredTranscriptSegment.init)
        )
    }
}

extension StoredTranscriptSegment {
    init(_ segment: TranscriptSegment) {
        self.init(
            id: segment.id,
            start: segment.start,
            end: segment.end,
            words: segment.words.map(StoredTranscriptWord.init),
            ebookText: segment.ebookText,
            alignmentScore: segment.alignmentScore,
            individualEbookMatchTrusted: segment.individualEbookMatchTrusted,
            documentEbookUseAllowed: segment.documentEbookUseAllowed
        )
    }
}

extension StoredTranscriptWord {
    init(_ word: TranscriptWord) {
        self.init(
            id: word.id,
            text: word.text,
            start: word.start,
            end: word.end,
            confidence: word.confidence
        )
    }
}

extension Transcript {
    init(_ stored: StoredTranscript) {
        self.init(
            chapterID: stored.chapterID.rawValue,
            audioPath: stored.localMediaKey,
            chapterStart: stored.chapterStart,
            createdAt: stored.createdAt,
            locale: stored.locale,
            segments: stored.segments.map(TranscriptSegment.init),
            source: stored.source,
            ebookAligned: stored.ebookAligned,
            ebookAlignment: stored.ebookAlignment.map(EPUBAlignmentAssessment.init),
            ebookUseOverride: stored.ebookUseOverride
        )
    }
}

extension TranscriptSegment {
    init(_ stored: StoredTranscriptSegment) {
        self.init(
            id: stored.id,
            start: stored.start,
            end: stored.end,
            words: stored.words.map(TranscriptWord.init),
            ebookText: stored.ebookText,
            alignmentScore: stored.alignmentScore,
            individualEbookMatchTrusted: stored.individualEbookMatchTrusted,
            documentEbookUseAllowed: stored.documentEbookUseAllowed
        )
    }
}

extension TranscriptWord {
    init(_ stored: StoredTranscriptWord) {
        self.init(
            id: stored.id,
            text: stored.text,
            start: stored.start,
            end: stored.end,
            confidence: stored.confidence
        )
    }
}

extension StoredVocabularyOccurrence {
    init(_ entry: VocabEntry) {
        self.init(
            id: VocabularyOccurrenceID(rawValue: entry.id),
            surface: entry.word,
            category: entry.category.rawValue,
            definition: entry.definition,
            dictionaryName: entry.dictionaryName,
            dictionaryHTML: entry.dictionaryHTML,
            translation: entry.translation,
            translationLanguage: entry.translationLanguage,
            translationModel: entry.translationModel,
            sourceLanguage: entry.sourceLanguage,
            context: entry.context,
            spokenText: entry.spokenText,
            ebookText: entry.ebookText,
            bookID: BookID(rawValue: entry.bookID),
            bookTitle: entry.bookTitle,
            chapterID: ChapterID(rawValue: entry.chapterID),
            chapterTitle: entry.chapterTitle,
            segmentID: entry.segmentID,
            wordID: entry.wordID,
            timestamp: entry.timestamp,
            addedAt: entry.addedAt,
            reviewCount: entry.reviewCount,
            nextReview: entry.nextReview,
            lastReviewedAt: entry.lastReviewedAt,
            lastReviewQuality: entry.lastReviewQuality?.rawValue,
            reviewIntervalDays: entry.reviewIntervalDays,
            reviewEaseFactor: entry.reviewEaseFactor,
            isInLearnList: entry.isInLearnList
        )
    }
}

extension VocabEntry {
    init(_ stored: StoredVocabularyOccurrence) {
        self.init(
            id: stored.id.rawValue,
            word: stored.surface,
            category: VocabCategory(rawValue: stored.category) ?? .word,
            definition: stored.definition,
            dictionaryName: stored.dictionaryName,
            dictionaryHTML: stored.dictionaryHTML,
            translation: stored.translation,
            translationLanguage: stored.translationLanguage,
            translationModel: stored.translationModel,
            sourceLanguage: stored.sourceLanguage,
            context: stored.context,
            spokenText: stored.spokenText,
            ebookText: stored.ebookText,
            bookID: stored.bookID.rawValue,
            bookTitle: stored.bookTitle,
            chapterID: stored.chapterID.rawValue,
            chapterTitle: stored.chapterTitle,
            segmentID: stored.segmentID,
            wordID: stored.wordID,
            timestamp: stored.timestamp,
            addedAt: stored.addedAt,
            reviewCount: stored.reviewCount,
            nextReview: stored.nextReview,
            lastReviewedAt: stored.lastReviewedAt,
            lastReviewQuality: stored.lastReviewQuality.flatMap(VocabReviewQuality.init(rawValue:)),
            reviewIntervalDays: stored.reviewIntervalDays,
            reviewEaseFactor: stored.reviewEaseFactor,
            isInLearnList: stored.isInLearnList
        )
    }
}

extension StoredAssistantResult {
    init(_ gloss: GlossEntry) {
        self.init(
            id: gloss.id,
            kind: gloss.kind == .word ? .wordGloss : .sentenceGloss,
            status: AssistantResultStatus(gloss.status),
            language: gloss.language,
            model: gloss.model,
            bookID: gloss.bookID.map(BookID.init(rawValue:)),
            bookTitle: gloss.bookTitle,
            chapterID: gloss.chapterID.map(ChapterID.init(rawValue:)),
            chapterTitle: gloss.chapterTitle,
            source: gloss.source,
            text: gloss.text,
            context: gloss.context,
            timestamp: gloss.timestamp,
            createdAt: gloss.createdAt,
            decidedAt: gloss.decidedAt,
            replacedText: gloss.replacedText,
            replacedModel: gloss.replacedModel
        )
    }
}

extension StoredEPUBAlignment {
    init(_ assessment: EPUBAlignmentAssessment) {
        self.init(
            status: assessment.status.rawValue,
            reason: assessment.reason,
            metrics: StoredEPUBAlignmentMetrics(assessment.metrics)
        )
    }
}

extension StoredEPUBAlignmentMetrics {
    init(_ metrics: EPUBAlignmentMetrics) {
        self.init(
            extractedWordCount: metrics.extractedWordCount,
            extractedSentenceCount: metrics.extractedSentenceCount,
            sampledAnchorCount: metrics.sampledAnchorCount,
            matchedAnchorCount: metrics.matchedAnchorCount,
            matchedCoverage: metrics.matchedCoverage,
            medianScore: metrics.medianScore,
            lowerPercentileScore: metrics.lowerPercentileScore,
            backwardJumps: metrics.backwardJumps,
            longestUnmatchedPassage: metrics.longestUnmatchedPassage,
            titleSimilarity: metrics.titleSimilarity,
            authorSimilarity: metrics.authorSimilarity,
            candidateComparisons: metrics.candidateComparisons,
            detailedAlignmentPerformed: metrics.detailedAlignmentPerformed
        )
    }
}

extension EPUBAlignmentAssessment {
    init(_ stored: StoredEPUBAlignment) {
        self.init(
            status: EPUBAlignmentStatus(rawValue: stored.status) ?? .uncertain,
            reason: stored.reason,
            metrics: EPUBAlignmentMetrics(stored.metrics)
        )
    }
}

extension EPUBAlignmentMetrics {
    init(_ stored: StoredEPUBAlignmentMetrics) {
        self.init(
            extractedWordCount: stored.extractedWordCount,
            extractedSentenceCount: stored.extractedSentenceCount,
            sampledAnchorCount: stored.sampledAnchorCount,
            matchedAnchorCount: stored.matchedAnchorCount,
            matchedCoverage: stored.matchedCoverage,
            medianScore: stored.medianScore,
            lowerPercentileScore: stored.lowerPercentileScore,
            backwardJumps: stored.backwardJumps,
            longestUnmatchedPassage: stored.longestUnmatchedPassage,
            titleSimilarity: stored.titleSimilarity,
            authorSimilarity: stored.authorSimilarity,
            candidateComparisons: stored.candidateComparisons,
            detailedAlignmentPerformed: stored.detailedAlignmentPerformed
        )
    }
}

extension GlossEntry {
    init(_ stored: StoredAssistantResult) throws {
        let kind: GlossKind
        switch stored.kind {
        case .wordGloss:
            kind = .word
        case .sentenceGloss:
            kind = .sentence
        case .chapterSummary, .chapterTranslation:
            throw LocalStoreError.unsupportedAssistantResultKind
        }
        self.init(
            id: stored.id,
            kind: kind,
            language: stored.language,
            source: stored.source,
            context: stored.context,
            text: stored.text,
            status: GlossStatus(stored.status),
            model: stored.model,
            bookID: stored.bookID?.rawValue,
            bookTitle: stored.bookTitle,
            chapterID: stored.chapterID?.rawValue,
            chapterTitle: stored.chapterTitle,
            timestamp: stored.timestamp,
            createdAt: stored.createdAt,
            decidedAt: stored.decidedAt,
            replacedText: stored.replacedText,
            replacedModel: stored.replacedModel
        )
    }
}

private extension AssistantResultStatus {
    init(_ status: GlossStatus) {
        switch status {
        case .pending: self = .pending
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        }
    }
}

private extension GlossStatus {
    init(_ status: AssistantResultStatus) {
        switch status {
        case .pending: self = .pending
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        }
    }
}

enum GlossPhrases {
    static func extract(from grokText: String) -> [(phrase: String, meaning: String)] {
        var results: [(String, String)] = []
        var inSection = false
        let lines = grokText.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let uppercased = line.uppercased()
            if line.hasPrefix("短语")
                || uppercased.hasPrefix(GlossTextFormat.phrasesHeading)
                || uppercased.hasPrefix(GlossTextFormat.learningNotesHeading) {
                inSection = true
                let rest = line
                    .replacingOccurrences(of: #"^短语[：:\s]*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)^PHRASAL VERBS AND PHRASES[:\s]*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)^LANGUAGE AND CONTEXT NOTES[:\s]*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty || rest.hasPrefix("无") || rest.caseInsensitiveCompare("None") == .orderedSame { continue }
                if let pair = parseLine(rest) { results.append(pair) }
                continue
            }
            if GlossTextFormat.isHeading(line) {
                inSection = false
                continue
            }
            guard !line.isEmpty else { continue }
            let isBullet = line.hasPrefix("•") || line.hasPrefix("·") || line.hasPrefix("- ") || line.hasPrefix("* ")
            if inSection || isBullet {
                if line == "无" || line.hasPrefix("无") || line.caseInsensitiveCompare("None") == .orderedSame { continue }
                if let pair = parseLine(line) { results.append(pair) }
            }
        }
        return results
    }

    private static func parseLine(_ line: String) -> (String, String)? {
        var body = line
        while let first = body.first, "•·-–—*".contains(first) {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let seps = [" — ", " – ", "——", " —", "– ", " - ", "：", ": "]
        for sep in seps {
            if let r = body.range(of: sep) {
                let phrase = String(body[..<r.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
                let meaning = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if phrase.count >= 2, meaning.count >= 1, phrase.count < 80 {
                    return (phrase, meaning)
                }
            }
        }
        return nil
    }
}
