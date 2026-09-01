import Foundation

/// The branch-isolated schema starts empty by design. It never inspects or
/// repairs the legacy database because that file remains owned by local-reader.
public enum LocalSchemaVNext: Sendable {
    public static let version = 2

    /// Version 1 shipped before these device-local metadata fields existed.
    /// Defaults preserve old rows without inventing provider or cache provenance.
    static let version2ColumnAdditions: [(table: String, column: String, sql: String)] = [
        ("local_assets", "content_hash", "ALTER TABLE local_assets ADD COLUMN content_hash TEXT"),
        ("local_assets", "byte_count", "ALTER TABLE local_assets ADD COLUMN byte_count INTEGER"),
        ("local_assets", "metadata_json", "ALTER TABLE local_assets ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}'"),
        ("local_assistant_results", "prompt_version", "ALTER TABLE local_assistant_results ADD COLUMN prompt_version TEXT NOT NULL DEFAULT 'local'"),
        ("local_assistant_results", "model_policy_hash", "ALTER TABLE local_assistant_results ADD COLUMN model_policy_hash TEXT NOT NULL DEFAULT 'local'"),
        ("local_assistant_results", "shared_cache_entry_id", "ALTER TABLE local_assistant_results ADD COLUMN shared_cache_entry_id TEXT"),
    ]

    public static let requiredTables = [
        "entity_versions",
        "local_assets",
        "local_sync_asset_manifests",
        "local_book_tombstones",
        "local_assistant_result_history",
        "local_assistant_results",
        "local_books",
        "local_chapters",
        "local_known_lemmas",
        "local_reader_progress",
        "local_review_cards",
        "local_review_events",
        "local_settings",
        "local_study_activity",
        "local_transcript_overlay_conflicts",
        "local_transcript_overlays",
        "local_transcript_revisions",
        "local_transcript_segments",
        "local_translation_checkpoints",
        "local_vocabulary_occurrences",
        "sync_outbox",
        "sync_state"
    ]

