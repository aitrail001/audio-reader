import { describe, expect, it } from "vitest";
import { createSupabaseOpsStore, RestPersistenceError } from "./ops";
import type { RestClient, RestRequest, RestResponse } from "./rest";

const POLICY_ID = "00000000-0000-4000-8000-0000000000aa";
const FLAG_KEY = "managed_qwen";
const QUOTA_KEY = "qwen_tasks_day";

type Row = Record<string, unknown>;

function seedPolicy(model = "qwen3.7-plus"): Row {
  return {
    id: POLICY_ID,
    task: "translation",
    region: "ap-southeast-1",
    model,
    prompt_version: "qwen-managed-v1",
    system_prompt: "Return JSON with keys translation and notes.",
    user_prompt: "Translate {{source}} into {{targetLanguage}}.",
    schema_version: "1",
    policy_version: "qwen-managed-v1",
    enabled: true,
    canary_percent: "0",
    max_input_tokens: 8000,
    max_output_tokens: 2000,
    timeout_ms: 30000,
    created_at: "2026-08-28T00:00:00.000Z",
    updated_at: "2026-08-28T00:00:00.000Z",
  };
}

function seedFlag(enabled = true): Row {
  return {
    key: FLAG_KEY,
    enabled,
    variant: null,
    rollout_percent: "80",
    min_app_version: null,
    platforms: ["macos"],
  };
}

function seedQuota(limit = 50): Row {
  return { key: QUOTA_KEY, limit_value: String(limit), updated_at: "2026-08-28T00:00:00.000Z" };
}

function seedSettings(): Row {
  return {
    id: "default",
    payload: { qwenModel: "qwen3.7-plus" },
    ciphertext: null,
    nonce: null,
    updated_at: "2026-08-28T00:00:00.000Z",
    updated_by: null,
  };
}

function filterRows(rows: Row[], query: Record<string, string> | undefined): Row[] {
  if (query === undefined) {
    return rows;
  }
  return rows.filter((row) => {
    for (const [name, value] of Object.entries(query)) {
      if (name === "select" || name === "order" || name === "limit" || name === "on_conflict") {
        continue;
      }
      const candidate = row[name];
      const actual =
        typeof candidate === "string" ||
        typeof candidate === "number" ||
        typeof candidate === "boolean"
          ? String(candidate)
          : "";
      if (value.startsWith("eq.") && actual !== value.slice(3)) {
        return false;
      }
    }
    return true;
  });
}

function opsRest(options: {
  tables: Record<string, Row[]>;
  fail?: { method: string; path: string; response: RestResponse };
  rejectColumns?: { path: string; columns: Set<string> };
  emptyWrite?: { method: string; path: string };
}): RestClient {
  return {
    async request(input: RestRequest): Promise<RestResponse> {
      await Promise.resolve();
      const path = input.path;
      if (
        options.fail !== undefined &&
        input.method === options.fail.method &&
        path === options.fail.path
      ) {
        return options.fail.response;
      }
      if (
        options.emptyWrite !== undefined &&
        input.method === options.emptyWrite.method &&
        path === options.emptyWrite.path
      ) {
        return { status: 200, body: [] };
      }
      const rows = options.tables[path] ?? [];
      if (input.method === "GET") {
        return { status: 200, body: filterRows(rows, input.query) };
      }
      if (input.method === "PATCH" || input.method === "POST") {
        const body =
          typeof input.body === "object" && input.body !== null ? (input.body as Row) : {};
        const rejected = options.rejectColumns;
        if (rejected !== undefined && rejected.path === path) {
          for (const column of rejected.columns) {
            if (Object.prototype.hasOwnProperty.call(body, column)) {
              return {
                status: 400,
                body: {
                  code: "PGRST204",
                  message: `Could not find the '${column}' column of '${path.slice(1)}' in the schema cache`,
                },
              };
            }
          }
        }
        if (input.method === "POST") {
          const key = typeof body.key === "string" ? body.key : undefined;
          const id = typeof body.id === "string" ? body.id : undefined;
          const existingIndex = rows.findIndex((row) => {
            if (key !== undefined && row.key === key) {
              return true;
            }
            return id !== undefined && row.id === id;
          });
          const next = {
            ...(existingIndex >= 0 ? rows[existingIndex] : {}),
            ...body,
            ...(path === "/audit_events" && typeof body.id !== "string"
              ? {
                  id: "11111111-1111-4111-8111-111111111111",
                  created_at: "2026-08-28T00:00:00.000Z",
                }
              : {}),
          };
          if (existingIndex >= 0) {
            rows[existingIndex] = next;
          } else {
            rows.push(next);
          }
          return { status: 201, body: [next] };
        }
        const matched = filterRows(rows, input.query);
        if (matched.length === 0) {
          return { status: 200, body: [] };
        }
        for (const current of matched) {
          Object.assign(current, body);
        }
        return { status: 200, body: matched };
      }
      return { status: 405, body: { code: "PGRST001", message: "method not allowed" } };
    },
  };
}

