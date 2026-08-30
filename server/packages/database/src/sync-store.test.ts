import { describe, expect, it } from "vitest";
import { createMemoryIdentityStore } from "./identity";
import { createMemorySyncStore, createSupabaseSyncStore, type SyncMutation } from "./sync-store";
import { createSupabaseRestClient, type RestFetch } from "./rest";

const USER_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const USER_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const DEVICE_A = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const MUTATION_A = "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d";
const MUTATION_B = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed";
const ENTITY = "2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d";
const BATCH = "7c9e6679-7425-40de-944b-e07fc1f90ae7";

function progressMutation(overrides: Partial<SyncMutation> = {}): SyncMutation {
  return {
    mutationId: MUTATION_A,
    entityType: "progress",
    entityId: ENTITY,
    operation: "upsert",
    baseRevision: 0,
    occurredAt: "2026-08-26T09:12:04.000Z",
    payload: { positionSeconds: 184.25, completed: false },
    ...overrides,
  };
}

describe("memory sync store", () => {
  it("applies a mutation once and isolates users", async () => {
    const store = createMemorySyncStore();
    const first = await store.push({
      userId: USER_A,
      deviceId: DEVICE_A,
      batchId: BATCH,
      mutations: [progressMutation()],
    });
    expect(first.results).toEqual([
      {
        mutationId: MUTATION_A,
        status: "applied",
        entityRevision: 1,
        problem: null,
      },
    ]);
    expect(first.cursor).toBe("1");
    const replay = await store.push({
      userId: USER_A,
      deviceId: DEVICE_A,
      batchId: BATCH,
      mutations: [progressMutation()],
    });
    expect(replay.results[0]?.status).toBe("duplicate");
    expect(replay.results[0]?.entityRevision).toBe(1);
    expect(replay.cursor).toBe("1");
    const other = await store.pull({ userId: USER_B, cursor: "0", limit: 100 });
    expect(other.changes).toEqual([]);
    const pulled = await store.pull({ userId: USER_A, cursor: "0", limit: 100 });
    expect(pulled.changes).toHaveLength(1);
    expect(pulled.changes[0]?.entityId).toBe(ENTITY);
    expect(pulled.hasMore).toBe(false);
  });

  it("conflicts when baseRevision is behind another device", async () => {
    const store = createMemorySyncStore();
    await store.push({
      userId: USER_A,
      deviceId: DEVICE_A,
      batchId: BATCH,
      mutations: [progressMutation()],
    });
    const conflict = await store.push({
      userId: USER_A,
      deviceId: DEVICE_A,
      batchId: crypto.randomUUID(),
      mutations: [progressMutation({ mutationId: MUTATION_B, baseRevision: 0 })],
    });
    expect(conflict.results[0]?.status).toBe("conflict");
    expect(conflict.results[0]?.entityRevision).toBe(1);
  });

  it("applies settings mutations through the identity store", async () => {
    const identity = createMemoryIdentityStore();
    await identity.ensureProfile({ userId: USER_A, email: "a@example.com" });
    const store = createMemorySyncStore({ identity });
    const pushed = await store.push({
      userId: USER_A,
      deviceId: DEVICE_A,
      batchId: BATCH,
      mutations: [
        {
          mutationId: MUTATION_A,
          entityType: "settings",
          entityId: USER_A,
          operation: "upsert",
          baseRevision: 0,
          occurredAt: "2026-08-26T09:12:04.000Z",
          payload: { targetLanguage: "ja", sourceLanguage: "en", appearance: "system" },
        },
      ],
    });
    expect(pushed.results[0]?.status).toBe("applied");
    expect((await identity.getSettings(USER_A)).targetLanguage).toBe("ja");
    expect((await identity.getSettings(USER_A)).appearance).toBe("system");
  });
});

