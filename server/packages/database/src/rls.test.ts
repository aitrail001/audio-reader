import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startPostgres, type PostgresSession, type SqlResult } from "./postgres-harness";
import {
  CORE_TABLES,
  JWT_DENIED_TABLES,
  OPTIONAL_OWNER_TABLES,
  PRIVATE_TABLES,
  SERVER_ONLY_TABLES,
  USER_OWNED_TABLES,
  USER_READ_OWN_TABLES,
} from "./schema";
import { parsePostgresSchema, type PolicyDefinition } from "./schema-sql";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const migrationsDir = join(serverRoot, "supabase", "migrations");
const erNotesPath = join(serverRoot, "..", "docs", "architecture", "er-multi-user-schema.md");

const USER_A = "11111111-1111-4111-8111-111111111111";
const USER_B = "22222222-2222-4222-8222-222222222222";
const USER_SUSPENDED = "33333333-3333-4333-8333-333333333333";
const USER_GUESSED = "99999999-9999-4999-8999-999999999999";
const PROFILE_ONLY = "44444444-4444-4444-8444-444444444444";
const FRESH_PROFILE = "55555555-5555-4555-8555-555555555555";

const PRIVATE_WITH_OWNER = [...PRIVATE_TABLES, ...OPTIONAL_OWNER_TABLES] as const;
const INSERTABLE_PRIVATE = PRIVATE_WITH_OWNER.filter(
  (table) => table !== "profiles" && table !== "user_settings",
);

const DML_COMMANDS = ["select", "insert", "update", "delete"] as const;

function loadMigrationSql(): string {
  const files = readdirSync(migrationsDir)
    .filter((name) => name.endsWith(".sql"))
    .sort();
  return files.map((name) => readFileSync(join(migrationsDir, name), "utf8")).join("\n");
}

