import {
  createFakeDatabaseClient,
  createSupabaseDatabaseClient,
  decryptOperatorSecrets,
  type OpsStore,
} from "@audio-reader/database";
import { createFakeQwenClient, createQwenClient, type QwenClient } from "@audio-reader/qwen";
import { consumeJobBatch, processQueuedJobs } from "./jobs";

export { packageId } from "./packageId";
export { processQueuedJobs } from "./jobs";

type WorkerEnv = {
  QWEN_API_KEY?: string;
  QWEN_BASE_URL?: string;
  QWEN_MODEL?: string;
  SUPABASE_URL?: string;
  SUPABASE_SERVICE_ROLE_KEY?: string;
  SUPABASE_SECRET_KEY?: string;
  OPERATOR_CONFIG_KEY?: string;
  CACHE_HMAC_SECRET?: string;
};

function resolveDatabase(env: WorkerEnv) {
  const url = env.SUPABASE_URL?.trim() ?? "";
  const serviceRoleKey =
    env.SUPABASE_SERVICE_ROLE_KEY?.trim() || env.SUPABASE_SECRET_KEY?.trim() || "";
  if (url !== "" && serviceRoleKey !== "") {
    return createSupabaseDatabaseClient({ url, serviceRoleKey });
  }
  return createFakeDatabaseClient();
}

async function resolveQwen(env: WorkerEnv, ops: OpsStore): Promise<QwenClient> {
  let overlayKey = "";
  let overlayBase = "";
  let overlayModel = "";
  const wrapping = env.OPERATOR_CONFIG_KEY?.trim() || env.CACHE_HMAC_SECRET?.trim() || "";
  try {
    const stored = await ops.getOperatorSettings();
    if (stored !== undefined) {
      overlayBase =
        typeof stored.payload.qwenBaseUrl === "string" ? stored.payload.qwenBaseUrl : "";
      overlayModel = typeof stored.payload.qwenModel === "string" ? stored.payload.qwenModel : "";
      if (stored.ciphertext !== null && stored.nonce !== null && wrapping !== "") {
        const secrets = await decryptOperatorSecrets(wrapping, {
          ciphertext: stored.ciphertext,
          nonce: stored.nonce,
        });
        overlayKey = secrets.qwenApiKey?.trim() ?? "";
      }
    }
  } catch {
    overlayKey = "";
  }
  const apiKey = overlayKey || env.QWEN_API_KEY?.trim() || "";
  if (apiKey === "") {
    return createFakeQwenClient();
  }
  return createQwenClient({
    apiKey,
    baseUrl:
      overlayBase ||
      env.QWEN_BASE_URL?.trim() ||
      "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
    model: overlayModel || env.QWEN_MODEL?.trim() || "qwen3.7-plus",
  });
}

export default {
  fetch(): Response {
    return new Response(JSON.stringify({ status: "ok", service: "job-worker" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  },
  async queue(batch: MessageBatch, env: WorkerEnv): Promise<void> {
    const database = resolveDatabase(env);
    await consumeJobBatch(
      database.ops,
      await resolveQwen(env, database.ops),
      batch.messages,
      database.identity,
    );
  },
  async scheduled(
    _controller: ScheduledController,
    env: WorkerEnv,
    ctx: ExecutionContext,
  ): Promise<void> {
    const database = resolveDatabase(env);
    ctx.waitUntil(
      processQueuedJobs(database.ops, await resolveQwen(env, database.ops), database.identity).then(
        () => undefined,
      ),
    );
  },
} satisfies ExportedHandler<WorkerEnv>;
