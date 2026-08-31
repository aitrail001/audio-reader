import { LOCAL_PASSWORDLESS_HMAC_SECRET } from "@audio-reader/auth";
import {
  decryptOperatorSecrets,
  encryptOperatorSecrets,
  type OperatorSecrets,
} from "@audio-reader/database";
import type { OpsStore } from "@audio-reader/database";
import type { QwenClient } from "@audio-reader/qwen";
import { createFakeQwenClient, createQwenClient } from "@audio-reader/qwen";
import { parseEnvironment, type OperatorWrappingSource, type WorkerEnv } from "./env";
import { parseServiceAccountJson } from "./gcs";
import { recordOperatorEvent } from "./operator-events";
import {
  createFakeObjectStore,
  createR2ObjectStore,
  createUnavailableObjectStore,
  tryCreateGcsObjectStore,
  tryCreateSupabaseObjectStore,
  type ObjectStore,
} from "./object-store";

const CACHE_MS = 30_000;

export type RuntimeConfigView = {
  qwen: {
    apiKeyConfigured: boolean;
    apiKeyLast4?: string;
    baseUrl: string;
    model: string;
    source: "env" | "admin" | "none";
    ciphertextPresent: boolean;
    secretsDecryptable: boolean;
    wrappingSecretConfigured: boolean;
    wrappingSecretSource: OperatorWrappingSource;
  };
  storage: {
    provider: "gcs" | "supabase" | "r2" | "none";
    bucket?: string;
    credentialsConfigured: boolean;
    serviceAccountConfigured: boolean;
    clientEmail?: string;
    source: "env" | "admin" | "none";
  };
  turnstile: {
    configured: boolean;
    source: "env" | "admin" | "none";
  };
  bootstrap: {
    supabaseUrlConfigured: boolean;
    supabaseAnonKeyConfigured: boolean;
    supabaseServiceRoleConfigured: boolean;
    cacheHmacConfigured: boolean;
    operatorConfigKeyConfigured: boolean;
    adminBootstrapEmailConfigured: boolean;
    resendConfigured: boolean;
    otpFromConfigured: boolean;
    qwenEnvKeyConfigured: boolean;
  };
  assistant: {
    sentenceContextCount: number;
  };
  updatedAt?: string;
};

export class OperatorWrappingNotConfiguredError extends Error {
  constructor() {
    super("Operator wrapping key is not configured; refusing to encrypt secrets.");
    this.name = "OperatorWrappingNotConfiguredError";
  }
}

export type RuntimeConfigPut = {
  qwen?: {
    apiKey?: string | null;
    baseUrl?: string;
    model?: string;
  };
  storage?: {
    bucket?: string;
    serviceAccountJson?: string | null;
  };
  turnstile?: {
    secretKey?: string | null;
  };
  assistant?: {
    sentenceContextCount?: number;
  };
};

export type OperatorPublicPayload = {
  qwenBaseUrl?: string;
  qwenModel?: string;
  gcsBucket?: string;
  gcsClientEmail?: string;
  sentenceContextCount?: number;
};

export type RuntimeConfigService = {
  view(): Promise<RuntimeConfigView>;
  put(input: RuntimeConfigPut, actorId: string): Promise<RuntimeConfigView>;
  resolveQwen(): Promise<{ apiKey: string; baseUrl?: string; model?: string } | undefined>;
  resolveQwenClient(input: { useFakes: boolean }): Promise<QwenClient>;
  resolveStorage(input: { useFakes: boolean }): Promise<RuntimeStorageResolution>;
  resolveTurnstileSecret(): Promise<string | undefined>;
  invalidate(): void;
};

export type RuntimeStorageResolution = {
  store: ObjectStore;
  descriptor: {
    provider: "gcs" | "supabase" | "r2" | "memory" | "none";
    bucket?: string;
    configured: boolean;
    credentialsConfigured: boolean;
  };
};

type CachedState = {
  expiresAt: number;
  publicPayload: OperatorPublicPayload;
  secrets: OperatorSecrets;
  updatedAt?: string;
  hasAdminRow: boolean;
  ciphertextPresent: boolean;
  secretsDecryptable: boolean;
};

