import { createFakeDatabaseClient, SyncStoreWriteError } from "@audio-reader/database";
import { describe, expect, it, vi } from "vitest";
import { createTestApp } from "./app";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const REVISION_ID = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const CHAPTER_ID = "2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d";
const TRANSCRIPT_BYTES = new TextEncoder().encode('{"segments":[]}');
const TRANSCRIPT_SHA = "cf84482b9efdd9291a36643471c6e09c79a69623f87a7b61265b660e54e69eaf";

function headers(key?: string): Record<string, string> {
  return {
    authorization: "Bearer test",
    "X-Device-Id": DEVICE_ID,
    ...(key === undefined ? {} : { "Idempotency-Key": key, "content-type": "application/json" }),
  };
}

describe("object-backed sync v2", () => {
  it("logs safe structured database context for a failed atomic push", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchFlag("account_sync", { enabled: true });
    database.syncV2 = {
      ...database.syncV2,
      push: () => Promise.reject(new SyncStoreWriteError(400, "P0001")),
    };
    const errorLog = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const response = await createTestApp({ database }).fetch(
        new Request("http://localhost/v2/sync/push", {
          method: "POST",
          headers: { ...headers("failed-database-push"), "X-Request-Id": "sync-db-request-1" },
          body: JSON.stringify({
            deviceId: DEVICE_ID,
            batchId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            mutations: [
              {
                mutationId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                entityType: "progress",
                entityId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                operation: "upsert",
                baseRevision: 0,
                occurredAt: "2026-09-01T00:00:00Z",
                payload: { progressKind: "reader", relativeSeconds: 1 },
              },
            ],
          }),
        }),
      );

      expect(response.status).toBe(500);
      const entries = errorLog.mock.calls.map(
        ([line]) => JSON.parse(String(line)) as Record<string, unknown>,
      );
      expect(entries).toContainEqual({
        level: "error",
        message: "sync_push_database_failed",
        component: "database",
        requestId: "sync-db-request-1",
        operation: "sync_push",
        mutations: 1,
        status: 400,
        code: "P0001",
      });
      expect(JSON.stringify(entries)).not.toContain("relativeSeconds");
    } finally {
      errorLog.mockRestore();
    }
  });

  it("preserves epubReadingPackage and emits no second manifest, change, or transfer", async () => {
    const app = createTestApp();
    const bytes = new Uint8Array([1]);
    const draft = {
      kind: "epubReadingPackage",
      contentType: "application/zip",
      encoding: "identity",
      compressedBytes: 1,
      originalBytes: 1,
      sha256: "4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a",
      fileName: "reading-package.zip",
    };
    const created = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: headers("reading-package-create"),
        body: JSON.stringify(draft),
      }),
    );
    const ticket: { uploadId: string; url: string } = await created.json();
    expect(created.status).toBe(201);
    expect(
      (
        await app.fetch(
          new Request(ticket.url, {
            method: "PUT",
            headers: {
              authorization: "Bearer test",
              "content-type": "application/zip",
              "content-length": "1",
            },
            body: bytes,
          }),
        )
      ).status,
    ).toBe(200);
    expect(
      (
        await app.fetch(
          new Request(`http://localhost/v2/assets/uploads/${ticket.uploadId}/complete`, {
            method: "POST",
            headers: headers("reading-package-complete"),
            body: "{}",
          }),
        )
      ).status,
    ).toBe(200);
    const first = await app.fetch(
      new Request("http://localhost/v2/sync/pull?cursor=0&limit=100", { headers: headers() }),
    );
    const firstBody: { cursor: string; changes: Array<{ payload: { kind?: string } }> } =
      await first.json();
    expect(firstBody.changes).toHaveLength(1);
    expect(firstBody.changes[0]?.payload.kind).toBe("epubReadingPackage");

    const retried = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: headers("reading-package-retry"),
        body: JSON.stringify(draft),
      }),
    );
    expect(retried.status).toBe(200);
    expect(await retried.json()).toMatchObject({ uploadId: ticket.uploadId, ready: true });
    const immediate = await app.fetch(
      new Request(`http://localhost/v2/sync/pull?cursor=${firstBody.cursor}&limit=100`, {
        headers: headers(),
      }),
    );
    expect(await immediate.json()).toMatchObject({ changes: [], cursor: firstBody.cursor });
    const listed = await app.fetch(
      new Request("http://localhost/v2/assets?kind=epubReadingPackage", { headers: headers() }),
    );
    const listedBody: { assets: unknown[] } = await listed.json();
    expect(listedBody.assets).toHaveLength(1);
  });

  it("requires upgrade on legacy negotiation and exposes only v2 manifest protocol", async () => {
    const app = createTestApp();
    const legacy = await app.fetch(
      new Request("http://localhost/v1/sync/capabilities", { headers: headers() }),
    );
    expect(legacy.status).toBe(426);
    expect(await legacy.json()).toMatchObject({ code: "upgrade_required" });

    const protocol = await app.fetch(
      new Request("http://localhost/v2/sync/protocol", { headers: headers() }),
    );
    expect(protocol.status).toBe(200);
    expect(await protocol.json()).toEqual({
      protocol: "object-v2",
      transcriptRepresentation: "asset-manifest-only",
      legacyBootstrap: false,
    });
  });

  it("publishes a verified transcript manifest once and never exposes its bytes or legacy history", async () => {
    const app = createTestApp();
    const created = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: headers("transcript-create-v2"),
        body: JSON.stringify({
          kind: "transcriptRevision",
          contentType: "application/json",
          encoding: "identity-json-v1",
          compressedBytes: TRANSCRIPT_BYTES.byteLength,
          originalBytes: TRANSCRIPT_BYTES.byteLength,
          sha256: TRANSCRIPT_SHA,
          revisionId: REVISION_ID,
          chapterId: CHAPTER_ID,
          segmentCount: 0,
          fileName: "transcript.json",
        }),
      }),
    );
    expect(created.status).toBe(201);
    const ticket: { uploadId: string; url: string } = await created.json();
    expect(
      (
        await app.fetch(
          new Request(ticket.url, {
            method: "PUT",
            headers: {
              authorization: "Bearer test",
              "content-type": "application/json",
              "content-length": String(TRANSCRIPT_BYTES.byteLength),
            },
            body: TRANSCRIPT_BYTES,
          }),
        )
      ).status,
    ).toBe(200);

    for (const key of ["transcript-complete-v2-a", "transcript-complete-v2-b"]) {
      expect(
        (
          await app.fetch(
            new Request(`http://localhost/v2/assets/uploads/${ticket.uploadId}/complete`, {
              method: "POST",
              headers: headers(key),
              body: "{}",
            }),
          )
        ).status,
      ).toBe(200);
    }
    const retriedCreate = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: headers("transcript-create-v2-retry"),
        body: JSON.stringify({
          kind: "transcriptRevision",
          contentType: "application/json",
          encoding: "identity-json-v1",
          compressedBytes: TRANSCRIPT_BYTES.byteLength,
          originalBytes: TRANSCRIPT_BYTES.byteLength,
          sha256: TRANSCRIPT_SHA,
          revisionId: REVISION_ID,
          chapterId: CHAPTER_ID,
          segmentCount: 0,
          fileName: "transcript.json",
        }),
      }),
    );
    expect(retriedCreate.status).toBe(200);
    expect(await retriedCreate.json()).toMatchObject({ uploadId: ticket.uploadId, ready: true });

    const pulled = await app.fetch(
      new Request("http://localhost/v2/sync/pull?cursor=0&limit=100", { headers: headers() }),
    );
    const body: { changes: Array<{ payload: Record<string, unknown> }>; cursor: string } =
      await pulled.json();
    expect(body.cursor).toBe("1");
    expect(body.changes).toHaveLength(1);
    expect(body.changes[0]?.payload).toMatchObject({
      revisionId: REVISION_ID,
      sha256: TRANSCRIPT_SHA,
      encoding: "identity-json-v1",
      compressedBytes: TRANSCRIPT_BYTES.byteLength,
      originalBytes: TRANSCRIPT_BYTES.byteLength,
      segmentCount: 0,
    });
    expect(JSON.stringify(body)).not.toContain("transcriptJSON");
    expect(JSON.stringify(body)).not.toContain("transcriptData");

    const immediate = await app.fetch(
      new Request("http://localhost/v2/sync/pull?cursor=1&limit=100", { headers: headers() }),
    );
    expect(await immediate.json()).toMatchObject({ changes: [], cursor: "1", hasMore: false });
    const legacy = await app.fetch(
      new Request("http://localhost/v1/sync/pull?cursor=0&limit=100", { headers: headers() }),
    );
    expect(legacy.status).toBe(426);
    expect(await legacy.json()).toMatchObject({ code: "upgrade_required" });
  });

  it("rejects transcript and other inline large object bytes before advancing v2 cursor", async () => {
    const app = createTestApp();
    const response = await app.fetch(
      new Request("http://localhost/v2/sync/push", {
        method: "POST",
        headers: headers("inline-transcript-v2"),
        body: JSON.stringify({
          deviceId: DEVICE_ID,
          batchId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          mutations: [
            {
              mutationId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
              entityType: "transcript",
              entityId: REVISION_ID,
              operation: "upsert",
              baseRevision: 0,
              occurredAt: "2026-08-31T00:00:00Z",
              payload: { transcriptJSON: '{"segments":[]}' },
            },
          ],
        }),
      }),
    );
    expect(response.status).toBe(400);
    const pulled = await app.fetch(
      new Request("http://localhost/v2/sync/pull?cursor=0&limit=100", { headers: headers() }),
    );
    expect(await pulled.json()).toMatchObject({ changes: [], cursor: "0", hasMore: false });
  });

  it.each([
    [
      "unknown top-level",
      { localId: "book", title: "Book", source: "files", chapters: [], surprise: true },
    ],
    [
      "unknown nested",
      {
        localId: "book",
        title: "Book",
        source: "files",
        chapters: [{ localId: "chapter", index: 0, title: "One", embeddedBytes: "AAAA" }],
      },
    ],
    [
      "oversized scalar",
      { localId: "book", title: "x".repeat(65 * 1024), source: "files", chapters: [] },
    ],
  ])("rejects %s payload outside the strict book schema", async (_label, payload) => {
    const app = createTestApp();
    const response = await app.fetch(
      new Request("http://localhost/v2/sync/push", {
        method: "POST",
        headers: headers(`strict-schema-${crypto.randomUUID()}`),
        body: JSON.stringify({
          deviceId: DEVICE_ID,
          batchId: crypto.randomUUID(),
          mutations: [
            {
              mutationId: crypto.randomUUID(),
              entityType: "book",
              entityId: crypto.randomUUID(),
              operation: "upsert",
              baseRevision: 0,
              occurredAt: "2026-08-31T00:00:00Z",
              payload,
            },
          ],
        }),
      }),
    );
    expect(response.status).toBe(400);
  });

  it("rejects a 101-item v2 batch at the HTTP contract before PostgreSQL", async () => {
    const app = createTestApp();
    const mutation = (index: number) => ({
      mutationId: `10000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      entityType: "study_activity",
      entityId: `20000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      operation: "upsert",
      baseRevision: 0,
      occurredAt: "2026-08-31T00:00:00Z",
      payload: { day: "2026-08-31" },
    });
    const response = await app.fetch(
      new Request("http://localhost/v2/sync/push", {
        method: "POST",
        headers: headers("batch-over-contract-limit"),
        body: JSON.stringify({
          deviceId: DEVICE_ID,
          batchId: crypto.randomUUID(),
          mutations: Array.from({ length: 101 }, (_, index) => mutation(index + 1)),
        }),
      }),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ code: "bad_request" });
  });
});
