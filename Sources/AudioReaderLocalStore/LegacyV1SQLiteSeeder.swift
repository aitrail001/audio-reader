import Foundation

func seedLegacyV1(
    at url: URL,
    transcripts: [String],
    vocab: [String],
    glosses: [String]
) throws {
    let connection = SQLiteConnection(fileURL: url)
    try connection.exec("""
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
    try connection.exec("""
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
    try connection.exec("""
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

    for json in transcripts {
        let object = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        try connection.run(
            "INSERT OR REPLACE INTO transcripts(chapter_id, audio_path, created_at, locale, source, ebook_aligned, json) VALUES (?,?,?,?,?,?,?)"
        ) { stmt in
            connection.bind(stmt, 1, object["chapterID"] as? String)
            connection.bind(stmt, 2, object["audioPath"] as? String)
            connection.bind(stmt, 3, 0)
            connection.bind(stmt, 4, object["locale"] as? String)
            connection.bind(stmt, 5, object["source"] as? String)
            connection.bind(stmt, 6, 0)
            connection.bind(stmt, 7, json)
        }
    }

    for json in vocab {
        let object = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        try connection.run(
            "INSERT OR REPLACE INTO vocab(id, word, category, book_id, book_title, chapter_id, timestamp, added_at, json) VALUES (?,?,?,?,?,?,?,?,?)"
        ) { stmt in
            connection.bind(stmt, 1, object["id"] as? String)
            connection.bind(stmt, 2, object["word"] as? String ?? "")
            connection.bind(stmt, 3, object["category"] as? String ?? "word")
            connection.bind(stmt, 4, object["bookID"] as? String)
            connection.bind(stmt, 5, object["bookTitle"] as? String)
            connection.bind(stmt, 6, object["chapterID"] as? String)
            connection.bind(stmt, 7, object["timestamp"] as? Double ?? 0)
            connection.bind(stmt, 8, 0)
            connection.bind(stmt, 9, json)
        }
    }

    for json in glosses {
        let object = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        try connection.run(
            "INSERT OR REPLACE INTO glosses(id, kind, language, status, book_id, chapter_id, created_at, json) VALUES (?,?,?,?,?,?,?,?)"
        ) { stmt in
            connection.bind(stmt, 1, object["id"] as? String)
            connection.bind(stmt, 2, object["kind"] as? String)
            connection.bind(stmt, 3, object["language"] as? String)
            connection.bind(stmt, 4, object["status"] as? String)
            connection.bind(stmt, 5, object["bookID"] as? String)
            connection.bind(stmt, 6, object["chapterID"] as? String)
            connection.bind(stmt, 7, 0)
            connection.bind(stmt, 8, json)
        }
    }
}
