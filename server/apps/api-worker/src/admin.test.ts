import {
  LOCAL_PASSWORDLESS_HMAC_SECRET,
  createFakePrincipal,
  type AdminRole,
} from "@audio-reader/auth";
import { RestPersistenceError, createFakeDatabaseClient } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";
import { createFakeObjectStore, createUnavailableObjectStore } from "./object-store";
import { createRuntimeConfigService } from "./runtime-config";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const USER_ID = "00000000-0000-4000-8000-000000000002";
const OPERATOR_ID = "00000000-0000-4000-8000-000000000003";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function pageItems(value: unknown): Array<Record<string, unknown>> {
  return isRecord(value) && Array.isArray(value.items) ? value.items.filter(isRecord) : [];
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

describe("admin and privacy API", () => {
  it("audits legacy cleanup dry-runs without enqueueing destructive work", async () => {
    const database = createFakeDatabaseClient();
    const cleanup = {
      changes: 3, outcomes: 2, batches: 1, transcriptRevisions: 4,
      transcriptSegments: 20, assets: 5, objectKeys: [`${USER_ID}/legacy.epub`], executed: false,
    };
    Object.assign(database.ops, {
      cleanupObsoleteV1Data: () => Promise.resolve(cleanup),
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({
        role: "admin", accountId: OPERATOR_ID, adminRoles: ["operator"],
      }),
    });

    const response = await app.fetch(new Request("http://localhost/v1/admin/legacy-cleanup", {
      method: "POST",
      headers: { authorization: "Bearer admin", "content-type": "application/json" },
      body: JSON.stringify({ userId: USER_ID, dryRun: true }),
    }));

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual(cleanup);
    expect(await database.ops.listJobs()).toHaveLength(0);
    expect(await database.ops.listAudit({ action: "legacy_cleanup_dry_run" })).toMatchObject([
      { actorId: OPERATOR_ID, resourceId: USER_ID, metadata: { objectKeys: 1 } },
    ]);
  });

  it("queues legacy cleanup execution idempotently and records its audit", async () => {
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({
        role: "admin", accountId: OPERATOR_ID, adminRoles: ["operator"],
      }),
    });
    const request = () => new Request("http://localhost/v1/admin/legacy-cleanup", {
      method: "POST",
      headers: {
        authorization: "Bearer admin",
        "content-type": "application/json",
        "idempotency-key": "legacy-cleanup-execute-0001",
      },
      body: JSON.stringify({ userId: USER_ID, dryRun: false }),
    });

    const first = await app.fetch(request());
    const replay = await app.fetch(request());

    expect(first.status).toBe(202);
    expect(replay.status).toBe(202);
    expect(await readJson(replay)).toEqual(await readJson(first));
    expect(await database.ops.listJobs()).toHaveLength(1);
    expect(await database.ops.listAudit({ action: "legacy_cleanup_execute_requested" })).toHaveLength(1);
  });

  it("rejects requested account sync enablement while object storage is unavailable", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchFlag("account_sync", { enabled: false });
    const app = createTestApp({
      database,
      storage: createUnavailableObjectStore(),
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });

    const response = await app.fetch(
      new Request("http://localhost/v1/admin/feature-flags/account_sync", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "content-type": "application/json",
          "x-device-id": DEVICE_ID,
          "idempotency-key": "account-sync-readiness-reject",
        },
        body: JSON.stringify({ reason: "enable account sync", enabled: true }),
      }),
    );

    expect(response.status).toBe(503);
    expect(await readJson(response)).toMatchObject({
      code: "account_sync_unavailable",
    });
    expect((await database.ops.listFlags()).find((flag) => flag.key === "account_sync")?.enabled).toBe(
      false,
    );
  });

  it("forces a fresh readiness probe before enabling instead of trusting cached success", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchFlag("account_sync", { enabled: false });
    const storage = createFakeObjectStore();
    storage.supportsBoundUpload = () => Promise.resolve(true);
    let available = true;
    storage.ping = () => Promise.resolve(available ? "ok" : "unavailable");
    const app = createTestApp({
      database,
      storage,
      storageDescriptor: () =>
        Promise.resolve({
          provider: "gcs",
          bucket: "private-sync",
          configured: true,
          credentialsConfigured: true,
        }),
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const cached = await app.fetch(
      new Request("http://localhost/v1/admin/account-sync-readiness", {
        headers: { authorization: "Bearer admin", "x-device-id": DEVICE_ID },
      }),
    );
    expect(cached.status).toBe(200);
    expect(await readJson(cached)).toMatchObject({ ready: true });
    available = false;

    const response = await app.fetch(
      new Request("http://localhost/v1/admin/feature-flags/account_sync", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "content-type": "application/json",
          "x-device-id": DEVICE_ID,
          "idempotency-key": "account-sync-readiness-force-reject",
        },
        body: JSON.stringify({ reason: "enable account sync", enabled: true }),
      }),
    );

    expect(response.status).toBe(503);
    expect((await database.ops.listFlags()).find((flag) => flag.key === "account_sync")?.enabled).toBe(
      false,
    );
  });

  it.each([
    ["suspend", "suspend_user"],
    ["unsuspend", "unsuspend_user"],
    ["revoke-sessions", "revoke_sessions"],
  ] as const)(
    "prevents an operator from applying %s to a superadmin account",
    async (action, auditAction) => {
      const database = createFakeDatabaseClient();
      await database.identity.ensureProfile({ userId: USER_ID, email: "owner@example.com" });
      await database.identity.ensureProfile({ userId: OPERATOR_ID, email: "ops@example.com" });
      database.identity.seedActiveDevice?.(USER_ID, DEVICE_ID);
      const originalAdminRoles = database.identity.adminRoles.bind(database.identity);
      Object.assign(database.identity, {
        adminRoles: (userId: string) =>
          userId === USER_ID
            ? Promise.resolve(["superadmin"] as const)
            : originalAdminRoles(userId),
      });
      const app = createTestApp({
        database,
        authenticate: () =>
          createFakePrincipal({
            role: "admin",
            accountId: OPERATOR_ID,
            adminRoles: ["operator"],
          }),
      });

      const response = await app.fetch(
        new Request(`http://localhost/v1/admin/users/${USER_ID}/${action}`, {
          method: "POST",
          headers: {
            authorization: "Bearer scoped-admin",
            "content-type": "application/json",
            "x-device-id": DEVICE_ID,
            "idempotency-key": `protect-superadmin-${action}`,
          },
          body: JSON.stringify({ reason: "support request" }),
        }),
      );

      expect(response.status).toBe(403);
      expect(await readJson(response)).toMatchObject({ code: "forbidden" });
      expect((await database.identity.getProfileByUserId(USER_ID))?.status).toBe("active");
      expect((await database.identity.listDevices(USER_ID))[0]?.revoked).toBe(false);
      expect(await database.ops.listAudit({ action: auditAction })).toHaveLength(0);
    },
  );

  it("preserves ordinary user management for operators", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "learner@example.com" });
    const app = createTestApp({
      database,
      authenticate: () =>
        createFakePrincipal({
          role: "admin",
          accountId: OPERATOR_ID,
          adminRoles: ["operator"],
        }),
    });

    const response = await app.fetch(
      new Request(`http://localhost/v1/admin/users/${USER_ID}/suspend`, {
        method: "POST",
        headers: {
          authorization: "Bearer scoped-admin",
          "content-type": "application/json",
          "x-device-id": DEVICE_ID,
          "idempotency-key": "suspend-ordinary-user",
        },
        body: JSON.stringify({ reason: "support request" }),
      }),
    );

    expect(response.status).toBe(200);
    expect((await database.identity.getProfileByUserId(USER_ID))?.status).toBe("suspended");
  });

  it("allows a superadmin to revoke another superadmin's sessions", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "owner@example.com" });
    database.identity.seedActiveDevice?.(USER_ID, DEVICE_ID);
    Object.assign(database.identity, {
      adminRoles: () => Promise.resolve(["superadmin"] as const),
    });
    const app = createTestApp({
      database,
      authenticate: () =>
        createFakePrincipal({
          role: "admin",
          accountId: OPERATOR_ID,
          adminRoles: ["superadmin"],
        }),
    });

    const response = await app.fetch(
      new Request(`http://localhost/v1/admin/users/${USER_ID}/revoke-sessions`, {
        method: "POST",
        headers: {
          authorization: "Bearer scoped-admin",
          "content-type": "application/json",
          "x-device-id": DEVICE_ID,
          "idempotency-key": "superadmin-revoke-superadmin",
        },
        body: JSON.stringify({ reason: "security response" }),
      }),
    );

    expect(response.status).toBe(200);
    expect((await database.identity.listDevices(USER_ID))[0]?.revoked).toBe(true);
  });

  it.each([
    {
      role: "support_readonly",
      allowed: "/v1/admin/users",
      denied: "/v1/admin/cache",
      deniedMethod: "GET",
    },
    {
      role: "operator",
      allowed: "/v1/admin/jobs",
      denied: "/v1/admin/llm/policies",
      deniedMethod: "GET",
    },
    {
      role: "privacy_officer",
      allowed: "/v1/admin/privacy-requests",
      denied: "/v1/admin/runtime-config",
      deniedMethod: "GET",
    },
    {
      role: "billing_operator",
      allowed: "/v1/admin/quotas",
      denied: "/v1/admin/users",
      deniedMethod: "GET",
    },
  ])("enforces $role capabilities at the route boundary", async (scenario) => {
    const database = createFakeDatabaseClient();
    Object.assign(database.identity, {
      adminRoles: () => Promise.resolve([scenario.role]),
    });
    const app = createTestApp({
      database,
      authenticate: () =>
        createFakePrincipal({
          role: "admin",
          accountId: USER_ID,
          adminRoles: [scenario.role as AdminRole],
        }),
    });

    const allowed = await app.fetch(
      new Request(`http://localhost${scenario.allowed}`, {
        headers: { authorization: "Bearer scoped-admin" },
      }),
    );
    expect(allowed.status).not.toBe(403);

    const denied = await app.fetch(
      new Request(`http://localhost${scenario.denied}`, {
        method: scenario.deniedMethod,
        headers: {
          authorization: "Bearer scoped-admin",
          "content-type": "application/json",
        },
        ...(scenario.deniedMethod === "GET" ? {} : { body: "{}" }),
      }),
    );
    expect(denied.status).toBe(403);
    expect(await readJson(denied)).toMatchObject({ code: "forbidden" });
  });

  it("reports the signed-in operator's effective roles and capabilities", async () => {
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      authenticate: () =>
        createFakePrincipal({
          role: "admin",
          accountId: USER_ID,
          adminRoles: ["support_readonly"],
        }),
    });

    const response = await app.fetch(
      new Request("http://localhost/v1/admin/capabilities", {
        headers: { authorization: "Bearer scoped-admin" },
      }),
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      roles: ["support_readonly"],
      capabilities: ["access.read", "activity.read", "users.read"],
    });
  });

  it.each([
    [
      "GET",
      "/v1/admin/capabilities",
      ["support_readonly", "operator", "privacy_officer", "billing_operator", "superadmin"],
    ],
    ["GET", "/v1/admin/users", ["support_readonly", "operator", "privacy_officer", "superadmin"]],
    [
      "GET",
      `/v1/admin/users/${USER_ID}`,
      ["support_readonly", "operator", "privacy_officer", "superadmin"],
    ],
    [
      "GET",
      `/v1/admin/users/${USER_ID}/progress`,
      ["support_readonly", "operator", "privacy_officer", "superadmin"],
    ],
    ["POST", `/v1/admin/users/${USER_ID}/suspend`, ["operator", "superadmin"]],
    ["POST", `/v1/admin/users/${USER_ID}/unsuspend`, ["operator", "superadmin"]],
    ["POST", `/v1/admin/users/${USER_ID}/revoke-sessions`, ["operator", "superadmin"]],
    ["POST", `/v1/admin/users/${USER_ID}/grant-admin`, ["superadmin"]],
    ["POST", "/v1/admin/legacy-cleanup", ["operator", "superadmin"]],
    ["GET", "/v1/admin/runtime-config", ["superadmin"]],
    ["PUT", "/v1/admin/runtime-config", ["superadmin"]],
    ["GET", "/v1/admin/llm/policies", ["superadmin"]],
    ["PATCH", "/v1/admin/llm/policies/policy", ["superadmin"]],
    ["POST", "/v1/admin/llm/policies/policy/preview", ["superadmin"]],
    ["POST", "/v1/admin/llm/policies/policy/probe", ["superadmin"]],
    ["GET", "/v1/admin/cache", ["superadmin"]],
    ["GET", `/v1/admin/cache/${USER_ID}`, ["superadmin"]],
    ["POST", `/v1/admin/cache/${USER_ID}/actions`, ["superadmin"]],
    ["GET", "/v1/admin/jobs", ["operator", "superadmin"]],
    ["POST", `/v1/admin/jobs/${USER_ID}/retry`, ["operator", "superadmin"]],
    ["POST", `/v1/admin/jobs/${USER_ID}/cancel`, ["operator", "superadmin"]],
    ["GET", "/v1/admin/metrics", ["operator", "billing_operator", "superadmin"]],
    ["GET", "/v1/admin/product-analytics", ["operator", "billing_operator", "superadmin"]],
    [
      "GET",
      "/v1/admin/audit-events",
      ["support_readonly", "operator", "privacy_officer", "superadmin"],
    ],
    [
      "GET",
      "/v1/admin/product-events",
      ["support_readonly", "operator", "privacy_officer", "superadmin"],
    ],
    ["GET", "/v1/admin/events", ["support_readonly", "operator", "privacy_officer", "superadmin"]],
    ["GET", "/v1/admin/diagnostics", ["superadmin"]],
    ["GET", "/v1/admin/feature-flags", ["operator", "superadmin"]],
    ["PATCH", "/v1/admin/feature-flags/managed_qwen", ["operator", "superadmin"]],
    ["GET", "/v1/admin/quotas", ["billing_operator", "superadmin"]],
    ["PATCH", "/v1/admin/quotas/storage", ["billing_operator", "superadmin"]],
    ["GET", "/v1/admin/privacy-requests", ["privacy_officer", "superadmin"]],
    ["POST", `/v1/admin/privacy-requests/${USER_ID}/actions`, ["privacy_officer", "superadmin"]],
  ] as const)("enforces the full role matrix for %s %s", async (method, path, allowedRoles) => {
    const allRoles: AdminRole[] = [
      "support_readonly",
      "operator",
      "privacy_officer",
      "billing_operator",
      "superadmin",
    ];
    for (const role of allRoles) {
      const database = createFakeDatabaseClient();
      const app = createTestApp({
        database,
        authenticate: () =>
          createFakePrincipal({ role: "admin", accountId: USER_ID, adminRoles: [role] }),
      });
      const response = await app.fetch(
        new Request(`http://localhost${path}`, {
          method,
          headers: {
            authorization: "Bearer scoped-admin",
            ...(method === "GET" ? {} : { "content-type": "application/json" }),
          },
          ...(method === "GET" ? {} : { body: "{}" }),
        }),
      );
      if ((allowedRoles as readonly string[]).includes(role)) {
        expect(response.status, `${role} should be allowed`).not.toBe(403);
      } else {
        expect(response.status, `${role} should be denied`).toBe(403);
      }
    }
  });

  it("returns an audited, consented per-user learning summary without synced content", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "learner@example.com" });
    database.identity.seedActiveDevice?.(USER_ID, DEVICE_ID);
    await database.identity.grantAdminRole(USER_ID);
    const summary = {
      generatedAt: "2026-08-30T04:00:00.000Z",
      expiresAt: "2026-11-28T04:00:00.000Z",
      sync: {
        lastSuccessfulAt: "2026-08-30T03:58:00.000Z",
        lastDevice: { id: DEVICE_ID, platform: "macos", name: "MacBook" },
        entityCounts: [{ entityType: "vocabulary", count: 42 }],
        pendingCount: 2,
        conflictCount: 1,
      },
      reading: {
        lastActivityAt: "2026-08-30T03:55:00.000Z",
        activeBooks: 2,
        completedBooks: 1,
        currentChapter: 4,
        completionPercent: 63,
      },
      review: {
        due: 3,
        new: 9,
        learning: 7,
        reviewsLast30Days: 48,
        reviewsPerActiveDay: 6,
        retentionRate: 0.88,
        streakDays: 5,
      },
      learning: {
        vocabulary: 42,
        known: 18,
        learning: 7,
        aiUsesLast30Days: 12,
        aiUsesByFeature: [{ feature: "translation", count: 9 }],
      },
    };
    Object.assign(database.ops, {
      userProgressSummary: () => Promise.resolve(summary),
      analyticsPreference: () =>
        Promise.resolve({ operatorLearningAnalyticsEnabled: true, updatedAt: summary.generatedAt }),
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin", accountId: USER_ID }),
    });

    const response = await app.fetch(
      new Request(`http://localhost/v1/admin/users/${USER_ID}/progress`, {
        headers: { authorization: "Bearer admin" },
      }),
    );
    const body = await readJson(response);
    expect(response.status).toBe(200);
    expect(body).toMatchObject({
      consent: { operatorLearningAnalyticsEnabled: true },
      sync: { pendingCount: 2, conflictCount: 1 },
      reading: { activeBooks: 2, completionPercent: 63 },
      review: { due: 3, retentionRate: 0.88 },
      learning: { vocabulary: 42, aiUsesLast30Days: 12 },
      activity: {
        eventsPath: `/v1/admin/product-events?accountId=${USER_ID}`,
        auditPath: `/v1/admin/audit-events?resourceId=${USER_ID}`,
      },
    });
    expect(JSON.stringify(body)).not.toMatch(
      /"(payload|context|definition|note|transcript|sourceText|translatedText)"\s*:/i,
    );
    const audits = await database.ops.listAudit({ action: "admin_user_progress_read" });
    expect(audits).toHaveLength(1);
    expect(audits[0]).toMatchObject({
      actorId: USER_ID,
      resourceType: "user_progress",
      resourceId: USER_ID,
    });
    expect(JSON.stringify(audits[0]?.metadata)).not.toContain("42");
  });

  it("withholds learning analytics without explicit user consent", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "learner@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    Object.assign(database.ops, {
      analyticsPreference: () =>
        Promise.resolve({
          operatorLearningAnalyticsEnabled: false,
          updatedAt: "2026-08-30T04:00:00.000Z",
        }),
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin", accountId: USER_ID }),
    });
    const response = await app.fetch(
      new Request(`http://localhost/v1/admin/users/${USER_ID}/progress`, {
        headers: { authorization: "Bearer admin" },
      }),
    );
    const body = await readJson(response);
    expect(response.status).toBe(200);
    expect(body).toMatchObject({
      consent: { operatorLearningAnalyticsEnabled: false },
      reading: null,
      review: null,
      learning: null,
    });
  });

  it("returns a traceable dependency failure when progress materialization fails", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "learner@example.com" });
    Object.assign(database.ops, {
      userProgressSummary: () =>
        Promise.reject(new RestPersistenceError(502, "progress RPC unavailable")),
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin", accountId: USER_ID }),
    });

    const response = await app.fetch(
      new Request(`http://localhost/v1/admin/users/${USER_ID}/progress`, {
        headers: { authorization: "Bearer admin", "x-request-id": "progress-trace" },
      }),
    );
    const body = await readJson(response);

    expect(response.status).toBe(502);
    expect(body).toMatchObject({ code: "dependency_failed", traceId: "progress-trace" });
    expect(JSON.stringify(body)).not.toContain("progress RPC unavailable");
  });

  it("requires a scoped support role for per-user progress", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "billing@example.com" });
    Object.assign(database.identity, {
      adminRoles: () => Promise.resolve(["billing_operator"]),
    });
    const app = createTestApp({
      database,
      authenticate: () =>
        createFakePrincipal({
          role: "admin",
          accountId: USER_ID,
          adminRoles: ["billing_operator"],
        }),
    });
    const response = await app.fetch(
      new Request(`http://localhost/v1/admin/users/${USER_ID}/progress`, {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(response.status).toBe(403);
  });

  it("lets a signed-in user explicitly control Operator learning analytics", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "learner@example.com" });
    database.identity.seedActiveDevice?.(USER_ID, DEVICE_ID);
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ accountId: USER_ID }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/me/analytics-preferences", {
        method: "PUT",
        headers: {
          authorization: "Bearer user",
          "content-type": "application/json",
          "x-device-id": DEVICE_ID,
          "idempotency-key": "analytics-preference-opt-in",
        },
        body: JSON.stringify({ operatorLearningAnalyticsEnabled: true }),
      }),
    );
    expect(response.status).toBe(200);
    expect(await readJson(response)).toMatchObject({ operatorLearningAnalyticsEnabled: true });
    const audits = await database.ops.listAudit({ action: "analytics_preference_changed" });
    expect(audits).toHaveLength(1);

    const unbound = await app.fetch(
      new Request("http://localhost/v1/me/analytics-preferences", {
        method: "PUT",
        headers: {
          authorization: "Bearer user",
          "content-type": "application/json",
          "x-device-id": "00000000-0000-4000-8000-000000000099",
          "idempotency-key": "analytics-preference-unbound",
        },
        body: JSON.stringify({ operatorLearningAnalyticsEnabled: false }),
      }),
    );
    expect(unbound.status).toBe(401);
  });

  it("previews every managed prompt layer from an unsaved policy draft", async () => {
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const response = await app.fetch(
      new Request(
        "http://localhost/v1/admin/llm/policies/00000000-0000-4000-8000-0000000000aa/preview",
        {
          method: "POST",
          headers: { authorization: "Bearer admin", "content-type": "application/json" },
          body: JSON.stringify({
            subtask: "sentence",
            draft: {
              systemPrompt: "Unsaved operator layer.",
              userPrompt: "Quoted source: {{source}}",
              schemaVersion: "1",
            },
          }),
        },
      ),
    );
    const body = await readJson(response);
    expect(response.status).toBe(200);
    expect(isRecord(body) && isRecord(body.editable) ? body.editable.system : null).toBe(
      "Unsaved operator layer.",
    );
    expect(isRecord(body) && isRecord(body.enforced) ? body.enforced.taskContract : "").toContain(
      "exact source-language span",
    );
    expect(isRecord(body) && isRecord(body.effective) ? body.effective.user : "").toContain(
      "Ada Author",
    );
    expect(isRecord(body) && isRecord(body.validation) ? body.validation.valid : false).toBe(true);

    const heard = await app.fetch(
      new Request(
        "http://localhost/v1/admin/llm/policies/00000000-0000-4000-8000-0000000000ac/preview",
        {
          method: "POST",
          headers: { authorization: "Bearer admin", "content-type": "application/json" },
          body: JSON.stringify({ subtask: "heard_quiz" }),
        },
      ),
    );
    const heardBody = await readJson(heard);
    expect(heard.status).toBe(200);
    expect(
      isRecord(heardBody) && isRecord(heardBody.enforced) ? heardBody.enforced.taskContract : "",
    ).toContain("already-heard");
    expect(
      isRecord(heardBody) && isRecord(heardBody.outputSchema)
        ? heardBody.outputSchema.properties
        : null,
    ).toBeTruthy();
  });

  it("rejects a heard_quiz probe that cites a segment outside the preview fixture", async () => {
    const database = createFakeDatabaseClient();
    const runtime = createRuntimeConfigService({
      env: {
        ENVIRONMENT: "test",
        QWEN_API_KEY: "test-key",
        QWEN_BASE_URL: "https://example.invalid/v1",
        QWEN_MODEL: "qwen-test",
      },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
      fetch: () =>
        Promise.resolve(
          new Response(
            JSON.stringify({
              model: "qwen-test",
              choices: [
                {
                  message: {
                    role: "assistant",
                    content:
                      '{"questions":[{"id":"q1","kind":"comprehension","prompt":"What happened?","choices":["A","B","C","D"],"answerIndex":0,"rationale":"Because.","segmentID":"future"},{"id":"q2","kind":"sequencing","prompt":"Then?","choices":["A","B","C","D"],"answerIndex":1,"rationale":"Because.","segmentID":"s1"}]}',
                  },
                },
              ],
            }),
            { status: 200 },
          ),
        ),
    });
    const app = createTestApp({
      database,
      runtime,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const response = await app.fetch(
      new Request(
        "http://localhost/v1/admin/llm/policies/00000000-0000-4000-8000-0000000000ac/probe",
        {
          method: "POST",
          headers: { authorization: "Bearer admin", "content-type": "application/json" },
          body: JSON.stringify({ subtask: "heard_quiz" }),
        },
      ),
    );
    const body = await readJson(response);
    expect(response.status).toBe(200);
    expect(
      isRecord(body) && isRecord(body.outputValidation) ? body.outputValidation.valid : true,
    ).toBe(false);
    expect(
      isRecord(body) && isRecord(body.outputValidation) ? body.outputValidation.errors : [],
    ).toContain("$.questions[0].segmentID is outside the heard passage.");
  });

  it("rejects policy prompt drift before save", async () => {
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/admin/llm/policies/00000000-0000-4000-8000-0000000000aa", {
        method: "PATCH",
        headers: {
          authorization: "Bearer admin",
          "content-type": "application/json",
          "x-device-id": DEVICE_ID,
          "idempotency-key": "policy-contract-invalid",
        },
        body: JSON.stringify({
          reason: "test invalid prompt",
          userPrompt: "{{unknownPromptInput}}",
          schemaVersion: "2",
        }),
      }),
    );
    const body = await readJson(response);
    expect(response.status).toBe(422);
    expect(
      isRecord(body) && Array.isArray(body.fieldErrors)
        ? body.fieldErrors.some(
            (entry) =>
              isRecord(entry) &&
              entry.field === "userPrompt" &&
              String(entry.message).includes("Unknown placeholder"),
          )
        : false,
    ).toBe(true);
  });
  it("returns privacy-preserving product analytics with granular filters", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    for (const [index, platform] of ["macos", "macos", "ipados"].entries()) {
      await database.ops.putAnalyticsPreference(`${USER_ID.slice(0, -1)}${String(index)}`, true);
      await database.ops.recordProductEvent({
        accountId: `${USER_ID.slice(0, -1)}${String(index)}`,
        deviceId: `${DEVICE_ID.slice(0, -1)}${String(index)}`,
        name: "review.completed",
        outcome: "ok",
        requestId: `analytics-${String(index)}`,
        properties: {
          country: "AU",
          platform,
          readerLevel: "intermediate",
          sourceLanguage: "en",
          targetLanguage: "zh-Hans",
          contentId: `content-${String(index)}`,
          feature: "review",
        },
        createdAt: `2026-08-30T0${String(index + 1)}:00:00.000Z`,
      });
    }
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const response = await app.fetch(
      new Request(
        "http://localhost/v1/admin/product-analytics?from=2026-08-30T00%3A00%3A00.000Z&to=2026-08-31T00%3A00%3A00.000Z&platform=macos&interval=hour",
        { headers: { authorization: "Bearer admin" } },
      ),
    );
    const body = await readJson(response);
    expect(response.status).toBe(200);
    expect(isRecord(body) && isRecord(body.summary) ? body.summary.events : null).toBe(2);
    expect(JSON.stringify(body)).not.toContain(USER_ID);
    expect(JSON.stringify(body)).not.toContain("content-0");
  });

  it("includes filtered analytics events beyond the first 5,000 source rows", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    await database.ops.putAnalyticsPreference(USER_ID, true);
    await database.ops.recordProductEvent({
      accountId: USER_ID,
      deviceId: DEVICE_ID,
      name: "review.completed",
      outcome: "ok",
      requestId: "older-matching-event",
      properties: { platform: "macos", feature: "review" },
      createdAt: "2026-08-30T01:00:00.000Z",
    });
    await Promise.all(
      Array.from({ length: 5_000 }, (_, index) =>
        database.ops.recordProductEvent({
          accountId: USER_ID,
          deviceId: DEVICE_ID,
          name: "reader.opened",
          outcome: "ok",
          requestId: `newer-nonmatch-${String(index)}`,
          properties: { platform: "ipados", feature: "reader" },
          createdAt: "2026-08-30T12:00:00.000Z",
        }),
      ),
    );
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });

    const response = await app.fetch(
      new Request(
        "http://localhost/v1/admin/product-analytics?from=2026-08-30T00%3A00%3A00.000Z&to=2026-08-31T00%3A00%3A00.000Z&platform=macos&interval=day",
        { headers: { authorization: "Bearer admin" } },
      ),
    );
    const body = await readJson(response);

    expect(response.status).toBe(200);
    expect(isRecord(body) && isRecord(body.summary) ? body.summary.events : null).toBe(1);
    expect(isRecord(body) ? body.sampled : null).toBe(false);
  });

  it("filters product events by request id", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    await database.ops.putAnalyticsPreference(USER_ID, true);
    await database.ops.recordProductEvent({
      accountId: USER_ID,
      deviceId: DEVICE_ID,
      name: "ai.translation.completed",
      outcome: "ok",
      requestId: "req-match",
      properties: {},
    });
    await database.ops.recordProductEvent({
      accountId: USER_ID,
      deviceId: DEVICE_ID,
      name: "ai.translation.completed",
      outcome: "ok",
      requestId: "req-other",
      properties: {},
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });

    const response = await app.fetch(
      new Request("http://localhost/v1/admin/product-events?requestId=req-match", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    const body = await readJson(response);
    expect(response.status).toBe(200);
    expect(isRecord(body) && Array.isArray(body.items) ? body.items : []).toHaveLength(1);
    expect(
      isRecord(body) && Array.isArray(body.items) && isRecord(body.items[0])
        ? body.items[0].requestId
        : null,
    ).toBe("req-match");
    expect(JSON.stringify(body)).not.toContain(USER_ID);
    expect(
      isRecord(body) && Array.isArray(body.items) && isRecord(body.items[0])
        ? String(body.items[0].subjectId).startsWith("learner-")
        : false,
    ).toBe(true);
  });

  it("paginates filtered product events without truncating later matches", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    await database.ops.putAnalyticsPreference(USER_ID, true);
    for (const index of [0, 1, 2]) {
      await database.ops.recordProductEvent({
        accountId: USER_ID,
        deviceId: DEVICE_ID,
        name: "review.completed",
        outcome: "ok",
        requestId: `review-page-${String(index)}`,
        properties: {},
        createdAt: "2026-08-30T03:00:00.000Z",
      });
    }
    await database.ops.recordProductEvent({
      accountId: USER_ID,
      deviceId: DEVICE_ID,
      name: "reader.opened",
      outcome: "ok",
      requestId: "not-a-review",
      properties: {},
      createdAt: "2026-08-30T04:00:00.000Z",
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });

    const firstResponse = await app.fetch(
      new Request("http://localhost/v1/admin/product-events?name=review.completed&limit=2", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    const first = await readJson(firstResponse);
    const nextCursor =
      isRecord(first) && typeof first.nextCursor === "string" ? first.nextCursor : null;
    expect(firstResponse.status).toBe(200);
    expect(pageItems(first)).toHaveLength(2);
    expect(nextCursor).not.toBeNull();
    expect(nextCursor).not.toMatch(/^\d+$/);

    const secondResponse = await app.fetch(
      new Request(
        `http://localhost/v1/admin/product-events?name=review.completed&limit=2&cursor=${encodeURIComponent(nextCursor ?? "")}`,
        { headers: { authorization: "Bearer admin" } },
      ),
    );
    const second = await readJson(secondResponse);
    const allItems = [...pageItems(first), ...pageItems(second)];
    expect(secondResponse.status).toBe(200);
    expect(pageItems(second)).toHaveLength(1);
    expect(new Set(allItems.map((item) => item.id)).size).toBe(3);
    expect(allItems.every((item) => item.name === "review.completed")).toBe(true);
  });

  it("paginates filtered audit events beyond the storage read cap", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    for (let index = 0; index < 102; index += 1) {
      await database.ops.appendAudit({
        actorId: USER_ID,
        action: "review_schedule_changed",
        resourceType: "review_schedule",
        resourceId: `schedule-${String(index)}`,
        reason: "pagination regression",
        traceId: `audit-page-${String(index)}`,
        metadata: {},
      });
    }
    await database.ops.appendAudit({
      actorId: USER_ID,
      action: "unrelated_action",
      resourceType: "review_schedule",
      resourceId: "unrelated",
      reason: "filter control",
      traceId: "audit-unrelated",
      metadata: {},
    });
    const listAudit = database.ops.listAudit.bind(database.ops);
    Object.assign(database.ops, {
      listAudit: async (filter?: Parameters<typeof listAudit>[0]) =>
        (await listAudit(filter)).slice(0, 100),
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });

    const firstResponse = await app.fetch(
      new Request(
        "http://localhost/v1/admin/audit-events?action=review_schedule_changed&limit=60",
        { headers: { authorization: "Bearer admin" } },
      ),
    );
    const first = await readJson(firstResponse);
    const nextCursor =
      isRecord(first) && typeof first.nextCursor === "string" ? first.nextCursor : null;
    const secondResponse = await app.fetch(
      new Request(
        `http://localhost/v1/admin/audit-events?action=review_schedule_changed&limit=60&cursor=${encodeURIComponent(nextCursor ?? "")}`,
        { headers: { authorization: "Bearer admin" } },
      ),
    );
    const second = await readJson(secondResponse);
    const allItems = [...pageItems(first), ...pageItems(second)];

    expect(firstResponse.status).toBe(200);
    expect(secondResponse.status).toBe(200);
    expect(nextCursor).not.toBeNull();
    expect(nextCursor).not.toMatch(/^\d+$/);
    expect(allItems).toHaveLength(102);
    expect(new Set(allItems.map((item) => item.id)).size).toBe(102);
    expect(allItems.every((item) => item.action === "review_schedule_changed")).toBe(true);
  });

  it("withholds account-scoped product events after analytics opt-out", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    await database.ops.putAnalyticsPreference(USER_ID, true);
    await database.ops.recordProductEvent({
      accountId: USER_ID,
      deviceId: DEVICE_ID,
      name: "review.completed",
      outcome: "ok",
      requestId: "pre-opt-out",
      properties: {},
    });
    await database.ops.putAnalyticsPreference(USER_ID, false);
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });

    const response = await app.fetch(
      new Request(`http://localhost/v1/admin/product-events?accountId=${USER_ID}`, {
        headers: { authorization: "Bearer admin" },
      }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ items: [] });
  });

  it("audits account-scoped product activity reads", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    await database.ops.putAnalyticsPreference(USER_ID, true);
    await database.ops.recordProductEvent({
      accountId: USER_ID,
      deviceId: DEVICE_ID,
      name: "review.completed",
      outcome: "ok",
      requestId: "account-activity-read",
      properties: {},
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });

    const response = await app.fetch(
      new Request(`http://localhost/v1/admin/product-events?accountId=${USER_ID}`, {
        headers: { authorization: "Bearer admin", "x-request-id": "activity-read-trace" },
      }),
    );

    expect(response.status).toBe(200);
    const audits = await database.ops.listAudit({ action: "admin_user_activity_read" });
    expect(audits).toHaveLength(1);
    expect(audits[0]).toMatchObject({
      actorId: USER_ID,
      resourceType: "user_activity",
      resourceId: USER_ID,
      traceId: "activity-read-trace",
      metadata: { consented: true },
    });
  });

  it("applies kind and task filters to persisted Trace fallback events", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    await database.ops.appendAudit({
      actorId: USER_ID,
      action: "managed_qwen_complete",
      resourceType: "llm_policy",
      resourceId: "translation",
      reason: "translation completed",
      traceId: "trace-filter",
      metadata: { task: "translation", status: "ok" },
    });
    await database.ops.appendAudit({
      actorId: USER_ID,
      action: "operator_runtime_saved",
      resourceType: "runtime",
      resourceId: "default",
      reason: "runtime saved",
      traceId: "trace-other",
      metadata: { task: "runtime", status: "ok" },
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/admin/events?kind=managed_qwen_complete&task=translation", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    const body = await readJson(response);
    expect(response.status).toBe(200);
    expect(Array.isArray(body) ? body : []).toHaveLength(1);
    expect(Array.isArray(body) && isRecord(body[0]) ? body[0].kind : null).toBe(
      "managed_qwen_complete",
    );
  });

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
      new Request(`http://localhost/v2/assets/${job.assetId}/content`, {
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

  it("reports the current deletion workflow accurately by retaining events after completion", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "fake@example.com" });
    await database.identity.grantAdminRole(USER_ID);
    await database.ops.recordProductEvent({
      accountId: USER_ID,
      deviceId: DEVICE_ID,
      name: "reading.session.completed",
      outcome: "ok",
      requestId: "before-deletion",
      properties: {},
    });
    const request = await database.ops.createPrivacyRequest({
      accountId: USER_ID,
      kind: "deletion",
      status: "queued",
      reason: "user asked support",
    });
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    });

    const completed = await app.fetch(
      new Request(`http://localhost/v1/admin/privacy-requests/${request.id}/actions`, {
        method: "POST",
        headers: {
          authorization: "Bearer admin",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-privacy-complete-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({ action: "complete", reason: "request processing complete" }),
      }),
    );

    expect(completed.status).toBe(200);
    await expect(database.identity.getProfileByUserId(USER_ID)).resolves.toMatchObject({
      status: "deleted",
    });
    await expect(database.ops.listProductEvents({ accountId: USER_ID })).resolves.toHaveLength(1);
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
    const probeRequestId = probed.headers.get("X-Request-Id");
    expect(probeRequestId).not.toBeNull();
    const probedBody = await readJson(probed);
    expect(
      isRecord(probedBody) &&
        isRecord(probedBody.qwenComplete) &&
        probedBody.qwenComplete.status === "ok" &&
        probedBody.qwenComplete.model === "qwen3.7-flash",
    ).toBe(true);
    expect(isRecord(probedBody) ? probedBody.requestId : null).toBe(probeRequestId);
    expect(await database.ops.listProductEvents({ requestId: probeRequestId ?? "" })).toEqual([
      expect.objectContaining({
        accountId: USER_ID,
        name: "operator.qwen_probe",
        outcome: "ok",
        requestId: probeRequestId,
      }),
    ]);
    expect(await database.ops.listAudit({ requestId: probeRequestId ?? "" })).toEqual([
      expect.objectContaining({
        actorId: USER_ID,
        action: "operator_qwen_probe",
        resourceType: "managed_qwen",
        traceId: probeRequestId,
      }),
    ]);
    const trace = await app.fetch(
      new Request(`http://localhost/v1/admin/events?requestId=${String(probeRequestId)}`, {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(await readJson(trace)).toEqual([
      expect.objectContaining({
        kind: "operator_qwen_probe",
        requestId: probeRequestId,
        status: "ok",
      }),
    ]);
  });
});
