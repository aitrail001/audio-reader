import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startPostgres, type PostgresSession, type SqlResult } from "./postgres-harness";
import { TRANSACTION_FUNCTIONS } from "./schema";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const migrationsDir = join(serverRoot, "supabase", "migrations");

const USER_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const USER_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const DEVICE_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1";
const DEVICE_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1";
const KEY_A = "idempotency-key-aaaa";
const KEY_B = "idempotency-key-bbbb";

function loadMigrationSql(): string {
  const files = readdirSync(migrationsDir)
    .filter((name) => name.endsWith(".sql"))
    .sort();
  return files.map((name) => readFileSync(join(migrationsDir, name), "utf8")).join("\n");
}

function sqlString(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function sqlJson(value: unknown): string {
  return sqlString(JSON.stringify(value));
}

function requireDb(db: PostgresSession | undefined): PostgresSession {
  if (db === undefined) {
    throw new Error("postgres session was not started");
  }
  return db;
}

function execOk(db: PostgresSession, sql: string): string {
  const result = db.exec(sql);
  if (!result.ok) {
    throw new Error(result.stderr || result.stdout);
  }
  return result.stdout;
}

function parseJsonObject(stdout: string): Record<string, unknown> {
  const line = stdout
    .trim()
    .split("\n")
    .map((item) => item.trim())
    .filter((item) => item.length > 0)
    .at(-1);
  if (line === undefined) {
    throw new Error(`no json in ${stdout}`);
  }
  const value: unknown = JSON.parse(line);
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`expected object, got ${line}`);
  }
  return value as Record<string, unknown>;
}

function callJson(db: PostgresSession, sql: string): Record<string, unknown> {
  return parseJsonObject(execOk(db, sql));
}

function requireJsonObjectArray(value: unknown): Array<Record<string, unknown>> {
  if (
    !Array.isArray(value) ||
    value.some((item) => typeof item !== "object" || item === null || Array.isArray(item))
  ) {
    throw new Error("expected an array of JSON objects");
  }
  return value as Array<Record<string, unknown>>;
}

function requireJsonObject(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("expected a JSON object");
  }
  return value as Record<string, unknown>;
}

function scalar(db: PostgresSession, sql: string): string {
  return execOk(db, sql).trim().split("\n").at(-1)?.trim() ?? "";
}

const SEED_SQL = `
insert into public.profiles (user_id, display_name, account_status)
values
  (${sqlString(USER_A)}::uuid, 'user a', 'active'),
  (${sqlString(USER_B)}::uuid, 'user b', 'active');

insert into public.books (user_id, title, edition_fingerprint, fingerprint_version, source)
values
  (${sqlString(USER_A)}::uuid, 'Book A', 'fp-a', 1, 'files'),
  (${sqlString(USER_B)}::uuid, 'Book B', 'fp-b', 1, 'files');

insert into public.devices (id, user_id, platform, name, app_version)
values
  (${sqlString(DEVICE_A)}::uuid, ${sqlString(USER_A)}::uuid, 'macos', 'Mac A', '1.3.0'),
  (${sqlString(DEVICE_B)}::uuid, ${sqlString(USER_B)}::uuid, 'ipados', 'iPad B', '1.3.0');

insert into public.user_settings (user_id)
values (${sqlString(USER_A)}::uuid), (${sqlString(USER_B)}::uuid);
`;

