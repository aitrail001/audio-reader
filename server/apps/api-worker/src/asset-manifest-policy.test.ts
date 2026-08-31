import { describe, expect, it } from "vitest";
import { createFakePrincipal } from "@audio-reader/auth";
import { createFakeDatabaseClient } from "@audio-reader/database";
import { createTestApp } from "./app";
import {
  ASSET_MANIFEST_KINDS,
  contentAddressedObjectKey,
  validateAssetManifestDraft,
  verifyAssetObject,
  verifyAssetStream,
} from "./asset-manifest-policy";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const SHA256_123 = "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";

function headers(idempotencyKey: string): Record<string, string> {
  return {
    authorization: "Bearer test",
    "X-Device-Id": DEVICE_ID,
    "Idempotency-Key": idempotencyKey,
    "content-type": "application/json",
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function verifyTranscriptJSON(
  json: string,
  segmentCount: number,
  chunkBytes = 3,
): Promise<boolean> {
  const bytes = new TextEncoder().encode(json);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const sha256 = [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      for (let offset = 0; offset < bytes.byteLength; offset += chunkBytes) {
        controller.enqueue(bytes.subarray(offset, Math.min(offset + chunkBytes, bytes.byteLength)));
      }
      controller.close();
    },
  });
  return verifyAssetStream(
    {
      compressedBytes: bytes.byteLength,
      originalBytes: bytes.byteLength,
      sha256,
      kind: "transcriptRevision",
      encoding: "identity-json-v1",
      segmentCount,
    },
    { size: bytes.byteLength, body },
  );
}

