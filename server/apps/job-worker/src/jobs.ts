import type { OpsStore } from "@audio-reader/database";
import type { QwenClient } from "@audio-reader/qwen";

export type QueueMessageAck = {
  ack(): void;
  retry(): void;
};

export type DeletionObjectStore = {
  list(prefix: string): Promise<string[]>;
  delete(key: string): Promise<void>;
};

export async function consumeJobBatch(
  ops: OpsStore,
  qwen: QwenClient,
  messages: readonly QueueMessageAck[],
  objects?: DeletionObjectStore,
): Promise<number> {
  try {
    const completed = await processQueuedJobs(ops, qwen, objects);
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
  objects?: DeletionObjectStore,
): Promise<number> {
  const queued = await ops.claimJobs(16);
  let completed = 0;
  for (const job of queued) {
    if (job.kind === "legacy_cleanup" && job.accountId !== null) {
      try {
        if (objects === undefined) throw new Error("legacy_cleanup_object_store_not_configured");
        const inspected = await ops.cleanupObsoleteV1Data(job.accountId, false);
        const prefixes = [`${job.accountId}/`, `private/v1/${job.accountId}/`];
        const listed = (await Promise.all(prefixes.map((prefix) => objects.list(prefix)))).flat();
        const keys = new Set([
          ...listed,
          ...inspected.objectKeys.filter((key) =>
            prefixes.some((prefix) => key.startsWith(prefix)),
          ),
        ]);
        for (const key of [...keys].sort()) await objects.delete(key);
        const result = await ops.cleanupObsoleteV1Data(job.accountId, true);
        await ops.updateJob(job.id, {
          status: "succeeded",
          finishedAt: new Date().toISOString(),
          payload: { ...job.payload, result },
        });
        completed += 1;
      } catch (error) {
        const status = job.attempts >= job.maxAttempts ? "dead_letter" : "queued";
        await ops.updateJob(job.id, {
          status,
          lastError: error instanceof Error ? error.message : "legacy_cleanup_failed",
          finishedAt: status === "dead_letter" ? new Date().toISOString() : null,
        });
      }
      continue;
    }
    if (job.kind === "chat" || job.kind === "translation" || job.kind === "summary") {
      const message = typeof job.payload.message === "string" ? job.payload.message : job.kind;
      const result = await qwen.complete({ messages: [{ role: "user", content: message }] });
      if (!result.ok) {
        await ops.updateJob(job.id, {
          status: job.attempts >= job.maxAttempts ? "dead_letter" : "failed",
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
      console.warn(
        JSON.stringify({
          level: "info",
          message: "account_deletion_started",
          component: "job-worker",
          jobId: job.id,
          accountId: job.accountId,
        }),
      );
      let erased: boolean;
      try {
        if (objects === undefined) throw new Error("account_object_store_not_configured");
        const prefixes = [`${job.accountId}/`, `private/v2/${job.accountId}/`];
        const writeLeases = await ops.accountObjectWriteLeases(job.accountId);
        if (writeLeases.some((lease) => Date.parse(lease.expiresAt) > Date.now())) {
          await ops.updateJob(job.id, {
            status: "queued",
            attempts: Math.max(0, job.attempts - 1),
            lastError: "account_object_writes_in_progress",
            finishedAt: null,
          });
          console.warn(
            JSON.stringify({
              level: "info",
              message: "account_deletion_deferred_for_object_writes",
              component: "job-worker",
              jobId: job.id,
              accountId: job.accountId,
              outcome: "queued",
            }),
          );
          continue;
        }
        const keys = [
          ...new Set([
            ...(await ops.accountObjectKeys(job.accountId)),
            ...writeLeases.map((lease) => lease.objectKey),
            ...(await Promise.all(prefixes.map((prefix) => objects.list(prefix)))).flat(),
          ]),
        ].sort();
        for (const key of keys) await objects.delete(key);
        const remaining = new Set(
          (await Promise.all(prefixes.map((prefix) => objects.list(prefix)))).flat(),
        );
        if (keys.some((key) => remaining.has(key))) {
          throw new Error("account_object_delete_not_verified");
        }
        erased = await ops.deleteAccountData(job.accountId);
      } catch {
        erased = false;
      }
      if (!erased) {
        const status = job.attempts >= job.maxAttempts ? "dead_letter" : "queued";
        await ops.updateJob(job.id, {
          status,
          lastError: "account_deletion_failed",
          finishedAt: status === "dead_letter" ? new Date().toISOString() : null,
        });
        console.warn(
          JSON.stringify({
            level: "warn",
            message: "account_deletion_failed",
            component: "job-worker",
            jobId: job.id,
            accountId: job.accountId,
            outcome: status,
          }),
        );
        continue;
      }
      console.warn(
        JSON.stringify({
          level: "info",
          message: "account_deletion_finished",
          component: "job-worker",
          jobId: job.id,
          outcome: "erased",
        }),
      );
    }
    await ops.updateJob(job.id, { status: "succeeded", finishedAt: new Date().toISOString() });
    completed += 1;
  }
  return completed;
}

/** Scheduled maintenance owns time-based retention independently of Operator reads. */
export async function runScheduledMaintenance(
  ops: OpsStore,
  qwen: QwenClient,
  objects?: DeletionObjectStore,
): Promise<{
  purgedSnapshots: number;
  purgedProductEvents: number;
  purgedAssetObjects: number;
  completedJobs: number;
}> {
  const purgedSnapshots = await ops.purgeExpiredUserProgressSummaries();
  console.warn(
    JSON.stringify({
      level: "info",
      message: "user_progress_retention_purged",
      component: "job-worker",
      purgedSnapshots,
      outcome: "ok",
    }),
  );
  const purgedProductEvents = await ops.purgeExpiredProductEvents();
  console.warn(
    JSON.stringify({
      level: "info",
      message: "product_event_retention_purged",
      component: "job-worker",
      purgedProductEvents,
      outcome: "ok",
    }),
  );
  const readyUploadCleanup = await ops.claimReadyAssetUploadCleanup(500);
  if (readyUploadCleanup.length > 0 && objects === undefined) {
    throw new Error("ready_asset_cleanup_object_store_not_configured");
  }
  for (const cleanup of readyUploadCleanup) {
    await objects?.delete(cleanup.uploadObjectKey);
    await ops.finishReadyAssetUploadCleanup([cleanup.id]);
  }
  const abandonedUploads = await ops.gcAbandonedAssetUploads(new Date().toISOString(), 500);
  if (abandonedUploads.length > 0 && objects === undefined) {
    throw new Error("abandoned_asset_object_store_not_configured");
  }
  let purgedAssetObjects = 0;
  for (const upload of abandonedUploads) {
    for (const key of upload.objectKeys) {
      await objects?.delete(key);
      purgedAssetObjects += 1;
    }
    await ops.finishAbandonedAssetUploadGc([upload.id]);
  }
  console.warn(
    JSON.stringify({
      level: "info",
      message: "abandoned_asset_uploads_purged",
      component: "job-worker",
      purgedAssetObjects,
      outcome: "ok",
    }),
  );
  const completedJobs = await processQueuedJobs(ops, qwen, objects);
  return {
    purgedSnapshots,
    purgedProductEvents,
    purgedAssetObjects,
    completedJobs,
  };
}
