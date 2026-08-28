import type { IdentityStore, OpsStore } from "@audio-reader/database";
import type { QwenClient } from "@audio-reader/qwen";

export type QueueMessageAck = {
  ack(): void;
  retry(): void;
};

export async function consumeJobBatch(
  ops: OpsStore,
  qwen: QwenClient,
  messages: readonly QueueMessageAck[],
  identity?: IdentityStore,
): Promise<number> {
  try {
    const completed = await processQueuedJobs(ops, qwen, identity);
    for (const message of messages) {
      message.ack();
    }
    return completed;
  } catch {
    for (const message of messages) {
      message.retry();
    }
    return 0;
  }
}

export async function processQueuedJobs(
  ops: OpsStore,
  qwen: QwenClient,
  identity?: IdentityStore,
): Promise<number> {
  const queued = await ops.listJobs({ status: "queued" });
  let completed = 0;
  for (const job of queued) {
    await ops.updateJob(job.id, {
      status: "running",
      startedAt: new Date().toISOString(),
      attempts: job.attempts + 1,
    });
    if (job.kind === "chat" || job.kind === "translation" || job.kind === "summary") {
      const message = typeof job.payload.message === "string" ? job.payload.message : job.kind;
      const result = await qwen.complete({ messages: [{ role: "user", content: message }] });
      if (!result.ok) {
        await ops.updateJob(job.id, {
          status: job.attempts + 1 >= job.maxAttempts ? "dead_letter" : "failed",
          lastError: result.code,
          finishedAt: new Date().toISOString(),
        });
        continue;
      }
      await ops.updateJob(job.id, {
        status: "succeeded",
        finishedAt: new Date().toISOString(),
        payload: { ...job.payload, text: result.text },
      });
      completed += 1;
      continue;
    }
    if (job.kind === "account_deletion" && job.accountId !== null) {
      await identity?.setAccountStatus(job.accountId, "deleted");
      await identity?.revokeAllDevices(job.accountId);
      const pending = await ops.listPrivacyRequests({ status: "queued" });
      for (const request of pending.filter(
        (item) => item.accountId === job.accountId && item.kind === "deletion",
      )) {
        await ops.patchPrivacyRequest(request.id, {
          status: "ready",
          completedAt: new Date().toISOString(),
        });
      }
    }
    await ops.updateJob(job.id, { status: "succeeded", finishedAt: new Date().toISOString() });
    completed += 1;
  }
  return completed;
}
