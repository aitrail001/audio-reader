import { createFakeDatabaseClient } from "@audio-reader/database";
import { createFakeQwenClient } from "@audio-reader/qwen";
import { afterEach, describe, expect, it, vi } from "vitest";
import { consumeJobBatch, processQueuedJobs, runScheduledMaintenance } from "./jobs";
import worker, { resolveJobOperatorWrappingSecret } from "./worker";

function deletionStore(keys: string[], failKey?: string) {
  const remaining = new Set(keys);
  return {
    deleted: [] as string[],
    list(prefix: string) {
      return Promise.resolve([...remaining].filter((key) => key.startsWith(prefix)));
    },
    delete(key: string) {
      if (key === failKey) return Promise.reject(new Error("object delete failed"));
      remaining.delete(key);
      this.deleted.push(key);
      return Promise.resolve();
    },
  };
}

describe("job worker", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("uses the same Operator wrapping-key priority as the API Worker", () => {
    expect(
      resolveJobOperatorWrappingSecret({
        OPERATOR_CONFIG_KEY: "operator",
        CACHE_HMAC_SECRET: "cache",
        PASSWORDLESS_HMAC_SECRET: "passwordless",
      }),
    ).toBe("operator");
    expect(
      resolveJobOperatorWrappingSecret({
        CACHE_HMAC_SECRET: "cache",
        PASSWORDLESS_HMAC_SECRET: "passwordless",
      }),
    ).toBe("cache");
    expect(resolveJobOperatorWrappingSecret({ PASSWORDLESS_HMAC_SECRET: "passwordless" })).toBe(
      "passwordless",
    );
    expect(resolveJobOperatorWrappingSecret({})).toBe("");
  });

  it("reports unavailable instead of silently using memory without hosted database secrets", async () => {
    const unavailable = await Promise.resolve(
      worker.fetch(new Request("https://job-worker.example/health"), {}),
    );
    expect(unavailable.status).toBe(503);
    await expect(unavailable.json()).resolves.toMatchObject({
      status: "unavailable",
      dependencies: { database: "unavailable" },
    });
    await expect(worker.queue({ messages: [] } as unknown as MessageBatch, {})).rejects.toThrow(
      "job_worker_database_not_configured",
    );

    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response("[]", { status: 200 }))),
    );
    const configured = await Promise.resolve(
      worker.fetch(new Request("https://job-worker.example/health"), {
        APP_VERSION: "1.0.0",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
        SUPABASE_STORAGE_BUCKET: "audio-reader",
      }),
    );
    expect(configured.status).toBe(200);
    await expect(configured.json()).resolves.toMatchObject({
      status: "ok",
      version: "1.0.0",
      dependencies: { database: "ok", storage: "ok" },
    });

    const unidentifiedStorage = await Promise.resolve(
      worker.fetch(new Request("https://job-worker.example/health"), {
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
      }),
    );
    expect(unidentifiedStorage.status).toBe(503);
    await expect(unidentifiedStorage.json()).resolves.toMatchObject({
      dependencies: { database: "ok", storage: "unavailable" },
    });

    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response("database down", { status: 503 }))),
    );
    const down = await Promise.resolve(
      worker.fetch(new Request("https://job-worker.example/health"), {
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
      }),
    );
    expect(down.status).toBe(503);
    await expect(down.json()).resolves.toMatchObject({
      status: "unavailable",
      dependencies: { database: "unavailable" },
    });
  });

  it("completes queued assistant jobs with Qwen", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.createJob({
      accountId: "00000000-0000-4000-8000-000000000002",
      kind: "chat",
      payload: { message: "hello" },
    });
    const completed = await processQueuedJobs(database.ops, createFakeQwenClient({ text: "hi" }));
    expect(completed).toBe(1);
    const jobs = await database.ops.listJobs({ status: "succeeded" });
    expect(jobs).toHaveLength(1);
    expect(jobs[0]?.payload.text).toBe("hi");
  });

  it("acks a queue batch after processing queued jobs", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.createJob({
      accountId: "00000000-0000-4000-8000-000000000002",
      kind: "translation",
      payload: { message: "hello" },
    });
    const acked: string[] = [];
    const completed = await consumeJobBatch(database.ops, createFakeQwenClient({ text: "ok" }), [
      {
        ack: () => acked.push("ack"),
        retry: () => acked.push("retry"),
      },
    ]);
    expect(completed).toBe(1);
    expect(acked).toEqual(["ack"]);
  });

  it("completes account deletion jobs only after the database erases the account", async () => {
    const database = createFakeDatabaseClient();
    const profile = await database.identity.ensureProfile({
      userId: "00000000-0000-4000-8000-000000000002",
      email: "gone@example.com",
    });
    await database.ops.createPrivacyRequest({
      accountId: profile.accountId,
      kind: "deletion",
      status: "queued",
      reason: "leaving",
    });
    await database.ops.createJob({
      accountId: profile.accountId,
      kind: "account_deletion",
      payload: { reason: "leaving" },
    });
    const deleted: string[] = [];
    Object.assign(database.ops, {
      deleteAccountData(accountId: string) {
        deleted.push(accountId);
        return Promise.resolve(true);
      },
    });
    const objects = deletionStore([`${profile.accountId}/audio.m4b`, "other-user/cover.jpg"]);
    const completed = await processQueuedJobs(database.ops, createFakeQwenClient(), objects);
    expect(completed).toBe(1);
    expect(deleted).toEqual([profile.accountId]);
    expect(objects.deleted).toEqual([`${profile.accountId}/audio.m4b`]);
    expect(await database.ops.listJobs({ status: "succeeded" })).toHaveLength(1);
  });

  it("defers deletion without spending retry budget until an object-write lease expires", async () => {
    const database = createFakeDatabaseClient();
    const accountId = "00000000-0000-4000-8000-000000000002";
    const objectKey = `${accountId}/late-audio.m4b`;
    const job = await database.ops.createJob({ accountId, kind: "account_deletion", payload: {} });
    const lease = await database.ops.beginObjectWrite(accountId, objectKey);
    let databaseErased = false;
    Object.assign(database.ops, {
      deleteAccountData() {
        databaseErased = true;
        return Promise.resolve(true);
      },
    });
    const objects = deletionStore([objectKey]);

    await expect(processQueuedJobs(database.ops, createFakeQwenClient(), objects)).resolves.toBe(0);
    expect(databaseErased).toBe(false);
    expect(await database.ops.getJob(job.id)).toMatchObject({ status: "queued", attempts: 0 });
    expect(objects.deleted).toEqual([]);

    Object.assign(database.ops, {
      accountObjectWriteLeases: () =>
        Promise.resolve([{ ...lease, expiresAt: new Date(0).toISOString() }]),
    });
    await expect(processQueuedJobs(database.ops, createFakeQwenClient(), objects)).resolves.toBe(1);
    expect(databaseErased).toBe(true);
    expect(objects.deleted).toEqual([objectKey]);
  });

  it("purges expired progress snapshots and product events on the independent scheduled path", async () => {
    const database = createFakeDatabaseClient();
    const calls: string[] = [];
    Object.assign(database.ops, {
      purgeExpiredUserProgressSummaries() {
        calls.push("progress-purge");
        return Promise.resolve(2);
      },
      purgeExpiredProductEvents() {
        calls.push("event-purge");
        return Promise.resolve(7);
      },
      claimJobs() {
        calls.push("jobs");
        return Promise.resolve([]);
      },
    });
    await expect(
      runScheduledMaintenance(database.ops, createFakeQwenClient()),
    ).resolves.toMatchObject({ purgedSnapshots: 2, purgedProductEvents: 7, completedJobs: 0 });
    expect(calls).toEqual(["progress-purge", "event-purge", "jobs"]);
  });

  it("does not complete an account deletion job when erasure fails", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.createJob({
      accountId: "00000000-0000-4000-8000-000000000002",
      kind: "account_deletion",
      payload: { reason: "leaving" },
    });
    Object.assign(database.ops, {
      deleteAccountData() {
        return Promise.resolve(false);
      },
    });
    await expect(
      processQueuedJobs(database.ops, createFakeQwenClient(), deletionStore([])),
    ).resolves.toBe(0);
    expect(await database.ops.listJobs({ status: "succeeded" })).toHaveLength(0);
    expect(await database.ops.listJobs({ status: "queued" })).toHaveLength(1);
  });

  it("retries transient deletion failures and dead-letters only at the attempt limit", async () => {
    const database = createFakeDatabaseClient();
    const retrying = await database.ops.createJob({
      accountId: "00000000-0000-4000-8000-000000000002",
      kind: "account_deletion",
      payload: {},
    });
    let erasures = 0;
    Object.assign(database.ops, {
      deleteAccountData() {
        erasures += 1;
        return Promise.resolve(erasures >= 3);
      },
    });
    await expect(
      processQueuedJobs(database.ops, createFakeQwenClient(), deletionStore([])),
    ).resolves.toBe(0);
    await expect(
      processQueuedJobs(database.ops, createFakeQwenClient(), deletionStore([])),
    ).resolves.toBe(0);
    await expect(
      processQueuedJobs(database.ops, createFakeQwenClient(), deletionStore([])),
    ).resolves.toBe(1);
    expect(await database.ops.getJob(retrying.id)).toMatchObject({
      status: "succeeded",
      attempts: 3,
    });

    const terminal = await database.ops.createJob({
      accountId: "00000000-0000-4000-8000-000000000003",
      kind: "account_deletion",
      payload: {},
    });
    await database.ops.updateJob(terminal.id, { attempts: terminal.maxAttempts - 1 });
    Object.assign(database.ops, { deleteAccountData: () => Promise.resolve(false) });
    await expect(
      processQueuedJobs(database.ops, createFakeQwenClient(), deletionStore([])),
    ).resolves.toBe(0);
    expect(await database.ops.getJob(terminal.id)).toMatchObject({
      status: "dead_letter",
      attempts: terminal.maxAttempts,
    });
  });

  it("retries without deleting database metadata when an object body cannot be erased", async () => {
    const database = createFakeDatabaseClient();
    const accountId = "00000000-0000-4000-8000-000000000002";
    await database.ops.createJob({ accountId, kind: "account_deletion", payload: {} });
    let databaseErased = false;
    Object.assign(database.ops, {
      accountObjectKeys: () => Promise.resolve([`${accountId}/ebook.epub`]),
      deleteAccountData: () => {
        databaseErased = true;
        return Promise.resolve(true);
      },
    });

    const objects = deletionStore(
      [`${accountId}/audio.m4b`, `${accountId}/ebook.epub`],
      `${accountId}/ebook.epub`,
    );
    await expect(processQueuedJobs(database.ops, createFakeQwenClient(), objects)).resolves.toBe(0);
    expect(databaseErased).toBe(false);
    expect(await database.ops.listJobs({ status: "queued" })).toHaveLength(1);
  });

  it("fails health closed when hosted Operator settings cannot be read", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn((input: string | URL | Request) => {
        const url = String(input instanceof Request ? input.url : input);
        if (url.includes("/operator_settings")) {
          return Promise.resolve(new Response("database down", { status: 503 }));
        }
        return Promise.resolve(new Response("[]", { status: 200 }));
      }),
    );
    const response = await Promise.resolve(
      worker.fetch(new Request("https://job-worker.example/health"), {
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
      }),
    );
    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toMatchObject({
      status: "unavailable",
      dependencies: { database: "ok", storage: "unavailable" },
    });
  });
});
