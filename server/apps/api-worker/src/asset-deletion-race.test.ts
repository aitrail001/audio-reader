import { createFakeDatabaseClient } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";
import { createFakeObjectStore, type ObjectStore } from "./object-store";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const USER_ID = "00000000-0000-4000-8000-000000000002";

describe("asset upload deletion race", () => {
  it("removes a body written by a request that raced deletion_pending", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "private@example.com" });
    const inner = createFakeObjectStore();
    let firstPut = true;
    const storage: ObjectStore = {
      ...inner,
      async put(key, bytes) {
        await inner.put(key, bytes);
        if (firstPut) {
          firstPut = false;
          await database.identity.setAccountStatus(USER_ID, "deletion_pending");
        }
      },
    };
    const app = createTestApp({ database, storage });
    const created = await app.fetch(
      new Request("http://localhost/v1/uploads", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "asset-delete-race-create",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          kind: "audio",
          contentType: "audio/mp4",
          sizeBytes: 3,
          sha256: "abc",
          fileName: "private.m4b",
        }),
      }),
    );
    expect(created.status).toBe(201);
    const ticket: { uploadId: string } = await created.json();
    const uploaded = await app.fetch(
      new Request(`http://localhost/v1/uploads/${ticket.uploadId}/body`, {
        method: "PUT",
        headers: { authorization: "Bearer test", "content-type": "audio/mp4" },
        body: new Uint8Array([1, 2, 3]),
      }),
    );

    expect(uploaded.status).toBe(409);
    await expect(inner.list("")).resolves.toEqual([]);
  });

  it("removes an account export written while deletion begins", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "private@example.com" });
    const inner = createFakeObjectStore();
    const storage: ObjectStore = {
      ...inner,
      async put(key, bytes) {
        await inner.put(key, bytes);
        await database.identity.setAccountStatus(USER_ID, "deletion_pending");
      },
    };
    const app = createTestApp({ database, storage });
    const exported = await app.fetch(
      new Request("http://localhost/v1/exports", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "export-delete-race",
          "content-type": "application/json",
        },
        body: JSON.stringify({ format: "zip_json" }),
      }),
    );

    expect(exported.status).toBe(409);
    await expect(inner.list("")).resolves.toEqual([]);
  });

  it("retains a durable write lease when compensating object deletion fails", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({ userId: USER_ID, email: "private@example.com" });
    const inner = createFakeObjectStore();
    const storage: ObjectStore = {
      ...inner,
      async put(key, bytes) {
        await inner.put(key, bytes);
        await database.identity.setAccountStatus(USER_ID, "deletion_pending");
      },
      delete() {
        return Promise.reject(new Error("transient object delete failure"));
      },
    };
    const app = createTestApp({ database, storage });
    const created = await app.fetch(
      new Request("http://localhost/v1/uploads", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "asset-delete-failure-create",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          kind: "audio",
          contentType: "audio/mp4",
          sizeBytes: 3,
          sha256: "abc",
          fileName: "private.m4b",
        }),
      }),
    );
    const ticket: { uploadId: string } = await created.json();
    const uploaded = await app.fetch(
      new Request(`http://localhost/v1/uploads/${ticket.uploadId}/body`, {
        method: "PUT",
        headers: { authorization: "Bearer test", "content-type": "audio/mp4" },
        body: new Uint8Array([1, 2, 3]),
      }),
    );

    expect(uploaded.status).toBe(500);
    await expect(inner.list(`${USER_ID}/`)).resolves.toHaveLength(1);
    await expect(database.ops.accountObjectWriteLeases(USER_ID)).resolves.toHaveLength(1);
  });
});
