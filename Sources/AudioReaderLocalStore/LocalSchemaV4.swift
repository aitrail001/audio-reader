import Foundation

/// Schema v4 persists derived-mirror repair intent beside sync cursors and versions.
/// A crash or write failure can therefore retry projections without replaying server history.
public enum LocalSchemaV4: Sendable {
    public static let version = 4

    public static let requiredTables = LocalSchemaV3.requiredTables + [
        "sync_mirror_repairs"
    ]

    static let createStatements = LocalSchemaV3.createStatements + [
        """
        CREATE TABLE IF NOT EXISTS sync_mirror_repairs (
          id TEXT PRIMARY KEY,
          changes_json TEXT NOT NULL,
          refresh_vocabulary INTEGER NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL
        );
        """
    ]
}