describe("supabase policy store", () => {
  it("keeps a patched model after listPolicies reloads from Postgres", async () => {
    const rows = [seedPolicy()];
    const ops = createSupabaseOpsStore(opsRest({ tables: { "/model_policies": rows } }));
    const patched = await ops.patchPolicy(POLICY_ID, {
      model: "qwen3.6-flash",
      promptVersion: "qwen-managed-v1",
      systemPrompt: "Return JSON with keys translation and notes.",
    });
    expect(patched?.model).toBe("qwen3.6-flash");
    const listed = await ops.listPolicies();
    expect(listed).toHaveLength(1);
    expect(listed[0]?.model).toBe("qwen3.6-flash");
  });

  it("retries without unknown columns so a model change still persists", async () => {
    const rows = [seedPolicy()];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/model_policies": rows },
        rejectColumns: { path: "/model_policies", columns: new Set(["system_prompt"]) },
      }),
    );
    const patched = await ops.patchPolicy(POLICY_ID, {
      model: "qwen3.6-flash",
      systemPrompt: "Return JSON with keys translation and notes.",
    });
    expect(patched?.model).toBe("qwen3.6-flash");
    expect(rows[0]?.model).toBe("qwen3.6-flash");
    expect(rows[0]?.system_prompt).toBe("Return JSON with keys translation and notes.");
    expect((await ops.listPolicies())[0]?.model).toBe("qwen3.6-flash");
  });

  it("does not pretend a rejected patch saved into the in-memory seed", async () => {
    const rows = [seedPolicy()];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/model_policies": rows },
        fail: {
          method: "PATCH",
          path: "/model_policies",
          response: { status: 401, body: { code: "PGRST301", message: "JWT expired" } },
        },
      }),
    );
    await expect(ops.patchPolicy(POLICY_ID, { model: "qwen3.6-flash" })).rejects.toBeInstanceOf(
      RestPersistenceError,
    );
    expect((await ops.listPolicies())[0]?.model).toBe("qwen3.7-plus");
  });

  it("does not report success when the only patched column is unknown", async () => {
    const rows = [seedPolicy()];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/model_policies": rows },
        rejectColumns: { path: "/model_policies", columns: new Set(["system_prompt"]) },
      }),
    );
    await expect(
      ops.patchPolicy(POLICY_ID, {
        systemPrompt: "Be terse.",
      }),
    ).rejects.toBeInstanceOf(RestPersistenceError);
    expect(rows[0]?.model).toBe("qwen3.7-plus");
    expect(rows[0]?.system_prompt).toBe("Return JSON with keys translation and notes.");
    expect((await ops.listPolicies())[0]?.model).toBe("qwen3.7-plus");
  });

  it("returns an empty list when Postgres has no policies, not memory seeds", async () => {
    const ops = createSupabaseOpsStore(opsRest({ tables: { "/model_policies": [] } }));
    expect(await ops.listPolicies()).toEqual([]);
  });

  it("returns an empty list when policy GET fails instead of qwen3.7-flash seeds", async () => {
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/model_policies": [seedPolicy()] },
        fail: {
          method: "GET",
          path: "/model_policies",
          response: { status: 401, body: { code: "PGRST301", message: "JWT expired" } },
        },
      }),
    );
    expect(await ops.listPolicies()).toEqual([]);
  });
});

