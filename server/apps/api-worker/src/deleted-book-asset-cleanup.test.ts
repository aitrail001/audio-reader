import {
  createFakeDatabaseClient,
  type DatabaseClient,
  type SyncMutation,
} from "@audio-reader/database";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createTestApp, type ApiApp } from "./app";
import { createFakeObjectStore, type ObjectStore } from "./object-store";

const ACCOUNT_ID = "00000000-0000-4000-8000-000000000002";
const OTHER_ACCOUNT_ID = "00000000-0000-4000-8000-000000000003";
const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const BOOK_ID = "10000000-0000-4000-8000-000000000001";

function requestHeaders(idempotencyKey?: string): Record<string, string> {
  return {
    authorization: "Bearer test",
    "X-Device-Id": DEVICE_ID,
    ...(idempotencyKey === undefined
      ? {}
      : { "Idempotency-Key": idempotencyKey, "content-type": "application/json" }),
  };
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function reserveTranscript(
  app: ApiApp,
  input: {
    bookId: string;
    revisionId: string;
    chapterId: string;
    label: string;
    complete: boolean;
  },
): Promise<{ assetId: string; uploadId: string }> {
  const bytes = new TextEncoder().encode(`{"segments":[],"label":"${input.label}"}`);
  const created = await app.fetch(
    new Request("http://localhost/v2/assets/uploads", {
      method: "POST",
      headers: requestHeaders(`create-${input.label}-asset`),
      body: JSON.stringify({
        kind: "transcriptRevision",
        contentType: "application/json",
        encoding: "identity-json-v1",
        compressedBytes: bytes.byteLength,
        originalBytes: bytes.byteLength,
        sha256: await sha256(bytes),
        revisionId: input.revisionId,
        bookId: input.bookId,
        chapterId: input.chapterId,
        segmentCount: 0,
        fileName: `${input.label}.json`,
      }),
    }),
  );
  expect(created.status).toBe(201);
  const ticket: { assetId: string; uploadId: string; url: string } = await created.json();
  const uploaded = await app.fetch(
    new Request(ticket.url, {
      method: "PUT",
      headers: {
        authorization: "Bearer test",
        "content-type": "application/json",
        "content-length": String(bytes.byteLength),
      },
      body: bytes,
    }),
  );
  expect(uploaded.status).toBe(200);
  if (input.complete) {
    const completed = await app.fetch(
      new Request(`http://localhost/v2/assets/uploads/${ticket.uploadId}/complete`, {
        method: "POST",
        headers: requestHeaders(`complete-${input.label}-asset`),
        body: "{}",
      }),
    );
    expect(completed.status).toBe(200);
  }
  return ticket;
}

function deleteMutation(input: {
  mutationId: string;
  entityType?: "book" | "chapter";
  entityId?: string;
}): SyncMutation {
  return {
    mutationId: input.mutationId,
    entityType: input.entityType ?? "book",
    entityId: input.entityId ?? BOOK_ID,
    operation: "delete",
    baseRevision: 0,
    occurredAt: "2026-09-01T00:00:00Z",
    payload: {},
  };
}

async function pushDelete(
  app: ApiApp,
  mutation: ReturnType<typeof deleteMutation>,
  key: string,
  batchId = crypto.randomUUID(),
) {
  return app.fetch(
    new Request("http://localhost/v2/sync/push", {
      method: "POST",
      headers: requestHeaders(key),
      body: JSON.stringify({ deviceId: DEVICE_ID, batchId, mutations: [mutation] }),
    }),
  );
}

function testApp(database: DatabaseClient, storage: ObjectStore): ApiApp {
  return createTestApp({
    database,
    storage,
    storageDescriptor: () =>
      Promise.resolve({
        provider: "memory" as const,
        bucket: "deleted-book-cleanup-test",
        configured: true,
        credentialsConfigured: true,
      }),
  });
}

describe("deleted book asset cleanup", () => {
  let database: DatabaseClient;
  let storage: ObjectStore;
  let app: ApiApp;

  beforeEach(async () => {
    database = createFakeDatabaseClient();
    await database.ops.patchFlag("account_sync", { enabled: true });
    storage = createFakeObjectStore();
    app = testApp(database, storage);
  });

  it("removes ready and pending book assets and publishes a child tombstone only for announced assets", async () => {
    const ready = await reserveTranscript(app, {
      bookId: BOOK_ID,
      revisionId: "20000000-0000-4000-8000-000000000001",
      chapterId: "30000000-0000-4000-8000-000000000001",
      label: "ready",
      complete: true,
    });
    const pending = await reserveTranscript(app, {
      bookId: BOOK_ID,
      revisionId: "20000000-0000-4000-8000-000000000002",
      chapterId: "30000000-0000-4000-8000-000000000002",
      label: "pending",
      complete: false,
    });
    await database.syncV2.push({
      userId: ACCOUNT_ID,
      deviceId: DEVICE_ID,
      batchId: "35000000-0000-4000-8000-000000000001",
      mutations: [
        {
          mutationId: "36000000-0000-4000-8000-000000000001",
          entityType: "transcript",
          entityId: "20000000-0000-4000-8000-000000000001",
          operation: "upsert",
          baseRevision: 1,
          occurredAt: "2026-09-01T00:00:00Z",
          payload: {},
        },
      ],
    });

    const response = await pushDelete(
      app,
      deleteMutation({ mutationId: "40000000-0000-4000-8000-000000000001" }),
      "delete-book-assets-applied",
    );

    expect(response.status).toBe(200);
    await expect(database.ops.getAsset(ACCOUNT_ID, ready.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
    await expect(database.ops.getAsset(ACCOUNT_ID, pending.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
    await expect(storage.list(`private/v2/${ACCOUNT_ID}/`)).resolves.toEqual([]);
    const pulled = await app.fetch(
      new Request("http://localhost/v2/sync/pull?cursor=0&limit=100", {
        headers: requestHeaders(),
      }),
    );
    const body: {
      changes: Array<{
        entityType: string;
        entityId: string;
        operation: string;
        revision: number;
      }>;
    } = await pulled.json();
    expect(body.changes).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          entityType: "book",
          entityId: BOOK_ID,
          operation: "delete",
        }),
        expect.objectContaining({
          entityType: "transcript",
          entityId: "20000000-0000-4000-8000-000000000001",
          operation: "delete",
        }),
      ]),
    );
    expect(
      body.changes.filter(
        (change) => change.entityType === "transcript" && change.operation === "delete",
      ),
    ).toEqual([expect.objectContaining({ revision: 3 })]);
  });

  it("returns a committed push and resumes cleanup from a duplicate tombstone after object deletion fails", async () => {
    const inner = createFakeObjectStore();
    let failCanonicalDelete = true;
    storage = {
      ...inner,
      async delete(key) {
        if (failCanonicalDelete && key.includes("/transcriptRevision/")) {
          failCanonicalDelete = false;
          throw new Error("temporary object deletion failure");
        }
        await inner.delete(key);
      },
    };
    app = testApp(database, storage);
    const ready = await reserveTranscript(app, {
      bookId: BOOK_ID,
      revisionId: "20000000-0000-4000-8000-000000000011",
      chapterId: "30000000-0000-4000-8000-000000000011",
      label: "retry",
      complete: true,
    });
    const mutation = deleteMutation({ mutationId: "40000000-0000-4000-8000-000000000011" });
    const batchId = "41000000-0000-4000-8000-000000000011";

    expect((await pushDelete(app, mutation, "delete-book-assets-retry", batchId)).status).toBe(200);
    await expect(database.ops.getAsset(ACCOUNT_ID, ready.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
    expect((await pushDelete(app, mutation, "delete-book-assets-retry-2", batchId)).status).toBe(
      200,
    );
    await expect(database.ops.getAsset(ACCOUNT_ID, ready.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
    await expect(storage.list(`private/v2/${ACCOUNT_ID}/`)).resolves.toEqual([]);

    const pulled = await database.syncV2.pull({ userId: ACCOUNT_ID, cursor: "0", limit: 100 });
    expect(
      pulled.changes.filter(
        (change) => change.entityType === "transcript" && change.operation === "delete",
      ),
    ).toHaveLength(1);
  });

  it("keeps children deleting and GC-visible when the post-push cleanup RPC fails", async () => {
    const ready = await reserveTranscript(app, {
      bookId: BOOK_ID,
      revisionId: "20000000-0000-4000-8000-000000000071",
      chapterId: "30000000-0000-4000-8000-000000000071",
      label: "claim-failure",
      complete: true,
    });
    database.ops.claimDeletedBookAssets = () =>
      Promise.reject(new Error("cleanup RPC unavailable after sync commit"));

    const response = await pushDelete(
      app,
      deleteMutation({ mutationId: "40000000-0000-4000-8000-000000000071" }),
      "delete-book-claim-failure",
    );

    expect(response.status).toBe(200);
    await expect(database.ops.getAsset(ACCOUNT_ID, ready.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
    const gc = await database.ops.gcAbandonedAssetUploads(
      new Date(Date.now() + 2 * 86_400_000).toISOString(),
      100,
    );
    expect(gc).toEqual(expect.arrayContaining([expect.objectContaining({ id: ready.assetId })]));
    const pulled = await database.syncV2.pull({ userId: ACCOUNT_ID, cursor: "0", limit: 100 });
    expect(
      pulled.changes.filter(
        (change) =>
          change.entityType === "transcript" &&
          change.entityId === "20000000-0000-4000-8000-000000000071" &&
          change.operation === "delete",
      ),
    ).toHaveLength(1);
  });

  it("acknowledges unrelated mutations after committed book cleanup fails", async () => {
    const inner = createFakeObjectStore();
    let blockedKey = "";
    storage = {
      ...inner,
      async delete(key) {
        if (key === blockedKey) throw new Error("object deletion failed after sync commit");
        await inner.delete(key);
      },
    };
    app = testApp(database, storage);
    const ready = await reserveTranscript(app, {
      bookId: BOOK_ID,
      revisionId: "20000000-0000-4000-8000-000000000081",
      chapterId: "30000000-0000-4000-8000-000000000081",
      label: "mixed-batch",
      complete: true,
    });
    blockedKey = (await database.ops.getAsset(ACCOUNT_ID, ready.assetId))?.objectKey ?? "";
    const bookMutationId = "40000000-0000-4000-8000-000000000081";
    const progressMutationId = "40000000-0000-4000-8000-000000000082";

    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const response = await app.fetch(
      new Request("http://localhost/v2/sync/push", {
        method: "POST",
        headers: requestHeaders("delete-book-assets-mixed-batch"),
        body: JSON.stringify({
          deviceId: DEVICE_ID,
          batchId: "41000000-0000-4000-8000-000000000081",
          mutations: [
            deleteMutation({ mutationId: bookMutationId }),
            {
              mutationId: progressMutationId,
              entityType: "progress",
              entityId: "50000000-0000-4000-8000-000000000081",
              operation: "upsert",
              baseRevision: 0,
              occurredAt: "2026-09-01T00:00:00Z",
              payload: { progressKind: "reader", relativeSeconds: 42 },
            },
          ],
        }),
      }),
    );
    const cleanupLogs = warning.mock.calls
      .map(([value]) => JSON.parse(String(value)) as Record<string, unknown>)
      .filter((entry) => entry.message === "sync_book_asset_cleanup");
    warning.mockRestore();

    expect(response.status).toBe(200);
    const body: { results: Array<{ mutationId: string; status: string }> } = await response.json();
    expect(body.results).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ mutationId: bookMutationId, status: "applied" }),
        expect.objectContaining({ mutationId: progressMutationId, status: "applied" }),
      ]),
    );
    expect(cleanupLogs).toContainEqual(
      expect.objectContaining({ outcome: "partial_failure", failedCount: 1 }),
    );
    await expect(database.ops.getAsset(ACCOUNT_ID, ready.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
  });

  it("compensates a Worker fallback write that races a book tombstone", async () => {
    const inner = createFakeObjectStore();
    let raced = false;
    storage = {
      ...inner,
      async put(key, value) {
        await inner.put(key, value);
        if (!raced) {
          raced = true;
          expect(
            (
              await pushDelete(
                app,
                deleteMutation({ mutationId: "40000000-0000-4000-8000-000000000051" }),
                "worker-write-race-delete",
              )
            ).status,
          ).toBe(200);
        }
      },
    };
    app = testApp(database, storage);
    const bytes = new Uint8Array([7]);
    const created = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: requestHeaders("worker-write-race-create"),
        body: JSON.stringify({
          kind: "audio",
          contentType: "audio/mp4",
          encoding: "identity",
          compressedBytes: 1,
          originalBytes: 1,
          sha256: await sha256(bytes),
          bookId: BOOK_ID,
          fileName: "race.m4b",
        }),
      }),
    );
    const ticket: { assetId: string; uploadId: string; url: string } = await created.json();

    const uploaded = await app.fetch(
      new Request(ticket.url, {
        method: "PUT",
        headers: {
          authorization: "Bearer test",
          "content-type": "audio/mp4",
          "content-length": "1",
        },
        body: bytes,
      }),
    );

    expect(uploaded.status).toBe(409);
    await expect(inner.list(`private/v2/${ACCOUNT_ID}/`)).resolves.toEqual([]);
    await expect(database.ops.getAsset(ACCOUNT_ID, ticket.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
  });

  it("retains a small deleting manifest through a late old-Worker generic lease and write", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-01T02:00:00.000Z"));
    try {
      const inner = createFakeObjectStore();
      storage = inner;
      app = testApp(database, storage);
      const ticket = await reserveTranscript(app, {
        bookId: BOOK_ID,
        revisionId: "20000000-0000-4000-8000-000000000081",
        chapterId: "30000000-0000-4000-8000-000000000081",
        label: "old-worker-drain",
        complete: true,
      });
      const manifest = await database.ops.getAsset(ACCOUNT_ID, ticket.assetId);
      if (manifest === undefined) throw new Error("test manifest missing");

      expect(
        (
          await pushDelete(
            app,
            deleteMutation({ mutationId: "40000000-0000-4000-8000-000000000081" }),
            "old-worker-drain-delete",
          )
        ).status,
      ).toBe(200);
      await expect(inner.list(`private/v2/${ACCOUNT_ID}/`)).resolves.toEqual([]);

      const oldLease = await database.ops.beginObjectWrite(ACCOUNT_ID, manifest.uploadObjectKey);
      await inner.put(manifest.uploadObjectKey, new Uint8Array([8]));
      const leasedGc = await database.ops.gcAbandonedAssetUploads(
        new Date(Date.now() + 2 * 86_400_000).toISOString(),
        100,
      );
      expect(leasedGc.some((row) => row.id === manifest.id)).toBe(false);
      await database.ops.finishObjectWrite(oldLease.id);

      const reclaimed = await database.ops.gcAbandonedAssetUploads(
        new Date(Date.now() + 2 * 86_400_000).toISOString(),
        100,
      );
      const target = reclaimed.find((row) => row.id === manifest.id);
      expect(target).toBeDefined();
      for (const key of target?.objectKeys ?? []) await inner.delete(key);
      await database.ops.finishAbandonedAssetUploadGc([manifest.id]);
      await expect(database.ops.getAsset(ACCOUNT_ID, manifest.id)).resolves.toMatchObject({
        status: "deleting",
      });

      vi.advanceTimersByTime(25 * 60 * 60_000);
      const finalGc = await database.ops.gcAbandonedAssetUploads(
        new Date(Date.now() + 2 * 86_400_000).toISOString(),
        100,
      );
      expect(finalGc.some((row) => row.id === manifest.id)).toBe(true);
      for (const row of finalGc.filter((candidate) => candidate.id === manifest.id)) {
        for (const key of row.objectKeys) await inner.delete(key);
      }
      await database.ops.finishAbandonedAssetUploadGc([manifest.id]);
      await expect(database.ops.getAsset(ACCOUNT_ID, manifest.id)).resolves.toBeUndefined();
    } finally {
      vi.useRealTimers();
    }
  });

  it("retains direct-upload retry state until capability expiry and rejects ticket reissue", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-01T01:00:00.000Z"));
    try {
      const inner = createFakeObjectStore();
      let directKey = "";
      storage = {
        ...inner,
        createBoundUpload(key) {
          directKey = key;
          return Promise.resolve({
            url: "https://storage.example/direct",
            headers: { "x-upsert": "false" },
            expiresAt: "2026-09-01T01:15:00.000Z",
          });
        },
      };
      app = testApp(database, storage);
      const draft = {
        kind: "audio",
        contentType: "audio/mp4",
        encoding: "identity",
        compressedBytes: 8 * 1_024 * 1_024 + 1,
        originalBytes: 8 * 1_024 * 1_024 + 1,
        sha256: "ab".repeat(32),
        bookId: BOOK_ID,
        fileName: "direct-race.m4b",
      };
      const created = await app.fetch(
        new Request("http://localhost/v2/assets/uploads", {
          method: "POST",
          headers: requestHeaders("direct-race-create"),
          body: JSON.stringify(draft),
        }),
      );
      const ticket: { assetId: string } = await created.json();
      const mutation = deleteMutation({ mutationId: "40000000-0000-4000-8000-000000000061" });

      expect((await pushDelete(app, mutation, "direct-race-delete")).status).toBe(200);
      await inner.put(directKey, new Uint8Array([9]));
      await expect(database.ops.getAsset(ACCOUNT_ID, ticket.assetId)).resolves.toMatchObject({
        status: "deleting",
      });
      await expect(inner.get(directKey)).resolves.toBeDefined();

      const reissue = await app.fetch(
        new Request("http://localhost/v2/assets/uploads", {
          method: "POST",
          headers: requestHeaders("direct-race-reissue"),
          body: JSON.stringify(draft),
        }),
      );
      expect(reissue.status).toBe(409);

      vi.advanceTimersByTime(17 * 60_000);
      expect((await pushDelete(app, mutation, "direct-race-expired-retry")).status).toBe(200);
      await expect(database.ops.getAsset(ACCOUNT_ID, ticket.assetId)).resolves.toMatchObject({
        status: "deleting",
      });
      await expect(inner.get(directKey)).resolves.toBeUndefined();
      vi.advanceTimersByTime(24 * 60 * 60_000);
      expect((await pushDelete(app, mutation, "direct-race-retention-expired")).status).toBe(200);
      await expect(database.ops.getAsset(ACCOUNT_ID, ticket.assetId)).resolves.toBeUndefined();
    } finally {
      vi.useRealTimers();
    }
  });

  it("deletes successful objects while retaining manifests across a partial deletion failure", async () => {
    const inner = createFakeObjectStore();
    let blockedKey = "";
    storage = {
      ...inner,
      async delete(key) {
        if (blockedKey !== "" && key === blockedKey) throw new Error("one object is unavailable");
        await inner.delete(key);
      },
    };
    app = testApp(database, storage);
    const first = await reserveTranscript(app, {
      bookId: BOOK_ID,
      revisionId: "20000000-0000-4000-8000-000000000021",
      chapterId: "30000000-0000-4000-8000-000000000021",
      label: "partial-a",
      complete: true,
    });
    const second = await reserveTranscript(app, {
      bookId: BOOK_ID,
      revisionId: "20000000-0000-4000-8000-000000000022",
      chapterId: "30000000-0000-4000-8000-000000000022",
      label: "partial-b",
      complete: true,
    });
    blockedKey = (await database.ops.getAsset(ACCOUNT_ID, second.assetId))?.objectKey ?? "";

    const mutation = deleteMutation({ mutationId: "40000000-0000-4000-8000-000000000021" });
    expect((await pushDelete(app, mutation, "delete-book-assets-partial")).status).toBe(200);
    await expect(database.ops.getAsset(ACCOUNT_ID, first.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
    await expect(database.ops.getAsset(ACCOUNT_ID, second.assetId)).resolves.toMatchObject({
      status: "deleting",
    });

    blockedKey = "";
    expect((await pushDelete(app, mutation, "delete-book-assets-partial-retry")).status).toBe(200);
    await expect(database.ops.getAsset(ACCOUNT_ID, second.assetId)).resolves.toMatchObject({
      status: "deleting",
    });
    await expect(storage.list(`private/v2/${ACCOUNT_ID}/`)).resolves.toEqual([]);
  });

  it("does not clean another account or react to a chapter tombstone", async () => {
    const own = await database.ops.createAsset(ACCOUNT_ID, {
      kind: "audio",
      contentType: "audio/mp4",
      encoding: "identity",
      compressedBytes: 1,
      originalBytes: 1,
      sha256: "01".repeat(32),
      revisionId: null,
      bookId: BOOK_ID,
      chapterId: null,
      segmentCount: null,
      fileName: "own.m4b",
      objectKey: `private/v2/${ACCOUNT_ID}/audio/own`,
      uploadObjectKey: `private/v2/${ACCOUNT_ID}/uploads/own`,
      uploadId: "50000000-0000-4000-8000-000000000001",
    });
    const other = await database.ops.createAsset(OTHER_ACCOUNT_ID, {
      kind: "audio",
      contentType: "audio/mp4",
      encoding: "identity",
      compressedBytes: 1,
      originalBytes: 1,
      sha256: "02".repeat(32),
      revisionId: null,
      bookId: BOOK_ID,
      chapterId: null,
      segmentCount: null,
      fileName: "other.m4b",
      objectKey: `private/v2/${OTHER_ACCOUNT_ID}/audio/other`,
      uploadObjectKey: `private/v2/${OTHER_ACCOUNT_ID}/uploads/other`,
      uploadId: "50000000-0000-4000-8000-000000000002",
    });

    expect(
      (
        await pushDelete(
          app,
          deleteMutation({
            mutationId: "40000000-0000-4000-8000-000000000031",
            entityType: "chapter",
            entityId: "30000000-0000-4000-8000-000000000031",
          }),
          "delete-chapter-does-not-clean-book",
        )
      ).status,
    ).toBe(200);
    await expect(database.ops.getAsset(ACCOUNT_ID, own.id)).resolves.toBeDefined();

    await database.syncV2.push({
      userId: ACCOUNT_ID,
      deviceId: DEVICE_ID,
      batchId: "45000000-0000-4000-8000-000000000031",
      mutations: [deleteMutation({ mutationId: "46000000-0000-4000-8000-000000000031" })],
    });
    const claimed = await database.ops.claimDeletedBookAssets(ACCOUNT_ID, [BOOK_ID]);
    expect(claimed).toHaveLength(1);
    expect(claimed[0]?.id).toBe(own.id);
    await expect(database.ops.getAsset(OTHER_ACCOUNT_ID, other.id)).resolves.toBeDefined();
  });

  it("does not transition children for conflicted or rejected book deletes", async () => {
    const asset = await database.ops.createAsset(ACCOUNT_ID, {
      kind: "audio",
      contentType: "audio/mp4",
      encoding: "identity",
      compressedBytes: 1,
      originalBytes: 1,
      sha256: "03".repeat(32),
      revisionId: null,
      bookId: BOOK_ID,
      chapterId: null,
      segmentCount: null,
      fileName: "unchanged.m4b",
      objectKey: `private/v2/${ACCOUNT_ID}/audio/unchanged`,
      uploadObjectKey: `private/v2/${ACCOUNT_ID}/uploads/unchanged`,
      uploadId: "50000000-0000-4000-8000-000000000003",
    });
    await database.ops.completeAsset(ACCOUNT_ID, asset.uploadId);
    await database.syncV2.push({
      userId: ACCOUNT_ID,
      deviceId: DEVICE_ID,
      batchId: "50500000-0000-4000-8000-000000000003",
      mutations: [
        {
          ...deleteMutation({ mutationId: crypto.randomUUID() }),
          operation: "upsert",
          payload: { title: "Still present" },
        },
      ],
    });

    const conflict = await database.syncV2.push({
      userId: ACCOUNT_ID,
      deviceId: DEVICE_ID,
      batchId: "51000000-0000-4000-8000-000000000003",
      mutations: [{ ...deleteMutation({ mutationId: crypto.randomUUID() }), baseRevision: 0 }],
    });
    const rejected = await database.syncV2.push({
      userId: ACCOUNT_ID,
      deviceId: DEVICE_ID,
      batchId: "52000000-0000-4000-8000-000000000003",
      mutations: [{ ...deleteMutation({ mutationId: crypto.randomUUID() }), baseRevision: -1 }],
    });

    expect(conflict.results[0]?.status).toBe("conflict");
    expect(rejected.results[0]?.status).toBe("rejected");
    await expect(database.ops.getAsset(ACCOUNT_ID, asset.id)).resolves.toMatchObject({
      status: "ready",
    });
  });

  it("logs cleanup boundaries without private content", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      await pushDelete(
        app,
        deleteMutation({ mutationId: "40000000-0000-4000-8000-000000000041" }),
        "delete-book-assets-log",
      );
      const entries = warning.mock.calls
        .map(([value]) => String(value))
        .filter((value) => value.includes("sync_book_asset_cleanup"))
        .map((value) => JSON.parse(value) as Record<string, unknown>);
      const success = entries.find((entry) => entry.outcome === "success");
      expect(success).toMatchObject({
        accountId: ACCOUNT_ID,
        deviceId: DEVICE_ID,
        bookCount: 1,
        outcome: "success",
      });
      expect(typeof success?.requestId).toBe("string");
    } finally {
      warning.mockRestore();
    }
  });
});
