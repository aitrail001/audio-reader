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
});

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