    static let createStatements = [
        """
        CREATE TABLE IF NOT EXISTS local_books (
          id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT, source TEXT NOT NULL,
          created_at REAL NOT NULL, updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0, deleted_at REAL, last_mutation_id TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_sync_asset_manifests (
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, revision_id TEXT, book_id TEXT, chapter_id TEXT,
          content_type TEXT NOT NULL, encoding TEXT NOT NULL, sha256 TEXT NOT NULL,
          compressed_bytes INTEGER NOT NULL, original_bytes INTEGER NOT NULL, segment_count INTEGER,
          local_object_path TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_book_tombstones (
          book_id TEXT PRIMARY KEY, deleted_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_assets (
          id TEXT PRIMARY KEY, book_id TEXT NOT NULL, kind TEXT NOT NULL,
          local_media_key TEXT NOT NULL, content_hash TEXT, byte_count INTEGER,
          metadata_json TEXT NOT NULL DEFAULT '{}', created_at REAL NOT NULL, updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0, deleted_at REAL, last_mutation_id TEXT,
          FOREIGN KEY(book_id) REFERENCES local_books(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_chapters (
          id TEXT PRIMARY KEY, book_id TEXT NOT NULL, asset_id TEXT, position INTEGER NOT NULL DEFAULT 0,
          title TEXT NOT NULL, duration REAL, start_time REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0, deleted_at REAL, last_mutation_id TEXT,
          FOREIGN KEY(book_id) REFERENCES local_books(id), FOREIGN KEY(asset_id) REFERENCES local_assets(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_transcript_revisions (
          id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, local_media_key TEXT NOT NULL,
          chapter_start REAL, created_at REAL NOT NULL, locale TEXT NOT NULL, source TEXT NOT NULL,
          ebook_aligned INTEGER NOT NULL DEFAULT 0, ebook_use_override INTEGER,
          alignment_status TEXT, alignment_reason TEXT,
          alignment_extracted_word_count INTEGER, alignment_extracted_sentence_count INTEGER,
          alignment_sampled_anchor_count INTEGER, alignment_matched_anchor_count INTEGER,
          alignment_matched_coverage REAL, alignment_median_score REAL,
          alignment_lower_percentile_score REAL, alignment_backward_jumps INTEGER,
          alignment_longest_unmatched_passage INTEGER, alignment_title_similarity REAL,
          alignment_author_similarity REAL, alignment_candidate_comparisons INTEGER,
          alignment_detailed_performed INTEGER,
          is_active INTEGER NOT NULL DEFAULT 1, server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL, last_mutation_id TEXT,
          FOREIGN KEY(chapter_id) REFERENCES local_chapters(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_transcript_segments (
          revision_id TEXT NOT NULL, chapter_id TEXT NOT NULL, sequence INTEGER NOT NULL,
          segment_id TEXT NOT NULL, start_time REAL NOT NULL, end_time REAL NOT NULL,
          spoken_text TEXT NOT NULL, words_json TEXT NOT NULL, ebook_text TEXT,
          sentence_hash TEXT, alignment_score REAL,
          individual_ebook_match_trusted INTEGER NOT NULL DEFAULT 0,
          document_ebook_use_allowed INTEGER NOT NULL DEFAULT 0,
          token_alignment_json TEXT,
          PRIMARY KEY(revision_id, segment_id), UNIQUE(revision_id, sequence),
          FOREIGN KEY(revision_id) REFERENCES local_transcript_revisions(id) ON DELETE CASCADE,
          FOREIGN KEY(chapter_id) REFERENCES local_chapters(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_transcript_overlays (
          id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, segment_id TEXT NOT NULL,
          base_fingerprint TEXT NOT NULL, corrected_text TEXT NOT NULL,
          corrected_start REAL NOT NULL, corrected_end REAL NOT NULL,
          provenance_json TEXT NOT NULL, updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0, deleted_at REAL, last_mutation_id TEXT,
          UNIQUE(chapter_id, segment_id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_transcript_overlay_conflicts (
          candidate_id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, segment_id TEXT NOT NULL,
          overlay_json TEXT NOT NULL, server_revision INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_vocabulary_occurrences (
          id TEXT PRIMARY KEY, surface TEXT NOT NULL, canonical_form TEXT NOT NULL,
          part_of_speech TEXT NOT NULL, sense_id TEXT, canonicalization_source TEXT NOT NULL,
          canonicalization_confidence REAL NOT NULL, canonicalization_status TEXT NOT NULL,
          canonicalization_trace_id TEXT, capture_source TEXT NOT NULL, review_eligible INTEGER NOT NULL,
          category TEXT NOT NULL, definition TEXT, dictionary_name TEXT, dictionary_html TEXT,
          translation TEXT, translation_language TEXT, translation_model TEXT, source_language TEXT,
          context TEXT NOT NULL, spoken_text TEXT, ebook_text TEXT,
          book_id TEXT NOT NULL, book_title TEXT NOT NULL, chapter_id TEXT NOT NULL, chapter_title TEXT NOT NULL,
          segment_id TEXT, word_id TEXT, timestamp REAL NOT NULL, added_at REAL NOT NULL,
          review_count INTEGER NOT NULL DEFAULT 0, next_review REAL, last_reviewed_at REAL,
          last_review_quality TEXT, review_interval_days REAL NOT NULL DEFAULT 0,
          review_ease_factor REAL NOT NULL DEFAULT 2.5, is_in_learn_list INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0, deleted_at REAL, last_mutation_id TEXT,
          FOREIGN KEY(book_id) REFERENCES local_books(id), FOREIGN KEY(chapter_id) REFERENCES local_chapters(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_known_lemmas (
          language TEXT NOT NULL, form TEXT NOT NULL, updated_at REAL NOT NULL, created_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0, deleted_at REAL, last_mutation_id TEXT,
          PRIMARY KEY(language, form)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_review_cards (
          id TEXT PRIMARY KEY, vocabulary_id TEXT NOT NULL, face TEXT NOT NULL,
          review_count INTEGER NOT NULL DEFAULT 0, next_review REAL, last_reviewed_at REAL,
          last_review_quality TEXT, review_interval_days REAL NOT NULL DEFAULT 0,
          review_ease_factor REAL NOT NULL DEFAULT 2.5, created_at REAL NOT NULL, updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0, deleted_at REAL, last_mutation_id TEXT,
          FOREIGN KEY(vocabulary_id) REFERENCES local_vocabulary_occurrences(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_review_events (
          id TEXT PRIMARY KEY, vocabulary_id TEXT NOT NULL, card_id TEXT, face TEXT NOT NULL,
          rating TEXT NOT NULL, reviewed_at REAL NOT NULL, created_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0, last_mutation_id TEXT,
          FOREIGN KEY(vocabulary_id) REFERENCES local_vocabulary_occurrences(id),
          FOREIGN KEY(card_id) REFERENCES local_review_cards(id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_assistant_results (
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, language TEXT NOT NULL,
          model TEXT NOT NULL, prompt_version TEXT NOT NULL, model_policy_hash TEXT NOT NULL,
          book_id TEXT, book_title TEXT, chapter_id TEXT, chapter_title TEXT,
          source TEXT NOT NULL, text TEXT NOT NULL, context TEXT, timestamp REAL,
          created_at REAL NOT NULL, decided_at REAL, replaced_text TEXT, replaced_model TEXT,
          shared_cache_entry_id TEXT,
          updated_at REAL NOT NULL, server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL, last_mutation_id TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_assistant_result_history (
          result_id TEXT NOT NULL, sequence INTEGER NOT NULL, status TEXT NOT NULL,
          text TEXT NOT NULL, model TEXT NOT NULL, prompt_version TEXT NOT NULL,
          model_policy_hash TEXT NOT NULL, recorded_at REAL NOT NULL,
          shared_cache_entry_id TEXT, PRIMARY KEY(result_id, sequence)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_translation_checkpoints (
          chapter_id TEXT NOT NULL, language TEXT NOT NULL, mode TEXT NOT NULL,
          completed_segment_count INTEGER NOT NULL, total_segment_count INTEGER NOT NULL,
          status TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY(chapter_id, language)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_settings (
          id TEXT PRIMARY KEY CHECK(id = 'local'), payload_json TEXT NOT NULL, updated_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_study_activity (
          day TEXT PRIMARY KEY, created_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS local_reader_progress (
          id TEXT PRIMARY KEY, book_id TEXT NOT NULL, chapter_id TEXT NOT NULL,
          relative_seconds REAL NOT NULL, updated_at REAL NOT NULL, device_id TEXT NOT NULL,
          revision INTEGER NOT NULL DEFAULT 0, is_current INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_outbox (
          id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, operation TEXT NOT NULL,
          base_revision INTEGER NOT NULL DEFAULT 0, occurred_at REAL NOT NULL, payload BLOB NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending'
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_state (
          id TEXT PRIMARY KEY, cursor TEXT, last_pull_at REAL, last_push_at REAL, payload_json TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS entity_versions (
          entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, server_version INTEGER NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL, last_mutation_id TEXT, payload_json TEXT,
          PRIMARY KEY(entity_type, entity_id)
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_local_chapters_book ON local_chapters(book_id, position);",
        "CREATE INDEX IF NOT EXISTS idx_local_assets_book ON local_assets(book_id, kind);",
        "CREATE INDEX IF NOT EXISTS idx_local_sync_assets_kind ON local_sync_asset_manifests(kind, book_id, chapter_id);",
        "CREATE INDEX IF NOT EXISTS idx_local_transcript_revision_chapter ON local_transcript_revisions(chapter_id, is_active);",
        "CREATE INDEX IF NOT EXISTS idx_local_transcript_segment_range ON local_transcript_segments(chapter_id, revision_id, sequence);",
        "CREATE INDEX IF NOT EXISTS idx_local_transcript_segment_time ON local_transcript_segments(chapter_id, start_time, end_time);",
        "CREATE INDEX IF NOT EXISTS idx_local_overlays_chapter ON local_transcript_overlays(chapter_id, segment_id);",
        "CREATE INDEX IF NOT EXISTS idx_local_overlay_conflicts_segment ON local_transcript_overlay_conflicts(chapter_id, segment_id, updated_at);",
        "CREATE INDEX IF NOT EXISTS idx_local_vocab_book ON local_vocabulary_occurrences(book_id, chapter_id);",
        "CREATE INDEX IF NOT EXISTS idx_local_vocab_canonical_id ON local_vocabulary_occurrences(lower(id));",
        "CREATE INDEX IF NOT EXISTS idx_local_review_cards_vocab ON local_review_cards(vocabulary_id);",
        "CREATE INDEX IF NOT EXISTS idx_local_review_cards_canonical_vocab ON local_review_cards(lower(vocabulary_id));",
        "CREATE INDEX IF NOT EXISTS idx_local_review_events_vocab ON local_review_events(vocabulary_id, reviewed_at);",
        "CREATE INDEX IF NOT EXISTS idx_local_review_events_canonical_vocab ON local_review_events(lower(vocabulary_id));",
        "CREATE INDEX IF NOT EXISTS idx_local_review_events_card ON local_review_events(card_id);",
        "CREATE INDEX IF NOT EXISTS idx_local_assistant_chapter ON local_assistant_results(chapter_id, kind, status);",
        "CREATE INDEX IF NOT EXISTS idx_local_assistant_history_result ON local_assistant_result_history(result_id, sequence);",
        "CREATE INDEX IF NOT EXISTS idx_local_reader_progress_book ON local_reader_progress(book_id, is_current, updated_at);",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_local_reader_progress_current ON local_reader_progress(book_id) WHERE is_current = 1;"
    ]
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

    public init(
        id: String,
        vocabularyID: VocabularyOccurrenceID,
        face: String,
        reviewCount: Int,
        nextReview: Date?,
        lastReviewedAt: Date?,
        lastReviewQuality: String?,
        reviewIntervalDays: Double,
        reviewEaseFactor: Double
    ) {
        self.id = id
        self.vocabularyID = vocabularyID
        self.face = face
        self.reviewCount = reviewCount
        self.nextReview = nextReview
        self.lastReviewedAt = lastReviewedAt
        self.lastReviewQuality = lastReviewQuality
        self.reviewIntervalDays = reviewIntervalDays
        self.reviewEaseFactor = reviewEaseFactor
    }
}
