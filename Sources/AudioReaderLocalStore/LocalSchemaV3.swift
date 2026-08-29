import Foundation

/// Schema v3 is additive: immutable transcript revisions stay untouched while
/// one current correction overlay is stored per chapter/segment identity.
public enum LocalSchemaV3: Sendable {
    public static let version = 3

    public static let requiredTables = LocalSchemaV2.requiredTables + [
        "local_transcript_overlays",
        "local_transcript_overlay_conflicts",
        "local_reader_progress"
    ]

    static let createStatements = LocalSchemaV2.createStatements + [
        """
        CREATE TABLE IF NOT EXISTS local_transcript_overlays (
          id TEXT PRIMARY KEY,
          chapter_id TEXT NOT NULL,
          segment_id TEXT NOT NULL,
          base_fingerprint TEXT NOT NULL,
          corrected_text TEXT NOT NULL,
          corrected_start REAL NOT NULL,
          corrected_end REAL NOT NULL,
          provenance_json TEXT NOT NULL,
          updated_at REAL NOT NULL,
          server_version INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL,
          last_mutation_id TEXT,
          UNIQUE(chapter_id, segment_id)
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_local_overlays_chapter ON local_transcript_overlays(chapter_id, segment_id);",
        """
        CREATE TABLE IF NOT EXISTS local_transcript_overlay_conflicts (
          candidate_id TEXT PRIMARY KEY,
          chapter_id TEXT NOT NULL,
          segment_id TEXT NOT NULL,
          overlay_json TEXT NOT NULL,
          server_revision INTEGER NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_local_overlay_conflicts_segment ON local_transcript_overlay_conflicts(chapter_id, segment_id, updated_at);",
        """
        CREATE TABLE IF NOT EXISTS local_reader_progress (
          id TEXT PRIMARY KEY,
          book_id TEXT NOT NULL,
          chapter_id TEXT NOT NULL,
          relative_seconds REAL NOT NULL,
          updated_at REAL NOT NULL,
          device_id TEXT NOT NULL,
          revision INTEGER NOT NULL DEFAULT 0,
          is_current INTEGER NOT NULL DEFAULT 0
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_local_reader_progress_book ON local_reader_progress(book_id, is_current, updated_at);",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_local_reader_progress_current ON local_reader_progress(book_id) WHERE is_current = 1;"
    ]
}