describe("supabase flag, quota, settings, and audit writes", () => {
  it("parses numeric rollout_percent strings from PostgREST", async () => {
    const ops = createSupabaseOpsStore(opsRest({ tables: { "/feature_flags": [seedFlag()] } }));
    const listed = await ops.listFlags();
    expect(listed).toHaveLength(1);
    expect(listed[0]?.rolloutPercent).toBe(80);
  });

  it("throws when a flag PATCH is 401 and leaves GET data unchanged", async () => {
    const flags = [seedFlag(true)];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/feature_flags": flags },
        fail: {
          method: "PATCH",
          path: "/feature_flags",
          response: { status: 401, body: { code: "PGRST301", message: "JWT expired" } },
        },
      }),
    );
    await expect(ops.patchFlag(FLAG_KEY, { enabled: false })).rejects.toBeInstanceOf(
      RestPersistenceError,
    );
    expect((await ops.listFlags())[0]?.enabled).toBe(true);
  });

  it("throws when a flag PATCH returns an empty representation", async () => {
    const flags = [seedFlag(true)];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/feature_flags": flags },
        emptyWrite: { method: "PATCH", path: "/feature_flags" },
      }),
    );
    await expect(ops.patchFlag(FLAG_KEY, { enabled: false })).rejects.toBeInstanceOf(
      RestPersistenceError,
    );
    expect(flags[0]?.enabled).toBe(true);
    expect((await ops.listFlags())[0]?.enabled).toBe(true);
  });

  it("throws when a quota write is 401 and leaves GET data unchanged", async () => {
    const quotas = [seedQuota(50)];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/quota_limits": quotas },
        fail: {
          method: "POST",
          path: "/quota_limits",
          response: { status: 401, body: { code: "PGRST301", message: "JWT expired" } },
        },
      }),
    );
    await expect(ops.patchQuota(QUOTA_KEY, 9)).rejects.toBeInstanceOf(RestPersistenceError);
    const listed = await ops.quotasFor("");
    expect(listed.find((item) => item.key === QUOTA_KEY)?.limit).toBe(50);
  });

  it("throws when a quota write returns an empty representation", async () => {
    const quotas = [seedQuota(50)];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/quota_limits": quotas },
        emptyWrite: { method: "POST", path: "/quota_limits" },
      }),
    );
    await expect(ops.patchQuota(QUOTA_KEY, 9)).rejects.toBeInstanceOf(RestPersistenceError);
    expect(finiteFromRow(quotas[0]?.limit_value)).toBe(50);
  });

  it("throws when operator settings POST is 401 and leaves GET data unchanged", async () => {
    const settings = [seedSettings()];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/operator_settings": settings },
        fail: {
          method: "POST",
          path: "/operator_settings",
          response: { status: 401, body: { code: "PGRST301", message: "JWT expired" } },
        },
      }),
    );
    await expect(
      ops.putOperatorSettings({
        id: "default",
        payload: { qwenModel: "qwen3.6-flash" },
        ciphertext: null,
        nonce: null,
        updatedBy: null,
      }),
    ).rejects.toBeInstanceOf(RestPersistenceError);
    expect((await ops.getOperatorSettings())?.payload).toEqual({ qwenModel: "qwen3.7-plus" });
  });

  it("does not treat a PostgREST error object as saved operator settings", async () => {
    const settings = [seedSettings()];
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/operator_settings": settings },
        fail: {
          method: "POST",
          path: "/operator_settings",
          response: {
            status: 201,
            body: { code: "PGRST301", message: "JWT expired" },
          },
        },
      }),
    );
    await expect(
      ops.putOperatorSettings({
        id: "default",
        payload: { qwenModel: "qwen3.6-flash" },
        ciphertext: null,
        nonce: null,
        updatedBy: null,
      }),
    ).rejects.toBeInstanceOf(RestPersistenceError);
    expect((await ops.getOperatorSettings())?.id).toBe("default");
    expect((await ops.getOperatorSettings())?.payload).toEqual({ qwenModel: "qwen3.7-plus" });
  });

  it("throws when audit insert fails instead of returning a memory-only event", async () => {
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/audit_events": [] },
        fail: {
          method: "POST",
          path: "/audit_events",
          response: { status: 401, body: { code: "PGRST301", message: "JWT expired" } },
        },
      }),
    );
    await expect(
      ops.appendAudit({
        actorId: "00000000-0000-4000-8000-0000000000ae",
        action: "patch_policy",
        resourceType: "llm_policy",
        resourceId: POLICY_ID,
        reason: "switch model",
        traceId: "trace-1",
        metadata: {},
      }),
    ).rejects.toBeInstanceOf(RestPersistenceError);
    expect(await ops.listAudit()).toEqual([]);
  });

  it("requests the bounded product-event analytics window from PostgREST", async () => {
    let captured: RestRequest | undefined;
    const ops = createSupabaseOpsStore({
      async request(input: RestRequest): Promise<RestResponse> {
        await Promise.resolve();
        captured = input;
        return { status: 200, body: [] };
      },
    });
    await ops.listProductEvents({
      from: "2026-08-01T00:00:00.000Z",
      to: "2026-09-01T00:00:00.000Z",
      limit: 5000,
    });
    expect(captured).toMatchObject({
      method: "GET",
      path: "/product_events",
      query: {
        limit: "5000",
        and: "(created_at.gte.2026-08-01T00:00:00.000Z,created_at.lt.2026-09-01T00:00:00.000Z)",
      },
    });
  });

  it("returns an empty flag list when GET fails instead of default seeds", async () => {
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/feature_flags": [seedFlag()] },
        fail: {
          method: "GET",
          path: "/feature_flags",
          response: { status: 401, body: { code: "PGRST301", message: "JWT expired" } },
        },
      }),
    );
    expect(await ops.listFlags()).toEqual([]);
  });

  it("stores assistant cache in Postgres so listCache reloads the row", async () => {
    const rows: Row[] = [];
    const ops = createSupabaseOpsStore(opsRest({ tables: { "/assistant_cache_entries": rows } }));
    const stored = await ops.putCache({
      id: "00000000-0000-4000-8000-0000000000c1",
      cacheKey: "ck-1",
      task: "translation",
      state: "active",
      sourceLanguage: "en",
      targetLanguage: "zh",
      editionFingerprint: "ed-1",
      policyVersion: "qwen-managed-v1",
      payload: { translation: "你好" },
    });
    expect(stored.cacheKey).toBe("ck-1");
    expect(stored.task).toBe("translation");
    expect(rows).toHaveLength(1);
    const listed = await ops.listCache({ task: "translation" });
    expect(listed).toHaveLength(1);
    expect(listed[0]?.id).toBe(stored.id);
    expect(listed[0]?.payload).toEqual({ translation: "你好" });
    expect(await ops.lookupCache("ck-1")).toEqual(expect.objectContaining({ id: stored.id }));
  });

  it("maps bigint cache counters that PostgREST returns as strings", async () => {
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: {
          "/assistant_cache_entries": [
            {
              id: "00000000-0000-4000-8000-0000000000c3",
              cache_key: "ck-hits",
              task_type: "translation",
              source_language: "en",
              target_language: "zh",
              edition_fingerprint: "ed-1",
              state: "active",
              policy_version: "qwen-managed-v1",
              hit_count: "14",
              accept_count: "2",
              reject_count: "1",
              result: { source: "ice", translation: "冰", bookTitle: "Frankenstein" },
              created_at: "2026-08-29T00:00:00.000Z",
              last_hit_at: "2026-08-29T01:00:00.000Z",
            },
          ],
        },
      }),
    );
    const listed = await ops.listCache();
    expect(listed[0]?.hitCount).toBe(14);
    expect(listed[0]?.acceptCount).toBe(2);
    expect(listed[0]?.payload).toEqual({
      source: "ice",
      translation: "冰",
      bookTitle: "Frankenstein",
    });
  });

  it("does not pretend a failed cache insert succeeded", async () => {
    const ops = createSupabaseOpsStore(
      opsRest({
        tables: { "/assistant_cache_entries": [] },
        fail: {
          method: "POST",
          path: "/assistant_cache_entries",
          response: {
            status: 400,
            body: { code: "PGRST204", message: "Could not find the 'result' column" },
          },
        },
      }),
    );
    await expect(
      ops.putCache({
        id: "00000000-0000-4000-8000-0000000000c2",
        cacheKey: "ck-fail",
        task: "chapter_summary",
        state: "active",
        sourceLanguage: "en",
        targetLanguage: "zh",
        editionFingerprint: "ed-2",
        policyVersion: "qwen-managed-v1",
        payload: { overview: "Nope" },
      }),
    ).rejects.toBeInstanceOf(RestPersistenceError);
    expect(await ops.listCache()).toEqual([]);
  });
});

function finiteFromRow(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}
