import Foundation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

public enum LocalSchemaV2: Sendable {
    public static let version = 2

    public static let requiredTables: [String] = [
        "local_books",
        "local_assets",
        "local_chapters",
        "local_transcript_revisions",
        "local_vocabulary_occurrences",
        "local_known_lemmas",
        "local_review_cards",
        "local_review_events",
        "local_assistant_results",
        "sync_outbox",
        "sync_state",
        "entity_versions"
    ]

    static let receiptTable = "local_migration_receipts"

    static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS local_books (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT,
          source TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_assets (
          id TEXT PRIMARY KEY,
          book_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          local_media_key TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT,
          FOREIGN KEY(book_id) REFERENCES local_books(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_chapters (
          id TEXT PRIMARY KEY,
          book_id TEXT NOT NULL,
          asset_id TEXT,
          position INTEGER NOT NULL DEFAULT 0,
          title TEXT NOT NULL,
          duration REAL,
          start_time REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT,
          FOREIGN KEY(book_id) REFERENCES local_books(id),
          FOREIGN KEY(asset_id) REFERENCES local_assets(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_transcript_revisions (
          id TEXT PRIMARY KEY,
          chapter_id TEXT NOT NULL,
          local_media_key TEXT NOT NULL,
          chapter_start REAL,
          created_at REAL NOT NULL,
          locale TEXT NOT NULL,
          source TEXT NOT NULL,
          ebook_aligned INTEGER NOT NULL DEFAULT 0,
          ebook_alignment_json TEXT,
          ebook_use_override INTEGER,
          segments_json TEXT NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 1,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT,
          FOREIGN KEY(chapter_id) REFERENCES local_chapters(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_vocabulary_occurrences (
          id TEXT PRIMARY KEY,
          surface TEXT NOT NULL,
          category TEXT NOT NULL,
          definition TEXT,
          dictionary_name TEXT,
          dictionary_html TEXT,
          translation TEXT,
          translation_language TEXT,
          translation_model TEXT,
          source_language TEXT,
          context TEXT NOT NULL,
          spoken_text TEXT,
          ebook_text TEXT,
          book_id TEXT NOT NULL,
          book_title TEXT NOT NULL,
          chapter_id TEXT NOT NULL,
          chapter_title TEXT NOT NULL,
          segment_id TEXT,
          word_id TEXT,
          timestamp REAL NOT NULL,
          added_at REAL NOT NULL,
          review_count INTEGER NOT NULL DEFAULT 0,
          next_review REAL,
          last_reviewed_at REAL,
          last_review_quality TEXT,
          review_interval_days REAL NOT NULL DEFAULT 0,
          review_ease_factor REAL NOT NULL DEFAULT 2.5,
          is_in_learn_list INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT,
          FOREIGN KEY(book_id) REFERENCES local_books(id),
          FOREIGN KEY(chapter_id) REFERENCES local_chapters(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_known_lemmas (
          language TEXT NOT NULL,
          form TEXT NOT NULL,
          updated_at REAL NOT NULL,
          created_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT,
          PRIMARY KEY(language, form)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_review_cards (
          id TEXT PRIMARY KEY,
          vocabulary_id TEXT NOT NULL,
          face TEXT NOT NULL,
          review_count INTEGER NOT NULL DEFAULT 0,
          next_review REAL,
          last_reviewed_at REAL,
          last_review_quality TEXT,
          review_interval_days REAL NOT NULL DEFAULT 0,
          review_ease_factor REAL NOT NULL DEFAULT 2.5,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT,
          FOREIGN KEY(vocabulary_id) REFERENCES local_vocabulary_occurrences(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_review_events (
          id TEXT PRIMARY KEY,
          vocabulary_id TEXT NOT NULL,
          card_id TEXT,
          face TEXT NOT NULL,
          rating TEXT NOT NULL,
          reviewed_at REAL NOT NULL,
          created_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          last_mutation_id TEXT,
          FOREIGN KEY(vocabulary_id) REFERENCES local_vocabulary_occurrences(id),
          FOREIGN KEY(card_id) REFERENCES local_review_cards(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_assistant_results (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          status TEXT NOT NULL,
          language TEXT NOT NULL,
          model TEXT NOT NULL,
          book_id TEXT,
          book_title TEXT,
          chapter_id TEXT,
          chapter_title TEXT,
          source TEXT NOT NULL,
          text TEXT NOT NULL,
          context TEXT,
          timestamp REAL,
          created_at REAL NOT NULL,
          decided_at REAL,
          replaced_text TEXT,
          replaced_model TEXT,
          updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_outbox (
          id TEXT PRIMARY KEY,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          operation TEXT NOT NULL,
          base_revision INTEGER NOT NULL DEFAULT 0,
          occurred_at REAL NOT NULL,
          payload BLOB NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending'
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_state (
          id TEXT PRIMARY KEY,
          cursor TEXT,
          last_pull_at REAL,
          last_push_at REAL,
          payload_json TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS entity_versions (
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL,
          last_mutation_id TEXT,
          payload_json TEXT,
          PRIMARY KEY(entity_type, entity_id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_migration_receipts (
          schema_version INTEGER PRIMARY KEY,
          completed_at REAL NOT NULL,
          book_count INTEGER NOT NULL,
          asset_count INTEGER NOT NULL,
          chapter_count INTEGER NOT NULL,
          transcript_revision_count INTEGER NOT NULL,
          vocabulary_count INTEGER NOT NULL,
          known_lemma_count INTEGER NOT NULL,
          review_card_count INTEGER NOT NULL,
          review_event_count INTEGER NOT NULL,
          assistant_result_count INTEGER NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_local_chapters_book ON local_chapters(book_id, position);",
        "CREATE INDEX IF NOT EXISTS idx_local_assets_book ON local_assets(book_id, kind);",
        "CREATE INDEX IF NOT EXISTS idx_local_transcripts_chapter ON local_transcript_revisions(chapter_id, is_active);",
        "CREATE INDEX IF NOT EXISTS idx_local_vocab_book ON local_vocabulary_occurrences(book_id, chapter_id);",
        "CREATE INDEX IF NOT EXISTS idx_local_review_cards_vocab ON local_review_cards(vocabulary_id);",
        "CREATE INDEX IF NOT EXISTS idx_local_review_events_vocab ON local_review_events(vocabulary_id, reviewed_at);",
        "CREATE INDEX IF NOT EXISTS idx_local_assistant_chapter ON local_assistant_results(chapter_id, kind, status);"
    ]

    static let dataTablesInDeleteOrder: [String] = [
        "local_review_events",
        "local_review_cards",
        "local_vocabulary_occurrences",
        "local_transcript_revisions",
        "local_assistant_results",
        "local_known_lemmas",
        "local_chapters",
        "local_assets",
        "local_books",
        "sync_outbox",
        "sync_state",
        "entity_versions",
        receiptTable
    ]
}

public struct LocalMigrationReceipt: Equatable, Sendable {
    public var schemaVersion: Int
    public var completedAt: Date
    public var bookCount: Int
    public var assetCount: Int
    public var chapterCount: Int
    public var transcriptRevisionCount: Int
    public var vocabularyCount: Int
    public var knownLemmaCount: Int
    public var reviewCardCount: Int
    public var reviewEventCount: Int
    public var assistantResultCount: Int
}

public enum LocalMigrationError: Error, Equatable, Sendable {
    case interrupted(table: String)
    case sqlite(String)
}

public struct LegacyLocalDataSources: Sendable {
    public var sqliteURL: URL
    public var persistenceRoot: URL

    public init(sqliteURL: URL, persistenceRoot: URL) {
        self.sqliteURL = sqliteURL
        self.persistenceRoot = persistenceRoot
    }

    var transcriptsDirectory: URL {
        persistenceRoot.appendingPathComponent("transcripts", isDirectory: true)
    }

    var vocabJSON: URL { persistenceRoot.appendingPathComponent("vocab.json") }
    var glossesJSON: URL { persistenceRoot.appendingPathComponent("glosses.json") }
    var lexiconJSON: URL { persistenceRoot.appendingPathComponent("lexicon.json") }
    var studyActivityJSON: URL { persistenceRoot.appendingPathComponent("study-activity.json") }
    var settingsJSON: URL { persistenceRoot.appendingPathComponent("settings.json") }
    var summariesJSON: URL { persistenceRoot.appendingPathComponent("chapter-summaries.json") }
    var checkpointsJSON: URL { persistenceRoot.appendingPathComponent("chapter-translation-checkpoints.json") }
}

public struct StoredLocalAsset: Equatable, Sendable {
    public var id: AssetID
    public var bookID: BookID
    public var kind: String
    public var localMediaKey: String
}

public struct StoredLocalReviewCard: Equatable, Sendable {
    public var id: String
    public var vocabularyID: VocabularyOccurrenceID
    public var face: String
    public var reviewCount: Int
    public var nextReview: Date?
    public var lastReviewedAt: Date?
    public var lastReviewQuality: String?
    public var reviewIntervalDays: Double
    public var reviewEaseFactor: Double
}
