import { ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION, type DatabaseClient } from "@audio-reader/database";
import { createUnavailableObjectStore, type ObjectStore } from "./object-store";

export type AccountSyncCheckStatus = "ok" | "failed" | "not_checked";
export type AccountSyncStorageProvider = "gcs" | "supabase" | "r2" | "memory" | "none";
export type AccountSyncUnavailableReason =
  | "upgrade_required"
  | "required_schema_unavailable"
  | "storage_not_configured"
  | "storage_bucket_missing"
  | "storage_credentials_missing"
  | "storage_credentials_invalid"
  | "storage_direct_upload_unavailable"
  | "storage_public_access_allowed"
  | "storage_privacy_verification_failed"
  | "storage_upload_failed"
  | "storage_download_failed"
  | "storage_checksum_mismatch"
  | "storage_delete_failed"
  | "storage_delete_verification_failed";

export type AccountSyncStorageDescriptor = {
  provider: AccountSyncStorageProvider;
  bucket?: string;
  configured: boolean;
  credentialsConfigured: boolean;
};

export type AccountSyncStorageResolution = {
  store: ObjectStore;
  descriptor: AccountSyncStorageDescriptor;
};

export type AccountSyncReadiness = {
  minAppVersion: string;
  requiredSchemaVersion: string;
  schemaReady: boolean;
  provider: AccountSyncStorageProvider;
  bucket: string | null;
  credentialStatus: AccountSyncCheckStatus;
  privacyStatus: AccountSyncCheckStatus;
  uploadStatus: AccountSyncCheckStatus;
  downloadStatus: AccountSyncCheckStatus;
  checksumStatus: AccountSyncCheckStatus;
  deleteStatus: AccountSyncCheckStatus;
  notFoundStatus: AccountSyncCheckStatus;
  ready: boolean;
  requested: boolean;
  effective: boolean;
  reason: AccountSyncUnavailableReason | null;
  checkedAt: string;
  cachedUntil: string;
  retryAfterSeconds: number;
  lastSuccessAt: string | null;
  lastFailureAt: string | null;
  lastFailureCode: AccountSyncUnavailableReason | null;
  lastFailureDetail: string | null;
};

type DependencyReadiness = Omit<
  AccountSyncReadiness,
  | "requested"
  | "effective"
  | "lastSuccessAt"
  | "lastFailureAt"
  | "lastFailureCode"
  | "lastFailureDetail"
>;

export type AccountSyncReadinessService = {
  read(requested: boolean, options?: { force?: boolean }): Promise<AccountSyncReadiness>;
  invalidate(): void;
};

const PRIVATE_CANARY_PREFIX = "private/account-sync-readiness/";
const STALE_SWEEP_LIMIT = 21;
const STALE_DELETE_LIMIT = 20;
const CANARY_STALE_AFTER_MS = 15 * 60 * 1_000;