function sqlString(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function quoteTable(table: string): string {
  const allowed = new Set<string>(CORE_TABLES);
  if (!allowed.has(table)) {
    throw new Error(`unknown table ${table}`);
  }
  return `"${table}"`;
}

function covers(policy: PolicyDefinition, command: (typeof DML_COMMANDS)[number]): boolean {
  return policy.command === "all" || policy.command === command;
}

function authenticatedPolicies(policies: PolicyDefinition[], table: string): PolicyDefinition[] {
  return policies.filter(
    (policy) => policy.table === table && policy.roles.includes("authenticated"),
  );
}

function policyText(policy: PolicyDefinition): string {
  return `${policy.using ?? ""} ${policy.withCheck ?? ""}`;
}

function isOwnRowPolicy(policy: PolicyDefinition): boolean {
  const text = policyText(policy).toLowerCase();
  return text.includes("auth.uid()") && text.includes("user_id");
}

describe("row level isolation policies", () => {
  it("parses enable/force RLS and auth.uid policies", () => {
    const schema = parsePostgresSchema(`
      create table public.books (id uuid, user_id uuid);
      alter table public.books enable row level security;
      alter table public.books force row level security;
      create policy books_own on public.books
        for all to authenticated
        using (user_id = (select auth.uid()) and public.current_user_is_active())
        with check (user_id = (select auth.uid()) and public.current_user_is_active());
    `);
    expect(schema.rlsEnabled.has("books")).toBe(true);
    expect(schema.rlsForced.has("books")).toBe(true);
    expect(schema.policies).toHaveLength(1);
    expect(schema.policies[0]?.command).toBe("all");
    expect(schema.policies[0]?.roles).toEqual(["authenticated"]);
    expect(schema.policies[0]?.using).toMatch(/auth\.uid\(\)/);
    expect(schema.policies[0]?.withCheck).toMatch(/current_user_is_active/);
  });

  it("partitions core tables into owned, read-own, and server-only", () => {
    const union = [...USER_OWNED_TABLES, ...USER_READ_OWN_TABLES, ...SERVER_ONLY_TABLES];
    expect([...new Set(union)].sort()).toEqual([...CORE_TABLES].sort());
    expect(union).toHaveLength(CORE_TABLES.length);
    for (const table of JWT_DENIED_TABLES) {
      expect(SERVER_ONLY_TABLES).toContain(table);
    }
  });

  it("enables and forces RLS on every core table", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const table of CORE_TABLES) {
      expect(schema.rlsEnabled.has(table), `${table} enable`).toBe(true);
      expect(schema.rlsForced.has(table), `${table} force`).toBe(true);
    }
  });

  it("scopes user-owned table policies to auth.uid() for select/insert/update/delete", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const table of USER_OWNED_TABLES) {
      const policies = authenticatedPolicies(schema.policies, table);
      expect(policies.length, table).toBeGreaterThan(0);
      for (const command of DML_COMMANDS) {
        const match = policies.filter((policy) => covers(policy, command));
        expect(match.length, `${table} ${command}`).toBeGreaterThan(0);
        expect(
          match.every((policy) => isOwnRowPolicy(policy) && policy.roles.includes("authenticated")),
          `${table} ${command} auth.uid()`,
        ).toBe(true);
        expect(
          match.every((policy) => /current_user_is_active/i.test(policyText(policy))),
          `${table} ${command} active`,
        ).toBe(true);
      }
    }
  });

  it("lets users read their own jobs, usage, and sync rows but not write them", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const table of USER_READ_OWN_TABLES) {
      const policies = authenticatedPolicies(schema.policies, table);
      const select = policies.filter((policy) => covers(policy, "select"));
      expect(select.length, `${table} select`).toBeGreaterThan(0);
      expect(select.every(isOwnRowPolicy), `${table} select auth.uid()`).toBe(true);
      for (const command of ["insert", "update", "delete"] as const) {
        expect(
          policies.some((policy) => covers(policy, command)),
          `${table} ${command} denied`,
        ).toBe(false);
      }
    }
  });

  it("denies normal JWT policies on cache, model policy, admin roles, and audit", () => {
    const schema = parsePostgresSchema(loadMigrationSql());
    for (const table of SERVER_ONLY_TABLES) {
      expect(authenticatedPolicies(schema.policies, table), table).toEqual([]);
    }
  });

  it("defines a security definer active-user helper used by policies", () => {
    const sql = loadMigrationSql();
    expect(sql).toMatch(/create\s+or\s+replace\s+function\s+public\.current_user_is_active/i);
    expect(sql).toMatch(/security\s+definer/i);
    expect(sql).toMatch(/auth\.uid\s*\(/i);
  });

  it("counts only RLS 42501 and hidden rows as denial, not unique or FK errors", () => {
    expect(
      denied({
        ok: false,
        stdout: "",
        stderr: 'ERROR:  duplicate key value violates unique constraint "profiles_user_id_key"',
      }),
    ).toBe(false);
    expect(
      denied({
        ok: false,
        stdout: "",
        stderr:
          'ERROR:  insert or update on table "devices" violates foreign key constraint "devices_user_id_fkey"',
      }),
    ).toBe(false);
    expect(
      denied({
        ok: false,
        stdout: "",
        stderr: 'ERROR:  new row violates row-level security policy for table "books"',
      }),
    ).toBe(true);
    expect(
      denied({
        ok: false,
        stdout: "",
        stderr: "ERROR:  42501: permission denied for table admin_roles",
      }),
    ).toBe(true);
    expect(denied({ ok: true, stdout: "AR_RLS:0\n", stderr: "" })).toBe(true);
    expect(denied({ ok: true, stdout: "AR_RLS:1\n", stderr: "" })).toBe(false);
  });

  it("documents that service_role is server-side only", () => {
    expect(existsSync(erNotesPath)).toBe(true);
    const notes = readFileSync(erNotesPath, "utf8");
    expect(notes).toMatch(/row level security/i);
    expect(notes).toMatch(/auth\.uid\(\)/);
    expect(notes).toMatch(/service_role/);
    expect(notes).toMatch(/server-side/i);
    expect(notes).toMatch(/BYPASSRLS|bypass row-level/i);
    expect(notes).toMatch(/Private, user-filed[^\n]*privacy_requests/);
    expect(notes).not.toMatch(/Private, server-owned[^\n]*privacy_requests/);
    const wrangler = readFileSync(join(serverRoot, "apps", "api-worker", "wrangler.toml"), "utf8");
    expect(wrangler).not.toMatch(/SERVICE_ROLE/);
    const admin = readFileSync(join(serverRoot, "apps", "admin-web", "src", "app.tsx"), "utf8");
    expect(admin).not.toMatch(/SERVICE_ROLE|service_role/);
    const supabaseConfig = readFileSync(join(serverRoot, "supabase", "config.toml"), "utf8");
    expect(supabaseConfig).not.toMatch(/service_role/i);
  });
});