export function createRuntimeConfigService(input: {
  env: WorkerEnv;
  ops?: OpsStore;
  wrappingSecret: string;
  wrappingSource?: OperatorWrappingSource;
  now?: () => number;
  fetch?: typeof fetch;
}): RuntimeConfigService {
  const wrappingSource =
    input.wrappingSource ??
    ((input.env.OPERATOR_CONFIG_KEY?.trim() ?? "") !== ""
      ? "operator_config_key"
      : (input.env.CACHE_HMAC_SECRET?.trim() ?? "") !== "" ||
          (input.env.PASSWORDLESS_HMAC_SECRET?.trim() ?? "") !== ""
        ? "cache_hmac"
        : input.wrappingSecret.trim() === ""
          ? "none"
          : "cache_hmac");
  const now = input.now ?? (() => Date.now());
  let cache: CachedState | undefined;
  let qwenClient: { key: string; client: QwenClient } | undefined;
  let objectStore:
    | {
        config: readonly (string | boolean)[];
        resolution: RuntimeStorageResolution;
      }
    | undefined;

  async function load(): Promise<CachedState> {
    if (cache !== undefined && cache.expiresAt > now()) {
      return cache;
    }
    const settingsRead = await input.ops?.readOperatorSettings();
    if (settingsRead !== undefined && !settingsRead.ok) {
      throw new Error("operator_settings_unavailable");
    }
    const stored = settingsRead?.value;
    let secrets: OperatorSecrets = {};
    const nonce = stored?.nonce;
    const ciphertext = stored?.ciphertext;
    const ciphertextPresent =
      typeof ciphertext === "string" &&
      ciphertext !== "" &&
      typeof nonce === "string" &&
      nonce !== "";
    let secretsDecryptable = !ciphertextPresent;
    if (ciphertextPresent && typeof nonce === "string" && typeof ciphertext === "string") {
      try {
        secrets = await decryptOperatorSecrets(input.wrappingSecret, {
          nonce,
          ciphertext,
        });
        secretsDecryptable = true;
      } catch {
        secrets = {};
        secretsDecryptable = false;
        recordOperatorEvent({
          kind: "operator_secrets_decrypt_failed",
          requestId: "runtime",
          status: "error",
          summary:
            "Saved operator secrets could not be decrypted. Check OPERATOR_CONFIG_KEY / CACHE_HMAC_SECRET.",
        });
        console.warn(
          JSON.stringify({
            level: "warn",
            component: "runtime-config",
            message: "operator_secrets_decrypt_failed",
            requestId: "runtime",
            outcome: "failed",
            wrappingSource,
            ciphertextPresent: true,
            secretsDecryptable: false,
          }),
        );
      }
    }
    cache = {
      expiresAt: now() + CACHE_MS,
      publicPayload: asPublicPayload(stored?.payload ?? {}),
      secrets,
      ...(stored?.updatedAt === undefined ? {} : { updatedAt: stored.updatedAt }),
      hasAdminRow: stored !== undefined,
      ciphertextPresent,
      secretsDecryptable,
    };
    return cache;
  }

  function envQwenKey(): string {
    return input.env.QWEN_API_KEY?.trim() ?? "";
  }

  function envGcsJson(): string {
    return input.env.GCS_SERVICE_ACCOUNT_JSON?.trim() ?? "";
  }

  function envGcsBucket(): string {
    return input.env.GCS_BUCKET?.trim() ?? "";
  }

  function envTurnstile(): string {
    return input.env.TURNSTILE_SECRET_KEY?.trim() ?? "";
  }

  async function resolved() {
    const state = await load();
    // Ciphertext that will not decrypt must not mix Desk model/URL with env keys.
    const denyEnvSecrets = state.ciphertextPresent && !state.secretsDecryptable;
    const qwenApiKey = state.secrets.qwenApiKey?.trim() || (denyEnvSecrets ? "" : envQwenKey());
    const qwenBaseUrl =
      state.publicPayload.qwenBaseUrl?.trim() || input.env.QWEN_BASE_URL?.trim() || "";
    const qwenModel = state.publicPayload.qwenModel?.trim() || input.env.QWEN_MODEL?.trim() || "";
    const gcsJson =
      state.secrets.gcsServiceAccountJson?.trim() || (denyEnvSecrets ? "" : envGcsJson());
    const gcsBucket = state.publicPayload.gcsBucket?.trim() || envGcsBucket();
    const turnstileSecret =
      state.secrets.turnstileSecret?.trim() || (denyEnvSecrets ? "" : envTurnstile());
    return {
      state,
      qwenApiKey,
      qwenBaseUrl,
      qwenModel,
      gcsJson,
      gcsBucket,
      turnstileSecret,
    };
  }

  async function view(): Promise<RuntimeConfigView> {
    const snapshot = await resolved();
    const supabaseBucket = input.env.SUPABASE_STORAGE_BUCKET?.trim() ?? "";
    const denyEnvSecrets = snapshot.state.ciphertextPresent && !snapshot.state.secretsDecryptable;
    const qwenSource =
      (snapshot.state.secrets.qwenApiKey?.trim() ?? "") !== ""
        ? "admin"
        : !denyEnvSecrets && envQwenKey() !== ""
          ? "env"
          : "none";
    const storageSource =
      (snapshot.state.secrets.gcsServiceAccountJson?.trim() ?? "") !== ""
        ? "admin"
        : !denyEnvSecrets && envGcsJson() !== ""
          ? "env"
          : "none";
    const turnstileSource =
      (snapshot.state.secrets.turnstileSecret?.trim() ?? "") !== ""
        ? "admin"
        : !denyEnvSecrets && envTurnstile() !== ""
          ? "env"
          : "none";
    let clientEmail = snapshot.state.publicPayload.gcsClientEmail;
    if ((clientEmail === undefined || clientEmail === "") && snapshot.gcsJson !== "") {
      try {
        clientEmail = parseServiceAccountJson(snapshot.gcsJson).clientEmail;
      } catch {
        clientEmail = undefined;
      }
    }
    const storageResolution = resolveStorageFor(snapshot, false);
    const storageDescriptor = storageResolution.descriptor;
    return {
      qwen: {
        apiKeyConfigured: snapshot.qwenApiKey !== "",
        ...(snapshot.qwenApiKey.length >= 4 ? { apiKeyLast4: snapshot.qwenApiKey.slice(-4) } : {}),
        baseUrl: snapshot.qwenBaseUrl,
        model: snapshot.qwenModel,
        source: qwenSource,
        ciphertextPresent: snapshot.state.ciphertextPresent,
        secretsDecryptable: snapshot.state.secretsDecryptable,
        wrappingSecretConfigured: input.wrappingSecret.trim() !== "",
        wrappingSecretSource: wrappingSource,
      },
      storage: {
        provider: storageDescriptor.provider === "memory" ? "none" : storageDescriptor.provider,
        ...(storageDescriptor.bucket === undefined ? {} : { bucket: storageDescriptor.bucket }),
        credentialsConfigured: storageDescriptor.credentialsConfigured,
        serviceAccountConfigured: snapshot.gcsJson !== "",
        ...(clientEmail === undefined || clientEmail === "" ? {} : { clientEmail }),
        source:
          supabaseBucket !== ""
            ? "env"
            : input.env.ASSETS !== undefined && snapshot.gcsBucket === ""
              ? "env"
              : storageSource === "none" && snapshot.gcsBucket !== ""
                ? "admin"
                : storageSource,
      },
      turnstile: {
        configured: snapshot.turnstileSecret !== "",
        source: turnstileSource,
      },
      bootstrap: {
        supabaseUrlConfigured: (input.env.SUPABASE_URL?.trim() ?? "") !== "",
        supabaseAnonKeyConfigured: (input.env.SUPABASE_ANON_KEY?.trim() ?? "") !== "",
        supabaseServiceRoleConfigured:
          (input.env.SUPABASE_SERVICE_ROLE_KEY?.trim() ||
            input.env.SUPABASE_SECRET_KEY?.trim() ||
            "") !== "",
        cacheHmacConfigured: (input.env.CACHE_HMAC_SECRET?.trim() ?? "") !== "",
        operatorConfigKeyConfigured: (input.env.OPERATOR_CONFIG_KEY?.trim() ?? "") !== "",
        adminBootstrapEmailConfigured: (input.env.ADMIN_BOOTSTRAP_EMAIL?.trim() ?? "") !== "",
        resendConfigured: (input.env.RESEND_API_KEY?.trim() ?? "") !== "",
        otpFromConfigured: (input.env.OTP_FROM_EMAIL?.trim() ?? "") !== "",
        qwenEnvKeyConfigured: (input.env.QWEN_API_KEY?.trim() ?? "") !== "",
      },
      assistant: {
        sentenceContextCount: sentenceContextCountOf(snapshot.state.publicPayload),
      },
      ...(snapshot.state.updatedAt === undefined ? {} : { updatedAt: snapshot.state.updatedAt }),
    };
  }

  /** Provider selection and its public descriptor are resolved from one immutable snapshot. */
  function resolveStorageFor(
    snapshot: { gcsBucket: string; gcsJson: string },
    useFakes: boolean,
  ): RuntimeStorageResolution {
    const supabaseUrl = input.env.SUPABASE_URL?.trim() ?? "";
    const supabaseKey =
      input.env.SUPABASE_SERVICE_ROLE_KEY?.trim() || input.env.SUPABASE_SECRET_KEY?.trim() || "";
    const supabaseBucket = input.env.SUPABASE_STORAGE_BUCKET?.trim() ?? "";
    const supabaseSignedUploadTtlRaw =
      input.env.SUPABASE_STORAGE_SIGNED_UPLOAD_TTL_SECONDS?.trim() ?? "";
    const supabaseSignedUploadTtlCandidate = Number(supabaseSignedUploadTtlRaw);
    const supabaseSignedUploadTtlSeconds =
      supabaseSignedUploadTtlRaw !== "" &&
      Number.isSafeInteger(supabaseSignedUploadTtlCandidate) &&
      supabaseSignedUploadTtlCandidate > 0
        ? supabaseSignedUploadTtlCandidate
        : undefined;
    const hasR2 = input.env.ASSETS !== undefined;
    const r2 = input.env.ASSETS;
    const r2AccountId = input.env.R2_ACCOUNT_ID?.trim() ?? "";
    const r2BucketName = input.env.R2_BUCKET_NAME?.trim() ?? "";
    const r2ManagementApiToken = input.env.R2_MANAGEMENT_API_TOKEN?.trim() ?? "";
    const r2CredentialsConfigured =
      r2AccountId !== "" && r2BucketName !== "" && r2ManagementApiToken !== "";
    const config = [
      snapshot.gcsBucket,
      snapshot.gcsJson,
      supabaseUrl,
      supabaseKey,
      supabaseBucket,
      supabaseSignedUploadTtlRaw,
      hasR2,
      r2AccountId,
      r2BucketName,
      r2ManagementApiToken,
      useFakes,
    ] as const;
    if (
      objectStore !== undefined &&
      objectStore.config.every((value, index) => value === config[index])
    ) {
      return objectStore.resolution;
    }

    let resolution: RuntimeStorageResolution;
    if (supabaseBucket !== "") {
      const parsed = tryCreateSupabaseObjectStore({
        ...(supabaseUrl === "" ? {} : { url: supabaseUrl }),
        ...(supabaseKey === "" ? {} : { serviceRoleKey: supabaseKey }),
        bucket: supabaseBucket,
        ...(supabaseSignedUploadTtlSeconds === undefined
          ? {}
          : { signedUploadTtlSeconds: supabaseSignedUploadTtlSeconds }),
        ...(input.fetch === undefined ? {} : { fetch: input.fetch }),
      });
      resolution = {
        store: parsed ?? createUnavailableObjectStore(),
        descriptor: {
          provider: "supabase",
          bucket: supabaseBucket,
          configured: true,
          credentialsConfigured: parsed !== undefined,
        },
      };
    } else if (snapshot.gcsBucket !== "" || snapshot.gcsJson !== "") {
      const parsed =
        snapshot.gcsBucket === "" || snapshot.gcsJson === ""
          ? undefined
          : tryCreateGcsObjectStore({
              bucket: snapshot.gcsBucket,
              serviceAccountJson: snapshot.gcsJson,
              ...(input.fetch === undefined ? {} : { fetch: input.fetch }),
            });
      resolution = {
        store: parsed ?? createUnavailableObjectStore(),
        descriptor: {
          provider: "gcs",
          ...(snapshot.gcsBucket === "" ? {} : { bucket: snapshot.gcsBucket }),
          configured: true,
          credentialsConfigured: parsed !== undefined,
        },
      };
    } else if (r2 !== undefined) {
      resolution = {
        store: createR2ObjectStore(r2, {
          accountId: r2AccountId,
          bucketName: r2BucketName,
          apiToken: r2ManagementApiToken,
          ...(input.fetch === undefined ? {} : { fetch: input.fetch }),
        }),
        descriptor: {
          provider: "r2",
          ...(r2BucketName === "" ? {} : { bucket: r2BucketName }),
          configured: true,
          credentialsConfigured: r2CredentialsConfigured,
        },
      };
    } else if (useFakes) {
      resolution = {
        store: createFakeObjectStore(),
        descriptor: {
          provider: "memory",
          bucket: "memory",
          configured: true,
          credentialsConfigured: true,
        },
      };
    } else {
      resolution = {
        store: createUnavailableObjectStore(),
        descriptor: { provider: "none", configured: false, credentialsConfigured: false },
      };
    }
    objectStore = { config, resolution };
    return resolution;
  }

  return {
    view,
    async put(patch, actorId) {
      const current = await load();
      const nextPublic: OperatorPublicPayload = { ...current.publicPayload };
      const nextSecrets: OperatorSecrets = { ...current.secrets };

      if (patch.qwen?.baseUrl !== undefined) {
        const trimmed = patch.qwen.baseUrl.trim();
        if (trimmed === "") {
          delete nextPublic.qwenBaseUrl;
        } else {
          nextPublic.qwenBaseUrl = trimmed;
        }
      }
      if (patch.qwen?.model !== undefined) {
        const trimmed = patch.qwen.model.trim();
        if (trimmed === "") {
          delete nextPublic.qwenModel;
        } else {
          nextPublic.qwenModel = trimmed;
        }
      }
      if (patch.qwen?.apiKey === null) {
        delete nextSecrets.qwenApiKey;
      } else if (typeof patch.qwen?.apiKey === "string" && patch.qwen.apiKey.trim() !== "") {
        nextSecrets.qwenApiKey = patch.qwen.apiKey.trim();
      }

      if (patch.storage?.bucket !== undefined) {
        const trimmed = patch.storage.bucket.trim();
        if (trimmed === "") {
          delete nextPublic.gcsBucket;
        } else {
          nextPublic.gcsBucket = trimmed;
        }
      }
      if (patch.storage?.serviceAccountJson === null) {
        delete nextSecrets.gcsServiceAccountJson;
        delete nextPublic.gcsClientEmail;
      } else if (
        typeof patch.storage?.serviceAccountJson === "string" &&
        patch.storage.serviceAccountJson.trim() !== ""
      ) {
        const parsed = parseServiceAccountJson(patch.storage.serviceAccountJson);
        nextSecrets.gcsServiceAccountJson = patch.storage.serviceAccountJson.trim();
        nextPublic.gcsClientEmail = parsed.clientEmail;
      }

      if (patch.turnstile?.secretKey === null) {
        delete nextSecrets.turnstileSecret;
      } else if (
        typeof patch.turnstile?.secretKey === "string" &&
        patch.turnstile.secretKey.trim() !== ""
      ) {
        nextSecrets.turnstileSecret = patch.turnstile.secretKey.trim();
      }

      if (patch.assistant?.sentenceContextCount !== undefined) {
        nextPublic.sentenceContextCount = sentenceContextCountOf({
          sentenceContextCount: patch.assistant.sentenceContextCount,
        });
      }

      const encrypting = Object.keys(nextSecrets).length > 0;
      if (
        encrypting &&
        !canEncryptOperatorSecrets(input.env.ENVIRONMENT, wrappingSource, input.wrappingSecret)
      ) {
        console.warn(
          JSON.stringify({
            level: "warn",
            component: "runtime-config",
            message: "operator_runtime_put_refused",
            requestId: actorId,
            outcome: "wrapping_not_configured",
            wrappingSource,
          }),
        );
        throw new OperatorWrappingNotConfiguredError();
      }

      const cipher = encrypting
        ? await encryptOperatorSecrets(input.wrappingSecret, nextSecrets)
        : { ciphertext: null, nonce: null };
      const saved = await input.ops?.putOperatorSettings({
        id: "default",
        payload: nextPublic,
        ciphertext: cipher.ciphertext,
        nonce: cipher.nonce,
        updatedBy: actorId,
      });
      cache = undefined;
      qwenClient = undefined;
      objectStore = undefined;
      recordOperatorEvent({
        kind: "operator_runtime_saved",
        requestId: actorId,
        status: "ok",
        summary: `Runtime config saved (Qwen model ${nextPublic.qwenModel ?? ""}, key ${
          (nextSecrets.qwenApiKey?.trim() ?? "") !== "" ? "set" : "absent"
        }).`,
        metadata: {
          qwenModel: nextPublic.qwenModel ?? "",
          qwenKeyConfigured: (nextSecrets.qwenApiKey?.trim() ?? "") !== "",
        },
      });
      console.warn(
        JSON.stringify({
          level: "warn",
          message: "operator_runtime_saved",
          actorId,
          qwenModel: nextPublic.qwenModel ?? "",
          qwenBaseUrlHost: hostOf(nextPublic.qwenBaseUrl ?? ""),
          qwenKeyConfigured: (nextSecrets.qwenApiKey?.trim() ?? "") !== "",
          qwenKeyLast4:
            (nextSecrets.qwenApiKey?.trim() ?? "").length >= 4
              ? nextSecrets.qwenApiKey?.trim().slice(-4)
              : undefined,
          wrappingSource,
          ciphertextPresent: cipher.ciphertext !== null && cipher.ciphertext !== "",
        }),
      );
      if (saved !== undefined) {
        cache = {
          expiresAt: now() + CACHE_MS,
          publicPayload: asPublicPayload(saved.payload),
          secrets: nextSecrets,
          updatedAt: saved.updatedAt,
          hasAdminRow: true,
          ciphertextPresent: saved.ciphertext !== null && saved.ciphertext !== "",
          secretsDecryptable: true,
        };
      }
      return view();
    },
    async resolveQwen() {
      const snapshot = await resolved();
      if (snapshot.qwenApiKey === "") {
        return undefined;
      }
      return {
        apiKey: snapshot.qwenApiKey,
        ...(snapshot.qwenBaseUrl === "" ? {} : { baseUrl: snapshot.qwenBaseUrl }),
        ...(snapshot.qwenModel === "" ? {} : { model: snapshot.qwenModel }),
      };
    },
    async resolveQwenClient({ useFakes }) {
      const config = await this.resolveQwen();
      const key = config === undefined ? "none" : JSON.stringify(config);
      if (qwenClient?.key === key) {
        return qwenClient.client;
      }
      const client =
        config === undefined
          ? createFakeQwenClient(useFakes ? {} : { status: "unavailable" })
          : createQwenClient({
              apiKey: config.apiKey,
              ...(config.baseUrl === undefined ? {} : { baseUrl: config.baseUrl }),
              ...(config.model === undefined ? {} : { model: config.model }),
              ...(input.fetch === undefined ? {} : { fetch: input.fetch }),
            });
      qwenClient = { key, client };
      return client;
    },
    async resolveStorage({ useFakes }) {
      // An explicit bucket is the provider selection, so stale Operator GCS settings are irrelevant.
      if ((input.env.SUPABASE_STORAGE_BUCKET?.trim() ?? "") !== "") {
        return resolveStorageFor({ gcsBucket: "", gcsJson: "" }, useFakes);
      }
      const snapshot = await resolved();
      return resolveStorageFor(snapshot, useFakes);
    },
    async resolveTurnstileSecret() {
      const snapshot = await resolved();
      return snapshot.turnstileSecret === "" ? undefined : snapshot.turnstileSecret;
    },
    invalidate() {
      cache = undefined;
      qwenClient = undefined;
      objectStore = undefined;
    },
  };
}

