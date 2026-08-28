import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const BATCH_ID = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const MUTATION_ID = "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d";
const ENTITY_ID = "2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

function authHeaders(): Record<string, string> {
  return {
    authorization: "Bearer test",
    "X-Device-Id": DEVICE_ID,
    "Idempotency-Key": "idempotency-key-sync-01",
    "content-type": "application/json",
  };
}

describe("sync API", () => {
  it("rejects unauthenticated push and pull", async () => {
    const app = createTestApp({ authenticate: () => null });
    const pushed = await app.fetch(
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-sync-01",
        },
        body: JSON.stringify({ deviceId: DEVICE_ID, batchId: BATCH_ID, mutations: [] }),
      }),
    );
    expect(pushed.status).toBe(401);
    const pulled = await app.fetch(
      new Request("http://localhost/v1/sync/pull?cursor=0", {
        headers: { "X-Device-Id": DEVICE_ID },
      }),
    );
    expect(pulled.status).toBe(401);
  });

  it("rejects sync from an unregistered device", async () => {
    const app = createTestApp();
    const pushed = await app.fetch(
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          "Idempotency-Key": "idempotency-key-sync-unregistered",
        },
        body: JSON.stringify({
          deviceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          batchId: BATCH_ID,
          mutations: [],
        }),
      }),
    );
    expect(pushed.status).toBe(401);
  });

  it("pushes a mutation once and pulls it for the same account", async () => {
    const app = createTestApp();
    const requestBody = {
      deviceId: DEVICE_ID,
      batchId: BATCH_ID,
      mutations: [
        {
          mutationId: MUTATION_ID,
          entityType: "progress",
          entityId: ENTITY_ID,
          operation: "upsert",
          baseRevision: 0,
          occurredAt: "2026-08-26T09:12:04.000Z",
          payload: { positionSeconds: 184.25, completed: false },
        },
      ],
    };
    const first = await app.fetch(
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers: authHeaders(),
        body: JSON.stringify(requestBody),
      }),
    );
    expect(first.status).toBe(200);
    const firstBody = await readJson(first);
    expect(isRecord(firstBody)).toBe(true);
    if (!isRecord(firstBody) || !Array.isArray(firstBody.results)) {
      return;
    }
    expect(firstBody.results[0]).toMatchObject({
      mutationId: MUTATION_ID,
      status: "applied",
      entityRevision: 1,
    });
    expect(firstBody.cursor).toBe("1");

    const replay = await app.fetch(
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers: {
          ...authHeaders(),
          "Idempotency-Key": "idempotency-key-sync-02",
        },
        body: JSON.stringify(requestBody),
      }),
    );
    const replayBody = await readJson(replay);
    expect(isRecord(replayBody) && Array.isArray(replayBody.results)).toBe(true);
    if (!isRecord(replayBody) || !Array.isArray(replayBody.results)) {
      return;
    }
    expect(replayBody.results[0]).toMatchObject({ status: "duplicate", mutationId: MUTATION_ID });

    const pulled = await app.fetch(
      new Request("http://localhost/v1/sync/pull?cursor=0&limit=100", {
        headers: { authorization: "Bearer test", "X-Device-Id": DEVICE_ID },
      }),
    );
    expect(pulled.status).toBe(200);
    const pullBody = await readJson(pulled);
    expect(isRecord(pullBody)).toBe(true);
    if (!isRecord(pullBody) || !Array.isArray(pullBody.changes)) {
      return;
    }
    expect(pullBody.hasMore).toBe(false);
    expect(pullBody.cursor).toBe("1");
    expect(pullBody.changes[0]).toMatchObject({
      sequence: 1,
      entityType: "progress",
      entityId: ENTITY_ID,
      operation: "upsert",
      revision: 1,
    });
  });

  it("returns conflict when a later mutation uses a stale baseRevision", async () => {
    const app = createTestApp();
    await app.fetch(
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers: authHeaders(),
        body: JSON.stringify({
          deviceId: DEVICE_ID,
          batchId: BATCH_ID,
          mutations: [
            {
              mutationId: MUTATION_ID,
              entityType: "progress",
              entityId: ENTITY_ID,
              operation: "upsert",
              baseRevision: 0,
              occurredAt: "2026-08-26T09:12:04.000Z",
              payload: { positionSeconds: 10 },
            },
          ],
        }),
      }),
    );
    const conflict = await app.fetch(
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers: {
          ...authHeaders(),
          "Idempotency-Key": "idempotency-key-sync-03",
        },
        body: JSON.stringify({
          deviceId: DEVICE_ID,
          batchId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          mutations: [
            {
              mutationId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
              entityType: "progress",
              entityId: ENTITY_ID,
              operation: "upsert",
              baseRevision: 0,
              occurredAt: "2026-08-26T09:13:04.000Z",
              payload: { positionSeconds: 20 },
            },
          ],
        }),
      }),
    );
    const body = await readJson(conflict);
    expect(isRecord(body) && Array.isArray(body.results)).toBe(true);
    if (!isRecord(body) || !Array.isArray(body.results)) {
      return;
    }
    expect(body.results[0]).toMatchObject({ status: "conflict", entityRevision: 1 });
  });
});