describe("row level isolation (postgres)", () => {
  let db: PostgresSession | undefined;
  let idsA: TenantIds;
  let idsB: TenantIds;
  let idsGuessed: TenantIds;
  let idsSuspended: TenantIds;

  beforeAll(async () => {
    db = await startPostgres();
    const migrated = db.exec(loadMigrationSql());
    if (!migrated.ok) {
      throw new Error(`migrations failed: ${migrated.stderr || migrated.stdout}`);
    }
    const seeded = db.exec(SEED_SQL);
    if (!seeded.ok) {
      throw new Error(`seed failed: ${seeded.stderr || seeded.stdout}`);
    }
    idsA = loadTenantIds(db, USER_A);
    idsB = loadTenantIds(db, USER_B);
    idsGuessed = loadTenantIds(db, USER_GUESSED);
    idsSuspended = loadTenantIds(db, USER_SUSPENDED);
  }, 180_000);

  afterAll(async () => {
    await db?.stop();
  });

  it("records ENABLE+FORCE RLS in pg_class for every core table", () => {
    const session = requireDb(db);
    const result = session.exec(`
      select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind = 'r'
        and (not c.relrowsecurity or not c.relforcerowsecurity)
      order by 1;
    `);
    expect(result.ok, result.stderr).toBe(true);
    expect(result.stdout.trim()).toBe("");
  });

  it.each(PRIVATE_WITH_OWNER)("user A cannot select/update/delete user B rows in %s", (table) => {
    const session = requireDb(db);
    expect(denied(countAs(session, USER_A, ownRows(table, USER_B)))).toBe(true);
    expect(denied(countAs(session, USER_A, updateOwnUserId(table, USER_B)))).toBe(true);
    expect(denied(countAs(session, USER_A, deleteOwnRows(table, USER_B)))).toBe(true);
  });

  it.each(PRIVATE_WITH_OWNER)("guessed UUIDs do not open %s", (table) => {
    const session = requireDb(db);
    const foreignId = idsB[idKey(table)];
    const guessedId = idsGuessed[idKey(table)];
    expect(denied(countAs(session, USER_A, rowsById(table, foreignId)))).toBe(true);
    expect(denied(countAs(session, USER_A, rowsById(table, guessedId)))).toBe(true);
    expect(denied(countAs(session, USER_A, updateById(table, foreignId)))).toBe(true);
    expect(denied(countAs(session, USER_A, updateById(table, guessedId)))).toBe(true);
    expect(denied(countAs(session, USER_A, deleteById(table, foreignId)))).toBe(true);
    expect(denied(countAs(session, USER_A, deleteById(table, guessedId)))).toBe(true);
  });

  it.each(INSERTABLE_PRIVATE)(
    "user A cannot insert a non-colliding %s row for another user",
    (table) => {
      const session = requireDb(db);
      expect(denied(countAs(session, USER_A, insertReturning(insertSql(table, idsB))))).toBe(true);
      expect(denied(countAs(session, USER_A, insertReturning(insertSql(table, idsGuessed))))).toBe(
        true,
      );
    },
  );

  it("does not let a user insert a profile or settings for another uid", () => {
    const session = requireDb(db);
    expect(
      denied(
        countAs(
          session,
          USER_A,
          insertReturning(
            `insert into profiles (user_id, display_name) values (${sqlString(FRESH_PROFILE)}, 'hijack')`,
          ),
        ),
      ),
    ).toBe(true);
    expect(
      denied(
        countAs(
          session,
          USER_A,
          insertReturning(
            `insert into user_settings (user_id) values (${sqlString(PROFILE_ONLY)})`,
          ),
        ),
      ),
    ).toBe(true);
  });

  it.each(USER_OWNED_TABLES)("active user A can select own rows in %s", (table) => {
    const session = requireDb(db);
    const result = countAs(session, USER_A, ownRows(table, USER_A));
    expect(result.ok, result.stderr).toBe(true);
    expect(parseMarker(result.stdout)).toBeGreaterThan(0);
  });

  it.each([...USER_READ_OWN_TABLES])("active user A can select own rows in %s", (table) => {
    const session = requireDb(db);
    const result = countAs(session, USER_A, ownRows(table, USER_A));
    expect(result.ok, result.stderr).toBe(true);
    expect(parseMarker(result.stdout)).toBeGreaterThan(0);
  });

  it("does not let a user assign their own admin role", () => {
    const session = requireDb(db);
    expect(denied(countAs(session, USER_A, insertReturning(insertSql("admin_roles", idsA))))).toBe(
      true,
    );
    expect(denied(countAs(session, USER_A, ownRows("admin_roles", USER_A)))).toBe(true);
  });

  it("does not let a user assign their own quota", () => {
    const session = requireDb(db);
    expect(denied(countAs(session, USER_A, insertReturning(insertSql("usage_ledger", idsA))))).toBe(
      true,
    );
    expect(denied(countAs(session, USER_A, updateOwnUserId("usage_ledger", USER_A)))).toBe(true);
    expect(denied(countAs(session, USER_A, deleteOwnRows("usage_ledger", USER_A)))).toBe(true);
  });

  it("does not let a user read cache entries, model policies, or audit events", () => {
    const session = requireDb(db);
    for (const table of JWT_DENIED_TABLES) {
      expect(
        denied(
          countAs(
            session,
            USER_A,
            `SELECT 'AR_RLS:' || (select count(*)::text from ${quoteTable(table)})`,
          ),
        ),
      ).toBe(true);
    }
  });

  it("blocks a suspended user from reading or writing their rows", () => {
    const session = requireDb(db);
    expect(denied(countAs(session, USER_SUSPENDED, ownRows("books", USER_SUSPENDED)))).toBe(true);
    expect(denied(countAs(session, USER_SUSPENDED, ownRows("profiles", USER_SUSPENDED)))).toBe(
      true,
    );
    expect(denied(countAs(session, USER_SUSPENDED, updateOwnUserId("books", USER_SUSPENDED)))).toBe(
      true,
    );
    expect(
      denied(
        countAs(session, USER_SUSPENDED, insertReturning(insertSql("known_lemmas", idsSuspended))),
      ),
    ).toBe(true);
    expect(
      denied(
        countAs(
          session,
          USER_SUSPENDED,
          `SELECT 'AR_RLS:' || (select count(*)::text from ${quoteTable("assistant_cache_entries")})`,
        ),
      ),
    ).toBe(true);
  });

  it("lets service_role bypass RLS for server-side access", () => {
    const session = requireDb(db);
    const books = countAsRole(
      session,
      "service_role",
      undefined,
      `SELECT 'AR_RLS:' || (select count(*)::text from books)`,
    );
    expect(books.ok, books.stderr).toBe(true);
    expect(parseMarker(books.stdout)).toBeGreaterThanOrEqual(4);
    const cache = countAsRole(
      session,
      "service_role",
      undefined,
      `SELECT 'AR_RLS:' || (select count(*)::text from assistant_cache_entries)`,
    );
    expect(cache.ok, cache.stderr).toBe(true);
    expect(parseMarker(cache.stdout)).toBeGreaterThan(0);
    const granted = countAsRole(
      session,
      "service_role",
      undefined,
      insertReturning(
        `insert into admin_roles (user_id, role) values (${sqlString(USER_A)}, 'superadmin')`,
      ),
    );
    expect(granted.ok, granted.stderr).toBe(true);
    expect(parseMarker(granted.stdout)).toBe(1);
    const quota = countAsRole(
      session,
      "service_role",
      undefined,
      insertReturning(
        `insert into usage_ledger (user_id, metric_key, quantity, unit) values (${sqlString(USER_A)}, 'tokens', 1, 'token')`,
      ),
    );
    expect(quota.ok, quota.stderr).toBe(true);
    expect(parseMarker(quota.stdout)).toBe(1);
  });
});

