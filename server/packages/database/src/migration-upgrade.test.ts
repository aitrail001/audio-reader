import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startPostgres, type PostgresSession } from "./postgres-harness";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const migrationsDir = join(serverRoot, "supabase", "migrations");
const OLD_SCHEMA_CUTOFF = "20260831120000";
const LIFECYCLE_UPGRADE = "20260831125000_assistant_result_lifecycle_upgrade.sql";
const DELETED_BOOK_CLEANUP_VERSION = "20260901090000";
const USER_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const DEVICE_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1";
const RESULT_ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const CACHE_ID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

function migrationSql(predicate: (version: string) => boolean): string {
  return readdirSync(migrationsDir)
    .filter((name) => name.endsWith(".sql") && predicate(name.slice(0, 14)))
    .sort()
    .map((name) => readFileSync(join(migrationsDir, name), "utf8"))
    .join("\n");
}

function requireDb(db: PostgresSession | undefined): PostgresSession {
  if (db === undefined) throw new Error("postgres session was not started");
  return db;
}

function execOk(db: PostgresSession, sql: string): string {
  const result = db.exec(sql);
  if (!result.ok) throw new Error(result.stderr || result.stdout);
  return result.stdout;
}

function scalar(db: PostgresSession, sql: string): string {
  return execOk(db, sql).trim().split("\n").at(-1)?.trim() ?? "";
}

