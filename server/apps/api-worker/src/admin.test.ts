import { LOCAL_PASSWORDLESS_HMAC_SECRET, createFakePrincipal } from "@audio-reader/auth";
import { RestPersistenceError, createFakeDatabaseClient } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";
import { createRuntimeConfigService } from "./runtime-config";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const USER_ID = "00000000-0000-4000-8000-000000000002";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

describe("admin and privacy API", () => {
  it("forbids ordinary users from listing admin users", async () => {
    const app = createTestApp();
    const response = await app.fetch(
      new Request("http://localhost/v1/admin/users", { headers: { authorization: "Bearer test" } }),
    );
    expect(response.status).toBe(403);
  });

  it("lists users, policies, metrics, and cache for admins", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const users = await app.fetch(
      new Request("http://localhost/v1/admin/users", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(users.status).toBe(200);
    const page = await readJson(users);
    expect(isRecord(page) && Array.isArray(page.items)).toBe(true);
    const policies = await app.fetch(
      new Request("http://localhost/v1/admin/llm/policies", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(policies.status).toBe(200);
    const usage = await app.fetch(
      new Request("http://localhost/v1/admin/product-events", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(usage.status).toBe(200);
    const policyBody = await readJson(policies);
    expect(Array.isArray(policyBody)).toBe(true);
    if (Array.isArray(policyBody) && isRecord(policyBody[0])) {
      expect(typeof policyBody[0].systemPrompt).toBe("string");
      expect(String(policyBody[0].systemPrompt).length).toBeGreaterThan(20);
    }
    const metrics = await app.fetch(
      new Request("http://localhost/v1/admin/metrics", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(metrics.status).toBe(200);
  });

  it("lets admins change a task system prompt", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const patched = await app.fetch(
      new Request("http://localhost/v1/admin/llm/policies/00000000-0000-4000-8000-0000000000aa", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-policy-prompt-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          reason: "tune translation prompt",
          promptVersion: "qwen-managed-v2",
          systemPrompt: "Return JSON with keys translation and notes. Be terse.",
          userPrompt: "Translate {{source}} into {{targetLanguage}}.",
        }),
      }),
    );
    expect(patched.status).toBe(200);
    const body = await readJson(patched);
    expect(isRecord(body) && body.promptVersion).toBe("qwen-managed-v2");
    expect(isRecord(body) && body.systemPrompt).toBe(
      "Return JSON with keys translation and notes. Be terse.",
    );
    expect(isRecord(body) && body.userPrompt).toBe("Translate {{source}} into {{targetLanguage}}.");
    const events = await app.fetch(
      new Request("http://localhost/v1/admin/events", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(events.status).toBe(200);
    const eventBody = await readJson(events);
    expect(Array.isArray(eventBody)).toBe(true);
    expect(
      Array.isArray(eventBody) &&
        eventBody.some((item) => isRecord(item) && item.kind === "patch_policy"),
    ).toBe(true);
    const user = await app.fetch(
      new Request(`http://localhost/v1/admin/users/${USER_ID}`, {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(user.status).toBe(200);
    const userBody = await readJson(user);
    expect(isRecord(userBody) && Array.isArray(userBody.quotas)).toBe(true);
    expect(isRecord(userBody) && userBody.accountId).toBe(USER_ID);
    expect(isRecord(userBody) && Array.isArray(userBody.devices)).toBe(true);
  });

  it("does not report a policy save when Postgres rejected the write", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    database.ops.patchPolicy = () => Promise.reject(new RestPersistenceError(502, "JWT expired"));
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const patched = await app.fetch(
      new Request("http://localhost/v1/admin/llm/policies/00000000-0000-4000-8000-0000000000aa", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-policy-prompt-02",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          reason: "switch translation model",
          model: "qwen3.6-flash",
        }),
      }),
    );
    expect(patched.status).toBe(502);
    const listed = await database.ops.listPolicies();
    expect(listed.find((policy) => policy.id.endsWith("aa"))?.model).not.toBe("qwen3.6-flash");
  });

  it("does not report a feature flag save when Postgres rejected the write", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    database.ops.patchFlag = () => Promise.reject(new RestPersistenceError(502, "JWT expired"));
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const patched = await app.fetch(
      new Request("http://localhost/v1/admin/feature-flags/managed_qwen", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-flag-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          reason: "disable managed qwen",
          enabled: false,
        }),
      }),
    );
    expect(patched.status).toBe(502);
    expect(
      (await database.ops.listFlags()).find((flag) => flag.key === "managed_qwen")?.enabled,
    ).toBe(true);
  });

  it("does not report a quota save when Postgres rejected the write", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    database.ops.patchQuota = () => Promise.reject(new RestPersistenceError(502, "JWT expired"));
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const patched = await app.fetch(
      new Request("http://localhost/v1/admin/quotas/qwen_tasks_day", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-quota-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          reason: "raise daily qwen cap",
          limit: 9,
        }),
      }),
    );
    expect(patched.status).toBe(502);
    expect(
      (await database.ops.quotasFor(USER_ID)).find((item) => item.key === "qwen_tasks_day")?.limit,
    ).toBe(50);
  });

  it("does not report a runtime config save when Postgres rejected the write", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    const runtime = createRuntimeConfigService({
      env: { ENVIRONMENT: "test" },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });
    runtime.put = () => Promise.reject(new RestPersistenceError(502, "JWT expired"));
    const app = createTestApp({
      database,
      runtime,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const saved = await app.fetch(
      new Request("http://localhost/v1/admin/runtime-config", {
        method: "PUT",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-runtime-fail-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          reason: "set qwen overlay",
          qwen: {
            apiKey: "sk-live-secret",
            baseUrl: "https://example.invalid/v1",
            model: "qwen3.6-flash",
          },
        }),
      }),
    );
    expect(saved.status).toBe(502);
    expect(JSON.stringify(await readJson(saved))).not.toContain("sk-live-secret");
  });

  it("returns 503 when operator wrapping is not configured instead of 500", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    const runtime = createRuntimeConfigService({
      env: { ENVIRONMENT: "production" },
      ops: database.ops,
      wrappingSecret: LOCAL_PASSWORDLESS_HMAC_SECRET,
      wrappingSource: "none",
    });
    const app = createTestApp({
      database,
      runtime,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const saved = await app.fetch(
      new Request("http://localhost/v1/admin/runtime-config", {
        method: "PUT",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-runtime-wrap-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          reason: "set qwen overlay",
          qwen: {
            apiKey: "sk-should-not-wrap",
            model: "qwen3.7-flash",
          },
        }),
      }),
    );
    expect(saved.status).toBe(503);
    const body = await readJson(saved);
    expect(isRecord(body) && body.code).toBe("dependency_failed");
    expect(JSON.stringify(body)).toContain("OPERATOR_CONFIG_KEY");
    expect(JSON.stringify(body)).not.toContain("sk-should-not-wrap");
  });

  it("lets admins read and write runtime config without returning secrets", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const headers = {
      authorization: "Bearer admin",
      "X-Device-Id": DEVICE_ID,
      "Idempotency-Key": "idempotency-key-runtime-01",
      "content-type": "application/json",
    };
    const saved = await app.fetch(
      new Request("http://localhost/v1/admin/runtime-config", {
        method: "PUT",
        headers,
        body: JSON.stringify({
          reason: "set qwen overlay",
          qwen: {
            apiKey: "sk-live-secret",
            baseUrl: "https://example.invalid/v1",
            model: "qwen3.7-flash",
          },
        }),
      }),
    );
    expect(saved.status).toBe(200);
    const body = await readJson(saved);
    expect(isRecord(body)).toBe(true);
    if (!isRecord(body) || !isRecord(body.qwen)) {
      return;
    }
    expect(body.qwen.apiKeyConfigured).toBe(true);
    expect(body.qwen.apiKeyLast4).toBe("cret");
    expect(body.qwen.model).toBe("qwen3.7-flash");
    expect(JSON.stringify(body)).not.toContain("sk-live-secret");

    const loaded = await app.fetch(
      new Request("http://localhost/v1/admin/runtime-config", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(loaded.status).toBe(200);
    const view = await readJson(loaded);
    expect(isRecord(view) && isRecord(view.qwen) && view.qwen.model).toBe("qwen3.7-flash");
  });

  it("lets admins grant the operator role", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    const other = await database.identity.ensureProfile({
      userId: "00000000-0000-4000-8000-000000000099",
      email: "reader@example.com",
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const granted = await app.fetch(
      new Request(`http://localhost/v1/admin/users/${other.accountId}/grant-admin`, {
        method: "POST",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-grant-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({ reason: "promote operator" }),
      }),
    );
    expect(granted.status).toBe(200);
    await expect(database.identity.hasAdminRole(other.accountId)).resolves.toBe(true);
  });

  it("queues an account export and a deletion request", async () => {
    const app = createTestApp();
    const exported = await app.fetch(
      new Request("http://localhost/v1/exports", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-export-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({ format: "json" }),
      }),
    );
    expect(exported.status).toBe(202);
    const job = await readJson(exported);
    expect(isRecord(job) && job.status).toBe("ready");
    expect(isRecord(job) && typeof job.assetId === "string").toBe(true);
    if (!isRecord(job) || typeof job.id !== "string" || typeof job.assetId !== "string") {
      return;
    }
    const fetched = await app.fetch(
      new Request(`http://localhost/v1/exports/${job.id}`, {
        headers: { authorization: "Bearer test" },
      }),
    );
    expect(fetched.status).toBe(200);
    const content = await app.fetch(
      new Request(`http://localhost/v1/assets/${job.assetId}/content`, {
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
        },
      }),
    );
    expect(content.status).toBe(200);
    const payload = await readJson(content);
    expect(isRecord(payload) && isRecord(payload.account)).toBe(true);
    const usage = await app.fetch(
      new Request("http://localhost/v1/admin/product-events", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(usage.status).toBe(403);
    const deletion = await app.fetch(
      new Request("http://localhost/v1/me/deletion", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-delete-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({ confirmation: "DELETE MY ACCOUNT", reason: "leaving the product" }),
      }),
    );
    expect(deletion.status).toBe(202);
  });

  it("lists and patches feature flags, quotas, and privacy requests", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const flags = await app.fetch(
      new Request("http://localhost/v1/admin/feature-flags", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(flags.status).toBe(200);
    const flagBody = await readJson(flags);
    expect(Array.isArray(flagBody)).toBe(true);
    const patched = await app.fetch(
      new Request("http://localhost/v1/admin/feature-flags/maintenance_mode", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-flag-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({ reason: "pause managed work", enabled: true }),
      }),
    );
    expect(patched.status).toBe(200);
    const quotas = await app.fetch(
      new Request("http://localhost/v1/admin/quotas", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(quotas.status).toBe(200);
    const quotaPatch = await app.fetch(
      new Request("http://localhost/v1/admin/quotas/devices", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-quota-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({ reason: "allow a third reader", limit: 3 }),
      }),
    );
    expect(quotaPatch.status).toBe(200);
    const quotaBody = await readJson(quotaPatch);
    expect(isRecord(quotaBody) && quotaBody.limit).toBe(3);

    await database.ops.createPrivacyRequest({
      accountId: USER_ID,
      kind: "deletion",
      status: "queued",
      reason: "user asked support",
    });
    const privacy = await app.fetch(
      new Request("http://localhost/v1/admin/privacy-requests", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(privacy.status).toBe(200);
    const page = await readJson(privacy);
    expect(isRecord(page) && Array.isArray(page.items) && page.items.length >= 1).toBe(true);
    const first =
      isRecord(page) && Array.isArray(page.items) && isRecord(page.items[0])
        ? page.items[0]
        : undefined;
    expect(first !== undefined && typeof first.id === "string").toBe(true);
    if (first === undefined || typeof first.id !== "string") {
      return;
    }
    const cancelled = await app.fetch(
      new Request(`http://localhost/v1/admin/privacy-requests/${first.id}/actions`, {
        method: "POST",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-privacy-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({ action: "cancel", reason: "user changed their mind" }),
      }),
    );
    expect(cancelled.status).toBe(200);
  });

  it("returns operator diagnostics without secrets and can probe completions", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    const fetchImpl: typeof fetch = (input) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (url.endsWith("/models")) {
        return Promise.resolve(
          new Response(JSON.stringify({ data: [{ id: "qwen3.7-flash" }] }), { status: 200 }),
        );
      }
      if (url.endsWith("/chat/completions")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              model: "qwen3.7-flash",
              choices: [{ message: { role: "assistant", content: "pong" } }],
            }),
            { status: 200 },
          ),
        );
      }
      return Promise.resolve(new Response("missing", { status: 404 }));
    };
    const runtime = createRuntimeConfigService({
      env: { ENVIRONMENT: "test" },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
      wrappingSource: "cache_hmac",
      fetch: fetchImpl,
    });
    const app = createTestApp({
      database,
      runtime,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const headers = {
      authorization: "Bearer admin",
      "X-Device-Id": DEVICE_ID,
      "Idempotency-Key": "idempotency-key-diag-01",
      "content-type": "application/json",
    };
    const saved = await app.fetch(
      new Request("http://localhost/v1/admin/runtime-config", {
        method: "PUT",
        headers,
        body: JSON.stringify({
          reason: "set qwen overlay for diagnostics",
          qwen: {
            apiKey: "sk-live-secret",
            baseUrl: "https://example.invalid/v1",
            model: "qwen3.7-flash",
          },
        }),
      }),
    );
    expect(saved.status).toBe(200);
    const snapshot = await app.fetch(
      new Request("http://localhost/v1/admin/diagnostics", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(snapshot.status).toBe(200);
    const body = await readJson(snapshot);
    expect(isRecord(body)).toBe(true);
    if (!isRecord(body) || !isRecord(body.runtime) || !isRecord(body.runtime.qwen)) {
      return;
    }
    expect(body.runtime.qwen.apiKeyConfigured).toBe(true);
    expect(body.runtime.qwen.model).toBe("qwen3.7-flash");
    expect(body.qwenProbe).toBe("ok (HTTP 200)");
    expect(isRecord(body.qwenComplete) && body.qwenComplete.status).toBe("skipped");
    expect(Array.isArray(body.notes)).toBe(true);
    expect(Array.isArray(body.flags)).toBe(true);
    expect(Array.isArray(body.quotas)).toBe(true);
    expect(JSON.stringify(body)).not.toContain("sk-live-secret");
    const probed = await app.fetch(
      new Request("http://localhost/v1/admin/diagnostics?probe=complete", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(probed.status).toBe(200);
    const probedBody = await readJson(probed);
    expect(
      isRecord(probedBody) &&
        isRecord(probedBody.qwenComplete) &&
        probedBody.qwenComplete.status === "ok" &&
        probedBody.qwenComplete.model === "qwen3.7-flash",
    ).toBe(true);
  });
});