describe("supabase sync store", () => {
  it("pushes the complete mutation batch through one database RPC", async () => {
    const requests: Array<{ url: string; method: string; body: unknown }> = [];
    const fetchImpl: RestFetch = (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      const method = init?.method ?? "GET";
      const body = typeof init?.body === "string" ? (JSON.parse(init.body) as unknown) : null;
      requests.push({ url, method, body });
      if (method === "POST" && url.endsWith("/rest/v1/rpc/push_sync_batch")) {
        return Promise.resolve(
          jsonResponse(200, {
            batchId: BATCH,
            cursor: "1",
            results: [
              {
                mutationId: MUTATION_A,
                status: "applied",
                entityRevision: 1,
                problem: null,
              },
            ],
          }),
        );
      }
      return Promise.resolve(jsonResponse(500, null));
    };
    const store = createSupabaseSyncStore(
      createSupabaseRestClient({
        url: "https://example.supabase.co",
        serviceRoleKey: "service-role-key",
        fetch: fetchImpl,
      }),
    );
    const pushed = await store.push({
      userId: USER_A,
      deviceId: DEVICE_A,
      batchId: BATCH,
      mutations: [progressMutation()],
    });
    expect(pushed.results[0]?.status).toBe("applied");
    expect(pushed.cursor).toBe("1");
    expect(requests).toHaveLength(1);
    expect(requests[0]?.body).toMatchObject({
      p_user_id: USER_A,
      p_device_id: DEVICE_A,
      p_batch_id: BATCH,
      p_mutations: [progressMutation()],
    });
  });

  it("pulls only one bounded page plus a has-more sentinel", async () => {
    const urls: string[] = [];
    const fetchImpl: RestFetch = (input) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      urls.push(url);
      return Promise.resolve(jsonResponse(200, [changeRow(11), changeRow(12), changeRow(13)]));
    };
    const store = createSupabaseSyncStore(
      createSupabaseRestClient({
        url: "https://example.supabase.co",
        serviceRoleKey: "service-role-key",
        fetch: fetchImpl,
      }),
    );

    const pulled = await store.pull({ userId: USER_A, cursor: "10", limit: 2 });

    expect(urls).toHaveLength(1);
    expect(urls[0]).toContain("sequence=gt.10");
    expect(urls[0]).toContain(
      "select=sequence%2Centity_type%2Centity_id%2Coperation%2Crevision%2Cchanged_at%2Cpayload",
    );
    expect(urls[0]).toContain("order=sequence.asc");
    expect(urls[0]).toContain("limit=3");
    expect(pulled.changes.map((change) => change.sequence)).toEqual([11, 12]);
    expect(pulled.cursor).toBe("12");
    expect(pulled.hasMore).toBe(true);
  });

  it("fails a pull when Postgres is unavailable instead of reporting a false empty page", async () => {
    const store = createSupabaseSyncStore(
      createSupabaseRestClient({
        url: "https://example.supabase.co",
        serviceRoleKey: "service-role-key",
        fetch: () => Promise.resolve(jsonResponse(503, { code: "unavailable", message: "down" })),
      }),
    );

    await expect(store.pull({ userId: USER_A, cursor: "10", limit: 100 })).rejects.toThrow(
      "sync pull failed",
    );
  });

  it("rejects an RPC response that does not acknowledge the requested batch", async () => {
    const store = createSupabaseSyncStore(
      createSupabaseRestClient({
        url: "https://example.supabase.co",
        serviceRoleKey: "service-role-key",
        fetch: () =>
          Promise.resolve(
            jsonResponse(200, {
              batchId: crypto.randomUUID(),
              cursor: "1",
              results: [],
            }),
          ),
      }),
    );

    await expect(
      store.push({
        userId: USER_A,
        deviceId: DEVICE_A,
        batchId: BATCH,
        mutations: [progressMutation()],
      }),
    ).rejects.toThrow("sync batch write failed");
  });

  it("fails latest-cursor lookup when Postgres is unavailable", async () => {
    const store = createSupabaseSyncStore(
      createSupabaseRestClient({
        url: "https://example.supabase.co",
        serviceRoleKey: "service-role-key",
        fetch: () => Promise.resolve(jsonResponse(503, { code: "unavailable", message: "down" })),
      }),
    );

    await expect(store.latestCursor(USER_A)).rejects.toThrow("sync cursor lookup failed");
  });
});

function changeRow(sequence: number): Record<string, unknown> {
  return {
    sequence,
    entity_type: "progress",
    entity_id: ENTITY,
    operation: "upsert",
    revision: sequence,
    changed_at: "2026-08-26T09:12:04.000Z",
    payload: { positionSeconds: sequence },
  };
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