/** A generation-fenced private-object round trip is the source of effective sync state. */
export function createAccountSyncReadinessService(input: {
  database: Pick<DatabaseClient, "accountSyncSchemaVersion">;
  resolveStorage: () => Promise<AccountSyncStorageResolution>;
  now?: () => number;
  randomUUID?: () => string;
  successTtlMs?: number;
  failureTtlMs?: number;
}): AccountSyncReadinessService {
  const now = input.now ?? (() => Date.now());
  const randomUUID = input.randomUUID ?? (() => crypto.randomUUID());
  const successTtlMs = boundedTtl(input.successTtlMs, 30_000);
  const failureTtlMs = boundedTtl(input.failureTtlMs, 5_000);
  const owner = randomUUID();
  let generation = 0;
  let cached: { generation: number; expiresAt: number; value: DependencyReadiness } | undefined;
  let inFlight: { generation: number; promise: Promise<DependencyReadiness> } | undefined;
  let lastSuccessAt: string | null = null;
  let lastFailureAt: string | null = null;
  let lastFailureCode: AccountSyncUnavailableReason | null = null;
  let lastFailureDetail: string | null = null;

  function baseFor(descriptor: AccountSyncStorageDescriptor, schemaReady: boolean) {
    return {
      minAppVersion: "2.0.0",
      requiredSchemaVersion: ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION,
      schemaReady,
      provider: descriptor.provider,
      bucket: descriptor.bucket?.trim() || null,
      credentialStatus: "not_checked" as AccountSyncCheckStatus,
      privacyStatus: "not_checked" as AccountSyncCheckStatus,
      uploadStatus: "not_checked" as AccountSyncCheckStatus,
      downloadStatus: "not_checked" as AccountSyncCheckStatus,
      checksumStatus: "not_checked" as AccountSyncCheckStatus,
      deleteStatus: "not_checked" as AccountSyncCheckStatus,
      notFoundStatus: "not_checked" as AccountSyncCheckStatus,
    };
  }

  async function probe(): Promise<DependencyReadiness> {
    const checkedAtMs = now();
    const schemaReady =
      (await safeSchemaVersion(input.database)) === ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION;
    if (!schemaReady) {
      return failure(
        baseFor({ provider: "none", configured: false, credentialsConfigured: false }, false),
        "required_schema_unavailable",
        checkedAtMs,
        failureTtlMs,
      );
    }

    const { descriptor, store } = await safeResolution(input.resolveStorage);
    let statuses = baseFor(descriptor, true);
    if (!descriptor.configured || descriptor.provider === "none")
      return failure(statuses, "storage_not_configured", checkedAtMs, failureTtlMs);
    if (statuses.bucket === null)
      return failure(statuses, "storage_bucket_missing", checkedAtMs, failureTtlMs);
    if (!descriptor.credentialsConfigured)
      return failure(statuses, "storage_credentials_missing", checkedAtMs, failureTtlMs);

    let metadataPublicAccess: boolean;
    try {
      const privacy = await store.inspectPrivacy();
      if (!privacy.bucketExists)
        return failure(
          { ...statuses, privacyStatus: "failed" },
          "storage_bucket_missing",
          checkedAtMs,
          failureTtlMs,
        );
      metadataPublicAccess = privacy.publicAccess;
      statuses = { ...statuses, privacyStatus: privacy.publicAccess ? "failed" : "ok" };
      // R2 management proof also yields the only anonymous URL, so exercise its canary before failing.
      if (privacy.publicAccess && descriptor.provider !== "r2") {
        return failure(statuses, "storage_public_access_allowed", checkedAtMs, failureTtlMs);
      }
    } catch {
      return failure(
        { ...statuses, privacyStatus: "failed", credentialStatus: "failed" },
        "storage_credentials_invalid",
        checkedAtMs,
        failureTtlMs,
      );
    }

    try {
      if ((await store.ping()) !== "ok") throw new Error("unavailable");
      statuses = { ...statuses, credentialStatus: "ok" };
    } catch {
      return failure(
        { ...statuses, credentialStatus: "failed" },
        "storage_credentials_invalid",
        checkedAtMs,
        failureTtlMs,
      );
    }

    if (descriptor.provider !== "memory" && !(await store.supportsBoundUpload())) {
      return failure(statuses, "storage_direct_upload_unavailable", checkedAtMs, failureTtlMs);
    }

    const sweep = await sweepStaleCanaries(store, checkedAtMs);
    if (!sweep.ok) {
      return failure(
        { ...statuses, deleteStatus: "failed" },
        sweep.verificationFailed ? "storage_delete_verification_failed" : "storage_delete_failed",
        checkedAtMs,
        failureTtlMs,
      );
    }

    const key = `${PRIVATE_CANARY_PREFIX}${String(checkedAtMs)}/${owner}/${randomUUID()}.canary`;
    const canary = new TextEncoder().encode(`audio-reader-account-sync:${randomUUID()}`);
    let uploadStatus: AccountSyncCheckStatus;
    let downloadStatus: AccountSyncCheckStatus = "not_checked";
    let checksumStatus: AccountSyncCheckStatus = "not_checked";
    let deleteStatus: AccountSyncCheckStatus;
    let notFoundStatus: AccountSyncCheckStatus = "not_checked";
    let anonymousNotFound = false;
    let reason: AccountSyncUnavailableReason | null = metadataPublicAccess
      ? "storage_public_access_allowed"
      : null;

    try {
      await store.put(key, canary);
      uploadStatus = "ok";
    } catch {
      uploadStatus = "failed";
      reason ??= "storage_upload_failed";
    }
    if (uploadStatus === "ok") {
      let anonymousStatus: Awaited<ReturnType<ObjectStore["anonymousRead"]>>;
      try {
        anonymousStatus = await store.anonymousRead(key);
      } catch {
        anonymousStatus = "unknown";
      }
      if (anonymousStatus === "readable") {
        statuses = { ...statuses, privacyStatus: "failed" };
        reason = "storage_public_access_allowed";
      } else if (anonymousStatus === "not_found") {
        // This only proves privacy if the authenticated read and checksum below prove the canary.
        anonymousNotFound = true;
      } else if (anonymousStatus !== "denied") {
        statuses = { ...statuses, privacyStatus: "failed" };
        reason ??= "storage_privacy_verification_failed";
      }
    }
    if (uploadStatus === "ok") {
      try {
        const downloaded = await store.get(key);
        if (downloaded === undefined) {
          downloadStatus = "failed";
          reason ??= "storage_download_failed";
        } else {
          downloadStatus = "ok";
          checksumStatus = (await sha256(downloaded)) === (await sha256(canary)) ? "ok" : "failed";
          if (checksumStatus === "failed") reason ??= "storage_checksum_mismatch";
        }
      } catch {
        downloadStatus = "failed";
        reason ??= "storage_download_failed";
      }
    }
    if (anonymousNotFound && (downloadStatus !== "ok" || checksumStatus !== "ok")) {
      statuses = { ...statuses, privacyStatus: "failed" };
      reason ??= "storage_privacy_verification_failed";
    }

    // Delete after every put attempt: a provider can commit an object before returning an error.
    try {
      await deleteWithRetry(store, key);
      deleteStatus = "ok";
    } catch {
      deleteStatus = "failed";
      reason ??= "storage_delete_failed";
    }
    if (deleteStatus === "ok") {
      try {
        notFoundStatus = (await store.get(key)) === undefined ? "ok" : "failed";
      } catch {
        notFoundStatus = "failed";
      }
      if (notFoundStatus === "failed") reason ??= "storage_delete_verification_failed";
    }
    statuses = {
      ...statuses,
      uploadStatus,
      downloadStatus,
      checksumStatus,
      deleteStatus,
      notFoundStatus,
    };
    if (reason !== null) return failure(statuses, reason, checkedAtMs, failureTtlMs);
    return {
      ...statuses,
      ready: true,
      reason: null,
      checkedAt: new Date(checkedAtMs).toISOString(),
      cachedUntil: new Date(checkedAtMs + successTtlMs).toISOString(),
      retryAfterSeconds: Math.max(1, Math.ceil(successTtlMs / 1_000)),
    };
  }

  function failure(
    statuses: ReturnType<typeof baseFor>,
    reason: AccountSyncUnavailableReason,
    checkedAtMs: number,
    ttlMs: number,
  ): DependencyReadiness {
    return {
      ...statuses,
      ready: false,
      reason,
      checkedAt: new Date(checkedAtMs).toISOString(),
      cachedUntil: new Date(checkedAtMs + ttlMs).toISOString(),
      retryAfterSeconds: Math.max(1, Math.ceil(ttlMs / 1_000)),
    };
  }

  async function dependencies(force: boolean): Promise<DependencyReadiness> {
    for (;;) {
      const targetGeneration = generation;
      if (!force && cached?.generation === targetGeneration && cached.expiresAt > now())
        return cached.value;
      let current = inFlight;
      if (current?.generation !== targetGeneration) {
        current = { generation: targetGeneration, promise: probe() };
        inFlight = current;
      }
      const value = await current.promise;
      if (generation !== targetGeneration) {
        // This caller must observe the current generation, but may reuse its completed probe.
        force = false;
        continue;
      }
      if (inFlight === current) inFlight = undefined;
      cached = { generation: targetGeneration, expiresAt: Date.parse(value.cachedUntil), value };
      if (value.ready) {
        lastSuccessAt = value.checkedAt;
      } else {
        lastFailureAt = value.checkedAt;
        lastFailureCode = value.reason;
        lastFailureDetail = detailFor(value.reason);
      }
      console.warn(
        JSON.stringify({
          level: value.ready ? "info" : "warn",
          component: "account-sync-readiness",
          message: "account_sync_storage_probe",
          requestId: "readiness",
          outcome: value.ready ? "ok" : "failed",
          provider: value.provider,
          reason: value.reason,
          checkedAt: value.checkedAt,
        }),
      );
      return value;
    }
  }

  return {
    async read(requested, options = {}) {
      const value = await dependencies(options.force === true);
      return {
        ...value,
        requested,
        effective: requested && value.ready,
        lastSuccessAt,
        lastFailureAt,
        lastFailureCode,
        lastFailureDetail,
      };
    },
    invalidate() {
      generation += 1;
      cached = undefined;
    },
  };
}

