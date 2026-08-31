import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION,
  CORE_TABLES,
  GLOBAL_TABLES,
  OPTIONAL_OWNER_TABLES,
  PRIVATE_TABLES,
  SYNC_COLUMNS,
  SYNC_TABLES,
  TENANT_PARENT_TABLES,
  TRANSACTION_FUNCTIONS,
} from "./schema";
import { parsePostgresSchema, type ForeignKey } from "./schema-sql";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const migrationsDir = join(serverRoot, "supabase", "migrations");
const erNotesPath = join(serverRoot, "..", "docs", "architecture", "er-multi-user-schema.md");

const MIGRATION_NAME = /^\d{14}_[a-z0-9_]+\.sql$/;

const JSON_COLUMNS_ALLOWED = new Map<string, readonly string[]>([
  ["user_settings", ["field_clocks"]],
  ["transcript_revisions", ["quality", "ebook_alignment"]],
  ["assistant_cache_entries", ["result"]],
  ["user_assistant_results", ["history", "private_content"]],
  ["sync_changes", ["payload"]],
  ["sync_mutation_outcomes", ["problem"]],
  ["sync_v2_changes", ["payload"]],
  ["sync_v2_mutation_outcomes", ["problem"]],
  ["idempotency_records", ["response_headers"]],
  ["audit_events", ["metadata", "before_metadata", "after_metadata"]],
  ["operator_settings", ["payload"]],
  ["product_events", ["properties"]],
  ["user_progress_summaries", ["sync_entity_counts", "ai_uses_by_feature"]],
]);

function loadMigrationSql(): string {
  const files = readdirSync(migrationsDir)
    .filter((name) => name.endsWith(".sql"))
    .sort();
  return files.map((name) => readFileSync(join(migrationsDir, name), "utf8")).join("\n");
}

function columnIsNotNull(definition: string | undefined): boolean {
  if (definition === undefined) {
    return false;
  }
  const sql = definition.toLowerCase();
  return /\bnot null\b/.test(sql) || /\bprimary key\b/.test(sql);
}

function sameColumns(left: readonly string[], right: readonly string[]): boolean {
  return (
    left.length === right.length &&
    left.every((column, index) => column.toLowerCase() === (right[index] ?? "").toLowerCase())
  );
}

function hasForeignKey(
  schema: ReturnType<typeof parsePostgresSchema>,
  wanted: {
    table: string;
    columns: readonly string[];
    refTable: string;
    refColumns: readonly string[];
    onDelete?: string;
  },
): boolean {
  return schema.foreignKeys.some(
    (fk: ForeignKey) =>
      fk.table === wanted.table &&
      fk.refTable === wanted.refTable &&
      sameColumns(fk.columns, wanted.columns) &&
      sameColumns(fk.refColumns, wanted.refColumns) &&
      (wanted.onDelete === undefined || fk.onDelete === wanted.onDelete),
  );
}