describe("v2 asset manifest policy", () => {
  it("enumerates every supported large immutable artifact kind", () => {
    expect(ASSET_MANIFEST_KINDS).toEqual([
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
    ]);
  });

  it("derives owner-scoped content-addressed keys without accepting a caller key", () => {
    const owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    expect(contentAddressedObjectKey(owner, "transcriptRevision", SHA256_123)).toBe(
      `private/v2/${owner}/transcriptRevision/${SHA256_123}`,
    );
    expect(
      validateAssetManifestDraft({
        kind: "cover",
        contentType: "image/png",
        compressedBytes: 3,
        originalBytes: 3,
        sha256: SHA256_123,
        encoding: "identity",
        objectKey: "https://attacker.invalid/object",
      }),
    ).toMatchObject({ ok: false, field: "objectKey" });
  });

  it("requires complete transcript revision integrity metadata and verifies bytes", async () => {
    expect(
      validateAssetManifestDraft({
        kind: "transcriptRevision",
        contentType: "application/json",
        compressedBytes: 3,
        originalBytes: 3,
        sha256: SHA256_123,
        encoding: "identity-json-v1",
        segmentCount: 2,
      }),
    ).toMatchObject({ ok: false, field: "revisionId" });

    expect(
      validateAssetManifestDraft({
        kind: "transcriptRevision",
        contentType: "application/json",
        compressedBytes: 3,
        originalBytes: 3,
        sha256: SHA256_123,
        encoding: "gzip",
        revisionId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        chapterId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        segmentCount: 1,
      }),
    ).toMatchObject({ ok: false, field: "encoding" });

    await expect(
      verifyAssetObject(
        {
          compressedBytes: 3,
          sha256: SHA256_123,
        },
        new Uint8Array([1, 2, 3]),
      ),
    ).resolves.toBe(true);
    await expect(
      verifyAssetObject(
        {
          compressedBytes: 4,
          sha256: SHA256_123,
        },
        new Uint8Array([1, 2, 3]),
      ),
    ).resolves.toBe(false);
  });

  it("verifies an object larger than the Worker fallback incrementally", async () => {
    const bytes = new Uint8Array(8 * 1024 * 1024 + 1).fill(7);
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const sha256 = [...new Uint8Array(digest)]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    let offset = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (offset === bytes.byteLength) {
          controller.close();
          return;
        }
        const end = Math.min(offset + 64 * 1024, bytes.byteLength);
        controller.enqueue(bytes.subarray(offset, end));
        offset = end;
      },
    });
    await expect(
      verifyAssetStream(
        {
          compressedBytes: bytes.byteLength,
          originalBytes: bytes.byteLength,
          sha256,
          encoding: "identity",
        },
        { size: bytes.byteLength, body },
      ),
    ).resolves.toBe(true);
    expect(offset).toBe(bytes.byteLength);
  });

  it("rejects simulated 2 GiB metadata and provider checksum mismatch before reading", async () => {
    let pulls = 0;
    const unread = () =>
      new ReadableStream<Uint8Array>({
        pull(controller) {
          pulls += 1;
          controller.enqueue(new Uint8Array([1]));
        },
      });
    await expect(
      verifyAssetStream(
        { compressedBytes: 3, sha256: SHA256_123 },
        {
          size: 2 * 1024 * 1024 * 1024,
          body: unread(),
        },
      ),
    ).resolves.toBe(false);
    await expect(
      verifyAssetStream(
        { compressedBytes: 3, sha256: SHA256_123 },
        {
          size: 3,
          sha256: "a".repeat(64),
          body: unread(),
        },
      ),
    ).resolves.toBe(false);
    expect(pulls).toBe(0);
  });

  it("streams transcript structure and rejects a wrong segment count", async () => {
    const bytes = new TextEncoder().encode('{"segments":[{"id":"1"},{"id":"2"}]}');
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const sha256 = [...new Uint8Array(digest)]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    const stream = (): ReadableStream<Uint8Array> =>
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(bytes);
          controller.close();
        },
      });
    const manifest = {
      compressedBytes: bytes.byteLength,
      originalBytes: bytes.byteLength,
      sha256,
      kind: "transcriptRevision" as const,
      encoding: "identity-json-v1",
    };
    await expect(
      verifyAssetStream(
        { ...manifest, segmentCount: 2 },
        {
          size: bytes.byteLength,
          body: stream(),
        },
      ),
    ).resolves.toBe(true);
    await expect(
      verifyAssetStream(
        { ...manifest, segmentCount: 1 },
        {
          size: bytes.byteLength,
          body: stream(),
        },
      ),
    ).resolves.toBe(false);
  });

  it.each([
    ['{"segments":[not-json]}', 1],
    ['{"segments":[{"id":"1"}]', 1],
    ['{"segments":[],"segments":[]}', 0],
    ['{"segments":"not-an-array"}', 0],
    ['{"segments":[1]}', 1],
    ['{"segments":[{"id":"1",}]}', 1],
    ['{"segments":[] } trailing', 0],
  ])("rejects malformed or wrong-shaped transcript JSON: %s", async (json, count) => {
    await expect(verifyTranscriptJSON(json, count)).resolves.toBe(false);
  });

  it("enforces bounded transcript parser depth and string length", async () => {
    const deep = `{"segments":[${"[".repeat(65)}{}${"]".repeat(65)}]}`;
    await expect(verifyTranscriptJSON(deep, 1)).resolves.toBe(false);
    const longString = `{"segments":[{"text":"${"a".repeat(65_537)}"}]}`;
    await expect(verifyTranscriptJSON(longString, 1)).resolves.toBe(false);
  });

  it("enforces the transcript token budget before a manifest can become ready", async () => {
    const excessiveTokens = `{"segments":[],"metadata":[${"0,".repeat(1_000_001)}0]}`;
    await expect(verifyTranscriptJSON(excessiveTokens, 0, 64 * 1024)).resolves.toBe(false);
  });

  it("does not mark a mismatched upload ready", async () => {
    const database = createFakeDatabaseClient();
    const principal = createFakePrincipal();
    const app = createTestApp({ database });
    const created = await app.fetch(
      new Request("http://localhost/v2/assets/uploads", {
        method: "POST",
        headers: headers("asset-v2-create-01"),
        body: JSON.stringify({
          kind: "cover",
          contentType: "image/png",
          encoding: "identity",
          compressedBytes: 3,
          originalBytes: 3,
          sha256: SHA256_123,
          fileName: "cover.png",
        }),
      }),
    );
    expect(created.status).toBe(201);
    const ticket: unknown = await created.json();
    expect(isRecord(ticket) && typeof ticket.uploadId === "string").toBe(true);
    if (
      !isRecord(ticket) ||
      typeof ticket.uploadId !== "string" ||
      typeof ticket.url !== "string"
    ) {
      return;
    }

    expect(
      (
        await app.fetch(
          new Request(ticket.url, {
            method: "PUT",
            headers: {
              authorization: "Bearer test",
              "content-type": "image/png",
              "content-length": "3",
            },
            body: new Uint8Array([9, 9, 9]),
          }),
        )
      ).status,
    ).toBe(200);
    const completed = await app.fetch(
      new Request(`http://localhost/v2/assets/uploads/${ticket.uploadId}/complete`, {
        method: "POST",
        headers: headers("asset-v2-complete-01"),
        body: "{}",
      }),
    );
    expect(completed.status).toBe(400);
    expect(await database.ops.getAssetByUpload(principal.accountId, ticket.uploadId)).toMatchObject(
      {
        status: "pending",
      },
    );
  });
});