type TenantIds = {
  userId: string;
  profileId: string;
  deviceId: string;
  settingsId: string;
  bookId: string;
  assetId: string;
  chapterId: string;
  extraChapterId: string;
  progressId: string;
  revisionId: string;
  segmentId: string;
  vocabId: string;
  lemmaId: string;
  cardId: string;
  eventId: string;
  resultId: string;
  jobId: string;
  usageId: string;
  syncId: string;
  syncBatchId: string;
  syncOutcomeId: string;
  idempotencyId: string;
  adminRoleId: string;
  privacyId: string;
};

function idKey(table: string): keyof TenantIds {
  const keys: Record<string, keyof TenantIds> = {
    profiles: "profileId",
    devices: "deviceId",
    user_settings: "settingsId",
    books: "bookId",
    book_assets: "assetId",
    chapters: "chapterId",
    reading_progress: "progressId",
    transcript_revisions: "revisionId",
    transcript_segments: "segmentId",
    vocabulary_occurrences: "vocabId",
    known_lemmas: "lemmaId",
    review_cards: "cardId",
    review_events: "eventId",
    user_assistant_results: "resultId",
    assistant_jobs: "jobId",
    usage_ledger: "usageId",
    sync_changes: "syncId",
    sync_batches: "syncBatchId",
    sync_mutation_outcomes: "syncOutcomeId",
    idempotency_records: "idempotencyId",
    admin_roles: "adminRoleId",
    privacy_requests: "privacyId",
  };
  const key = keys[table];
  if (key === undefined) {
    throw new Error(`no id key for ${table}`);
  }
  return key;
}