async function sweepStaleCanaries(
  store: ObjectStore,
  now: number,
): Promise<{ ok: boolean; verificationFailed?: boolean }> {
  try {
    const listed = await store.list(PRIVATE_CANARY_PREFIX, STALE_SWEEP_LIMIT);
    const stale = listed.filter((key) => {
      const relative = key.slice(PRIVATE_CANARY_PREFIX.length);
      const timestamp = Number(relative.split("/", 1)[0]);
      return Number.isFinite(timestamp) && timestamp < now - CANARY_STALE_AFTER_MS;
    });
    const overflow = stale.length > STALE_DELETE_LIMIT;
    for (const key of stale.slice(0, STALE_DELETE_LIMIT)) {
      await deleteWithRetry(store, key);
      if ((await store.get(key)) !== undefined) return { ok: false, verificationFailed: true };
    }
    return { ok: !overflow };
  } catch {
    return { ok: false };
  }
}

async function deleteWithRetry(store: ObjectStore, key: string): Promise<void> {
  try {
    await store.delete(key);
  } catch {
    await store.delete(key);
  }
}

function boundedTtl(value: number | undefined, fallback: number): number {
  if (value === undefined || !Number.isFinite(value)) return fallback;
  return Math.min(Math.max(Math.trunc(value), 1_000), 300_000);
}

