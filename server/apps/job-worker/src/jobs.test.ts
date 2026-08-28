import { createFakeDatabaseClient } from "@audio-reader/database";
import { createFakeQwenClient } from "@audio-reader/qwen";
import { describe, expect, it } from "vitest";
import { consumeJobBatch, processQueuedJobs } from "./jobs";

describe("job worker", () => {
  it("completes queued assistant jobs with Qwen", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.createJob({
      accountId: "00000000-0000-4000-8000-000000000002",
      kind: "chat",
      payload: { message: "hello" },
    });
    const completed = await processQueuedJobs(database.ops, createFakeQwenClient({ text: "hi" }));
    expect(completed).toBe(1);
    const jobs = await database.ops.listJobs({ status: "succeeded" });
    expect(jobs).toHaveLength(1);
    expect(jobs[0]?.payload.text).toBe("hi");
  });

  it("acks a queue batch after processing queued jobs", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.createJob({
      accountId: "00000000-0000-4000-8000-000000000002",
      kind: "translation",
      payload: { message: "hello" },
    });
    const acked: string[] = [];
    const completed = await consumeJobBatch(database.ops, createFakeQwenClient({ text: "ok" }), [
      {
        ack: () => acked.push("ack"),
        retry: () => acked.push("retry"),
      },
    ]);
    expect(completed).toBe(1);
    expect(acked).toEqual(["ack"]);
  });

  it("completes account deletion jobs and marks the profile deleted", async () => {
    const database = createFakeDatabaseClient();
    const profile = await database.identity.ensureProfile({
      userId: "00000000-0000-4000-8000-000000000002",
      email: "gone@example.com",
    });
    await database.ops.createPrivacyRequest({
      accountId: profile.accountId,
      kind: "deletion",
      status: "queued",
      reason: "leaving",
    });
    await database.ops.createJob({
      accountId: profile.accountId,
      kind: "account_deletion",
      payload: { reason: "leaving" },
    });
    const completed = await processQueuedJobs(
      database.ops,
      createFakeQwenClient(),
      database.identity,
    );
    expect(completed).toBe(1);
    const updated = await database.identity.getProfileByUserId(profile.accountId);
    expect(updated?.status).toBe("deleted");
    const privacy = await database.ops.listPrivacyRequests();
    expect(privacy[0]?.status).toBe("ready");
  });
});