function requireDb(db: PostgresSession | undefined): PostgresSession {
  if (db === undefined) {
    throw new Error("postgres session was not started");
  }
  return db;
}

function chapterAt(db: PostgresSession, userId: string, index: number): string {
  const result = db.exec(
    `select id::text from chapters where user_id = ${sqlString(userId)} and index = ${String(index)} limit 1;`,
  );
  if (!result.ok) {
    throw new Error(`chapter ${String(index)}: ${result.stderr || result.stdout}`);
  }
  const id = result.stdout.trim().split("\n").at(-1)?.trim();
  if (id === undefined || id.length === 0) {
    throw new Error(`no chapter ${String(index)} for ${userId}`);
  }
  return id;
}

function loadTenantIds(db: PostgresSession, userId: string): TenantIds {
  const one = (table: string): string => {
    const result = db.exec(
      `select id::text from ${quoteTable(table)} where user_id = ${sqlString(userId)} limit 1;`,
    );
    if (!result.ok) {
      throw new Error(`${table}: ${result.stderr || result.stdout}`);
    }
    const id = result.stdout.trim().split("\n").at(-1)?.trim();
    if (id === undefined || id.length === 0) {
      throw new Error(`no ${table} row for ${userId}`);
    }
    return id;
  };
  return {
    userId,
    profileId: one("profiles"),
    deviceId: one("devices"),
    settingsId: one("user_settings"),
    bookId: one("books"),
    assetId: one("book_assets"),
    chapterId: chapterAt(db, userId, 0),
    extraChapterId: chapterAt(db, userId, 2),
    progressId: one("reading_progress"),
    revisionId: one("transcript_revisions"),
    segmentId: one("transcript_segments"),
    vocabId: one("vocabulary_occurrences"),
    lemmaId: one("known_lemmas"),
    cardId: one("review_cards"),
    eventId: one("review_events"),
    resultId: one("user_assistant_results"),
    jobId: one("assistant_jobs"),
    usageId: one("usage_ledger"),
    syncId: one("sync_changes"),
    syncBatchId: one("sync_batches"),
    syncOutcomeId: one("sync_mutation_outcomes"),
    idempotencyId: one("idempotency_records"),
    adminRoleId: one("admin_roles"),
    privacyId: one("privacy_requests"),
  };
}

function parseMarker(stdout: string): number | undefined {
  const match = /AR_RLS:(\d+)/.exec(stdout);
  if (match?.[1] === undefined) {
    return undefined;
  }
  return Number(match[1]);
}

function denied(result: SqlResult): boolean {
  if (!result.ok) {
    return isRlsDeniedError(`${result.stderr} ${result.stdout}`);
  }
  return parseMarker(result.stdout) === 0;
}