async function safeSchemaVersion(
  database: Pick<DatabaseClient, "accountSyncSchemaVersion">,
): Promise<string | undefined> {
  try {
    return await database.accountSyncSchemaVersion();
  } catch {
    return undefined;
  }
}

async function safeResolution(
  resolve: () => Promise<AccountSyncStorageResolution>,
): Promise<AccountSyncStorageResolution> {
  try {
    return await resolve();
  } catch {
    return {
      store: createUnavailableObjectStore(),
      descriptor: { provider: "none", configured: false, credentialsConfigured: false },
    };
  }
}

async function sha256(value: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", value);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function detailFor(reason: AccountSyncUnavailableReason | null): string | null {
  switch (reason) {
    case "upgrade_required":
      return "The installed app version cannot use sync v2.";
    case "required_schema_unavailable":
      return "Required sync schema is unavailable.";
    case "storage_not_configured":
      return "Object storage is not configured.";
    case "storage_bucket_missing":
      return "Object storage bucket or container is missing.";
    case "storage_credentials_missing":
      return "Object storage credentials are missing.";
    case "storage_credentials_invalid":
      return "Object storage credentials could not access the configured bucket.";
    case "storage_direct_upload_unavailable":
      return "Object storage cannot bind large uploads to the reserved size and checksum.";
    case "storage_public_access_allowed":
      return "Object storage permits public access.";
    case "storage_privacy_verification_failed":
      return "Private anonymous-access verification was inconclusive.";
    case "storage_upload_failed":
      return "Private canary upload failed.";
    case "storage_download_failed":
      return "Private canary download failed.";
    case "storage_checksum_mismatch":
      return "Private canary checksum did not match.";
    case "storage_delete_failed":
      return "Private canary deletion failed.";
    case "storage_delete_verification_failed":
      return "Deleted private canary remained readable.";
    case null:
      return null;
  }
}
