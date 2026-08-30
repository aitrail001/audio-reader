import { createFakeDatabaseClient } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";

describe("privacy request data minimization", () => {
  it("uses one transactional deletion request instead of separate profile/request/job writes", async () => {
    const database = createFakeDatabaseClient();
    const calls: Array<{ userId: string; reason: string; requestId: string }> = [];
    Object.assign(database.ops, {
      requestAccountDeletion(userId: string, reason: string, requestId: string) {
        calls.push({ userId, reason, requestId });
        const timestamp = "2026-08-30T05:00:00.000Z";
        return Promise.resolve({
          request: {
            id: "11111111-1111-4111-8111-111111111111",
            accountId: userId,
            kind: "deletion",
            status: "queued",
            format: null,
            assetId: null,
            error: null,
            reason,
            createdAt: timestamp,
            updatedAt: timestamp,
            completedAt: null,
          },
          job: {
            id: "22222222-2222-4222-8222-222222222222",
            accountId: userId,
            kind: "account_deletion",
            status: "queued",
            attempts: 0,
            maxAttempts: 5,
            lastError: null,
            payload: {},
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: null,
            finishedAt: null,
          },
        });
      },
      createPrivacyRequest: () => Promise.reject(new Error("non-atomic request write")),
      createJob: () => Promise.reject(new Error("non-atomic job write")),
    });
    const app = createTestApp({ database });

    const response = await app.fetch(
      new Request("http://localhost/v1/me/deletion", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-atomic-deletion",
          "X-Request-Id": "atomic-delete-trace",
          "content-type": "application/json",
        },
        body: JSON.stringify({ confirmation: "DELETE MY ACCOUNT", reason: "leaving" }),
      }),
    );

    expect(response.status).toBe(202);
    expect(calls).toEqual([
      expect.objectContaining({ reason: "leaving", requestId: "atomic-delete-trace" }),
    ]);
  });

  it("keeps the user's free-form deletion reason out of durable jobs and immutable audit", async () => {
    const database = createFakeDatabaseClient();
    const app = createTestApp({ database });
    const privateReason = "Contact me at private@example.com about my medical details";

    const response = await app.fetch(
      new Request("http://localhost/v1/me/deletion", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-private-deletion-reason",
          "content-type": "application/json",
        },
        body: JSON.stringify({ confirmation: "DELETE MY ACCOUNT", reason: privateReason }),
      }),
    );

    expect(response.status).toBe(202);
    const [request] = await database.ops.listPrivacyRequests({ status: "queued" });
    expect(request?.reason).toBe(privateReason);
    const [job] = await database.ops.listJobs({ status: "queued" });
    expect(JSON.stringify(job?.payload)).not.toContain(privateReason);
    const [audit] = await database.ops.listAudit({ action: "request_deletion" });
    expect(audit?.reason).toBe("User requested account deletion.");
    expect(JSON.stringify(audit)).not.toContain(privateReason);
  });
});