function isRlsDeniedError(message: string): boolean {
  const text = message.toLowerCase();
  if (
    text.includes("duplicate key") ||
    text.includes("unique constraint") ||
    text.includes("violates foreign key") ||
    text.includes("violates unique")
  ) {
    return false;
  }
  return (
    text.includes("42501") ||
    text.includes("row-level security") ||
    text.includes("permission denied")
  );
}

function countAs(db: PostgresSession, userId: string, statement: string): SqlResult {
  return countAsRole(db, "authenticated", userId, statement);
}

function countAsRole(
  db: PostgresSession,
  role: string,
  userId: string | undefined,
  statement: string,
): SqlResult {
  const claims = JSON.stringify({
    role,
    ...(userId === undefined ? {} : { sub: userId }),
  });
  const subSql =
    userId === undefined
      ? `select set_config('request.jwt.claim.sub', '', true);`
      : `select set_config('request.jwt.claim.sub', ${sqlString(userId)}, true);`;
  return db.exec(`
BEGIN;
${subSql}
select set_config('request.jwt.claims', ${sqlString(claims)}, true);
SET LOCAL ROLE ${role};
${statement};
ROLLBACK;
`);
}

function ownRows(table: string, userId: string): string {
  return `SELECT 'AR_RLS:' || (select count(*)::text from ${quoteTable(table)} where user_id = ${sqlString(userId)})`;
}

function rowsById(table: string, id: string): string {
  return `SELECT 'AR_RLS:' || (select count(*)::text from ${quoteTable(table)} where id = ${sqlString(id)})`;
}

function updateOwnUserId(table: string, userId: string): string {
  return `WITH d AS (
    update ${quoteTable(table)} set user_id = user_id
    where user_id = ${sqlString(userId)}
    returning 1
  ) SELECT 'AR_RLS:' || (select count(*)::text from d)`;
}

function updateById(table: string, id: string): string {
  return `WITH d AS (
    update ${quoteTable(table)} set user_id = user_id
    where id = ${sqlString(id)}
    returning 1
  ) SELECT 'AR_RLS:' || (select count(*)::text from d)`;
}

function deleteOwnRows(table: string, userId: string): string {
  return `WITH d AS (
    delete from ${quoteTable(table)}
    where user_id = ${sqlString(userId)}
    returning 1
  ) SELECT 'AR_RLS:' || (select count(*)::text from d)`;
}

function deleteById(table: string, id: string): string {
  return `WITH d AS (
    delete from ${quoteTable(table)}
    where id = ${sqlString(id)}
    returning 1
  ) SELECT 'AR_RLS:' || (select count(*)::text from d)`;
}

function insertReturning(insert: string): string {
  return `WITH d AS (${insert} returning 1) SELECT 'AR_RLS:' || (select count(*)::text from d)`;
}

