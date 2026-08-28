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
          payload: { targetLanguage: "ja", sourceLanguage: "en" },
        },
      ],
    });
    expect(pushed.results[0]?.status).toBe("applied");
    expect((await identity.getSettings(USER_A)).targetLanguage).toBe("ja");
  });
});

describe("supabase sync store", () => {
  it("inserts changelog rows with the service role", async () => {
    const rows: Record<string, unknown>[] = [];
    const fetchImpl: RestFetch = (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      const method = init?.method ?? "GET";
      if (method === "GET" && url.includes("mutation_id=")) {
        return Promise.resolve(jsonResponse(200, []));
      }
      if (method === "GET" && url.includes("order=sequence.desc")) {
        const latest = rows.at(-1);
        return Promise.resolve(jsonResponse(200, latest === undefined ? [] : [latest]));
      }
      if (method === "GET") {
        return Promise.resolve(jsonResponse(200, rows));
      }
      if (method === "POST") {
        const body =
          typeof init?.body === "string" ? (JSON.parse(init.body) as Record<string, unknown>) : {};
        const inserted = { ...body, id: crypto.randomUUID() };
        rows.push(inserted);
        return Promise.resolve(jsonResponse(201, [inserted]));
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
    expect(rows).toHaveLength(1);
    expect(rows[0]?.entity_type).toBe("progress");
    expect(rows[0]?.user_id).toBe(USER_A);
  });
});

function jsonResponse(status: number, body: unknown): Response {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
