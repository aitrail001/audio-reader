import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { CORE_TABLES, GLOBAL_TABLES, PRIVATE_TABLES, SYNC_COLUMNS, SYNC_TABLES } from "./schema";
import { parsePostgresSchema } from "./schema-sql";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const migrationsDir = join(serverRoot, "supabase", "migrations");
const erNotesPath = join(serverRoot, "..", "docs", "architecture", "er-multi-user-schema.md");

const MIGRATION_NAME = /^\d{14}_[a-z0-9_]+\.sql$/;

const JSON_COLUMNS_ALLOWED = new Map<string, readonly string[]>([
  ["user_settings", ["field_clocks"]],
  ["transcript_revisions", ["quality", "ebook_alignment"]],
  ["assistant_cache_entries", ["result"]],
  ["sync_changes", ["payload"]],
  ["idempotency_records", ["response_headers"]],
  ["audit_events", ["metadata", "before_metadata", "after_metadata"]],
]);

function loadMigrationSql(): string {
  const files = readdirSync(migrationsDir)
    .filter((name) => name.endsWith(".sql"))
    .sort();
  return files.map((name) => readFileSync(join(migrationsDir, name), "utf8")).join("\n");
}

describe("multi-user postgres schema migrations", () => {
  it("tracks versioned SQL under server/supabase/migrations", () => {
    expect(existsSync(migrationsDir)).toBe(true);
    const files = readdirSync(migrationsDir)
      .filter((name) => name.endsWith(".sql"))
      .sort();
    expect(files.length).toBeGreaterThan(0);
    for (const file of files) {
      expect(file).toMatch(MIGRATION_NAME);
    }
  });

  it("creates every core table from the design", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    expect([...schema.tables.keys()].sort()).toEqual([...CORE_TABLES].sort());
  });

  it("puts sync identity columns on synchronized private entities", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const tableName of SYNC_TABLES) {
      const table = schema.tables.get(tableName);
      expect(table, tableName).toBeDefined();
      if (table === undefined) {
        continue;
      }
      for (const column of SYNC_COLUMNS) {
        expect(table.columns.get(column), `${tableName}.${column}`).toBeDefined();
      }
      expect(table.columns.get("id")?.toLowerCase()).toContain("uuid");
      expect(table.columns.get("user_id")?.toLowerCase()).toContain("uuid");
      expect(table.columns.get("created_at")?.toLowerCase()).toContain("timestamptz");
      expect(table.columns.get("updated_at")?.toLowerCase()).toContain("timestamptz");
      expect(table.columns.get("server_version")?.toLowerCase()).toContain("bigint");
      expect(table.columns.get("deleted_at")?.toLowerCase()).toContain("timestamptz");
      expect(table.columns.get("last_mutation_id")?.toLowerCase()).toContain("uuid");
    }
  });

  it("gives every private table a relational user_id uuid", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const tableName of PRIVATE_TABLES) {
      const table = schema.tables.get(tableName);
      expect(table, tableName).toBeDefined();
      if (table === undefined) {
        continue;
      }
      const userId = table.columns.get("user_id");
      expect(userId, `${tableName}.user_id`).toBeDefined();
      expect(userId?.toLowerCase()).toMatch(/\buuid\b/);
      expect(userId?.toLowerCase()).toMatch(/\bnot null\b/);
    }
  });

  it("keeps global operational tables free of user_id", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const tableName of GLOBAL_TABLES) {
      const table = schema.tables.get(tableName);
      expect(table, tableName).toBeDefined();
      expect(table?.columns.has("user_id"), tableName).toBe(false);
    }
  });

  it("uses foreign keys for ownership and library structure", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    const required = [
      ["devices", "profiles"],
      ["user_settings", "profiles"],
      ["books", "profiles"],
      ["book_assets", "books"],
      ["chapters", "books"],
      ["reading_progress", "chapters"],
      ["transcript_revisions", "chapters"],
      ["transcript_segments", "transcript_revisions"],
      ["vocabulary_occurrences", "chapters"],
      ["known_lemmas", "profiles"],
      ["review_cards", "vocabulary_occurrences"],
      ["review_events", "vocabulary_occurrences"],
      ["user_assistant_results", "profiles"],
      ["assistant_jobs", "profiles"],
      ["usage_ledger", "profiles"],
      ["sync_changes", "profiles"],
      ["idempotency_records", "profiles"],
      ["admin_roles", "profiles"],
      ["privacy_requests", "profiles"],
      ["canonical_editions", "canonical_works"],
      ["books", "canonical_works"],
      ["books", "canonical_editions"],
      ["user_assistant_results", "assistant_cache_entries"],
      ["user_assistant_results", "assistant_jobs"],
    ] as const;

    for (const [tableName, refTable] of required) {
      const fks = schema.foreignKeys.filter(
        (fk) => fk.table === tableName && fk.refTable === refTable,
      );
      expect(fks.length, `${tableName} -> ${refTable}`).toBeGreaterThan(0);
    }
  });

  it("declares unique identities used by sync, cache, and devices", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    expect(schema.hasUnique("profiles", ["user_id"])).toBe(true);
    expect(schema.hasUnique("user_settings", ["user_id"])).toBe(true);
    expect(schema.hasUnique("canonical_editions", ["edition_fingerprint"])).toBe(true);
    expect(schema.hasUnique("sync_changes", ["user_id", "sequence"])).toBe(true);
    expect(schema.hasUnique("idempotency_records", ["user_id", "method", "pathname", "key"])).toBe(
      true,
    );
    expect(schema.hasUnique("assistant_cache_entries", ["cache_key"])).toBe(true);
    expect(schema.hasUnique("feature_flags", ["key"])).toBe(true);
    expect(schema.hasUnique("reading_progress", ["user_id", "chapter_id"])).toBe(true);
    expect(schema.hasUnique("known_lemmas", ["user_id", "language", "lemma"])).toBe(true);
  });

  it("indexes expected pull, due-review, and library lookup paths", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    expect(schema.hasIndex("books", ["user_id"])).toBe(true);
    expect(schema.hasIndex("chapters", ["book_id"])).toBe(true);
    expect(schema.hasIndex("book_assets", ["user_id", "sha256"])).toBe(true);
    expect(schema.hasIndex("vocabulary_occurrences", ["user_id", "book_id"])).toBe(true);
    expect(schema.hasIndex("review_cards", ["user_id", "due_at"])).toBe(true);
    expect(schema.hasIndex("review_events", ["user_id", "vocabulary_id"])).toBe(true);
    expect(schema.hasIndex("sync_changes", ["user_id", "sequence"])).toBe(true);
    expect(schema.hasIndex("transcript_segments", ["revision_id"])).toBe(true);
    expect(schema.hasIndex("assistant_jobs", ["user_id", "status"])).toBe(true);
    expect(schema.hasIndex("usage_ledger", ["user_id", "metric_key"])).toBe(true);
    expect(schema.hasIndex("audit_events", ["created_at"])).toBe(true);
  });

  it("uses a partial unique index so only one in-flight job owns a cache_key", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    const match = schema.indexes.find(
      (index) =>
        index.table === "assistant_jobs" &&
        index.unique &&
        index.columns[0] === "cache_key" &&
        (index.where?.includes("queued") ?? false) &&
        (index.where?.includes("running") ?? false),
    );
    expect(match).toBeDefined();
  });

  it("keeps authorization fields relational instead of arbitrary json", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const [tableName, table] of schema.tables) {
      const allowed = new Set(JSON_COLUMNS_ALLOWED.get(tableName) ?? []);
      for (const [column, definition] of table.columns) {
        if (!/\bjsonb?\b/i.test(definition)) {
          continue;
        }
        expect(allowed.has(column), `${tableName}.${column} jsonb`).toBe(true);
      }
    }
    const cache = schema.tables.get("assistant_cache_entries");
    expect(cache?.columns.has("source_text")).toBe(false);
    expect(cache?.columns.has("source_passage")).toBe(false);
    expect(cache?.columns.has("user_id")).toBe(false);
  });

  it("does not implement RLS policies in this schema PR", () => {
    const sql = loadMigrationSql().toLowerCase();
    expect(sql).not.toMatch(/enable row level security/);
    expect(sql).not.toMatch(/create policy/);
    expect(sql).not.toMatch(/force row level security/);
  });

  it("does not persist provider secrets as columns", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const [tableName, table] of schema.tables) {
      for (const column of table.columns.keys()) {
        expect(column, `${tableName}.${column}`).not.toMatch(
          /api_key|(^|_)password($|_)|(^|_)secret($|_)|(^|_)token$/,
        );
      }
    }
  });

  it("check-constrains operational enums instead of free-form text", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    expect(schema.hasCheck("profiles", "account_status")).toBe(true);
    expect(schema.hasCheck("devices", "platform")).toBe(true);
    expect(schema.hasCheck("books", "source")).toBe(true);
    expect(schema.hasCheck("book_assets", "kind")).toBe(true);
    expect(schema.hasCheck("book_assets", "status")).toBe(true);
    expect(schema.hasCheck("vocabulary_occurrences", "category")).toBe(true);
    expect(schema.hasCheck("vocabulary_occurrences", "state")).toBe(true);
    expect(schema.hasCheck("review_cards", "face")).toBe(true);
    expect(schema.hasCheck("user_assistant_results", "status")).toBe(true);
    expect(schema.hasCheck("assistant_jobs", "status")).toBe(true);
    expect(schema.hasCheck("assistant_cache_entries", "state")).toBe(true);
    expect(schema.hasCheck("admin_roles", "role")).toBe(true);
    expect(schema.hasCheck("privacy_requests", "kind")).toBe(true);
  });

  it("documents core tables in the ER notes", () => {
    expect(existsSync(erNotesPath)).toBe(true);
    const notes = readFileSync(erNotesPath, "utf8");
    for (const table of CORE_TABLES) {
      expect(notes, table).toContain(table);
    }
    expect(notes).toContain("user_id");
    expect(notes).toContain("server_version");
  });
});