function insertSql(table: string, owner: TenantIds): string {
  const u = sqlString(owner.userId);
  const book = sqlString(owner.bookId);
  const chapter = sqlString(owner.chapterId);
  const revision = sqlString(owner.revisionId);
  const vocab = sqlString(owner.vocabId);
  const card = sqlString(owner.cardId);
  const extraChapter = sqlString(owner.extraChapterId);
  switch (table) {
    case "profiles":
      return `insert into profiles (user_id, display_name) values (${u}, 'hijack')`;
    case "devices":
      return `insert into devices (user_id, platform, app_version) values (${u}, 'ios', '0')`;
    case "user_settings":
      return `insert into user_settings (user_id) values (${u})`;
    case "books":
      return `insert into books (user_id, title, edition_fingerprint, fingerprint_version, source)
        values (${u}, 'hijack', 'fp-h', 1, 'files')`;
    case "book_assets":
      return `insert into book_assets (user_id, book_id, kind, content_type, size_bytes, sha256, status)
        values (${u}, ${book}, 'cover', 'image/png', 1, 'sha-hijack-${owner.userId}', 'ready')`;
    case "chapters":
      return `insert into chapters (user_id, book_id, index, title, chapter_fingerprint, duration_seconds)
        values (${u}, ${book}, 1, 'h', 'ch-h', 1)`;
    case "reading_progress":
      return `insert into reading_progress (user_id, book_id, chapter_id)
        values (${u}, ${book}, ${extraChapter})`;
    case "transcript_revisions":
      return `insert into transcript_revisions
        (user_id, book_id, chapter_id, version, engine, locale, chapter_fingerprint)
        values (${u}, ${book}, ${chapter}, 2, 'x', 'en', 'ch-h')`;
    case "transcript_segments":
      return `insert into transcript_segments
        (user_id, revision_id, chapter_id, sequence, start_seconds, end_seconds, spoken_text)
        values (${u}, ${revision}, ${chapter}, 1, 1, 2, 'x')`;
    case "vocabulary_occurrences":
      return `insert into vocabulary_occurrences
        (user_id, book_id, chapter_id, surface, lemma, category, context, timestamp_seconds, state)
        values (${u}, ${book}, ${chapter}, 'x', 'x', 'word', 'x', 0, 'unknown')`;
    case "known_lemmas":
      return `insert into known_lemmas (user_id, language, lemma, state)
        values (${u}, 'en', 'hijack-${owner.userId}', 'known')`;
    case "review_cards":
      return `insert into review_cards (user_id, vocabulary_id, face) values (${u}, ${vocab}, 'cloze')`;
    case "review_events":
      return `insert into review_events
        (user_id, vocabulary_id, card_id, face, rating, reviewed_at)
        values (${u}, ${vocab}, ${card}, 'cloze', 1, now())`;
    case "user_assistant_results":
      return `insert into user_assistant_results (user_id, task_type, status)
        values (${u}, 'translate', 'pending')`;
    case "assistant_jobs":
      return `insert into assistant_jobs (user_id, kind, status) values (${u}, 'translate', 'queued')`;
    case "usage_ledger":
      return `insert into usage_ledger (user_id, metric_key, quantity, unit)
        values (${u}, 'tokens', 999999, 'token')`;
    case "sync_changes":
      return `insert into sync_changes (user_id, sequence, entity_type, entity_id, operation)
        values (${u}, 99, 'books', 'x', 'upsert')`;
    case "sync_batches":
      return `insert into sync_batches (user_id, batch_id, mutation_fingerprint)
        values (${u}, gen_random_uuid(), 'hijack')`;
    case "sync_mutation_outcomes":
      return `insert into sync_mutation_outcomes
        (user_id, mutation_id, status, entity_revision, problem)
        values (${u}, gen_random_uuid(), 'rejected', null, '{"title":"Rejected"}'::jsonb)`;
    case "idempotency_records":
      return `insert into idempotency_records (user_id, key, method, pathname, fingerprint, status)
        values (${u}, 'idempotency-key-99xx', 'POST', '/v1/x', 'fp', 'completed')`;
    case "admin_roles":
      return `insert into admin_roles (user_id, role) values (${u}, 'superadmin')`;
    case "privacy_requests":
      return `insert into privacy_requests (user_id, kind, status)
        values (${u}, 'deletion', 'queued')`;
    default:
      throw new Error(`no insert for ${table}`);
  }
}

