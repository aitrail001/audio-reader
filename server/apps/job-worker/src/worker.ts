import {
  createSupabaseDatabaseClient,
  decryptOperatorSecrets,
  type OpsStore,
} from "@audio-reader/database";
import {
  createR2ObjectStore,
  tryCreateGcsObjectStore,
  tryCreateSupabaseObjectStore,
  type ObjectStore,
} from "@audio-reader/api-worker/object-store";
import { resolveOperatorWrappingSecret } from "@audio-reader/api-worker/env";
import { createFakeQwenClient, createQwenClient, type QwenClient } from "@audio-reader/qwen";
import { consumeJobBatch, runScheduledMaintenance } from "./jobs";

export { packageId } from "./packageId";
export { processQueuedJobs, runScheduledMaintenance } from "./jobs";

type WorkerEnv = {
  APP_VERSION?: string;
  QWEN_API_KEY?: string;
  QWEN_BASE_URL?: string;
  QWEN_MODEL?: string;
  SUPABASE_URL?: string;
  SUPABASE_SERVICE_ROLE_KEY?: string;
  SUPABASE_SECRET_KEY?: string;
  OPERATOR_CONFIG_KEY?: string;
  CACHE_HMAC_SECRET?: string;
  PASSWORDLESS_HMAC_SECRET?: string;
  GCS_BUCKET?: string;
  GCS_SERVICE_ACCOUNT_JSON?: string;
  R2_ACCOUNT_ID?: string;
  R2_BUCKET_NAME?: string;
  R2_MANAGEMENT_API_TOKEN?: string;
  SUPABASE_STORAGE_BUCKET?: string;
  ASSETS?: R2Bucket;
};

// The API and Job Workers must derive the same key or stored provider secrets become unreadable.
export function resolveJobOperatorWrappingSecret(env: WorkerEnv): string {
  const resolved = resolveOperatorWrappingSecret(env);
  return resolved.fromEnv ? resolved.secret : "";
}

function resolveDatabase(env: WorkerEnv) {
  const url = env.SUPABASE_URL?.trim() ?? "";
  const serviceRoleKey =
    env.SUPABASE_SERVICE_ROLE_KEY?.trim() || env.SUPABASE_SECRET_KEY?.trim() || "";
  if (url !== "" && serviceRoleKey !== "") {
    return createSupabaseDatabaseClient({ url, serviceRoleKey });
  }
  throw new Error("job_worker_database_not_configured");
}

function databaseConfigured(env: WorkerEnv): boolean {
  return (
    (env.SUPABASE_URL?.trim() ?? "") !== "" &&
    (env.SUPABASE_SERVICE_ROLE_KEY?.trim() || env.SUPABASE_SECRET_KEY?.trim() || "") !== ""
  );
}

async function resolveStorage(env: WorkerEnv, ops: OpsStore): Promise<ObjectStore> {
  const supabaseBucket = env.SUPABASE_STORAGE_BUCKET?.trim() ?? "";
  if (supabaseBucket !== "") {
    const supabaseUrl = env.SUPABASE_URL?.trim() ?? "";
    const supabaseKey =
      env.SUPABASE_SERVICE_ROLE_KEY?.trim() || env.SUPABASE_SECRET_KEY?.trim() || "";
    // The explicit bucket selects Supabase authoritatively; stale Operator GCS data is not read.
    const supabase = tryCreateSupabaseObjectStore({
      ...(supabaseUrl === "" ? {} : { url: supabaseUrl }),
      ...(supabaseKey === "" ? {} : { serviceRoleKey: supabaseKey }),
      bucket: supabaseBucket,
    });
    if (supabase === undefined || (await supabase.ping()) !== "ok") {
      throw new Error("job_worker_storage_unavailable");
    }
    return supabase;
  }

  let bucket = env.GCS_BUCKET?.trim() ?? "";
  let serviceAccountJson = env.GCS_SERVICE_ACCOUNT_JSON?.trim() ?? "";
  const wrapping = resolveJobOperatorWrappingSecret(env);
  const settingsRead = await ops.readOperatorSettings();
  if (!settingsRead.ok) throw new Error("job_worker_operator_settings_unavailable");
  const stored = settingsRead.value;
  if (stored !== undefined) {
    if (typeof stored.payload.gcsBucket === "string" && stored.payload.gcsBucket.trim() !== "") {
      bucket = stored.payload.gcsBucket.trim();
    }
    if (stored.ciphertext !== null && stored.nonce !== null) {
      if (wrapping === "") throw new Error("job_worker_storage_secrets_unavailable");
      const secrets = await decryptOperatorSecrets(wrapping, {
        ciphertext: stored.ciphertext,
        nonce: stored.nonce,
      });
      serviceAccountJson = secrets.gcsServiceAccountJson?.trim() ?? serviceAccountJson;
    }
  }
  if (bucket !== "" && serviceAccountJson === "") {
    throw new Error("job_worker_storage_secrets_unavailable");
  }
  const gcs = tryCreateGcsObjectStore({ bucket, serviceAccountJson });
  const store =
    gcs ??
    (env.ASSETS === undefined
      ? undefined
      : createR2ObjectStore(env.ASSETS, {
          accountId: env.R2_ACCOUNT_ID?.trim() ?? "",
          bucketName: env.R2_BUCKET_NAME?.trim() ?? "",
          apiToken: env.R2_MANAGEMENT_API_TOKEN?.trim() ?? "",
        }));
  if (store === undefined || (await store.ping()) !== "ok") {
    throw new Error("job_worker_storage_unavailable");
  }
  return store;
}

async function resolveQwen(env: WorkerEnv, ops: OpsStore): Promise<QwenClient> {
  let overlayKey = "";
  let overlayBase = "";
  let overlayModel = "";
  const wrapping = resolveJobOperatorWrappingSecret(env);
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
  async fetch(_request: Request, env: WorkerEnv): Promise<Response> {
    let databaseStatus: "ok" | "unavailable" = "unavailable";
    let storageStatus: "ok" | "unavailable" = "unavailable";
    if (databaseConfigured(env)) {
      try {
        const database = resolveDatabase(env);
        databaseStatus = (await database.ping()) === "ok" ? "ok" : "unavailable";
        if (databaseStatus === "ok") {
          storageStatus = (await resolveStorage(env, database.ops).catch(() => undefined))
            ? "ok"
            : "unavailable";
        }
      } catch {
        databaseStatus = "unavailable";
      }
    }
    const ready = databaseStatus === "ok" && storageStatus === "ok";
    return new Response(
      JSON.stringify({
        status: ready ? "ok" : "unavailable",
        service: "job-worker",
        version: env.APP_VERSION?.trim() || "unknown",
        dependencies: { database: databaseStatus, storage: storageStatus },
      }),
      {
        status: ready ? 200 : 503,
        headers: { "content-type": "application/json" },
      },
    );
  },
  async queue(batch: MessageBatch, env: WorkerEnv): Promise<void> {
    const database = resolveDatabase(env);
    const objects = await resolveStorage(env, database.ops);
    await consumeJobBatch(
      database.ops,
      await resolveQwen(env, database.ops),
      batch.messages,
      objects,
    );
  },
  async scheduled(
    _controller: ScheduledController,
    env: WorkerEnv,
    ctx: ExecutionContext,
  ): Promise<void> {
    const database = resolveDatabase(env);
    const objects = await resolveStorage(env, database.ops);
    ctx.waitUntil(
      runScheduledMaintenance(database.ops, await resolveQwen(env, database.ops), objects).then(
        () => undefined,
      ),
    );
  },
} satisfies ExportedHandler<WorkerEnv>;