function sqlString(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function sqlJson(value: unknown): string {
  return sqlString(JSON.stringify(value));
}

describe("forward-only assistant result lifecycle migration (postgres)", () => {
  let db: PostgresSession | undefined;

  beforeAll(async () => {
    db = await startPostgres();
  }, 180_000);

  afterAll(async () => {
    await db?.stop();
  });

  it("upgrades an already-applied schema without losing private rows or lifecycle history", () => {
    const session = requireDb(db);
    execOk(
      session,
      migrationSql((version) => version <= OLD_SCHEMA_CUTOFF),
    );

    // Model the hosted schema before lifecycle columns were mistakenly added to an applied file.
    execOk(
      session,
      `
      drop trigger if exists append_user_assistant_result_history
        on public.user_assistant_results;
      drop function if exists public.append_user_assistant_result_history();
      alter table public.user_assistant_results
        drop constraint user_assistant_results_status_check,
        drop column if exists result_kind,
        drop column if exists language,
        drop column if exists source_text,
        drop column if exists context_text,
        drop column if exists book_title,
        drop column if exists chapter_title,
        drop column if exists timestamp_seconds,
        drop column if exists private_content,
        drop column if exists model,
        drop column if exists prompt_version,
        drop column if exists model_policy_hash,
        drop column if exists replaced_text,
        drop column if exists replaced_model,
        drop column if exists history;
      alter table public.user_assistant_results
        add constraint user_assistant_results_status_check
        check (status in ('pending', 'accepted', 'rejected'));
      update public.feature_flags set enabled = true where key = 'account_sync';

      insert into public.profiles (user_id, display_name, account_status)
      values (${sqlString(USER_ID)}::uuid, 'upgrade user', 'active');
      insert into public.devices (id, user_id, platform, app_version)
      values (${sqlString(DEVICE_ID)}::uuid, ${sqlString(USER_ID)}::uuid, 'macos', '1.0.0');
      insert into public.assistant_cache_entries (
        id, cache_key, task_type, source_language, target_language, state, result
      ) values (
        ${sqlString(CACHE_ID)}::uuid, 'upgrade-cache', 'translation', 'en', 'zh',
        'active', '{"translation":"shared"}'::jsonb
      );
      insert into public.user_assistant_results (
        id, user_id, cache_entry_id, task_type, status, target_id,
        private_notes, private_edited_output, output_text, created_at, updated_at
      ) values (
        ${sqlString(RESULT_ID)}::uuid, ${sqlString(USER_ID)}::uuid,
        ${sqlString(CACHE_ID)}::uuid, 'translation', 'pending', 'sentence-1',
        'private note', 'private draft', 'private generated text',
        '2026-08-30T00:00:00Z', '2026-08-30T00:01:00Z'
      );
    `,
    );

    execOk(
      session,
      migrationSql(
        (version) => version > OLD_SCHEMA_CUTOFF && version < DELETED_BOOK_CLEANUP_VERSION,
      ),
    );
    const deletedBookId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    const smallAssetId = "11111111-1111-4111-8111-111111111111";
    const largeAssetId = "22222222-2222-4222-8222-222222222222";
    const deletingAssetId = "33333333-3333-4333-8333-333333333333";
    execOk(
      session,
      `insert into public.asset_manifests_v2 (
         id, upload_id, user_id, kind, content_type, encoding, compressed_bytes,
         original_bytes, sha256, object_key, upload_object_key, book_id, status, ready_at
       ) values
       (${sqlString(smallAssetId)}::uuid, gen_random_uuid(), ${sqlString(USER_ID)}::uuid,
        'audio', 'audio/mp4', 'identity', 1, 1, repeat('1', 64),
        'private/v2/${USER_ID}/audio/small', 'private/v2/${USER_ID}/pending/small',
        ${sqlString(deletedBookId)}::uuid, 'ready', clock_timestamp()),
       (${sqlString(largeAssetId)}::uuid, gen_random_uuid(), ${sqlString(USER_ID)}::uuid,
        'audio', 'audio/mp4', 'identity', 8388609, 8388609, repeat('2', 64),
        'private/v2/${USER_ID}/audio/large', 'private/v2/${USER_ID}/pending/large',
        ${sqlString(deletedBookId)}::uuid, 'ready', clock_timestamp()),
       (${sqlString(deletingAssetId)}::uuid, gen_random_uuid(), ${sqlString(USER_ID)}::uuid,
        'audio', 'audio/mp4', 'identity', 1, 1, repeat('3', 64),
        'private/v2/${USER_ID}/audio/deleting', 'private/v2/${USER_ID}/pending/deleting',
        ${sqlString(deletedBookId)}::uuid, 'deleting', null);
       insert into public.sync_v2_changes (
         user_id, entity_type, entity_id, operation, revision, payload
       ) values (${sqlString(USER_ID)}::uuid, 'book', ${sqlString(deletedBookId)}::uuid,
         'delete', 1, '{}'::jsonb)`,
    );
    execOk(
      session,
      migrationSql((version) => version >= DELETED_BOOK_CLEANUP_VERSION),
    );

    expect(
      scalar(
        session,
        `select string_agg(id::text || ':' || status, ',' order by id)
         from public.asset_manifests_v2
         where id in (${sqlString(smallAssetId)}::uuid, ${sqlString(largeAssetId)}::uuid,
           ${sqlString(deletingAssetId)}::uuid)`,
      ),
    ).toBe(`${smallAssetId}:deleting,${largeAssetId}:deleting,${deletingAssetId}:deleting`);
    expect(
      scalar(
        session,
        `select (select upload_authorized_until is null from public.asset_manifests_v2
           where id = ${sqlString(smallAssetId)}::uuid)::text || '|' ||
          (select upload_authorized_until > clock_timestamp() + interval '23 hours'
           from public.asset_manifests_v2 where id = ${sqlString(largeAssetId)}::uuid)::text`,
      ),
    ).toBe("true|true");
    expect(
      scalar(
        session,
        `select (deleted_at is not null)::text from public.asset_manifests_v2
         where id = ${sqlString(deletingAssetId)}::uuid`,
      ),
    ).toBe("true");
    expect(
      scalar(
        session,
        `select count(*)::text from public.sync_v2_changes where user_id = ${sqlString(USER_ID)}::uuid
         and entity_type = 'asset' and operation = 'delete'
         and entity_id in (${sqlString(smallAssetId)}::uuid, ${sqlString(largeAssetId)}::uuid)`,
      ),
    ).toBe("2");
    expect(
      scalar(
        session,
        `select migration_version from public.service_schema_versions
         where component = 'account_sync'`,
      ),
    ).toBe(DELETED_BOOK_CLEANUP_VERSION);

    expect(
      scalar(
        session,
        `
      select status || '|' || output_text || '|' || private_notes || '|' ||
        private_edited_output || '|' || cache_entry_id::text
      from public.user_assistant_results where id = ${sqlString(RESULT_ID)}::uuid
    `,
      ),
    ).toBe(`pending|private generated text|private note|private draft|${CACHE_ID}`);
    expect(
      scalar(
        session,
        `
      select history -> 0 ->> 'outputText'
      from public.user_assistant_results where id = ${sqlString(RESULT_ID)}::uuid
    `,
      ),
    ).toBe("private generated text");
    expect(
      scalar(
        session,
        `
      select enabled::text from public.feature_flags where key = 'account_sync'
    `,
      ),
    ).toBe("false");

    const lifecycle = [
      ["accepted", "accepted private text", "qwen-managed-v3", "a".repeat(64)],
      ["edited", "edited private text", "qwen-managed-v3", "a".repeat(64)],
      ["replaced", "replacement private text", "qwen-managed-v4", "b".repeat(64)],
    ] as const;
    for (const [index, [status, text, promptVersion, modelPolicyHash]] of lifecycle.entries()) {
      const mutation = {
        mutationId: crypto.randomUUID(),
        entityType: "assistant_result",
        entityId: RESULT_ID,
        operation: "upsert",
        baseRevision: index,
        occurredAt: `2026-09-01T00:00:0${String(index + 1)}Z`,
        payload: {
          result: {
            id: RESULT_ID,
            kind: "sentenceGloss",
            status,
            language: "zh-Hans",
            model: status === "replaced" ? "qwen3.5-plus-2026-08-31" : "qwen3.5-plus-2026-08-01",
            promptVersion,
            modelPolicyHash,
            source: "private source",
            text,
            createdAt: "2026-08-30T00:00:00Z",
            decidedAt: `2026-09-01T00:00:0${String(index + 1)}Z`,
            sharedCacheEntryID: CACHE_ID,
          },
          vocabulary: [],
        },
      };
      const pushed = execOk(
        session,
        `select public.push_sync_v2_batch(
        ${sqlString(USER_ID)}::uuid, ${sqlString(DEVICE_ID)}::uuid,
        ${sqlString(crypto.randomUUID())}::uuid, ${sqlJson([mutation])}::jsonb
      )`,
      );
      expect(pushed).toContain("applied");
    }

    expect(
      scalar(
        session,
        `
      select status || '|' || output_text || '|' || prompt_version || '|' ||
        model_policy_hash || '|' || jsonb_array_length(history)::text
      from public.user_assistant_results where id = ${sqlString(RESULT_ID)}::uuid
    `,
      ),
    ).toBe(`replaced|replacement private text|qwen-managed-v4|${"b".repeat(64)}|4`);
    expect(
      scalar(
        session,
        `
      with bootstrap as (
        select public.bootstrap_sync_v2_page(
          ${sqlString(USER_ID)}::uuid, null, 0, 500, 1048576
        ) as payload
      )
      select (entity -> 'payload' -> 'result' ->> 'id') || '|' ||
        (entity -> 'payload' -> 'result' ->> 'status') || '|' ||
        (entity -> 'payload' -> 'result' ->> 'text')
      from bootstrap, jsonb_array_elements(payload -> 'entities') entity
      where entity ->> 'entity_type' = 'assistant_result'
        and entity ->> 'entity_id' = ${sqlString(RESULT_ID)}
    `,
      ),
    ).toBe(`${RESULT_ID}|replaced|replacement private text`);
    expect(
      scalar(
        session,
        `
      select count(*)::text from public.quota_limits
      where (key, limit_value) in (
        ('qwen_tasks_day', 50), ('cloud_media_bytes', 262144000),
        ('cloud_books', 3), ('devices', 2)
      )
    `,
      ),
    ).toBe("4");

    execOk(session, readFileSync(join(migrationsDir, LIFECYCLE_UPGRADE), "utf8"));
    expect(
      scalar(
        session,
        `
      select status || '|' || output_text || '|' || jsonb_array_length(history)::text
      from public.user_assistant_results where id = ${sqlString(RESULT_ID)}::uuid
    `,
      ),
    ).toBe("replaced|replacement private text|4");
  }, 180_000);
});