const SEED_SQL = `
create or replace function public._seed_user(p_user uuid, p_status text)
returns void
language plpgsql
as $$
declare
  v_book uuid;
  v_chapter uuid;
  v_revision uuid;
  v_vocab uuid;
  v_card uuid;
  v_job uuid;
begin
  insert into public.profiles (user_id, display_name, account_status)
  values (p_user, p_status || ' user', p_status);

  insert into public.devices (user_id, platform, app_version)
  values (p_user, 'macos', '1.0.0');

  insert into public.user_settings (user_id) values (p_user);

  insert into public.books (user_id, title, edition_fingerprint, fingerprint_version, source)
  values (p_user, 'Book ' || p_status, 'fp-' || p_user::text, 1, 'files')
  returning id into v_book;

  insert into public.book_assets (user_id, book_id, kind, content_type, size_bytes, sha256, status)
  values (p_user, v_book, 'audio', 'audio/mpeg', 1, 'sha-' || p_user::text, 'ready');

  insert into public.chapters (user_id, book_id, index, title, chapter_fingerprint, duration_seconds)
  values (p_user, v_book, 0, 'Ch 1', 'chfp-' || p_user::text, 60)
  returning id into v_chapter;

  insert into public.chapters (user_id, book_id, index, title, chapter_fingerprint, duration_seconds)
  values (p_user, v_book, 2, 'Ch 2', 'chfp2-' || p_user::text, 30);

  insert into public.reading_progress (user_id, book_id, chapter_id)
  values (p_user, v_book, v_chapter);

  insert into public.transcript_revisions (
    user_id, book_id, chapter_id, version, engine, locale, chapter_fingerprint
  ) values (p_user, v_book, v_chapter, 1, 'test', 'en', 'chfp-' || p_user::text)
  returning id into v_revision;

  insert into public.transcript_segments (
    user_id, revision_id, chapter_id, sequence, start_seconds, end_seconds, spoken_text
  ) values (p_user, v_revision, v_chapter, 0, 0, 1, 'hello');

  insert into public.vocabulary_occurrences (
    user_id, book_id, chapter_id, surface, lemma, category, context, timestamp_seconds, state
  ) values (p_user, v_book, v_chapter, 'hello', 'hello', 'word', 'hello world', 0, 'learning')
  returning id into v_vocab;

  insert into public.known_lemmas (user_id, language, lemma, state)
  values (p_user, 'en', 'hello', 'learning');

  insert into public.review_cards (user_id, vocabulary_id, face)
  values (p_user, v_vocab, 'recognition')
  returning id into v_card;

  insert into public.review_events (user_id, vocabulary_id, card_id, face, rating, reviewed_at)
  values (p_user, v_vocab, v_card, 'recognition', 2, now());

  insert into public.assistant_jobs (user_id, kind, status)
  values (p_user, 'translate', 'succeeded')
  returning id into v_job;

  insert into public.user_assistant_results (user_id, job_id, book_id, chapter_id, task_type, status)
  values (p_user, v_job, v_book, v_chapter, 'translate', 'accepted');

  insert into public.usage_ledger (user_id, metric_key, quantity, unit, job_id)
  values (p_user, 'tokens', 10, 'token', v_job);

  insert into public.sync_changes (user_id, sequence, entity_type, entity_id, operation)
  values (p_user, 1, 'books', v_book::text, 'upsert');

  insert into public.sync_batches (user_id, batch_id, mutation_fingerprint)
  values (p_user, gen_random_uuid(), 'seed');

  insert into public.sync_mutation_outcomes
    (user_id, mutation_id, status, entity_revision, problem)
  values (p_user, gen_random_uuid(), 'rejected', null, '{"title":"Rejected"}'::jsonb);

  insert into public.idempotency_records (user_id, key, method, pathname, fingerprint, status)
  values (p_user, 'idempotency-key-16', 'POST', '/v1/sync', 'fp', 'completed');

  insert into public.admin_roles (user_id, role)
  values (p_user, 'operator');

  insert into public.privacy_requests (user_id, kind, status)
  values (p_user, 'export', 'queued');
end;
$$;

select public._seed_user(${sqlString(USER_A)}::uuid, 'active');
select public._seed_user(${sqlString(USER_B)}::uuid, 'active');
select public._seed_user(${sqlString(USER_GUESSED)}::uuid, 'active');
select public._seed_user(${sqlString(USER_SUSPENDED)}::uuid, 'suspended');

insert into public.profiles (user_id, display_name, account_status)
values (${sqlString(PROFILE_ONLY)}::uuid, 'settings target', 'active');

insert into public.canonical_works (normalized_title, normalized_author)
values ('seed title', 'seed author');

insert into public.canonical_editions (work_id, edition_fingerprint, fingerprint_version)
select id, 'seed-edition', 1 from public.canonical_works limit 1;

insert into public.assistant_cache_entries (
  cache_key, task_type, source_language, target_language, state
) values ('seed-cache', 'translate', 'en', 'zh', 'active');

insert into public.feature_flags (key, enabled) values ('seed-flag', true);

insert into public.model_policies (
  task, region, model, prompt_version, schema_version, policy_version
) values ('translate', 'global', 'qwen', '1', '1', '1');

insert into public.audit_events (actor_type, action, resource_type, resource_id, reason)
values ('system', 'seed', 'system', 'seed', 'test seed');

drop function public._seed_user(uuid, text);
`;
