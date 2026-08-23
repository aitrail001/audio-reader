import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class LibraryStore: @unchecked Sendable {
    static let shared = LibraryStore()
    private let lock = NSRecursiveLock()

    private var db: OpaquePointer?

    var url: URL { Persistence.root.appendingPathComponent("library.sqlite") }

    private init() {
        open()
        migrateSchema()
        importLegacyJSONIfNeeded()
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
        for item in items { upsertGloss(item) }
    }

    func deleteGloss(id: String) {
        guard let stmt = try? prepare("DELETE FROM glosses WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        sqlite3_step(stmt)
    }

    // MARK: - Open

    private func open() {
        try? FileManager.default.createDirectory(at: Persistence.root, withIntermediateDirectories: true)
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
        let flag = Persistence.root.appendingPathComponent(".sqlite-migrated-v1")
        guard !FileManager.default.fileExists(atPath: flag.path) else { return }

        let vocab = Persistence.loadVocabJSON()
        if !vocab.isEmpty { replaceVocab(vocab) }

        let glosses = Persistence.loadGlossesJSON()
        if !glosses.isEmpty { replaceGlosses(glosses) }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: Persistence.transcriptsDir,
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

enum GlossPhrases {
    static func extract(from grokText: String) -> [(phrase: String, meaning: String)] {
        var results: [(String, String)] = []
        var inSection = false
        let lines = grokText.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("短语") {
                inSection = true
                let rest = line.replacingOccurrences(of: #"^短语[：:\s]*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty || rest.hasPrefix("无") { continue }
                if let pair = parseLine(rest) { results.append(pair) }
                continue
            }
            if line.hasPrefix("译文") || line.hasPrefix("释义") || line.hasPrefix("例句") {
                inSection = false
                continue
            }
            guard !line.isEmpty else { continue }
            let isBullet = line.hasPrefix("•") || line.hasPrefix("·") || line.hasPrefix("- ") || line.hasPrefix("* ")
            if inSection || isBullet {
                if line == "无" || line.hasPrefix("无") { continue }
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
                let phrase = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let meaning = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if phrase.count >= 2, meaning.count >= 1, phrase.count < 80 {
                    return (phrase, meaning)
                }
            }
        }
        return nil
    }
}
