import { describe, expect, it } from "vitest";
import { createFakeDatabaseClient } from "@audio-reader/database";
import { createTestApp } from "./app";
import { createFakeObjectStore } from "./object-store";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

describe("asset upload API", () => {
  it("retrieves an announced ready asset directly even after 500 earlier manifests", async () => {
    const database = createFakeDatabaseClient();
    const app = createTestApp({ database });
    const principal = await app.authenticate(
      new Request("http://localhost", {
        headers: { authorization: "Bearer test" },
      }),
    );
    if (principal === null) throw new Error("test principal missing");
    let target = "";
    for (let index = 0; index <= 500; index += 1) {
      const uploadId = crypto.randomUUID();
      const created = await database.ops.createAsset(principal.accountId, {
        kind: "cover",
        contentType: "image/png",
        compressedBytes: 1,
        originalBytes: 1,
        sha256: index.toString(16).padStart(64, "0"),
        encoding: "identity",
        revisionId: null,
        bookId: null,
        chapterId: null,
        segmentCount: null,
        fileName: `cover-${String(index)}.png`,
        objectKey: `${principal.accountId}/cover/${String(index)}`,
        uploadObjectKey: `${principal.accountId}/pending/${uploadId}`,
        uploadId,
      });
      await database.ops.completeAsset(principal.accountId, uploadId);
      target = created.id;
    }

    const response = await app.fetch(
      new Request(`http://localhost/v2/assets/${target}`, {
        headers: { authorization: "Bearer test" },
      }),
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toMatchObject({ id: target, kind: "cover", status: "ready" });
  });

  it("publishes and discovers a compact ready manifest for every supported kind", async () => {
    const app = createTestApp();
    const kinds = [
      "audio",
      "epub",
      "cover",
      "transcriptRevision",
      "epubReadingPackage",
      "alignmentPackage",
      "mediaAnalysis",
      "transcriptExport",
      "accountExport",
      "assistantArtifact",
      "otherLargeImmutable",
    ] as const;
    for (const [index, kind] of kinds.entries()) {
      const bytes =
        kind === "transcriptRevision"
          ? new TextEncoder().encode('{"segments":[]}')
          : new Uint8Array([index + 1]);
      const digest = await crypto.subtle.digest("SHA-256", bytes);
      const sha256 = [...new Uint8Array(digest)]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
      const created = await app.fetch(
        new Request("http://localhost/v2/assets/uploads", {
          method: "POST",
          headers: {
            authorization: "Bearer test",
            "X-Device-Id": DEVICE_ID,
            "Idempotency-Key": `all-kind-create-${String(index)}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            kind,
            contentType:
              kind === "transcriptRevision" ? "application/json" : "application/octet-stream",
            encoding: kind === "transcriptRevision" ? "identity-json-v1" : "identity",
            compressedBytes: bytes.byteLength,
            originalBytes: bytes.byteLength,
            sha256,
            fileName: `${kind}.object`,
            ...(kind === "transcriptRevision"
              ? {
                  revisionId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                  chapterId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                  segmentCount: 0,
                }
              : {}),
          }),
        }),
      );
      expect(created.status, kind).toBe(201);
      const ticket = await readJson(created);
      if (
        !isRecord(ticket) ||
        typeof ticket.url !== "string" ||
        typeof ticket.uploadId !== "string"
      )
        continue;
      expect(
        (
          await app.fetch(
            new Request(ticket.url, {
              method: "PUT",
              headers: {
                authorization: "Bearer test",
                "content-type": "application/octet-stream",
                "content-length": String(bytes.byteLength),
              },
              body: bytes,
            }),
          )
        ).status,
        kind,
      ).toBe(200);
      expect(
        (
          await app.fetch(
            new Request(`http://localhost/v2/assets/uploads/${ticket.uploadId}/complete`, {
              method: "POST",
              headers: {
                authorization: "Bearer test",
                "X-Device-Id": DEVICE_ID,
                "Idempotency-Key": `all-kind-complete-${String(index)}`,
                "content-type": "application/json",
              },
              body: "{}",
            }),
          )
        ).status,
        kind,
      ).toBe(200);
      const discovered = await app.fetch(
        new Request(`http://localhost/v2/assets?kind=${kind}`, {
          headers: { authorization: "Bearer test" },
        }),
      );
      expect(discovered.status, kind).toBe(200);
      const list = await readJson(discovered);
      expect(
        isRecord(list) &&
          Array.isArray(list.assets) &&
          list.assets.some((asset) => isRecord(asset) && asset.kind === kind),
      ).toBe(true);
    }
  });

  it("creates a ticket, accepts the body, completes, and signs a download", async () => {
    const app = createTestApp();
    const created = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-upload-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          kind: "cover",
          contentType: "image/png",
          encoding: "identity",
          compressedBytes: 3,
          originalBytes: 3,
          sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
          fileName: "cover.png",
        }),
      }),
    );
    expect(created.status).toBe(201);
    const ticket = await readJson(created);
    expect(isRecord(ticket)).toBe(true);
    if (
      !isRecord(ticket) ||
      typeof ticket.url !== "string" ||
      typeof ticket.uploadId !== "string"
    ) {
      return;
    }
    const put = await app.fetch(
      new Request(ticket.url, {
        method: "PUT",
        headers: {
          authorization: "Bearer test",
          "content-type": "image/png",
          "content-length": "3",
        },
        body: new Uint8Array([1, 2, 3]),
      }),
    );
    expect(put.status).toBe(200);
    const completed = await app.fetch(
      new Request(`http://localhost/v2/assets/uploads/${ticket.uploadId}/complete`, {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-upload-02",
          "content-type": "application/json",
        },
        body: JSON.stringify({ parts: [{ partNumber: 1, etag: "etag" }] }),
      }),
    );
    expect(completed.status).toBe(200);
    const asset = await readJson(completed);
    expect(isRecord(asset) && asset.status).toBe("ready");
    if (!isRecord(asset) || typeof asset.id !== "string") {
      return;
    }
    const download = await app.fetch(
      new Request(`http://localhost/v2/assets/${asset.id}/download`, {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-upload-03",
          "content-type": "application/json",
        },
        body: "{}",
      }),
    );
    expect(download.status).toBe(200);
    const signed = await readJson(download);
    expect(isRecord(signed) && typeof signed.url === "string").toBe(true);
    if (!isRecord(signed) || typeof signed.url !== "string") {
      return;
    }
    const content = await app.fetch(
      new Request(signed.url, { headers: { authorization: "Bearer test" } }),
    );
    expect(content.status).toBe(200);
    expect(new Uint8Array(await content.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
  });

  it.each([
    ["POST", "/v1/uploads"],
    ["PUT", "/v1/uploads/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/body"],
    ["POST", "/v1/uploads/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/complete"],
    ["POST", "/v1/assets/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/download"],
    ["GET", "/v1/assets/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/content"],
  ])("retires authenticated legacy asset adapter %s %s", async (method, path) => {
    const response = await createTestApp().fetch(
      new Request(`http://localhost${path}`, {
        method,
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          ...(method === "POST" ? { "content-type": "application/json" } : {}),
        },
        ...(method === "POST" ? { body: "{}" } : {}),
      }),
    );
    expect(response.status).toBe(426);
    expect(response.headers.get("X-Min-App-Version")).toBe("2.0.0");
    expect(await readJson(response)).toMatchObject({ code: "upgrade_required" });
  });

  it("requires an exact Content-Length on the bounded Worker upload fallback", async () => {
    const app = createTestApp();
    const created = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "bounded-create-0001",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          kind: "cover",
          contentType: "image/png",
          encoding: "identity",
          compressedBytes: 3,
          originalBytes: 3,
          sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
          fileName: "cover.png",
        }),
      }),
    );
    const ticket = await readJson(created);
    if (!isRecord(ticket) || typeof ticket.url !== "string") return;
    const response = await app.fetch(
      new Request(ticket.url, {
        method: "PUT",
        headers: { authorization: "Bearer test", "content-type": "image/png" },
        body: new Uint8Array([1, 2, 3]),
      }),
    );
    expect(response.status).toBe(411);
  });

  it("refuses to reserve a large manifest when direct signed upload is unavailable", async () => {
    const app = createTestApp();
    const response = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "large-create-000001",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          kind: "audio",
          contentType: "audio/mp4",
          encoding: "identity",
          compressedBytes: 8 * 1024 * 1024 + 1,
          originalBytes: 8 * 1024 * 1024 + 1,
          sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          fileName: "large.m4b",
        }),
      }),
    );
    expect(response.status).toBe(503);
    expect(await readJson(response)).toMatchObject({ code: "direct_upload_unavailable" });
  });

  it("uses the provider's conservative absolute direct-upload deadline", async () => {
    const storage = createFakeObjectStore();
    storage.supportsBoundUpload = () => Promise.resolve(true);
    storage.createBoundUpload = () =>
      Promise.resolve({
        url: "https://example.supabase.co/storage/v1/object/upload/sign/private/large.m4b",
        headers: { "x-upsert": "false" },
        expiresAt: "2026-09-01T02:00:00.000Z",
      });
    const app = createTestApp({ storage });
    const response = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "large-expiry-create-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          kind: "audio",
          contentType: "audio/mp4",
          encoding: "identity",
          compressedBytes: 8 * 1024 * 1024 + 1,
          originalBytes: 8 * 1024 * 1024 + 1,
          sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          fileName: "large.m4b",
        }),
      }),
    );
    const ticket = await readJson(response);

    expect(response.status).toBe(201);
    expect(ticket).toMatchObject({
      method: "PUT",
      ready: false,
      expiresAt: "2026-09-01T02:00:00.000Z",
    });
  });
});