describe("multi-user postgres schema migrations", () => {
  it("isolates v2 object manifests and sync history from every legacy table", () => {
    const sql = loadMigrationSql();
    const schema = parsePostgresSchema(sql);
    for (const table of [
      "asset_manifests_v2",
      "sync_v2_changes",
      "sync_v2_batches",
      "sync_v2_mutation_outcomes",
    ]) {
      expect(schema.tables.has(table), table).toBe(true);
    }
    expect(schema.hasUnique("asset_manifests_v2", ["object_key"])).toBe(true);
    expect(schema.hasUnique("asset_manifests_v2", ["user_id", "kind", "sha256"])).toBe(true);
    expect(schema.hasCheck("asset_manifests_v2", "kind")).toBe(true);
    expect(schema.hasCheck("asset_manifests_v2", "status")).toBe(true);
    expect(sql).toContain("function public.complete_v2_asset_and_publish");
    expect(sql).toMatch(/set status = 'deleting'[\s\S]*finish_v2_asset_upload_gc/i);
    expect(sql).not.toMatch(/insert into public\.asset_manifests_v2[\s\S]{0,500}transcript_json/i);
  });

  it("seeds account sync requested-off in a new environment", () => {
    expect(loadMigrationSql()).toMatch(/\('account_sync',\s*false,\s*100\)/i);
  });

  it("publishes an exact service-role-only account sync migration identity", () => {
    const sql = loadMigrationSql();
    expect(sql).toContain("create function public.account_sync_schema_version()");
    expect(sql).toContain(`'${ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION}'`);
    expect(sql).toContain(
      "grant execute on function public.account_sync_schema_version() to service_role",
    );
  });

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

  it("keeps already-applied migrations immutable", () => {
    const expected = new Map([
      [
        "20260826140030_assistant_cache_jobs_usage.sql",
        "86dbaba57b4b52524b72d30c06c7229ad56f51407c75681443662cfbb6966307",
      ],
      [
        "20260828130000_quota_limits.sql",
        "4520c1c822655417cc5b416eb51a07276806b094a6755898585eabc99099a5ae",
      ],
    ]);
    for (const [file, digest] of expected) {
      const sql = readFileSync(join(migrationsDir, file));
      expect(createHash("sha256").update(sql).digest("hex"), file).toBe(digest);
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
    for (const tableName of OPTIONAL_OWNER_TABLES) {
      const userId = schema.tables.get(tableName)?.columns.get("user_id");
      expect(userId, `${tableName}.user_id`).toBeDefined();
      expect(userId?.toLowerCase()).toMatch(/\buuid\b/);
      expect(userId?.toLowerCase()).not.toMatch(/\bnot null\b/);
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
      ["object_write_leases", "profiles"],
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
    expect(schema.hasUnique("canonical_works", ["normalized_title", "normalized_author"])).toBe(
      true,
    );
    expect(schema.hasUnique("model_policies", ["task", "region", "policy_version"])).toBe(true);
  });

  it("parses create function and trigger names", () => {
    const schema = parsePostgresSchema(`
      create function public.claim_assistant_generation(p_user_id uuid)
      returns jsonb
      language sql
      as $$ select jsonb_build_object('status', 'claimed'); $$;
      create trigger audit_events_protect
        before update or delete on public.audit_events
        for each row execute function public.protect_audit_events();
    `);
    expect(schema.functions).toEqual([{ schema: "public", name: "claim_assistant_generation" }]);
    expect(schema.triggers).toEqual([{ name: "audit_events_protect", table: "audit_events" }]);
  });

  it("parses NULLS NOT DISTINCT unique indexes", () => {
    const schema = parsePostgresSchema(`
      create table public.canonical_works (id uuid primary key);
      create unique index canonical_works_title_author_uidx
        on public.canonical_works (normalized_title, normalized_author)
        nulls not distinct;
    `);
    const index = schema.indexes.find((item) => item.name === "canonical_works_title_author_uidx");
    expect(index?.unique).toBe(true);
    expect(index?.nullsNotDistinct).toBe(true);
    expect(index?.columns).toEqual(["normalized_title", "normalized_author"]);
    expect(schema.hasUnique("canonical_works", ["normalized_title", "normalized_author"])).toBe(
      true,
    );
  });

  it("keeps chapter order unique deferrable so tombstones do not occupy slots", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    const chapters = schema.tables.get("chapters");
    expect(chapters).toBeDefined();
    const ordering = chapters?.uniques.find((unique) =>
      sameColumns(unique.columns, ["book_id", "index", "deleted_at"]),
    );
    expect(ordering?.nullsNotDistinct).toBe(true);
    expect(ordering?.deferrable).toBe(true);
    const blocking = schema.indexes.find(
      (index) =>
        index.table === "chapters" &&
        index.unique &&
        sameColumns(index.columns, ["book_id", "index"]) &&
        index.where === undefined,
    );
    expect(blocking).toBeUndefined();
  });

  it("uses composite tenant foreign keys onto UNIQUE (user_id, id) parents", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const tableName of TENANT_PARENT_TABLES) {
      expect(schema.hasUnique(tableName, ["user_id", "id"]), tableName).toBe(true);
    }
    expect(schema.hasUnique("book_assets", ["book_id", "id"])).toBe(true);
    expect(schema.hasUnique("chapters", ["book_id", "id"])).toBe(true);
    const required = [
      {
        table: "books",
        columns: ["user_id", "cover_asset_id"],
        refTable: "book_assets",
        refColumns: ["user_id", "id"],
      },
      {
        table: "book_assets",
        columns: ["user_id", "book_id"],
        refTable: "books",
        refColumns: ["user_id", "id"],
      },
      {
        table: "chapters",
        columns: ["user_id", "book_id"],
        refTable: "books",
        refColumns: ["user_id", "id"],
      },
      {
        table: "chapters",
        columns: ["book_id", "audio_asset_id"],
        refTable: "book_assets",
        refColumns: ["book_id", "id"],
      },
      {
        table: "reading_progress",
        columns: ["user_id", "chapter_id"],
        refTable: "chapters",
        refColumns: ["user_id", "id"],
      },
      {
        table: "transcript_revisions",
        columns: ["user_id", "chapter_id"],
        refTable: "chapters",
        refColumns: ["user_id", "id"],
      },
      {
        table: "transcript_segments",
        columns: ["user_id", "revision_id"],
        refTable: "transcript_revisions",
        refColumns: ["user_id", "id"],
      },
      {
        table: "vocabulary_occurrences",
        columns: ["user_id", "chapter_id"],
        refTable: "chapters",
        refColumns: ["user_id", "id"],
      },
      {
        table: "review_cards",
        columns: ["user_id", "vocabulary_id"],
        refTable: "vocabulary_occurrences",
        refColumns: ["user_id", "id"],
      },
      {
        table: "review_events",
        columns: ["user_id", "vocabulary_id"],
        refTable: "vocabulary_occurrences",
        refColumns: ["user_id", "id"],
      },
      {
        table: "privacy_requests",
        columns: ["user_id", "asset_id"],
        refTable: "book_assets",
        refColumns: ["user_id", "id"],
      },
      {
        table: "vocabulary_occurrences",
        columns: ["user_id", "translation_id"],
        refTable: "user_assistant_results",
        refColumns: ["user_id", "id"],
      },
      {
        table: "user_assistant_results",
        columns: ["book_id", "chapter_id"],
        refTable: "chapters",
        refColumns: ["book_id", "id"],
        onDelete: "set null",
      },
    ] as const;
    for (const fk of required) {
      expect(hasForeignKey(schema, fk), `${fk.table} (${fk.columns.join(", ")})`).toBe(true);
    }
  });

  it("composite set-null fks only null nullable columns", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    const mixed = schema.foreignKeys.filter(
      (fk) => fk.onDelete === "set null" && fk.columns.length > 1,
    );
    expect(mixed.length).toBeGreaterThan(0);
    for (const fk of mixed) {
      const table = schema.tables.get(fk.table);
      expect(table, fk.table).toBeDefined();
      if (table === undefined) {
        continue;
      }
      const notNullColumns = fk.columns.filter((column) =>
        columnIsNotNull(table.columns.get(column)),
      );
      const label = `${fk.table} (${fk.columns.join(", ")})`;
      if (notNullColumns.length === 0) {
        continue;
      }
      expect(fk.onDeleteColumns, label).toBeDefined();
      const named = fk.onDeleteColumns ?? [];
      expect(named.length, label).toBeGreaterThan(0);
      for (const column of named) {
        expect(fk.columns, `${label} SET NULL ${column}`).toContain(column);
        expect(notNullColumns, `${label} SET NULL ${column} is NOT NULL`).not.toContain(column);
      }
    }
  });

  it("does not cascade-delete in-flight assistant jobs with the claiming profile", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    expect(
      hasForeignKey(schema, {
        table: "assistant_jobs",
        columns: ["user_id"],
        refTable: "profiles",
        refColumns: ["user_id"],
        onDelete: "set null",
      }),
    ).toBe(true);
  });

  it("does not keep non-unique indexes that duplicate unique keys", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    const names = new Set(schema.indexes.map((index) => index.name));
    expect(names.has("transcript_revisions_chapter_idx")).toBe(false);
    expect(names.has("transcript_segments_revision_id_idx")).toBe(false);
    expect(names.has("sync_changes_user_sequence_idx")).toBe(false);
    expect(names.has("chapters_book_index_uidx")).toBe(false);
    expect(names.has("chapters_book_id_idx")).toBe(false);
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
    expect(schema.hasIndex("model_policies", ["task", "region"])).toBe(true);
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

  it("separates durable assistant result history from disposable shared cache content", () => {
    const sql = loadMigrationSql();
    expect(sql).toMatch(
      /alter table public\.user_assistant_results[\s\S]*add column if not exists history jsonb/i,
    );
    expect(sql).toMatch(
      /alter table public\.user_assistant_results[\s\S]*add column if not exists model text/i,
    );
    expect(sql).toMatch(
      /status in \('pending', 'accepted', 'rejected', 'stale', 'edited', 'replaced'\)/i,
    );
    expect(sql).toMatch(
      /cache_entry_id uuid references public\.assistant_cache_entries \(id\) on delete set null/i,
    );
    expect(sql).toMatch(/append_user_assistant_result_history/i);
  });

  it("documents core tables in the ER notes", () => {
    expect(existsSync(erNotesPath)).toBe(true);
    const notes = readFileSync(erNotesPath, "utf8");
    for (const table of CORE_TABLES) {
      expect(notes, table).toContain(table);
    }
    expect(notes).toContain("user_id");
    expect(notes).toContain("server_version");
    expect(notes).toMatch(/claim_assistant_generation/);
    expect(notes).toMatch(/append_audit_event/);
    expect(notes).toMatch(/immutable/i);
  });

  it("declares privileged transaction functions for idempotency, cache claims, sync, and audit", () => {
    const sql = loadMigrationSql();
    const schema = parsePostgresSchema(sql);
    const publicFunctions = new Set(
      schema.functions.filter((fn) => fn.schema === "public").map((fn) => fn.name),
    );
    for (const name of TRANSACTION_FUNCTIONS) {
      expect(publicFunctions.has(name), name).toBe(true);
      expect(sql).toMatch(new RegExp(`function\\s+public\\.${name}`, "i"));
      expect(sql).toMatch(new RegExp(`revoke\\s+all\\s+on\\s+function\\s+public\\.${name}`, "i"));
      expect(sql).toMatch(
        new RegExp(
          `grant\\s+execute\\s+on\\s+function\\s+public\\.${name}(?:\\([^)]*\\))?\\s+to\\s+service_role`,
          "i",
        ),
      );
    }
    for (const table of SYNC_TABLES) {
      expect(sql, table).toContain(`'${table}'`);
    }
    expect(schema.triggers.some((trigger) => trigger.table === "audit_events")).toBe(true);
    expect(sql).toMatch(/audit_events are immutable/i);
    expect(sql).toMatch(/security\s+definer/i);
  });
});