export function createResolvingQwenClient(resolve: () => Promise<QwenClient>): QwenClient {
  return {
    ping: async () => (await resolve()).ping(),
    pingDetailed: async () => (await resolve()).pingDetailed(),
    complete: async (request) => (await resolve()).complete(request),
  };
}

export function hostOf(value: string): string {
  const trimmed = value.trim();
  if (trimmed === "") {
    return "(empty)";
  }
  try {
    return new URL(trimmed).host || "(invalid)";
  } catch {
    return "(invalid)";
  }
}

function canEncryptOperatorSecrets(
  environment: string | undefined,
  wrappingSource: OperatorWrappingSource,
  wrappingSecret: string,
): boolean {
  if (wrappingSecret.trim() === LOCAL_PASSWORDLESS_HMAC_SECRET) {
    return false;
  }
  if (wrappingSource === "none") {
    const parsed = parseEnvironment(environment);
    return parsed === "local" || parsed === "test";
  }
  return true;
}

function asPublicPayload(value: Record<string, unknown>): OperatorPublicPayload {
  return {
    ...(typeof value.qwenBaseUrl === "string" ? { qwenBaseUrl: value.qwenBaseUrl } : {}),
    ...(typeof value.qwenModel === "string" ? { qwenModel: value.qwenModel } : {}),
    ...(typeof value.gcsBucket === "string" ? { gcsBucket: value.gcsBucket } : {}),
    ...(typeof value.gcsClientEmail === "string" ? { gcsClientEmail: value.gcsClientEmail } : {}),
    sentenceContextCount: sentenceContextCountOf(value),
  };
}

export function sentenceContextCountOf(value: { sentenceContextCount?: unknown }): number {
  const raw = value.sentenceContextCount;
  if (typeof raw !== "number" || !Number.isFinite(raw)) {
    return 1;
  }
  return Math.min(10, Math.max(0, Math.trunc(raw)));
}