describe("idempotency, cache claims, and audit transactions (postgres)", () => {
  let db: PostgresSession | undefined;
  let bookA: string;
  let bookB: string;

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
    bookA = scalar(db, `select id::text from books where user_id = ${sqlString(USER_A)}`);
    bookB = scalar(db, `select id::text from books where user_id = ${sqlString(USER_B)}`);
  }, 180_000);

  afterAll(async () => {
    await db?.stop();
  });

  it("does not grant transaction functions to authenticated JWTs", () => {
    const session = requireDb(db);
    const names = TRANSACTION_FUNCTIONS.map((name) => sqlString(name)).join(", ");
    const result = session.exec(`
      select p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in (${names})
        and has_function_privilege('authenticated', p.oid, 'EXECUTE')
      order by 1;
    `);
    expect(result.ok, result.stderr).toBe(true);
    expect(result.stdout.trim()).toBe("");
    const service = session.exec(`
      select count(*)::text
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in (${names})
        and has_function_privilege('service_role', p.oid, 'EXECUTE');
    `);
    expect(service.ok, service.stderr).toBe(true);
    expect(service.stdout.trim()).toBe(String(TRANSACTION_FUNCTIONS.length));
  });

  it.each([
    ["nested media bytes", {
      localId: "book-a", title: "Book", source: "files",
      chapters: [{ localId: "chapter-a", index: 0, title: "One", audioData: "AAAA" }],
    }],
    ["unknown nested field", {
      localId: "book-a", title: "Book", source: "files",
      chapters: [{ localId: "chapter-a", index: 0, title: "One", surprise: true }],
    }],
    ["unknown top-level field", {
      localId: "book-a", title: "Book", source: "files", chapters: [], transcriptData: "{}",
    }],
  ])("rejects v2 RPC bypass payload with %s without advancing its cursor", (_label, payload) => {
    const session = requireDb(db);
    const before = scalar(
      session,
      `select count(*)::text from public.sync_v2_changes where user_id = ${sqlString(USER_A)}::uuid`,
    );
    const result = session.exec(`select public.push_sync_v2_batch(
      ${sqlString(USER_A)}::uuid,
      ${sqlString(DEVICE_A)}::uuid,
      gen_random_uuid(),
      ${sqlJson([{
        mutationId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        entityType: "book",
        entityId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        operation: "upsert",
        baseRevision: 0,
        occurredAt: "2026-08-31T00:00:00Z",
        payload,
      }])}::jsonb
    )`);
    expect(result.ok).toBe(false);
    expect(result.stderr).toMatch(/recursive compact entity schema|outside its entity schema|large immutable content/i);
    expect(scalar(
      session,
      `select count(*)::text from public.sync_v2_changes where user_id = ${sqlString(USER_A)}::uuid`,
    )).toBe(before);
  });

  it("rejects an unknown v2 entity type with an empty payload without advancing its cursor", () => {
    const session = requireDb(db);
    const before = scalar(
      session,
      `select count(*)::text from public.sync_v2_changes where user_id = ${sqlString(USER_A)}::uuid`,
    );
    const result = session.exec(`select public.push_sync_v2_batch(
      ${sqlString(USER_A)}::uuid,
      ${sqlString(DEVICE_A)}::uuid,
      gen_random_uuid(),
      ${sqlJson([{
        mutationId: "88888888-8888-4888-8888-888888888888",
        entityType: "unknown_empty_entity",
        entityId: "89898989-8989-4989-8989-898989898989",
        operation: "upsert",
        baseRevision: 0,
        occurredAt: "2026-08-31T00:00:00Z",
        payload: {},
      }])}::jsonb
    )`);
    expect(result.ok).toBe(false);
    expect(result.stderr).toMatch(/unsupported v2 entity type/i);
    expect(scalar(
      session,
      `select count(*)::text from public.sync_v2_changes where user_id = ${sqlString(USER_A)}::uuid`,
    )).toBe(before);
  });

  it("dry-runs and idempotently executes complete per-user v1 cleanup", () => {
    const session = requireDb(db);
    const userId = "99999999-9999-4999-8999-999999999999";
    const bookId = "11111111-1111-4111-8111-111111111111";
    const chapterId = "22222222-2222-4222-8222-222222222222";
    const revisionId = "33333333-3333-4333-8333-333333333333";
    execOk(session, `
      insert into public.profiles (user_id, display_name, account_status)
      values (${sqlString(userId)}::uuid, 'legacy cleanup', 'active');
      insert into public.books (
        id, user_id, title, edition_fingerprint, fingerprint_version, source
      ) values (
        ${sqlString(bookId)}::uuid, ${sqlString(userId)}::uuid,
        'Legacy', 'legacy-cleanup-fingerprint', 1, 'files'
      );
      insert into public.book_assets (
        id, user_id, book_id, kind, content_type, size_bytes, sha256, status, object_key
      ) values (
        '55555555-5555-4555-8555-555555555555'::uuid,
        ${sqlString(userId)}::uuid, ${sqlString(bookId)}::uuid,
        'audio', 'audio/mp4', 4, repeat('a', 64), 'ready',
        ${sqlString(`${userId}/legacy-audio.m4b`)}
      );
      insert into public.chapters (
        id, user_id, book_id, index, title, chapter_fingerprint, duration_seconds
      ) values (
        ${sqlString(chapterId)}::uuid, ${sqlString(userId)}::uuid,
        ${sqlString(bookId)}::uuid, 0, 'One', 'legacy-chapter', 1
      );
      insert into public.transcript_revisions (
        id, user_id, book_id, chapter_id, version, engine, locale,
        chapter_fingerprint, object_key, is_active
      ) values (
        ${sqlString(revisionId)}::uuid, ${sqlString(userId)}::uuid,
        ${sqlString(bookId)}::uuid, ${sqlString(chapterId)}::uuid,
        1, 'legacy', 'en', 'legacy-chapter',
        ${sqlString(`${userId}/legacy-transcript.json`)}, true
      );
      insert into public.transcript_segments (
        id, user_id, revision_id, chapter_id, sequence, start_seconds, end_seconds, spoken_text
      ) values (
        '44444444-4444-4444-8444-444444444444'::uuid,
        ${sqlString(userId)}::uuid, ${sqlString(revisionId)}::uuid,
        ${sqlString(chapterId)}::uuid, 0, 0, 1, 'legacy bytes'
      );
      insert into public.sync_changes (
        user_id, sequence, entity_type, entity_id, operation, revision, payload
      ) values (${sqlString(userId)}::uuid, 1, 'book', ${sqlString(bookId)}, 'upsert', 1, '{}');
      insert into public.sync_batches (user_id, batch_id, mutation_fingerprint)
      values (
        ${sqlString(userId)}::uuid, '66666666-6666-4666-8666-666666666666'::uuid, 'legacy'
      );
      insert into public.sync_mutation_outcomes (
        user_id, mutation_id, status, problem
      ) values (
        ${sqlString(userId)}::uuid,
        '77777777-7777-4777-8777-777777777777'::uuid, 'rejected', '{}'
      );
    `);

    const inspected = callJson(
      session,
      `select public.cleanup_obsolete_v1_data(${sqlString(userId)}::uuid, false)`,
    );
    expect(inspected).toMatchObject({
      changes: 1, outcomes: 1, batches: 1, transcriptRevisions: 1,
      transcriptSegments: 1, assets: 1, executed: false,
    });
    expect(inspected.objectKeys).toEqual([
      `${userId}/legacy-audio.m4b`,
      `${userId}/legacy-transcript.json`,
    ]);
    expect(scalar(
      session,
      `select count(*)::text from public.book_assets where user_id = ${sqlString(userId)}::uuid`,
    )).toBe("1");

    const executed = callJson(
      session,
      `select public.cleanup_obsolete_v1_data(${sqlString(userId)}::uuid, true)`,
    );
    expect(executed).toMatchObject({ changes: 1, transcriptSegments: 1, assets: 1, executed: true });
    expect(callJson(
      session,
      `select public.cleanup_obsolete_v1_data(${sqlString(userId)}::uuid, true)`,
    )).toMatchObject({
      changes: 0, outcomes: 0, batches: 0, transcriptRevisions: 0,
      transcriptSegments: 0, assets: 0, objectKeys: [], executed: true,
    });
  });

  it("records an idempotency response and replays it for the same fingerprint", () => {
    const session = requireDb(db);
    const claimed = callJson(
      session,
      `select public.claim_idempotency_record(
        ${sqlString(USER_A)}::uuid, ${sqlString(KEY_A)}, 'POST', '/v1/sync/push', 'fp-1'
      )`,
    );
    expect(claimed.status).toBe("claimed");
    const recorded = callJson(
      session,
      `select public.record_idempotency_response(
        ${sqlString(USER_A)}::uuid, ${sqlString(KEY_A)}, 'POST', '/v1/sync/push', 'fp-1',
        201, ${sqlJson({ "content-type": "application/json" })}::jsonb, '{"ok":true}'
      )`,
    );
    expect(recorded.status).toBe("completed");
    expect(recorded.response_status).toBe(201);
    expect(recorded.response_body).toBe('{"ok":true}');
    const replay = callJson(
      session,
      `select public.claim_idempotency_record(
        ${sqlString(USER_A)}::uuid, ${sqlString(KEY_A)}, 'POST', '/v1/sync/push', 'fp-1'
      )`,
    );
    expect(replay.status).toBe("replay");
    expect(replay.response_status).toBe(201);
    expect(replay.response_body).toBe('{"ok":true}');
  });

  it("rejects idempotency key reuse with a different fingerprint and aborts in-progress claims", () => {
    const session = requireDb(db);
    const claimed = callJson(
      session,
      `select public.claim_idempotency_record(
        ${sqlString(USER_A)}::uuid, ${sqlString(KEY_B)}, 'POST', '/v1/jobs', 'fp-same'
      )`,
    );
    expect(claimed.status).toBe("claimed");
    const inProgress = callJson(
      session,
      `select public.claim_idempotency_record(
        ${sqlString(USER_A)}::uuid, ${sqlString(KEY_B)}, 'POST', '/v1/jobs', 'fp-same'
      )`,
    );
    expect(inProgress.status).toBe("in_progress");
    const conflict = callJson(
      session,
      `select public.claim_idempotency_record(
        ${sqlString(USER_A)}::uuid, ${sqlString(KEY_B)}, 'POST', '/v1/jobs', 'fp-other'
      )`,
    );
    expect(conflict.status).toBe("conflict");
    const aborted = callJson(
      session,
      `select public.abort_idempotency_record(
        ${sqlString(USER_A)}::uuid, ${sqlString(KEY_B)}, 'POST', '/v1/jobs', 'fp-same'
      )`,
    );
    expect(aborted.status).toBe("aborted");
    const reclaimed = callJson(
      session,
      `select public.claim_idempotency_record(
        ${sqlString(USER_A)}::uuid, ${sqlString(KEY_B)}, 'POST', '/v1/jobs', 'fp-other'
      )`,
    );
    expect(reclaimed.status).toBe("claimed");
  });

  it("appends a sync change and increments the entity server_version", () => {
    const session = requireDb(db);
    const first = callJson(
      session,
      `select public.append_sync_change(
        ${sqlString(USER_A)}::uuid, 'books', ${sqlString(bookA)}, 'upsert',
        '11111111-1111-4111-8111-111111111111'::uuid, '{"title":"Book A"}'::jsonb
      )`,
    );
    expect(first.status).toBe("appended");
    expect(first.sequence).toBe(1);
    expect(first.revision).toBe(1);
    const second = callJson(
      session,
      `select public.append_sync_change(
        ${sqlString(USER_A)}::uuid, 'books', ${sqlString(bookA)}, 'upsert',
        '22222222-2222-4222-8222-222222222222'::uuid, '{"title":"Book A2"}'::jsonb
      )`,
    );
    expect(second.status).toBe("appended");
    expect(second.sequence).toBe(2);
    expect(second.revision).toBe(2);
    const replay = callJson(
      session,
      `select public.append_sync_change(
        ${sqlString(USER_A)}::uuid, 'books', ${sqlString(bookA)}, 'upsert',
        '11111111-1111-4111-8111-111111111111'::uuid, '{"title":"ignored"}'::jsonb
      )`,
    );
    expect(replay.status).toBe("replay");
    expect(replay.sequence).toBe(1);
    expect(replay.revision).toBe(1);
    expect(
      scalar(session, `select server_version::text from books where id = ${sqlString(bookA)}`),
    ).toBe("2");
    const removed = callJson(
      session,
      `select public.append_sync_change(
        ${sqlString(USER_A)}::uuid, 'books', ${sqlString(bookA)}, 'delete',
        '33333333-3333-4333-8333-333333333333'::uuid, '{}'::jsonb
      )`,
    );
    expect(removed.status).toBe("appended");
    expect(removed.sequence).toBe(3);
    expect(
      scalar(
        session,
        `select (deleted_at is not null)::text from books where id = ${sqlString(bookA)}`,
      ),
    ).toBe("true");
  });

  it("applies a sync batch atomically with replay, revisions, and settings CAS", () => {
    const session = requireDb(db);
    execOk(
      session,
      `update public.user_settings
       set server_version = 3, appearance = 'dark'
       where user_id = ${sqlString(USER_A)}::uuid`,
    );
    const batchId = "44444444-4444-4444-8444-444444444444";
    const mutations = [
      {
        mutationId: "55555555-5555-4555-8555-555555555551",
        entityType: "progress",
        entityId: "chapter-one",
        operation: "upsert",
        baseRevision: 0,
        occurredAt: "2026-08-30T09:45:00Z",
        payload: { positionSeconds: 10 },
      },
      {
        mutationId: "55555555-5555-4555-8555-555555555552",
        entityType: "progress",
        entityId: "chapter-one",
        operation: "upsert",
        baseRevision: 1,
        occurredAt: "2026-08-30T09:45:01Z",
        payload: { positionSeconds: 20 },
      },
      {
        mutationId: "55555555-5555-4555-8555-555555555553",
        entityType: "settings",
        entityId: USER_A,
        operation: "upsert",
        baseRevision: 3,
        occurredAt: "2026-08-30T09:45:02Z",
        payload: { targetLanguage: "ja", appearance: "system" },
      },
    ];
    const first = callJson(
      session,
      `select public.push_sync_batch(
        ${sqlString(USER_A)}::uuid,
        ${sqlString(DEVICE_A)}::uuid,
        ${sqlString(batchId)}::uuid,
        ${sqlJson(mutations)}::jsonb
      )`,
    );
    expect(first.batchId).toBe(batchId);
    expect(first.results).toEqual([
      expect.objectContaining({ status: "applied", entityRevision: 1 }),
      expect.objectContaining({ status: "applied", entityRevision: 2 }),
      expect.objectContaining({ status: "applied", entityRevision: 4 }),
    ]);
    expect(
      scalar(
        session,
        `select target_language || ':' || appearance || ':' || server_version::text
         from user_settings where user_id = ${sqlString(USER_A)}::uuid`,
      ),
    ).toBe("ja:system:4");

    const replay = callJson(
      session,
      `select public.push_sync_batch(
        ${sqlString(USER_A)}::uuid,
        ${sqlString(DEVICE_A)}::uuid,
        ${sqlString(batchId)}::uuid,
        ${sqlJson(mutations)}::jsonb
      )`,
    );
    expect(replay.cursor).toBe(first.cursor);
    expect(replay.results).toEqual([
      expect.objectContaining({ status: "duplicate", entityRevision: 1 }),
      expect.objectContaining({ status: "duplicate", entityRevision: 2 }),
      expect.objectContaining({ status: "duplicate", entityRevision: 4 }),
    ]);

    const mismatchedReplay = session.exec(
      `select public.push_sync_batch(
        ${sqlString(USER_A)}::uuid,
        ${sqlString(DEVICE_A)}::uuid,
        ${sqlString(batchId)}::uuid,
        ${sqlJson([
          {
            ...mutations[0],
            mutationId: "55555555-5555-4555-8555-555555555559",
          },
        ])}::jsonb
      )`,
    );
    expect(mismatchedReplay.ok).toBe(false);
    expect(mismatchedReplay.stderr).toContain("batchId was already used for different mutations");

    const rejectedDelete = callJson(
      session,
      `select public.push_sync_batch(
        ${sqlString(USER_A)}::uuid,
        ${sqlString(DEVICE_A)}::uuid,
        '66666666-6666-4666-8666-666666666666'::uuid,
        ${sqlJson([
          {
            mutationId: "77777777-7777-4777-8777-777777777777",
            entityType: "settings",
            entityId: USER_A,
            operation: "delete",
            baseRevision: 4,
            occurredAt: "2026-08-30T09:45:03Z",
            payload: {},
          },
        ])}::jsonb
      )`,
    );
    expect(rejectedDelete.results).toEqual([
      expect.objectContaining({ status: "rejected", entityRevision: null }),
    ]);
    expect(
      scalar(
        session,
        `select server_version::text from user_settings where user_id = ${sqlString(USER_A)}::uuid`,
      ),
    ).toBe("4");
  });

  it("materializes a bounded progress summary without returning synced reading content", () => {
    const session = requireDb(db);
    const batchId = "12121212-1212-4212-8212-121212121212";
    const mutations = [
      {
        mutationId: "13131313-1313-4313-8313-131313131311",
        entityType: "book",
        entityId: "book-safe-summary",
        operation: "upsert",
        baseRevision: 0,
        occurredAt: "2026-08-30T10:00:00Z",
        payload: {
          localId: "book-local",
          title: "PRIVATE BOOK TITLE",
          chapters: [
            { localId: "chapter-one", title: "PRIVATE CHAPTER", duration: 100 },
            { localId: "chapter-two", title: "PRIVATE CHAPTER TWO", duration: 200 },
          ],
        },
      },
      {
        mutationId: "13131313-1313-4313-8313-131313131312",
        entityType: "progress",
        entityId: "reader-progress-safe-summary",
        operation: "upsert",
        baseRevision: 0,
        occurredAt: "2026-08-30T10:01:00Z",
        payload: {
          progressKind: "reader",
          localBookId: "book-local",
          localChapterId: "chapter-two",
          relativeSeconds: 100,
        },
      },
      {
        mutationId: "13131313-1313-4313-8313-131313131313",
        entityType: "vocabulary",
        entityId: "vocab-safe-summary",
        operation: "upsert",
        baseRevision: 0,
        occurredAt: "2026-08-30T10:02:00Z",
        payload: {
          context: "PRIVATE SENTENCE CONTEXT",
          definition: "PRIVATE DEFINITION",
          state: "learning",
        },
      },
      {
        mutationId: "13131313-1313-4313-8313-131313131314",
        entityType: "progress",
        entityId: "vocab-safe-summary",
        operation: "upsert",
        baseRevision: 0,
        occurredAt: "2026-08-30T10:03:00Z",
        payload: {
          vocabularyId: "vocab-safe-summary",
          reviewCount: 2,
          nextReview: "2026-08-29T10:03:00Z",
          reviewIntervalDays: 2,
        },
      },
      {
        mutationId: "13131313-1313-4313-8313-131313131315",
        entityType: "review_event",
        entityId: "review-safe-summary",
        operation: "append",
        baseRevision: 0,
        occurredAt: "2026-08-30T10:04:00Z",
        payload: { vocabularyId: "vocab-safe-summary", rating: "remember" },
      },
      {
        mutationId: "13131313-1313-4313-8313-131313131316",
        entityType: "lexeme_state",
        entityId: "lemma-safe-summary",
        operation: "upsert",
        baseRevision: 0,
        occurredAt: "2026-08-30T10:05:00Z",
        payload: { lemma: "PRIVATE WORD", state: "known" },
      },
    ];
    callJson(
      session,
      `select public.push_sync_batch(
        ${sqlString(USER_A)}::uuid,
        ${sqlString(DEVICE_A)}::uuid,
        ${sqlString(batchId)}::uuid,
        ${sqlJson(mutations)}::jsonb
      )`,
    );
    execOk(
      session,
      `update public.sync_batches set device_id = ${sqlString(DEVICE_A)}::uuid
       where user_id = ${sqlString(USER_A)}::uuid and batch_id = ${sqlString(batchId)}::uuid`,
    );
    callJson(
      session,
      `select public.set_user_analytics_preference(${sqlString(USER_A)}::uuid, true)`,
    );

    const summary = callJson(
      session,
      `select public.admin_user_progress_summary(${sqlString(USER_A)}::uuid)`,
    );
    expect(summary).toMatchObject({
      sync: { lastDevice: { id: DEVICE_A, platform: "macos" } },
      reading: { activeBooks: 1, completedBooks: 0, currentChapter: 2 },
      review: { due: 1, learning: 1, reviewsLast30Days: 1, retentionRate: 1 },
      learning: { vocabulary: 1, known: 1 },
    });
    expect(JSON.stringify(summary)).not.toMatch(/PRIVATE|context|definition|title/i);
    expect(
      scalar(
        session,
        `select count(*)::text from public.user_progress_summaries
         where user_id = ${sqlString(USER_A)}::uuid and expires_at > generated_at`,
      ),
    ).toBe("1");
  });

  it("does not materialize detailed analytics without consent and deletes snapshots on opt-out", () => {
    const session = requireDb(db);
    const disabled = callJson(
      session,
      `select public.set_user_analytics_preference(${sqlString(USER_A)}::uuid, false)`,
    );
    expect(disabled.operatorLearningAnalyticsEnabled).toBe(false);
    expect(
      scalar(
        session,
        `select count(*)::text from public.user_analytics_preferences
         where user_id = ${sqlString(USER_A)}::uuid`,
      ),
    ).toBe("1");
    expect(
      scalar(
        session,
        `select count(*)::text from public.user_progress_summaries
         where user_id = ${sqlString(USER_A)}::uuid`,
      ),
    ).toBe("0");
    const safe = callJson(
      session,
      `select public.admin_user_progress_summary(${sqlString(USER_A)}::uuid)`,
    );
    expect(safe).toMatchObject({ reading: null, review: null, learning: null });
    expect(safe.sync).toEqual(expect.any(Object));
    expect(
      scalar(
        session,
        `select count(*)::text from public.user_progress_summaries
         where user_id = ${sqlString(USER_A)}::uuid`,
      ),
    ).toBe("0");
  });

  it("purges expired progress snapshots independently", () => {
    const session = requireDb(db);
    execOk(
      session,
      `insert into public.user_progress_summaries (user_id, expires_at)
       values (${sqlString(USER_B)}::uuid, clock_timestamp() - interval '1 second')
       on conflict (user_id) do update set expires_at = excluded.expires_at`,
    );
    expect(scalar(session, "select public.purge_expired_user_progress_summaries()::text")).toBe(
      "1",
    );
  });

  it("requires analytics consent, purges learner rows on opt-out, and retains events for 90 days", () => {
    const session = requireDb(db);
    execOk(session, `delete from public.product_events where user_id = ${sqlString(USER_B)}::uuid`);
    callJson(
      session,
      `select public.set_user_analytics_preference(${sqlString(USER_B)}::uuid, false)`,
    );

    const denied = session.exec(
      `insert into public.product_events (user_id, name, purpose)
       values (${sqlString(USER_B)}::uuid, 'reading.session.completed', 'learning_analytics')`,
    );
    expect(denied.ok).toBe(false);
    expect(`${denied.stderr}${denied.stdout}`).toContain("learning analytics consent is required");

    execOk(
      session,
      `insert into public.product_events (user_id, name, purpose, created_at)
       values (${sqlString(USER_B)}::uuid, 'security.session_revoked', 'operational',
               clock_timestamp() - interval '91 days')`,
    );
    callJson(
      session,
      `select public.set_user_analytics_preference(${sqlString(USER_B)}::uuid, true)`,
    );
    execOk(
      session,
      `insert into public.product_events (user_id, name, purpose, created_at)
       values
         (${sqlString(USER_B)}::uuid, 'review.completed', 'learning_analytics',
          clock_timestamp() - interval '91 days'),
         (${sqlString(USER_B)}::uuid, 'reading.session.completed', 'learning_analytics',
          clock_timestamp())`,
    );

    callJson(
      session,
      `select public.set_user_analytics_preference(${sqlString(USER_B)}::uuid, false)`,
    );
    expect(
      scalar(
        session,
        `select count(*)::text from public.product_events
         where user_id = ${sqlString(USER_B)}::uuid and purpose = 'learning_analytics'`,
      ),
    ).toBe("0");
    expect(scalar(session, "select public.purge_expired_product_events()::text")).toBe("1");
    expect(
      scalar(
        session,
        `select count(*)::text from public.product_events
         where user_id = ${sqlString(USER_B)}::uuid`,
      ),
    ).toBe("0");
  });

  it("keeps rejected mutation IDs terminal across later entity revisions", () => {
    const session = requireDb(db);
    const rejectedId = "88888888-8888-4888-8888-888888888881";
    const entityId = "terminal-replay";
    const rejectedMutation = {
      mutationId: rejectedId,
      entityType: "progress",
      entityId,
      operation: "upsert",
      baseRevision: 2,
      occurredAt: "2026-08-30T09:46:00Z",
      payload: { positionSeconds: 30 },
    };
    const rejected = callJson(
      session,
      `select public.push_sync_batch(
        ${sqlString(USER_A)}::uuid,
        ${sqlString(DEVICE_A)}::uuid,
        '88888888-8888-4888-8888-888888888882'::uuid,
        ${sqlJson([rejectedMutation])}::jsonb
      )`,
    );
    expect(rejected.results).toEqual([
      expect.objectContaining({ status: "rejected", entityRevision: null }),
    ]);

    for (const [index, baseRevision] of [0, 1].entries()) {
      callJson(
        session,
        `select public.push_sync_batch(
          ${sqlString(USER_A)}::uuid,
          ${sqlString(DEVICE_A)}::uuid,
          ${sqlString(`88888888-8888-4888-8888-88888888889${String(index)}`)}::uuid,
          ${sqlJson([
            {
              mutationId: `99999999-9999-4999-8999-99999999999${String(index)}`,
              entityType: "progress",
              entityId,
              operation: "upsert",
              baseRevision,
              occurredAt: `2026-08-30T09:46:0${String(index + 1)}Z`,
              payload: { positionSeconds: 40 + index },
            },
          ])}::jsonb
        )`,
      );
    }

    const replay = callJson(
      session,
      `select public.push_sync_batch(
        ${sqlString(USER_A)}::uuid,
        ${sqlString(DEVICE_A)}::uuid,
        '88888888-8888-4888-8888-888888888883'::uuid,
        ${sqlJson([rejectedMutation])}::jsonb
      )`,
    );
    expect(replay.results).toEqual([
      expect.objectContaining({ status: "duplicate", entityRevision: null }),
    ]);
    expect(
      scalar(
        session,
        `select count(*)::text from sync_changes
         where user_id = ${sqlString(USER_A)}::uuid
           and entity_type = 'progress'
           and entity_id = ${sqlString(entityId)}`,
      ),
    ).toBe("2");
  });

  it("rejects duplicate mutation IDs before committing any batch rows", () => {
    const session = requireDb(db);
    const mutation = {
      mutationId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa8",
      entityType: "progress",
      entityId: "duplicate-in-batch",
      operation: "upsert",
      baseRevision: 0,
      occurredAt: "2026-08-30T09:47:00Z",
      payload: { positionSeconds: 1 },
    };
    const result = session.exec(
      `select public.push_sync_batch(
        ${sqlString(USER_A)}::uuid,
        ${sqlString(DEVICE_A)}::uuid,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa9'::uuid,
        ${sqlJson([mutation, { ...mutation, payload: { positionSeconds: 2 } }])}::jsonb
      )`,
    );
    expect(result.ok).toBe(false);
    expect(result.stderr).toContain("mutationId must be unique within the batch");
    expect(
      scalar(
        session,
        `select count(*)::text from sync_changes
         where user_id = ${sqlString(USER_A)}::uuid
           and entity_id = 'duplicate-in-batch'`,
      ),
    ).toBe("0");
  });

  it("pulls at least one change while bounding each database page by encoded payload bytes", () => {
    const session = requireDb(db);
    execOk(
      session,
      `insert into public.sync_changes (
         user_id, sequence, entity_type, entity_id, operation, revision, mutation_id, payload, changed_at
       ) values
       (${sqlString(USER_A)}::uuid, 9001, 'transcript', 'byte-page-1', 'upsert', 1,
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1'::uuid,
        jsonb_build_object('text', repeat('a', 700000)), now()),
       (${sqlString(USER_A)}::uuid, 9002, 'transcript', 'byte-page-2', 'upsert', 1,
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2'::uuid,
        jsonb_build_object('text', repeat('b', 700000)), now())`,
    );

    const first = callJson(
      session,
      `select public.pull_sync_page(${sqlString(USER_A)}::uuid, 9000, 100, 1048576)`,
    );
    expect(first.changes).toHaveLength(1);
    expect(first.cursor).toBe("9001");
    expect(first.hasMore).toBe(true);

    const second = callJson(
      session,
      `select public.pull_sync_page(${sqlString(USER_A)}::uuid, 9001, 100, 1048576)`,
    );
    expect(second.changes).toHaveLength(1);
    expect(second.cursor).toBe("9002");
    expect(second.hasMore).toBe(false);
  });

  it("bootstraps latest entity state at a fixed cursor instead of replaying history", () => {
    const session = requireDb(db);
    execOk(
      session,
      `insert into public.sync_changes (
         user_id, sequence, entity_type, entity_id, operation, revision, mutation_id, payload, changed_at
       ) values
       (${sqlString(USER_A)}::uuid, 9101, 'vocabulary', 'bootstrap-latest', 'upsert', 1,
        'cccccccc-cccc-4ccc-8ccc-ccccccccccc1'::uuid, '{"surface":"old"}'::jsonb, now()),
       (${sqlString(USER_A)}::uuid, 9102, 'vocabulary', 'bootstrap-latest', 'upsert', 2,
        'cccccccc-cccc-4ccc-8ccc-ccccccccccc2'::uuid, '{"surface":"latest"}'::jsonb, now()),
       (${sqlString(USER_A)}::uuid, 9103, 'vocabulary', 'bootstrap-other', 'upsert', 1,
        'cccccccc-cccc-4ccc-8ccc-ccccccccccc3'::uuid, '{"surface":"other"}'::jsonb, now()),
       (${sqlString(USER_A)}::uuid, 9104, 'vocabulary', 'bootstrap-latest', 'upsert', 3,
        'cccccccc-cccc-4ccc-8ccc-ccccccccccc4'::uuid, '{"surface":"future"}'::jsonb, now())`,
    );

    let offset = 0;
    let hasMore = true;
    const entities: Array<Record<string, unknown>> = [];
    while (hasMore) {
      const page = callJson(
        session,
        `select public.bootstrap_sync_page(
          ${sqlString(USER_A)}::uuid, 9103, ${String(offset)}, 500, 1048576
        )`,
      );
      expect(page.cursor).toBe("9103");
      entities.push(...(page.entities as Array<Record<string, unknown>>));
      offset = Number(page.nextOffset);
      hasMore = Boolean(page.hasMore);
    }
    const latest = entities.filter((entity) => entity.entity_id === "bootstrap-latest");

    expect(latest).toHaveLength(1);
    expect(latest[0]).toMatchObject({ revision: 2, payload: { surface: "latest" } });
  });

  it("publishes one verified v2 transcript manifest atomically and leaves failures invisible", () => {
    const session = requireDb(db);
    const uploadId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const revisionId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    const chapterId = "ffffffff-ffff-4fff-8fff-ffffffffffff";
    const sha = "a".repeat(64);
    execOk(
      session,
      `insert into public.asset_manifests_v2 (
        upload_id, user_id, kind, content_type, encoding, compressed_bytes, original_bytes,
        sha256, object_key, upload_object_key, revision_id, chapter_id, segment_count
      ) values (
        ${sqlString(uploadId)}::uuid, ${sqlString(USER_A)}::uuid, 'transcriptRevision',
        'application/json', 'identity-json-v1', 3, 3, ${sqlString(sha)},
        'private/v2/${USER_A}/transcriptRevision/${sha}',
        'private/v2/${USER_A}/pending/${uploadId}',
        ${sqlString(revisionId)}::uuid, ${sqlString(chapterId)}::uuid, 1
      )`,
    );

    const completed = callJson(
      session,
      `select public.complete_v2_asset_and_publish(
        ${sqlString(USER_A)}::uuid, ${sqlString(uploadId)}::uuid, 3, ${sqlString(sha)}
      )`,
    );
    expect(completed.cursor).toBe(1);
    expect(
      scalar(
        session,
        `select count(*)::text from sync_v2_changes
         where user_id = ${sqlString(USER_A)}::uuid and entity_id = ${sqlString(revisionId)}::uuid`,
      ),
    ).toBe("1");
    const replay = callJson(
      session,
      `select public.complete_v2_asset_and_publish(
        ${sqlString(USER_A)}::uuid, ${sqlString(uploadId)}::uuid, 3, ${sqlString(sha)}
      )`,
    );
    expect(replay.cursor).toBe(1);
    const pulled = callJson(
      session,
      `select public.pull_sync_v2_page(${sqlString(USER_A)}::uuid, 0, 100, 1048576)`,
    );
    const changes = requireJsonObjectArray(pulled.changes);
    expect(changes).toHaveLength(1);
    expect(JSON.stringify(pulled)).not.toContain("transcriptJSON");
    expect(changes[0]?.entity_type).toBe("transcript");
    expect(changes[0]?.entity_id).toBe(revisionId);
    expect(changes[0]?.payload).toMatchObject({
      revisionId,
      objectKey: `private/v2/${USER_A}/transcriptRevision/${sha}`,
      sha256: sha,
      compressedBytes: 3,
    });

    const failedUpload = "12121212-1212-4212-8212-121212121212";
    const failedRevision = "13131313-1313-4313-8313-131313131313";
    execOk(
      session,
      `insert into public.asset_manifests_v2 (
        upload_id, user_id, kind, content_type, encoding, compressed_bytes, original_bytes,
        sha256, object_key, upload_object_key, revision_id, chapter_id, segment_count
      ) values (
        ${sqlString(failedUpload)}::uuid, ${sqlString(USER_A)}::uuid, 'transcriptRevision',
        'application/json', 'identity-json-v1', 3, 3, repeat('b', 64),
        'private/v2/${USER_A}/transcriptRevision/' || repeat('b', 64),
        'private/v2/${USER_A}/pending/${failedUpload}',
        ${sqlString(failedRevision)}::uuid, ${sqlString(chapterId)}::uuid, 1
      )`,
    );
    const failed = session.exec(
      `select public.complete_v2_asset_and_publish(
        ${sqlString(USER_A)}::uuid, ${sqlString(failedUpload)}::uuid, 4, repeat('b', 64)
      )`,
    );
    expect(failed.ok).toBe(false);
    expect(
      scalar(
        session,
        `select status || ':' || (
           select count(*)::text from sync_v2_changes
           where user_id = ${sqlString(USER_A)}::uuid and entity_id = ${sqlString(failedRevision)}::uuid
         ) from asset_manifests_v2 where upload_id = ${sqlString(failedUpload)}::uuid`,
      ),
    ).toBe("pending:0");
  });

  it("claims one assistant generation per cache key and attaches another user", () => {
    const session = requireDb(db);
    const cacheKey = `cache-key-${crypto.randomUUID()}`;
    const first = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_A)}::uuid, ${sqlString(cacheKey)}, 'translate'
      )`,
    );
    expect(first.status).toBe("claimed");
    expect(first.job_status).toBe("queued");
    expect(first.job_id).toEqual(expect.any(String));
    expect(first.result_id).toEqual(expect.any(String));
    const second = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_B)}::uuid, ${sqlString(cacheKey)}, 'translate'
      )`,
    );
    expect(second.status).toBe("attached");
    expect(second.job_id).toBe(first.job_id);
    expect(second.result_id).not.toBe(first.result_id);
    const attached = callJson(
      session,
      `select public.attach_user_assistant_result(
        ${sqlString(USER_B)}::uuid, ${sqlString(String(first.job_id))}::uuid
      )`,
    );
    expect(attached.status).toBe("attached");
    expect(attached.result_id).toBe(second.result_id);
    expect(
      scalar(
        session,
        `select count(*)::text from assistant_jobs
         where cache_key = ${sqlString(cacheKey)} and status in ('queued', 'running')`,
      ),
    ).toBe("1");
  });

  it("completes and fails jobs atomically", () => {
    const session = requireDb(db);
    const cacheKey = `cache-key-${crypto.randomUUID()}`;
    const claimed = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_A)}::uuid, ${sqlString(cacheKey)}, 'translate',
        ${sqlString(bookA)}::uuid
      )`,
    );
    callJson(
      session,
      `select public.attach_user_assistant_result(
        ${sqlString(USER_B)}::uuid, ${sqlString(String(claimed.job_id))}::uuid,
        ${sqlString(bookB)}::uuid, null, 'translate'
      )`,
    );
    const completed = callJson(
      session,
      `select public.complete_assistant_job(
        ${sqlString(String(claimed.job_id))}::uuid,
        '{"text":"你好"}'::jsonb,
        'translate',
        'en',
        'zh'
      )`,
    );
    expect(completed.status).toBe("succeeded");
    expect(completed.cache_entry_id).toEqual(expect.any(String));
    expect(
      scalar(
        session,
        `select status from assistant_jobs where id = ${sqlString(String(claimed.job_id))}`,
      ),
    ).toBe("succeeded");
    expect(
      scalar(
        session,
        `select count(*)::text from user_assistant_results
         where job_id = ${sqlString(String(claimed.job_id))}
           and cache_entry_id = ${sqlString(String(completed.cache_entry_id))}`,
      ),
    ).toBe("2");
    expect(
      scalar(
        session,
        `select result->>'text' from assistant_cache_entries
         where id = ${sqlString(String(completed.cache_entry_id))}`,
      ),
    ).toBe("你好");
    const hit = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_B)}::uuid, ${sqlString(cacheKey)}, 'translate'
      )`,
    );
    expect(hit.status).toBe("cache_hit");
    expect(hit.cache_entry_id).toBe(completed.cache_entry_id);
    const userC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    execOk(
      session,
      `insert into public.profiles (user_id, display_name, account_status)
       values (${sqlString(userC)}::uuid, 'user c', 'active')`,
    );
    const hitC = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(userC)}::uuid, ${sqlString(cacheKey)}, 'translate'
      )`,
    );
    expect(hitC.status).toBe("cache_hit");
    expect(hitC.cache_entry_id).toBe(completed.cache_entry_id);
    expect(
      scalar(
        session,
        `select output_text from user_assistant_results
         where id = ${sqlString(String(hitC.result_id))}`,
      ),
    ).toBe("你好");

    const failKey = `cache-key-${crypto.randomUUID()}`;
    const toFail = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_A)}::uuid, ${sqlString(failKey)}, 'explain'
      )`,
    );
    const failed = callJson(
      session,
      `select public.fail_assistant_job(
        ${sqlString(String(toFail.job_id))}::uuid, 'provider timeout'
      )`,
    );
    expect(failed.status).toBe("failed");
    const lateAttach = callJson(
      session,
      `select public.attach_user_assistant_result(
        ${sqlString(USER_B)}::uuid, ${sqlString(String(toFail.job_id))}::uuid
      )`,
    );
    expect(lateAttach.status).toBe("unavailable");
    const retry = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_B)}::uuid, ${sqlString(failKey)}, 'explain'
      )`,
    );
    expect(retry.status).toBe("claimed");
    expect(retry.job_id).not.toBe(toFail.job_id);
    const dead = callJson(
      session,
      `select public.fail_assistant_job(
        ${sqlString(String(retry.job_id))}::uuid, 'exhausted', true
      )`,
    );
    expect(dead.status).toBe("dead_letter");

    const quarantinedKey = `cache-key-${crypto.randomUUID()}`;
    const blocked = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_A)}::uuid, ${sqlString(quarantinedKey)}, 'translate'
      )`,
    );
    execOk(
      session,
      `insert into public.assistant_cache_entries (
         cache_key, task_type, source_language, target_language, state, result
       ) values (
         ${sqlString(quarantinedKey)}, 'translate', 'en', 'zh', 'quarantined', '{"text":"stale"}'::jsonb
       )`,
    );
    const refused = session.exec(
      `select public.complete_assistant_job(
         ${sqlString(String(blocked.job_id))}::uuid,
         '{"text":"fresh"}'::jsonb,
         'translate',
         'en',
         'zh'
       )`,
    );
    expect(refused.ok).toBe(false);
    expect(`${refused.stderr} ${refused.stdout}`).toMatch(/not active/i);
    expect(
      scalar(
        session,
        `select status from assistant_jobs where id = ${sqlString(String(blocked.job_id))}`,
      ),
    ).toBe("queued");
  });

  it("cache claim concurrency admits one owner", async () => {
    const session = requireDb(db);
    const cacheKey = `cache-key-${crypto.randomUUID()}`;
    const gate = "claim-concurrent";
    execOk(
      session,
      `
      create table if not exists public._tx_gate (
        name text primary key,
        opened boolean not null default false
      );
      insert into public._tx_gate (name, opened)
      values (${sqlString(gate)}, false)
      on conflict (name) do update set opened = false;
      `,
    );
    const worker = (userId: string): string => `
      begin;
      do $$
      begin
        while not coalesce(
          (select opened from public._tx_gate where name = ${sqlString(gate)}),
          false
        ) loop
          perform pg_sleep(0.05);
        end loop;
      end $$;
      select public.claim_assistant_generation(
        ${sqlString(userId)}::uuid, ${sqlString(cacheKey)}, 'translate'
      )::text;
      commit;
    `;
    const first = session.start(worker(USER_A), { timeout: 20_000 });
    const second = session.start(worker(USER_B), { timeout: 20_000 });
    await delay(400);
    execOk(session, `update public._tx_gate set opened = true where name = ${sqlString(gate)};`);
    const results = await Promise.all([first, second]);
    for (const result of results) {
      expect(result.ok, result.stderr || result.stdout).toBe(true);
    }
    const statuses = results
      .map((result) => parseJsonObject(result.stdout).status)
      .map((status) => String(status))
      .sort();
    expect(statuses).toEqual(["attached", "claimed"]);
    expect(
      scalar(
        session,
        `select count(*)::text from assistant_jobs
         where cache_key = ${sqlString(cacheKey)} and status in ('queued', 'running')`,
      ),
    ).toBe("1");
    expect(
      scalar(
        session,
        `select count(*)::text from user_assistant_results
         where job_id = (
           select id from assistant_jobs where cache_key = ${sqlString(cacheKey)}
         )`,
      ),
    ).toBe("2");
  }, 30_000);

  it("attach waits for complete and copies cache output onto the new result", async () => {
    const session = requireDb(db);
    const cacheKey = `cache-key-${crypto.randomUUID()}`;
    const claimed = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_A)}::uuid, ${sqlString(cacheKey)}, 'translate'
      )`,
    );
    const jobId = String(claimed.job_id);
    const completing = session.start(
      `
      begin;
      select public.complete_assistant_job(
        ${sqlString(jobId)}::uuid,
        '{"text":"copied"}'::jsonb,
        'translate',
        'en',
        'zh'
      )::text;
      select pg_sleep(0.4);
      commit;
      `,
      { timeout: 20_000 },
    );
    await delay(150);
    const attaching = session.start(
      `
      begin;
      select public.attach_user_assistant_result(
        ${sqlString(USER_B)}::uuid, ${sqlString(jobId)}::uuid
      )::text;
      commit;
      `,
      { timeout: 20_000 },
    );
    const [completed, attached] = await Promise.all([completing, attaching]);
    expect(completed.ok, completed.stderr || completed.stdout).toBe(true);
    expect(attached.ok, attached.stderr || attached.stdout).toBe(true);
    expect(parseJsonObject(completed.stdout).status).toBe("succeeded");
    expect(parseJsonObject(attached.stdout).status).toBe("attached");
    expect(
      scalar(
        session,
        `select output_text from user_assistant_results
         where user_id = ${sqlString(USER_B)}
           and job_id = ${sqlString(jobId)}`,
      ),
    ).toBe("copied");
    expect(
      scalar(
        session,
        `select (cache_entry_id is not null)::text from user_assistant_results
         where user_id = ${sqlString(USER_B)}
           and job_id = ${sqlString(jobId)}`,
      ),
    ).toBe("true");
  }, 30_000);

  it("keeps accepted private output and history after shared cache eviction", () => {
    const session = requireDb(db);
    const cacheKey = `cache-lifecycle-${crypto.randomUUID()}`;
    const claimed = callJson(
      session,
      `select public.claim_assistant_generation(
        ${sqlString(USER_A)}::uuid, ${sqlString(cacheKey)}, 'translate'
      )`,
    );
    const completed = callJson(
      session,
      `select public.complete_assistant_job(
        ${sqlString(String(claimed.job_id))}::uuid,
        '{"text":"durable accepted text"}'::jsonb,
        'translate', 'en', 'zh'
      )`,
    );
    execOk(
      session,
      `update public.user_assistant_results
       set status = 'accepted', model = 'qwen-test', decided_at = clock_timestamp()
       where id = ${sqlString(String(claimed.result_id))}::uuid`,
    );
    execOk(
      session,
      `delete from public.assistant_cache_entries
       where id = ${sqlString(String(completed.cache_entry_id))}::uuid`,
    );

    expect(
      scalar(
        session,
        `select output_text from public.user_assistant_results
         where id = ${sqlString(String(claimed.result_id))}::uuid`,
      ),
    ).toBe("durable accepted text");
    expect(
      scalar(
        session,
        `select (cache_entry_id is null)::text from public.user_assistant_results
         where id = ${sqlString(String(claimed.result_id))}::uuid`,
      ),
    ).toBe("true");
    expect(
      scalar(
        session,
        `select jsonb_array_length(history)::text from public.user_assistant_results
         where id = ${sqlString(String(claimed.result_id))}::uuid`,
      ),
    ).not.toBe("0");
  });

  it("applies native assistant lifecycle mutations to one private row and bootstrap entity", () => {
    const session = requireDb(db);
    const resultId = crypto.randomUUID();
    const cacheId = crypto.randomUUID();
    const cacheKey = `cache-result-lifecycle-${crypto.randomUUID()}`;
    execOk(
      session,
      `insert into public.assistant_cache_entries (
         id, cache_key, task_type, source_language, target_language, state, result
       ) values (
         ${sqlString(cacheId)}::uuid, ${sqlString(cacheKey)}, 'translation', 'en', 'zh',
         'active', '{"translation":"shared only"}'::jsonb
       );
       insert into public.user_assistant_results (
         id, user_id, cache_entry_id, task_type, status, output_text,
         model, prompt_version, model_policy_hash
       ) values (
         ${sqlString(resultId)}::uuid, ${sqlString(USER_A)}::uuid,
         ${sqlString(cacheId)}::uuid, 'translation', 'pending', 'generated',
         'qwen3.5-plus-2026-08-01', 'qwen-managed-v3', ${sqlString("a".repeat(64))}
       )`,
    );
    const lifecycle = [
      { status: "accepted", text: "accepted", model: "qwen3.5-plus-2026-08-01", prompt: "qwen-managed-v3", hash: "a".repeat(64) },
      { status: "edited", text: "edited", model: "qwen3.5-plus-2026-08-01", prompt: "qwen-managed-v3", hash: "a".repeat(64) },
      { status: "replaced", text: "replacement", model: "qwen3.5-plus-2026-08-31", prompt: "qwen-managed-v4", hash: "b".repeat(64) },
    ];
    for (const [index, state] of lifecycle.entries()) {
      const mutation = {
        mutationId: crypto.randomUUID(),
        entityType: "assistant_result",
        entityId: resultId,
        operation: "upsert",
        baseRevision: index,
        occurredAt: `2026-09-01T00:00:0${String(index + 1)}Z`,
        payload: {
          result: {
            id: resultId,
            kind: "sentenceGloss",
            status: state.status,
            language: "zh-Hans",
            model: state.model,
            promptVersion: state.prompt,
            modelPolicyHash: state.hash,
            source: "private source",
            text: state.text,
            createdAt: "2026-09-01T00:00:00Z",
            decidedAt: `2026-09-01T00:00:0${String(index + 1)}Z`,
            sharedCacheEntryID: cacheId,
          },
          vocabulary: [],
        },
      };
      const pushed = callJson(
        session,
        `select public.push_sync_v2_batch(
          ${sqlString(USER_A)}::uuid, ${sqlString(DEVICE_A)}::uuid,
          ${sqlString(crypto.randomUUID())}::uuid, ${sqlJson([mutation])}::jsonb
        )`,
      );
      expect(requireJsonObjectArray(pushed.results)[0]?.status).toBe("applied");
    }

    expect(
      scalar(session, `select count(*)::text from user_assistant_results where id = ${sqlString(resultId)}::uuid`),
    ).toBe("1");
    expect(
      scalar(session, `select status || '|' || output_text || '|' || model || '|' || prompt_version || '|' || model_policy_hash from user_assistant_results where id = ${sqlString(resultId)}::uuid`),
    ).toBe(`replaced|replacement|qwen3.5-plus-2026-08-31|qwen-managed-v4|${"b".repeat(64)}`);
    expect(
      Number(scalar(session, `select jsonb_array_length(history)::text from user_assistant_results where id = ${sqlString(resultId)}::uuid`)),
    ).toBeGreaterThanOrEqual(4);
    const bootstrap = callJson(
      session,
      `select public.bootstrap_sync_v2_page(
        ${sqlString(USER_A)}::uuid, null, 0, 500, 1048576
      )`,
    );
    const entity = requireJsonObjectArray(bootstrap.entities).find(
      (item) => item.entity_type === "assistant_result" && item.entity_id === resultId,
    );
    expect(entity).toBeDefined();
    expect(entity?.payload).toMatchObject({ result: { id: resultId, status: "replaced", text: "replacement" } });
  });

  it("records a complete generated private summary without requiring its shared cache row", () => {
    const session = requireDb(db);
    const resultId = crypto.randomUUID();
    const missingCacheId = crypto.randomUUID();
    const structured = {
      overview: "private overview",
      keyPoints: ["one", "two"],
      charactersOrIdeas: ["reader"],
      keyConcepts: [{ name: "concept", explanation: "detail" }],
      themes: ["theme"],
    };
    const outputText = JSON.stringify(structured);
    const recorded = callJson(
      session,
      `select jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(recorded)), '[]'::jsonb))
       from public.record_user_assistant_result(
         ${sqlString(USER_A)}::uuid,
         ${sqlJson({
          id: resultId,
          task: "chapter_summary",
          resultKind: "chapterSummary",
          status: "pending",
          cacheEntryId: missingCacheId,
          outputText,
          privateContent: structured,
          language: "zh-Hans",
          sourceText: "private chapter text",
          bookTitle: "Private Book",
          chapterTitle: "Private Chapter",
          targetId: "chapter-local-1",
          model: "qwen3.7-plus-2026-09-01",
          promptVersion: "qwen-managed-v4",
          modelPolicyHash: "c".repeat(64),
          createdAt: "2026-09-01T00:00:00Z",
         })}::jsonb
       ) recorded`,
    );
    const rows = requireJsonObjectArray(recorded.rows);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: resultId,
      cache_entry_id: null,
      result_kind: "chapterSummary",
      output_text: outputText,
      private_content: structured,
    });
    expect(
      callJson(
        session,
        `select history -> 0 from public.user_assistant_results
         where id = ${sqlString(resultId)}::uuid`,
      ),
    ).toMatchObject({ privateContent: structured, outputText });
    const bootstrap = callJson(
      session,
      `select public.bootstrap_sync_v2_page(
        ${sqlString(USER_A)}::uuid, null, 0, 500, 1048576
      )`,
    );
    const bootstrapped = requireJsonObjectArray(bootstrap.entities).find((entity) =>
      entity.entity_type === "assistant_result" && entity.entity_id === resultId
    );
    expect(bootstrapped).toBeDefined();
    const bootstrappedResult = requireJsonObject(requireJsonObject(bootstrapped?.payload).result);
    expect(bootstrappedResult.id).toBe(resultId);
    expect(bootstrappedResult.text).toBe(outputText);
  });

  it("appends an immutable redacted audit event", () => {
    const session = requireDb(db);
    const appended = callJson(
      session,
      `select public.append_audit_event(
        'admin',
        'cache.quarantine',
        'assistant_cache_entries',
        'cache-1',
        'unsafe output reported',
        ${sqlString(USER_A)}::uuid,
        'unsafe_output',
        'req-123',
        'iphash-9f',
        ${sqlJson({
          note: "ok",
          api_key: "sk-live",
          apiKey: "sk-camel",
          sourcePassage: "hello world",
          accessToken: "tok",
          privateKey: "pk",
        })}::jsonb,
        ${sqlJson({ password: "hunter2", keep: 1 })}::jsonb,
        ${sqlJson({ token: "abc", count: 2, spokenText: "hi" })}::jsonb
      )`,
    );
    expect(appended.id).toEqual(expect.any(String));
    expect(appended.created_at).toEqual(expect.any(String));
    const row = callJson(
      session,
      `select to_jsonb(t) from (
         select actor_type, action, resource_type, resource_id, reason, reason_code,
                request_id, source_ip_hash, metadata, before_metadata, after_metadata
         from public.audit_events
         where id = ${sqlString(String(appended.id))}
       ) t`,
    );
    expect(row.actor_type).toBe("admin");
    expect(row.action).toBe("cache.quarantine");
    expect(row.resource_type).toBe("assistant_cache_entries");
    expect(row.resource_id).toBe("cache-1");
    expect(row.reason).toBe("unsafe output reported");
    expect(row.reason_code).toBe("unsafe_output");
    expect(row.request_id).toBe("req-123");
    expect(row.source_ip_hash).toBe("iphash-9f");
    expect(row.metadata).toEqual({
      note: "ok",
      api_key: "<redacted>",
      apiKey: "<redacted>",
      sourcePassage: "<redacted>",
      accessToken: "<redacted>",
      privateKey: "<redacted>",
    });
    expect(row.before_metadata).toEqual({ password: "<redacted>", keep: 1 });
    expect(row.after_metadata).toEqual({ token: "<redacted>", count: 2, spokenText: "<redacted>" });
    const updated: SqlResult = session.exec(
      `update public.audit_events set reason = 'mutated' where id = ${sqlString(String(appended.id))}`,
    );
    expect(updated.ok).toBe(false);
    expect(`${updated.stderr} ${updated.stdout}`).toMatch(/immutable/i);
    const deleted: SqlResult = session.exec(
      `delete from public.audit_events where id = ${sqlString(String(appended.id))}`,
    );
    expect(deleted.ok).toBe(false);
    expect(`${deleted.stderr} ${deleted.stdout}`).toMatch(/immutable/i);
  });

  it("rolls back deletion_pending and the privacy request when atomic job creation fails", () => {
    const session = requireDb(db);
    const beforeRequests = scalar(
      session,
      `select count(*)::text from public.privacy_requests where user_id = ${sqlString(USER_A)}::uuid`,
    );
    execOk(
      session,
      `create or replace function public._fail_deletion_job_for_test()
       returns trigger language plpgsql as $$
       begin
         if new.kind = 'account_deletion' then raise exception 'forced job failure'; end if;
         return new;
       end $$;
       create trigger fail_deletion_job_for_test before insert on public.assistant_jobs
       for each row execute function public._fail_deletion_job_for_test()`,
    );
    const failed = session.exec(
      `select public.request_account_deletion(
        ${sqlString(USER_A)}::uuid, 'rollback test', 'rollback-trace'
      )`,
    );
    execOk(
      session,
      `drop trigger fail_deletion_job_for_test on public.assistant_jobs;
       drop function public._fail_deletion_job_for_test()`,
    );
    expect(failed.ok).toBe(false);
    expect(
      scalar(
        session,
        `select account_status from public.profiles where user_id = ${sqlString(USER_A)}::uuid`,
      ),
    ).toBe("active");
    expect(
      scalar(
        session,
        `select count(*)::text from public.privacy_requests where user_id = ${sqlString(USER_A)}::uuid`,
      ),
    ).toBe(beforeRequests);
  });

  it("serializes a concurrent child write behind account deletion and rejects it", async () => {
    const session = requireDb(db);
    const racingUser = "16161616-1616-4616-8616-161616161616";
    execOk(
      session,
      `insert into public.profiles (user_id, account_status)
       values (${sqlString(racingUser)}::uuid, 'active')`,
    );
    const deletion = session.start(
      `begin;
       select 1 from public.profiles where user_id = ${sqlString(racingUser)}::uuid for update;
       select pg_sleep(0.3);
       update public.profiles
       set account_status = 'deletion_pending', deletion_pending_at = clock_timestamp()
       where user_id = ${sqlString(racingUser)}::uuid;
       commit;`,
    );
    await delay(50);
    const racedWrite = session.start(
      `insert into public.devices (user_id, platform, app_version)
       values (${sqlString(racingUser)}::uuid, 'ios', '9.9.9')`,
    );
    const [deleted, written] = await Promise.all([deletion, racedWrite]);
    expect(deleted.ok, deleted.stderr).toBe(true);
    expect(written.ok).toBe(false);
    expect(`${written.stderr} ${written.stdout}`).toMatch(/not writable/i);
    expect(
      scalar(
        session,
        `select count(*)::text from public.devices where user_id = ${sqlString(racingUser)}::uuid`,
      ),
    ).toBe("0");
  });

  it("cascades private account data and retains only an anonymous deletion tombstone", () => {
    const session = requireDb(db);
    const deletionJobId = "15151515-1515-4515-8515-151515151515";
    const legacyJobId = "17171717-1717-4717-8717-171717171717";
    const otherUserJobId = "18181818-1818-4818-8818-181818181818";
    const sharedCacheId = "19191919-1919-4919-8919-191919191919";
    execOk(
      session,
      `update public.assistant_jobs set status = 'cancelled' where status = 'queued';
       insert into public.assistant_cache_entries (
         id, cache_key, task_type, source_language, target_language, state, result
       ) values (
         ${sqlString(sharedCacheId)}::uuid, 'deletion-shared-cache', 'translate',
         'en', 'zh', 'active', '{"text":"shared reusable result"}'::jsonb
       );
       insert into public.user_assistant_results (
         user_id, cache_entry_id, task_type, status, output_text, model
       ) values (
         ${sqlString(USER_B)}::uuid, ${sqlString(sharedCacheId)}::uuid,
         'translate', 'accepted', 'private accepted result', 'qwen-test'
       );
       insert into public.assistant_jobs (id, user_id, kind, status, payload)
       values
         (
           ${sqlString(deletionJobId)}::uuid,
           ${sqlString(USER_B)}::uuid,
           'account_deletion',
           'running',
           '{"reason":"PRIVATE DELETION REASON"}'::jsonb
         ),
         (
           ${sqlString(legacyJobId)}::uuid,
           ${sqlString(USER_B)}::uuid,
           'translate',
           'queued',
           '{"private":"PRIVATE TRANSLATION INPUT"}'::jsonb
         ),
         (
           ${sqlString(otherUserJobId)}::uuid,
           ${sqlString(USER_A)}::uuid,
           'translate',
           'queued',
           '{}'::jsonb
         );
       insert into public.object_write_leases (user_id, object_key)
       values (${sqlString(USER_B)}::uuid, ${sqlString(`${USER_B}/late-audio.m4b`)})`,
    );
    callJson(
      session,
      `select public.set_user_analytics_preference(${sqlString(USER_B)}::uuid, true)`,
    );
    callJson(session, `select public.admin_user_progress_summary(${sqlString(USER_B)}::uuid)`);
    const requested = callJson(
      session,
      `select public.request_account_deletion(
        ${sqlString(USER_B)}::uuid, 'PRIVATE REQUEST REASON', 'delete-request-trace'
      )`,
    );
    expect(requested).toMatchObject({
      privacy_request: { kind: "deletion", status: "queued" },
      job: { kind: "account_deletion", status: "queued", attempts: 0 },
    });
    expect(
      scalar(
        session,
        `select account_status from public.profiles where user_id = ${sqlString(USER_B)}::uuid`,
      ),
    ).toBe("deletion_pending");
    expect(
      callJson(
        session,
        `select jsonb_build_object(
           'status', status,
           'userIdRemoved', user_id is null,
           'payload', payload,
           'cacheKeyRemoved', cache_key is null,
           'lastErrorRemoved', last_error is null
         ) from public.assistant_jobs where id = ${sqlString(legacyJobId)}::uuid`,
      ),
    ).toEqual({
      status: "cancelled",
      userIdRemoved: true,
      payload: {},
      cacheKeyRemoved: true,
      lastErrorRemoved: true,
    });
    const blockedWhilePending = session.exec(
      `insert into public.devices (user_id, platform, app_version)
       values (${sqlString(USER_B)}::uuid, 'ios', '9.9.9')`,
    );
    expect(blockedWhilePending.ok).toBe(false);
    expect(`${blockedWhilePending.stderr} ${blockedWhilePending.stdout}`).toMatch(/not writable/i);
    const firstClaim = callJson(
      session,
      `select jsonb_build_object('items', coalesce(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb))
       from public.claim_assistant_jobs(10) claimed`,
    );
    expect(Array.isArray(firstClaim.items)).toBe(true);
    if (!Array.isArray(firstClaim.items)) return;
    expect(firstClaim.items).toHaveLength(2);
    expect(firstClaim.items.map((item: { kind: string }) => item.kind).sort()).toEqual([
      "account_deletion",
      "translate",
    ]);
    for (const item of firstClaim.items) {
      expect(item).toMatchObject({ status: "running", attempts: 1 });
    }
    expect(
      callJson(
        session,
        `select jsonb_build_object('items', coalesce(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb))
         from public.claim_assistant_jobs(10) claimed`,
      ),
    ).toEqual({ items: [] });
    expect(
      scalar(session, `select public.delete_account_data(${sqlString(USER_B)}::uuid)::text`),
    ).toBe("true");
    expect(
      callJson(
        session,
        `select jsonb_build_object(
           'status', account_status,
           'email', email,
           'displayName', display_name,
           'avatarUrl', avatar_url,
           'deleted', deleted_at is not null
         ) from public.profiles where user_id = ${sqlString(USER_B)}::uuid`,
      ),
    ).toEqual({
      status: "deleted",
      email: null,
      displayName: null,
      avatarUrl: null,
      deleted: true,
    });
    for (const sql of [
      `insert into public.devices (user_id, platform, app_version)
       values (${sqlString(USER_B)}::uuid, 'ios', '9.9.9')`,
      `insert into public.user_settings (user_id) values (${sqlString(USER_B)}::uuid)`,
      `insert into public.object_write_leases (user_id, object_key)
       values (${sqlString(USER_B)}::uuid, ${sqlString(`${USER_B}/too-late.m4b`)})`,
    ]) {
      const blocked = session.exec(sql);
      expect(blocked.ok).toBe(false);
      expect(`${blocked.stderr} ${blocked.stdout}`).toMatch(/not writable/i);
    }
    for (const table of [
      "devices",
      "user_settings",
      "books",
      "book_assets",
      "chapters",
      "reading_progress",
      "transcript_revisions",
      "transcript_segments",
      "vocabulary_occurrences",
      "known_lemmas",
      "review_cards",
      "review_events",
      "user_assistant_results",
      "usage_ledger",
      "sync_changes",
      "sync_batches",
      "sync_mutation_outcomes",
      "idempotency_records",
      "admin_roles",
      "chat_messages",
      "privacy_requests",
      "product_events",
      "user_analytics_preferences",
      "user_progress_summaries",
      "object_write_leases",
    ]) {
      expect(
        scalar(
          session,
          `select count(*)::text from public.${table} where user_id = ${sqlString(USER_B)}::uuid`,
        ),
        `${table} retained rows for the deleted account`,
      ).toBe("0");
    }
    expect(
      scalar(
        session,
        `select count(*)::text from public.assistant_cache_entries
         where id = ${sqlString(sharedCacheId)}::uuid`,
      ),
    ).toBe("1");
    expect(
      callJson(
        session,
        `select jsonb_build_object(
           'userIdRemoved', user_id is null,
           'payload', payload,
           'cacheKeyRemoved', cache_key is null,
           'lastErrorRemoved', last_error is null
         ) from public.assistant_jobs where id = ${sqlString(deletionJobId)}::uuid`,
      ),
    ).toEqual({
      userIdRemoved: true,
      payload: {},
      cacheKeyRemoved: true,
      lastErrorRemoved: true,
    });
  });
});

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
