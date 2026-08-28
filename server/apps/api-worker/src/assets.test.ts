import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

describe("asset upload API", () => {
  it("creates a ticket, accepts the body, completes, and signs a download", async () => {
    const app = createTestApp();
    const created = await app.fetch(
      new Request("http://localhost/v1/uploads", {
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
          sizeBytes: 3,
          sha256: "abc",
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
        headers: { authorization: "Bearer test", "content-type": "image/png" },
        body: new Uint8Array([1, 2, 3]),
      }),
    );
    expect(put.status).toBe(200);
    const completed = await app.fetch(
      new Request(`http://localhost/v1/uploads/${ticket.uploadId}/complete`, {
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
      new Request(`http://localhost/v1/assets/${asset.id}/download`, {
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
});
