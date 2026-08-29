import { defaultAssistantPrompt, defaultAssistantUserPrompt } from "./assistant-prompts";
import type { CatalogStore } from "./catalog";
import type { IdentityProfile, IdentityStore } from "./identity";
import {
  DEFAULT_FEATURE_FLAGS,
  DEFAULT_QUOTA_LIMITS,
  endOfUtcDay,
  isQuotaKey,
  utcDay,
  type QuotaKey,
} from "./product-limits";
import { isErrorBody, restOk, restRow, restRows, type RestClient } from "./rest";

/** Operator-visible Postgres write failure. Admin routes map this to 502; never treat it as an in-memory success. */
export class RestPersistenceError extends Error {
  readonly status: number;

  constructor(status: number, detail: string) {
    super(detail);
    this.name = "RestPersistenceError";
    this.status = status;
  }
}

export type AssetKind = "audio" | "ebook" | "cover" | "transcript_export" | "account_export";
export type AssetStatus = "pending" | "ready" | "failed" | "deleting";

export type OpsAsset = {
  id: string;
  uploadId: string;
  accountId: string;
  kind: AssetKind;
  contentType: string;
  sizeBytes: number;
  sha256: string;
  fileName: string;
  status: AssetStatus;
  objectKey: string;
  createdAt: string;
  deletedAt: string | null;
};

export type CacheState = "active" | "quarantined" | "superseded" | "expired" | "purged";

export type OpsCacheEntry = {
  id: string;
  cacheKey: string;
  task: string;
  state: CacheState;
  sourceLanguage: string;
  targetLanguage: string;
  editionFingerprint: string;
  policyVersion: string;
  hitCount: number;
  acceptCount: number;
  rejectCount: number;
  payload: Record<string, unknown>;
  createdAt: string;
  lastHitAt: string | null;
};

export type JobStatus = "queued" | "running" | "succeeded" | "failed" | "cancelled" | "dead_letter";

export type OpsJob = {
  id: string;
  accountId: string | null;
  kind: string;
  status: JobStatus;
  attempts: number;
  maxAttempts: number;
  lastError: string | null;
  payload: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
  startedAt: string | null;
  finishedAt: string | null;
};

export type OpsExport = {
  id: string;
  accountId: string;
  status: "queued" | "running" | "ready" | "failed" | "expired";
  format: string;
  assetId: string | null;
  error: string | null;
  createdAt: string;
  completedAt: string | null;
  expiresAt: string | null;
};

export type OpsPolicy = {
  id: string;
  task: string;
  region: string;
  model: string;
  promptVersion: string;
  systemPrompt: string;
  userPrompt: string;
  schemaVersion: string;
  policyVersion: string;
  enabled: boolean;
  canaryPercent: number;
  maxInputTokens: number | null;
  maxOutputTokens: number | null;
  timeoutMs: number | null;
  createdAt: string;
  updatedAt: string;
};

export type OpsAuditEvent = {
  id: string;
  actorId: string;
  action: string;
  resourceType: string;
  resourceId: string;
  reason: string;
  traceId: string | null;
  metadata: Record<string, unknown>;
  createdAt: string;
};

export type OpsProductEvent = {
  id: string;
  accountId: string;
  deviceId: string | null;
  name: string;
  outcome: "ok" | "failed" | "cancelled" | "started";
  requestId: string | null;
  properties: Record<string, unknown>;
  createdAt: string;
};

export type UsageWindow = {
  userId: string;
  day: string;
  translations: number;
  summaries: number;
  chat: number;
};

export type OpsFeatureFlag = {
  key: string;
  enabled: boolean;
  variant: string | null;
  rolloutPercent: number;
  minAppVersion: string | null;
  platforms: string[];
};

export type OpsQuota = {
  key: string;
  used: number;
  limit: number;
  periodEndsAt: string;
};

export type OpsPrivacyRequest = {
  id: string;
  accountId: string;
  kind: "export" | "deletion";
  status: "queued" | "running" | "ready" | "failed" | "expired" | "cancelled";
  format: string | null;
  assetId: string | null;
  error: string | null;
  reason: string | null;
  createdAt: string;
  updatedAt: string;
  completedAt: string | null;
};

export type AdminUserRecord = {
  id: string;
  accountId: string;
  email: string;
  displayName: string | null;
  status: "active" | "suspended" | "deletion_pending" | "deleted";
  deviceCount: number;
  bookCount: number;
  storageBytes: number;
  createdAt: string;
  lastSeenAt: string | null;
};

export type OperatorSettingsRecord = {
  id: string;
  payload: Record<string, unknown>;
  ciphertext: string | null;
  nonce: string | null;
  updatedAt: string;
  updatedBy: string | null;
};

export type OpsStore = {
  createAsset(
    userId: string,
    input: {
      kind: AssetKind;
      contentType: string;
      sizeBytes: number;
      sha256: string;
      fileName: string;
    },
  ): Promise<OpsAsset>;
  getAsset(userId: string, assetId: string): Promise<OpsAsset | undefined>;
  getAssetByUpload(userId: string, uploadId: string): Promise<OpsAsset | undefined>;
  completeAsset(userId: string, uploadId: string): Promise<OpsAsset | undefined>;
  lookupCache(cacheKey: string): Promise<OpsCacheEntry | undefined>;
  putCache(
    entry: Omit<
      OpsCacheEntry,
      "hitCount" | "acceptCount" | "rejectCount" | "createdAt" | "lastHitAt"
    > & {
      payload: Record<string, unknown>;
    },
  ): Promise<OpsCacheEntry>;
  touchCache(id: string): Promise<OpsCacheEntry | undefined>;
  listCache(filter?: {
    task?: string;
    state?: string;
    editionFingerprint?: string;
  }): Promise<OpsCacheEntry[]>;
  getCache(id: string): Promise<OpsCacheEntry | undefined>;
  actOnCache(
    id: string,
    action: "quarantine" | "activate" | "expire" | "purge",
  ): Promise<OpsCacheEntry | undefined>;
  createJob(input: {
    accountId: string | null;
    kind: string;
    payload?: Record<string, unknown>;
  }): Promise<OpsJob>;
  getJob(id: string): Promise<OpsJob | undefined>;
  listJobs(filter?: { status?: string }): Promise<OpsJob[]>;
  updateJob(
    id: string,
    patch: Partial<
      Pick<OpsJob, "status" | "attempts" | "lastError" | "startedAt" | "finishedAt" | "payload">
    >,
  ): Promise<OpsJob | undefined>;
  listPolicies(): Promise<OpsPolicy[]>;
  getPolicy(id: string): Promise<OpsPolicy | undefined>;
  patchPolicy(
    id: string,
    patch: Partial<Omit<OpsPolicy, "id" | "createdAt">>,
  ): Promise<OpsPolicy | undefined>;
  appendAudit(event: Omit<OpsAuditEvent, "id" | "createdAt">): Promise<OpsAuditEvent>;
  listAudit(filter?: {
    actorId?: string;
    action?: string;
    requestId?: string;
    resourceType?: string;
  }): Promise<OpsAuditEvent[]>;
  recordProductEvent(
    event: Omit<OpsProductEvent, "id" | "createdAt"> & { createdAt?: string },
  ): Promise<OpsProductEvent>;
  listProductEvents(filter?: {
    accountId?: string;
    name?: string;
    requestId?: string;
    from?: string;
    to?: string;
    limit?: number;
  }): Promise<OpsProductEvent[]>;
  createExport(userId: string, format: string): Promise<OpsExport>;
  getExport(userId: string, id: string): Promise<OpsExport | undefined>;
  completeExport(userId: string, id: string, assetId: string): Promise<OpsExport | undefined>;
  consumeQuota(
    userId: string,
    kind: "translations" | "summaries" | "chat",
    limit: number,
  ): Promise<boolean>;
  listFlags(): Promise<OpsFeatureFlag[]>;
  patchFlag(
    key: string,
    patch: Partial<Omit<OpsFeatureFlag, "key">>,
  ): Promise<OpsFeatureFlag | undefined>;
  quotasFor(userId: string): Promise<OpsQuota[]>;
  patchQuota(key: string, limit: number): Promise<OpsQuota | undefined>;
  createPrivacyRequest(input: {
    accountId: string;
    kind: "export" | "deletion";
    status?: OpsPrivacyRequest["status"];
    format?: string | null;
    assetId?: string | null;
    reason?: string | null;
  }): Promise<OpsPrivacyRequest>;
  listPrivacyRequests(filter?: { status?: string }): Promise<OpsPrivacyRequest[]>;
  getPrivacyRequest(id: string): Promise<OpsPrivacyRequest | undefined>;
  patchPrivacyRequest(
    id: string,
    patch: Partial<Omit<OpsPrivacyRequest, "id" | "accountId" | "kind" | "createdAt">>,
  ): Promise<OpsPrivacyRequest | undefined>;
  adminUsers(): Promise<AdminUserRecord[]>;
  recordAssistantUse(
    userId: string,
    input: { task: string; cacheEntryId: string | null; outputText: string },
  ): Promise<void>;
  putChatMessage(message: {
    accountId: string;
    threadId: string;
    messageId: string;
    role: "user" | "assistant";
    text: string;
    createdAt: string;
  }): Promise<void>;
  getChatMessage(
    threadId: string,
    messageId: string,
  ): Promise<
    | {
        accountId: string;
        threadId: string;
        messageId: string;
        role: "user" | "assistant";
        text: string;
        createdAt: string;
      }
    | undefined
  >;
  getOperatorSettings(): Promise<OperatorSettingsRecord | undefined>;
  putOperatorSettings(
    input: Omit<OperatorSettingsRecord, "updatedAt">,
  ): Promise<OperatorSettingsRecord>;
};

export function createMemoryOpsStore(
  options: {
    identity?: IdentityStore;
    catalog?: CatalogStore;
  } = {},
): OpsStore {
  const assets = new Map<string, OpsAsset>();
  const cache = new Map<string, OpsCacheEntry>();
  const jobs = new Map<string, OpsJob>();
  const policies = new Map<string, OpsPolicy>();
  const audit: OpsAuditEvent[] = [];
  const productEvents: OpsProductEvent[] = [];
  const exports = new Map<string, OpsExport>();
  const usage = new Map<string, UsageWindow>();
  const flags = new Map<string, OpsFeatureFlag>();
  const quotaLimits = new Map<QuotaKey, number>();
  const privacyRequests = new Map<string, OpsPrivacyRequest>();
  const chatMessages = new Map<
    string,
    {
      accountId: string;
      threadId: string;
      messageId: string;
      role: "user" | "assistant";
      text: string;
      createdAt: string;
    }
  >();
  const now = () => new Date().toISOString();
  seedDefaultPolicies(policies, now());
  seedDefaultFlags(flags);
  seedDefaultQuotaLimits(quotaLimits);
  let operatorSettings: OperatorSettingsRecord | undefined;

  return {
    createAsset(userId, input) {
      const id = crypto.randomUUID();
      const uploadId = crypto.randomUUID();
      const created: OpsAsset = {
        id,
        uploadId,
        accountId: userId,
        kind: input.kind,
        contentType: input.contentType,
        sizeBytes: input.sizeBytes,
        sha256: input.sha256,
        fileName: input.fileName,
        status: "pending",
        objectKey: `${userId}/${id}`,
        createdAt: now(),
        deletedAt: null,
      };
      assets.set(`${userId}:${id}`, created);
      assets.set(`upload:${userId}:${uploadId}`, created);
      return Promise.resolve({ ...created });
    },

    getAsset(userId, assetId) {
      const asset = assets.get(`${userId}:${assetId}`);
      return Promise.resolve(asset === undefined ? undefined : { ...asset });
    },

    getAssetByUpload(userId, uploadId) {
      const asset = assets.get(`upload:${userId}:${uploadId}`);
      return Promise.resolve(asset === undefined ? undefined : { ...asset });
    },

    completeAsset(userId, uploadId) {
      const asset = assets.get(`upload:${userId}:${uploadId}`);
      if (asset === undefined) {
        return Promise.resolve(undefined);
      }
      asset.status = "ready";
      return Promise.resolve({ ...asset });
    },

    lookupCache(cacheKey) {
      const entry = [...cache.values()].find(
        (item) => item.cacheKey === cacheKey && item.state === "active",
      );
      return Promise.resolve(
        entry === undefined ? undefined : { ...entry, payload: { ...entry.payload } },
      );
    },

    putCache(input) {
      const existing = [...cache.values()].find(
        (item) => item.cacheKey === input.cacheKey && item.state === "active",
      );
      if (existing !== undefined) {
        return Promise.resolve({ ...existing, payload: { ...existing.payload } });
      }
      const created: OpsCacheEntry = {
        id: input.id,
        cacheKey: input.cacheKey,
        task: input.task,
        state: input.state,
        sourceLanguage: input.sourceLanguage,
        targetLanguage: input.targetLanguage,
        editionFingerprint: input.editionFingerprint,
        policyVersion: input.policyVersion,
        hitCount: 0,
        acceptCount: 0,
        rejectCount: 0,
        payload: { ...input.payload },
        createdAt: now(),
        lastHitAt: null,
      };
      cache.set(created.id, created);
      return Promise.resolve({ ...created, payload: { ...created.payload } });
    },

    touchCache(id) {
      const entry = cache.get(id);
      if (entry === undefined) {
        return Promise.resolve(undefined);
      }
      entry.hitCount += 1;
      entry.lastHitAt = now();
      return Promise.resolve({ ...entry, payload: { ...entry.payload } });
    },

    listCache(filter) {
      const items = [...cache.values()].filter((item) => {
        if (filter?.task !== undefined && item.task !== filter.task) {
          return false;
        }
        if (filter?.state !== undefined && item.state !== filter.state) {
          return false;
        }
        if (
          filter?.editionFingerprint !== undefined &&
          item.editionFingerprint !== filter.editionFingerprint
        ) {
          return false;
        }
        return true;
      });
      return Promise.resolve(items.map((item) => ({ ...item, payload: { ...item.payload } })));
    },

    getCache(id) {
      const entry = cache.get(id);
      return Promise.resolve(
        entry === undefined ? undefined : { ...entry, payload: { ...entry.payload } },
      );
    },

    actOnCache(id, action) {
      const entry = cache.get(id);
      if (entry === undefined) {
        return Promise.resolve(undefined);
      }
      if (action === "quarantine") {
        entry.state = "quarantined";
      } else if (action === "activate") {
        entry.state = "active";
      } else if (action === "expire") {
        entry.state = "expired";
      } else {
        entry.state = "purged";
      }
      return Promise.resolve({ ...entry, payload: { ...entry.payload } });
    },

    createJob(input) {
      const created: OpsJob = {
        id: crypto.randomUUID(),
        accountId: input.accountId,
        kind: input.kind,
        status: "queued",
        attempts: 0,
        maxAttempts: 5,
        lastError: null,
        payload: { ...(input.payload ?? {}) },
        createdAt: now(),
        updatedAt: now(),
        startedAt: null,
        finishedAt: null,
      };
      jobs.set(created.id, created);
      return Promise.resolve({ ...created, payload: { ...created.payload } });
    },

    getJob(id) {
      const job = jobs.get(id);
      return Promise.resolve(
        job === undefined ? undefined : { ...job, payload: { ...job.payload } },
      );
    },

    listJobs(filter) {
      const items = [...jobs.values()].filter(
        (job) => filter?.status === undefined || job.status === filter.status,
      );
      return Promise.resolve(items.map((job) => ({ ...job, payload: { ...job.payload } })));
    },

    updateJob(id, patch) {
      const job = jobs.get(id);
      if (job === undefined) {
        return Promise.resolve(undefined);
      }
      Object.assign(job, patch);
      job.updatedAt = now();
      return Promise.resolve({ ...job, payload: { ...job.payload } });
    },

    listPolicies() {
      return Promise.resolve([...policies.values()].map((policy) => ({ ...policy })));
    },

    getPolicy(id) {
      const policy = policies.get(id);
      return Promise.resolve(policy === undefined ? undefined : { ...policy });
    },

    patchPolicy(id, patch) {
      const policy = policies.get(id);
      if (policy === undefined) {
        return Promise.resolve(undefined);
      }
      Object.assign(policy, patch);
      policy.updatedAt = now();
      return Promise.resolve({ ...policy });
    },

    appendAudit(event) {
      const created: OpsAuditEvent = {
        ...event,
        id: crypto.randomUUID(),
        createdAt: now(),
      };
      audit.push(created);
      return Promise.resolve({ ...created, metadata: { ...created.metadata } });
    },

    listAudit(filter) {
      const actorId = filter?.actorId?.trim() ?? "";
      const action = filter?.action?.trim() ?? "";
      const requestId = filter?.requestId?.trim() ?? "";
      const resourceType = filter?.resourceType?.trim() ?? "";
      return Promise.resolve(
        [...audit]
          .reverse()
          .filter((event) => (actorId === "" ? true : event.actorId === actorId))
          .filter((event) => (action === "" ? true : event.action === action))
          .filter((event) => (requestId === "" ? true : event.traceId === requestId))
          .filter((event) => (resourceType === "" ? true : event.resourceType === resourceType))
          .map((event) => ({ ...event, metadata: { ...event.metadata } })),
      );
    },

    recordProductEvent(event) {
      const created: OpsProductEvent = {
        id: crypto.randomUUID(),
        accountId: event.accountId,
        deviceId: event.deviceId,
        name: event.name,
        outcome: event.outcome,
        requestId: event.requestId,
        properties: { ...event.properties },
        createdAt: event.createdAt ?? now(),
      };
      productEvents.unshift(created);
      if (productEvents.length > 5000) {
        productEvents.length = 5000;
      }
      return Promise.resolve({ ...created, properties: { ...created.properties } });
    },

    listProductEvents(filter) {
      const accountId = filter?.accountId?.trim() ?? "";
      const name = filter?.name?.trim() ?? "";
      const requestId = filter?.requestId?.trim() ?? "";
      const from = filter?.from?.trim() ?? "";
      const to = filter?.to?.trim() ?? "";
      const limit = Math.min(Math.max(filter?.limit ?? 100, 1), 500);
      return Promise.resolve(
        productEvents
          .filter((event) => (accountId === "" ? true : event.accountId === accountId))
          .filter((event) => (name === "" ? true : productEventNameMatches(event.name, name)))
          .filter((event) => (requestId === "" ? true : event.requestId === requestId))
          .filter((event) => (from === "" ? true : event.createdAt >= from))
          .filter((event) => (to === "" ? true : event.createdAt <= to))
          .slice(0, limit)
          .map((event) => ({ ...event, properties: { ...event.properties } })),
      );
    },

    createExport(userId, format) {
      const created: OpsExport = {
        id: crypto.randomUUID(),
        accountId: userId,
        status: "queued",
        format,
        assetId: null,
        error: null,
        createdAt: now(),
        completedAt: null,
        expiresAt: null,
      };
      exports.set(`${userId}:${created.id}`, created);
      return Promise.resolve({ ...created });
    },

    getExport(userId, id) {
      const item = exports.get(`${userId}:${id}`);
      return Promise.resolve(item === undefined ? undefined : { ...item });
    },

    completeExport(userId, id, assetId) {
      const item = exports.get(`${userId}:${id}`);
      if (item === undefined) {
        return Promise.resolve(undefined);
      }
      item.status = "ready";
      item.assetId = assetId;
      item.completedAt = now();
      item.expiresAt = new Date(Date.now() + 7 * 86_400_000).toISOString();
      return Promise.resolve({ ...item });
    },

    consumeQuota(userId, kind, limit) {
      const day = utcDay();
      const key = `${userId}:${day}`;
      const window = usage.get(key) ?? {
        userId,
        day,
        translations: 0,
        summaries: 0,
        chat: 0,
      };
      const used = window.translations + window.summaries + window.chat;
      if (used >= limit) {
        return Promise.resolve(false);
      }
      window[kind] += 1;
      usage.set(key, window);
      return Promise.resolve(true);
    },

    listFlags() {
      return Promise.resolve(
        [...flags.values()].map(cloneFlag).sort((left, right) => left.key.localeCompare(right.key)),
      );
    },

    patchFlag(key, patch) {
      const existing = flags.get(key);
      if (existing === undefined) {
        return Promise.resolve(undefined);
      }
      const next: OpsFeatureFlag = {
        ...existing,
        ...patch,
        key,
        platforms: patch.platforms === undefined ? existing.platforms : [...patch.platforms],
      };
      flags.set(key, next);
      return Promise.resolve(cloneFlag(next));
    },

    async quotasFor(userId) {
      return buildQuotas(userId, quotaLimits, usage, options, assets);
    },

    async patchQuota(key, limit) {
      if (!isQuotaKey(key) || limit < 0) {
        return Promise.resolve(undefined);
      }
      quotaLimits.set(key, limit);
      const [updated] = (await buildQuotas("", quotaLimits, usage, options, assets)).filter(
        (item) => item.key === key,
      );
      return updated;
    },

    createPrivacyRequest(input) {
      const timestamp = now();
      const created: OpsPrivacyRequest = {
        id: crypto.randomUUID(),
        accountId: input.accountId,
        kind: input.kind,
        status: input.status ?? "queued",
        format: input.format ?? null,
        assetId: input.assetId ?? null,
        error: null,
        reason: input.reason ?? null,
        createdAt: timestamp,
        updatedAt: timestamp,
        completedAt: input.status === "ready" ? timestamp : null,
      };
      privacyRequests.set(created.id, created);
      return Promise.resolve({ ...created });
    },

    listPrivacyRequests(filter) {
      const items = [...privacyRequests.values()].filter((item) =>
        filter?.status === undefined || filter.status === "" ? true : item.status === filter.status,
      );
      items.sort((left, right) => right.createdAt.localeCompare(left.createdAt));
      return Promise.resolve(items.map((item) => ({ ...item })));
    },

    getPrivacyRequest(id) {
      const item = privacyRequests.get(id);
      return Promise.resolve(item === undefined ? undefined : { ...item });
    },

    patchPrivacyRequest(id, patch) {
      const item = privacyRequests.get(id);
      if (item === undefined) {
        return Promise.resolve(undefined);
      }
      const next: OpsPrivacyRequest = {
        ...item,
        ...patch,
        id: item.id,
        accountId: item.accountId,
        kind: item.kind,
        createdAt: item.createdAt,
        updatedAt: now(),
      };
      privacyRequests.set(id, next);
      return Promise.resolve({ ...next });
    },

    async adminUsers() {
      const identity = options.identity;
      if (identity === undefined) {
        return [];
      }
      const profiles = await identity.listProfiles();
      const rows: AdminUserRecord[] = [];
      for (const profile of profiles) {
        const devices = await identity.listDevices(profile.accountId);
        const books =
          options.catalog === undefined ? [] : await options.catalog.listBooks(profile.accountId);
        const lastSeen = devices
          .map((device) => device.lastSeenAt)
          .sort()
          .at(-1);
        rows.push({
          id: profile.id,
          accountId: profile.accountId,
          email: profile.email,
          displayName: profile.displayName,
          status: profile.status,
          deviceCount: devices.length,
          bookCount: books.length,
          storageBytes: 0,
          createdAt: profile.createdAt,
          lastSeenAt: lastSeen ?? null,
        });
      }
      return rows;
    },

    recordAssistantUse() {
      return Promise.resolve();
    },

    // Isolate-local until a chat table exists. Always store accountId so GET
    // cannot return another user's message from this Worker isolate.
    putChatMessage(message) {
      chatMessages.set(`${message.threadId}:${message.messageId}`, { ...message });
      return Promise.resolve();
    },

    getChatMessage(threadId, messageId) {
      const item = chatMessages.get(`${threadId}:${messageId}`);
      return Promise.resolve(item === undefined ? undefined : { ...item });
    },

    getOperatorSettings() {
      return Promise.resolve(
        operatorSettings === undefined
          ? undefined
          : {
              ...operatorSettings,
              payload: { ...operatorSettings.payload },
            },
      );
    },

    putOperatorSettings(input) {
      operatorSettings = {
        ...input,
        payload: { ...input.payload },
        updatedAt: now(),
      };
      return Promise.resolve({
        ...operatorSettings,
        payload: { ...operatorSettings.payload },
      });
    },
  };
}

export function createUnavailableOpsStore(): OpsStore {
  const fail = () => Promise.reject(new Error("database unavailable"));
  return {
    createAsset: fail,
    getAsset: () => Promise.resolve(undefined),
    getAssetByUpload: () => Promise.resolve(undefined),
    completeAsset: () => Promise.resolve(undefined),
    lookupCache: () => Promise.resolve(undefined),
    putCache: fail,
    touchCache: () => Promise.resolve(undefined),
    listCache: () => Promise.resolve([]),
    getCache: () => Promise.resolve(undefined),
    actOnCache: () => Promise.resolve(undefined),
    createJob: fail,
    getJob: () => Promise.resolve(undefined),
    listJobs: () => Promise.resolve([]),
    updateJob: () => Promise.resolve(undefined),
    listPolicies: () => Promise.resolve([]),
    getPolicy: () => Promise.resolve(undefined),
    patchPolicy: () => Promise.resolve(undefined),
    appendAudit: fail,
    listAudit: () => Promise.resolve([]),
    recordProductEvent: fail,
    listProductEvents: () => Promise.resolve([]),
    createExport: fail,
    getExport: () => Promise.resolve(undefined),
    completeExport: () => Promise.resolve(undefined),
    consumeQuota: () => Promise.resolve(true),
    listFlags: () => Promise.resolve([]),
    patchFlag: () => Promise.resolve(undefined),
    quotasFor: () => Promise.resolve([]),
    patchQuota: () => Promise.resolve(undefined),
    createPrivacyRequest: fail,
    listPrivacyRequests: () => Promise.resolve([]),
    getPrivacyRequest: () => Promise.resolve(undefined),
    patchPrivacyRequest: () => Promise.resolve(undefined),
    adminUsers: () => Promise.resolve([]),
    recordAssistantUse: () => Promise.resolve(),
    putChatMessage: () => Promise.resolve(),
    getChatMessage: () => Promise.resolve(undefined),
    getOperatorSettings: () => Promise.resolve(undefined),
    putOperatorSettings: fail,
  };
}

/**
 * Postgres (PostgREST) is the source of truth whenever this store is constructed.
 * The in-memory map is only for methods not yet wired to REST, and for local tests.
 * Policy, flag, quota, operator-settings, and audit writes must not fall back to memory
 * after REST has already responded — that is what made admin saves look successful
 * and then revert on reload.
 */
export function createSupabaseOpsStore(
  rest: RestClient,
  options: { identity?: IdentityStore; catalog?: CatalogStore } = {},
): OpsStore {
  const memory = createMemoryOpsStore(options);
  return {
    ...memory,
    async lookupCache(cacheKey) {
      return fetchCacheByKey(rest, cacheKey);
    },
    async putCache(input) {
      return persistCacheEntry(rest, input);
    },
    async getCache(id) {
      return fetchCacheById(rest, id);
    },
    async listCache(filter) {
      const query: Record<string, string> = {
        select: "*",
        order: "created_at.desc",
        limit: "500",
      };
      if ((filter?.task?.trim() ?? "") !== "") {
        query.task_type = `eq.${filter?.task?.trim() ?? ""}`;
      }
      if ((filter?.state?.trim() ?? "") !== "") {
        query.state = `eq.${filter?.state?.trim() ?? ""}`;
      }
      if ((filter?.editionFingerprint?.trim() ?? "") !== "") {
        query.edition_fingerprint = `eq.${filter?.editionFingerprint?.trim() ?? ""}`;
      }
      const response = await rest.request({
        method: "GET",
        path: "/assistant_cache_entries",
        query,
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        logPersistence("cache_list_failed", { status: response.status });
        return [];
      }
      return restRows(response.body)
        .map(mapCacheRow)
        .filter((row): row is OpsCacheEntry => row !== undefined);
    },
    async touchCache(id) {
      const current = await fetchCacheById(rest, id);
      const hits = (current?.hitCount ?? 0) + 1;
      const response = await rest.request({
        method: "PATCH",
        path: "/assistant_cache_entries",
        query: { id: `eq.${id}` },
        prefer: "return=representation",
        body: {
          hit_count: hits,
          last_hit_at: new Date().toISOString(),
        },
      });
      const mapped = mappedWriteRow(response, mapCacheRow);
      if (mapped !== undefined) {
        return mapped;
      }
      logPersistence("cache_touch_failed", { id, status: response.status });
      return current === undefined
        ? undefined
        : { ...current, hitCount: hits, lastHitAt: new Date().toISOString() };
    },
    async actOnCache(id, action) {
      const state =
        action === "quarantine"
          ? "quarantined"
          : action === "activate"
            ? "active"
            : action === "expire"
              ? "expired"
              : "purged";
      const response = await rest.request({
        method: "PATCH",
        path: "/assistant_cache_entries",
        query: { id: `eq.${id}` },
        prefer: "return=representation",
        body: {
          state,
          updated_at: new Date().toISOString(),
        },
      });
      const mapped = mappedWriteRow(response, mapCacheRow);
      if (mapped !== undefined) {
        logPersistence("cache_act_ok", { id, action, state });
        return mapped;
      }
      const replay = await fetchCacheById(rest, id);
      if (replay !== undefined && replay.state === state) {
        return replay;
      }
      logPersistence("cache_act_failed", { id, action, status: response.status });
      throw new RestPersistenceError(
        response.status === 0 ? 502 : 502,
        restErrorDetail(response.body) ?? "Postgres did not update the cache entry.",
      );
    },
    async recordAssistantUse(userId, input) {
      await rest.request({
        method: "POST",
        path: "/user_assistant_results",
        body: {
          user_id: userId,
          task_type: input.task,
          status: "pending",
          cache_entry_id: input.cacheEntryId,
          output_text: input.outputText.slice(0, 20000),
        },
      });
    },
    async adminUsers() {
      const response = await rest.request({
        method: "GET",
        path: "/profiles",
        query: { select: "*", order: "created_at.desc" },
      });
      if (response.status >= 400 || response.status === 0) {
        return memory.adminUsers();
      }
      const rows: AdminUserRecord[] = [];
      for (const row of restRows(response.body)) {
        const accountId = typeof row.user_id === "string" ? row.user_id : "";
        const devices =
          options.identity === undefined ? [] : await options.identity.listDevices(accountId);
        const books =
          options.catalog === undefined ? [] : await options.catalog.listBooks(accountId);
        const status = row.account_status;
        rows.push({
          id: typeof row.id === "string" ? row.id : accountId,
          accountId,
          email: typeof row.email === "string" ? row.email : "",
          displayName: typeof row.display_name === "string" ? row.display_name : null,
          status:
            status === "suspended" || status === "deletion_pending" || status === "deleted"
              ? status
              : "active",
          deviceCount: devices.length,
          bookCount: books.length,
          storageBytes: 0,
          createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
          lastSeenAt:
            devices
              .map((device) => device.lastSeenAt)
              .sort()
              .at(-1) ?? null,
        });
      }
      return rows;
    },
    async listPolicies() {
      const response = await rest.request({
        method: "GET",
        path: "/model_policies",
        query: { select: "*", order: "updated_at.desc" },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        logPersistence("model_policies_list_unavailable", { status: response.status });
        return [];
      }
      return restRows(response.body)
        .map(mapPolicyRow)
        .filter((row): row is OpsPolicy => row !== undefined);
    },
    async getPolicy(id) {
      const response = await rest.request({
        method: "GET",
        path: "/model_policies",
        query: { select: "*", id: `eq.${id}`, limit: "1" },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        logPersistence("model_policy_get_unavailable", { id, status: response.status });
        return undefined;
      }
      return mapPolicyRow(restRow(response.body));
    },
    async patchPolicy(id, patch) {
      return patchModelPolicy(rest, id, patch);
    },
    async listFlags() {
      const response = await rest.request({
        method: "GET",
        path: "/feature_flags",
        query: { select: "*", order: "key.asc" },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        logPersistence("feature_flags_list_unavailable", { status: response.status });
        return [];
      }
      return restRows(response.body)
        .map(mapFlagRow)
        .filter((row): row is OpsFeatureFlag => row !== undefined);
    },
    async patchFlag(key, patch) {
      return patchFeatureFlag(rest, key, patch);
    },
    async quotasFor(userId) {
      const response = await rest.request({
        method: "GET",
        path: "/quota_limits",
        query: { select: "*" },
      });
      if (response.status >= 400 || response.status === 0) {
        return memory.quotasFor(userId);
      }
      const rows = restRows(response.body);
      if (rows.length === 0) {
        return memory.quotasFor(userId);
      }
      for (const row of rows) {
        if (typeof row.key === "string" && isQuotaKey(row.key)) {
          const limit = finiteNumber(row.limit_value);
          if (limit !== undefined) {
            await memory.patchQuota(row.key, limit);
          }
        }
      }
      return memory.quotasFor(userId);
    },
    async patchQuota(key, limit) {
      if (!isQuotaKey(key) || limit < 0) {
        return undefined;
      }
      return persistQuotaLimit(rest, memory, key, limit);
    },
    async createPrivacyRequest(input) {
      const created = await memory.createPrivacyRequest(input);
      await rest.request({
        method: "POST",
        path: "/privacy_requests",
        prefer: "return=representation",
        body: {
          id: created.id,
          user_id: created.accountId,
          kind: created.kind,
          status: created.status,
          format: created.format,
          asset_id: created.assetId,
          reason: created.reason,
        },
      });
      return created;
    },
    async listPrivacyRequests(filter) {
      const query: Record<string, string> = { select: "*", order: "created_at.desc" };
      if (filter?.status !== undefined && filter.status !== "") {
        query.status = `eq.${filter.status}`;
      }
      const response = await rest.request({
        method: "GET",
        path: "/privacy_requests",
        query,
      });
      if (response.status >= 400 || response.status === 0) {
        return memory.listPrivacyRequests(filter);
      }
      const rows = restRows(response.body)
        .map(mapPrivacyRow)
        .filter((row): row is OpsPrivacyRequest => row !== undefined);
      return rows.length === 0 ? memory.listPrivacyRequests(filter) : rows;
    },
    async getPrivacyRequest(id) {
      const response = await rest.request({
        method: "GET",
        path: "/privacy_requests",
        query: { select: "*", id: `eq.${id}`, limit: "1" },
      });
      return mapPrivacyRow(restRow(response.body)) ?? memory.getPrivacyRequest(id);
    },
    async patchPrivacyRequest(id, patch) {
      const body: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (patch.status !== undefined) {
        body.status = patch.status;
      }
      if (patch.format !== undefined) {
        body.format = patch.format;
      }
      if (patch.assetId !== undefined) {
        body.asset_id = patch.assetId;
      }
      if (patch.error !== undefined) {
        body.error = patch.error;
      }
      if (patch.reason !== undefined) {
        body.reason = patch.reason;
      }
      if (patch.completedAt !== undefined) {
        body.completed_at = patch.completedAt;
      }
      const response = await rest.request({
        method: "PATCH",
        path: "/privacy_requests",
        query: { id: `eq.${id}` },
        prefer: "return=representation",
        body,
      });
      return mapPrivacyRow(restRow(response.body)) ?? memory.patchPrivacyRequest(id, patch);
    },
    async getOperatorSettings() {
      const response = await rest.request({
        method: "GET",
        path: "/operator_settings",
        query: { select: "*", id: "eq.default", limit: "1" },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        return memory.getOperatorSettings();
      }
      return mapOperatorSettingsRow(restRow(response.body)) ?? memory.getOperatorSettings();
    },
    async putOperatorSettings(input) {
      return persistOperatorSettings(rest, input);
    },
    async listAudit(filter) {
      const query: Record<string, string> = {
        select: "*",
        order: "created_at.desc",
        limit: "100",
      };
      if ((filter?.actorId?.trim() ?? "") !== "") {
        query.actor_id = `eq.${filter?.actorId?.trim() ?? ""}`;
      }
      if ((filter?.action?.trim() ?? "") !== "") {
        query.action = `eq.${filter?.action?.trim() ?? ""}`;
      }
      if ((filter?.requestId?.trim() ?? "") !== "") {
        query.request_id = `eq.${filter?.requestId?.trim() ?? ""}`;
      }
      if ((filter?.resourceType?.trim() ?? "") !== "") {
        query.resource_type = `eq.${filter?.resourceType?.trim() ?? ""}`;
      }
      const response = await rest.request({
        method: "GET",
        path: "/audit_events",
        query,
      });
      if (response.status >= 400 || response.status === 0) {
        return memory.listAudit(filter);
      }
      const rows = restRows(response.body)
        .map(mapAuditRow)
        .filter((row): row is OpsAuditEvent => row !== undefined);
      return rows;
    },
    async appendAudit(event) {
      return persistAuditEvent(rest, event);
    },
    async recordProductEvent(event) {
      return persistProductEvent(rest, event);
    },
    async listProductEvents(filter) {
      const query: Record<string, string> = {
        select: "*",
        order: "created_at.desc",
        limit: String(Math.min(Math.max(filter?.limit ?? 100, 1), 500)),
      };
      if ((filter?.accountId?.trim() ?? "") !== "") {
        query.user_id = `eq.${filter?.accountId?.trim() ?? ""}`;
      }
      if ((filter?.name?.trim() ?? "") !== "") {
        query.name = productEventNameQuery(filter?.name?.trim() ?? "");
      }
      if ((filter?.requestId?.trim() ?? "") !== "") {
        query.request_id = `eq.${filter?.requestId?.trim() ?? ""}`;
      }
      if ((filter?.from?.trim() ?? "") !== "") {
        query.created_at = `gte.${filter?.from?.trim() ?? ""}`;
      }
      if ((filter?.to?.trim() ?? "") !== "") {
        query.created_at = `${query.created_at === undefined ? "" : `${query.created_at},`}lte.${filter?.to?.trim() ?? ""}`;
      }
      const response = await rest.request({
        method: "GET",
        path: "/product_events",
        query,
      });
      if (response.status >= 400 || response.status === 0) {
        return memory.listProductEvents(filter);
      }
      return restRows(response.body)
        .map(mapProductEventRow)
        .filter((row): row is OpsProductEvent => row !== undefined);
    },
    async putChatMessage(message) {
      const response = await rest.request({
        method: "POST",
        path: "/chat_messages",
        prefer: "return=representation,resolution=merge-duplicates",
        query: { on_conflict: "thread_id,message_id" },
        body: {
          thread_id: message.threadId,
          message_id: message.messageId,
          user_id: message.accountId,
          role: message.role,
          text: message.text,
          created_at: message.createdAt,
        },
      });
      if (
        !restOk(response) ||
        isErrorBody(response.body) ||
        mapChatRow(restRow(response.body)) === undefined
      ) {
        throw new RestPersistenceError(
          response.status === 0 ? 502 : response.status,
          "Postgres did not store the chat message.",
        );
      }
    },
    async getChatMessage(threadId, messageId) {
      const response = await rest.request({
        method: "GET",
        path: "/chat_messages",
        query: {
          select: "*",
          thread_id: `eq.${threadId}`,
          message_id: `eq.${messageId}`,
          limit: "1",
        },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        return undefined;
      }
      return mapChatRow(restRow(response.body));
    },
  };
}

function mapChatRow(row: Record<string, unknown> | undefined):
  | {
      accountId: string;
      threadId: string;
      messageId: string;
      role: "user" | "assistant";
      text: string;
      createdAt: string;
    }
  | undefined {
  if (
    row === undefined ||
    isErrorBody(row) ||
    typeof row.user_id !== "string" ||
    typeof row.thread_id !== "string" ||
    typeof row.message_id !== "string" ||
    typeof row.text !== "string"
  ) {
    return undefined;
  }
  const role = row.role === "user" || row.role === "assistant" ? row.role : undefined;
  if (role === undefined) {
    return undefined;
  }
  return {
    accountId: row.user_id,
    threadId: row.thread_id,
    messageId: row.message_id,
    role,
    text: row.text,
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
  };
}

/** PostgREST may return bigint counters as numbers or decimal strings. */
function asNonNegativeInt(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
    return Math.trunc(value);
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed) && parsed >= 0) {
      return Math.trunc(parsed);
    }
  }
  return 0;
}

function mapCacheRow(row: Record<string, unknown> | undefined): OpsCacheEntry | undefined {
  if (
    row === undefined ||
    isErrorBody(row) ||
    typeof row.cache_key !== "string" ||
    row.cache_key === ""
  ) {
    return undefined;
  }
  const payload =
    typeof row.result === "object" && row.result !== null && !Array.isArray(row.result)
      ? (row.result as Record<string, unknown>)
      : {};
  const state = row.state;
  return {
    id: typeof row.id === "string" ? row.id : crypto.randomUUID(),
    cacheKey: typeof row.cache_key === "string" ? row.cache_key : "",
    task: typeof row.task_type === "string" ? row.task_type : "",
    state:
      state === "quarantined" || state === "superseded" || state === "expired" || state === "purged"
        ? state
        : "active",
    sourceLanguage: typeof row.source_language === "string" ? row.source_language : "",
    targetLanguage: typeof row.target_language === "string" ? row.target_language : "",
    editionFingerprint: typeof row.edition_fingerprint === "string" ? row.edition_fingerprint : "",
    policyVersion: typeof row.policy_version === "string" ? row.policy_version : "qwen-managed-v1",
    hitCount: asNonNegativeInt(row.hit_count),
    acceptCount: asNonNegativeInt(row.accept_count),
    rejectCount: asNonNegativeInt(row.reject_count),
    payload,
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
    lastHitAt: typeof row.last_hit_at === "string" ? row.last_hit_at : null,
  };
}

function seedDefaultFlags(flags: Map<string, OpsFeatureFlag>): void {
  for (const flag of DEFAULT_FEATURE_FLAGS) {
    flags.set(flag.key, { ...flag, platforms: [...flag.platforms] });
  }
}

function seedDefaultQuotaLimits(limits: Map<QuotaKey, number>): void {
  for (const quota of DEFAULT_QUOTA_LIMITS) {
    limits.set(quota.key, quota.limit);
  }
}

function cloneFlag(flag: OpsFeatureFlag): OpsFeatureFlag {
  return { ...flag, platforms: [...flag.platforms] };
}

async function buildQuotas(
  userId: string,
  quotaLimits: Map<QuotaKey, number>,
  usage: Map<string, UsageWindow>,
  options: { identity?: IdentityStore; catalog?: CatalogStore },
  assets: Map<string, OpsAsset>,
): Promise<OpsQuota[]> {
  const periodEndsAt = endOfUtcDay();
  const window = usage.get(`${userId}:${utcDay()}`);
  const qwenUsed = window === undefined ? 0 : window.translations + window.summaries + window.chat;
  const devices =
    userId === "" || options.identity === undefined
      ? []
      : (await options.identity.listDevices(userId)).filter((device) => !device.revoked);
  const books =
    userId === "" || options.catalog === undefined ? [] : await options.catalog.listBooks(userId);
  let storageBytes = 0;
  if (userId !== "") {
    for (const [key, asset] of assets) {
      if (key.startsWith(`${userId}:`) && !key.startsWith("upload:")) {
        storageBytes += asset.sizeBytes;
      }
    }
  }
  const rows: OpsQuota[] = [];
  for (const spec of DEFAULT_QUOTA_LIMITS) {
    const limit = quotaLimits.get(spec.key) ?? spec.limit;
    let used = 0;
    switch (spec.key) {
      case "qwen_tasks_day":
        used = qwenUsed;
        break;
      case "cloud_media_bytes":
        used = storageBytes;
        break;
      case "cloud_books":
        used = books.length;
        break;
      case "devices":
        used = devices.length;
        break;
    }
    rows.push({ key: spec.key, used, limit, periodEndsAt });
  }
  return rows;
}

function mapPrivacyRow(row: Record<string, unknown> | undefined): OpsPrivacyRequest | undefined {
  if (row === undefined) {
    return undefined;
  }
  const kind = row.kind;
  const status = row.status;
  if (kind !== "export" && kind !== "deletion") {
    return undefined;
  }
  if (
    status !== "queued" &&
    status !== "running" &&
    status !== "ready" &&
    status !== "failed" &&
    status !== "expired" &&
    status !== "cancelled"
  ) {
    return undefined;
  }
  return {
    id: typeof row.id === "string" ? row.id : crypto.randomUUID(),
    accountId: typeof row.user_id === "string" ? row.user_id : "",
    kind,
    status,
    format: typeof row.format === "string" ? row.format : null,
    assetId: typeof row.asset_id === "string" ? row.asset_id : null,
    error: typeof row.error === "string" ? row.error : null,
    reason: typeof row.reason === "string" ? row.reason : null,
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
    updatedAt: typeof row.updated_at === "string" ? row.updated_at : new Date().toISOString(),
    completedAt: typeof row.completed_at === "string" ? row.completed_at : null,
  };
}

function mapFlagRow(row: Record<string, unknown> | undefined): OpsFeatureFlag | undefined {
  if (row === undefined || isErrorBody(row) || typeof row.key !== "string" || row.key === "") {
    return undefined;
  }
  const platforms = Array.isArray(row.platforms)
    ? row.platforms.filter((item): item is string => typeof item === "string")
    : [];
  return {
    key: row.key,
    enabled: row.enabled !== false,
    variant: typeof row.variant === "string" ? row.variant : null,
    rolloutPercent: finiteNumber(row.rollout_percent) ?? 100,
    minAppVersion: typeof row.min_app_version === "string" ? row.min_app_version : null,
    platforms,
  };
}

function seedDefaultPolicies(policies: Map<string, OpsPolicy>, timestamp: string): void {
  for (const task of ["translation", "chapter_summary", "chat"] as const) {
    const id =
      task === "translation"
        ? "00000000-0000-4000-8000-0000000000aa"
        : task === "chapter_summary"
          ? "00000000-0000-4000-8000-0000000000ab"
          : "00000000-0000-4000-8000-0000000000ac";
    const policy: OpsPolicy = {
      id,
      task,
      region: "ap-southeast-1",
      model: "qwen3.7-flash",
      promptVersion: "qwen-managed-v1",
      systemPrompt: defaultAssistantPrompt(task),
      userPrompt: defaultAssistantUserPrompt(task),
      schemaVersion: "1",
      policyVersion: "qwen-managed-v1",
      enabled: true,
      canaryPercent: 0,
      maxInputTokens: 8000,
      maxOutputTokens: 2000,
      timeoutMs: 30000,
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    policies.set(policy.id, policy);
  }
}

function mapAuditRow(row: Record<string, unknown> | undefined): OpsAuditEvent | undefined {
  if (
    row === undefined ||
    isErrorBody(row) ||
    typeof row.id !== "string" ||
    row.id === "" ||
    typeof row.action !== "string" ||
    row.action === ""
  ) {
    return undefined;
  }
  const metadata =
    typeof row.metadata === "object" && row.metadata !== null && !Array.isArray(row.metadata)
      ? (row.metadata as Record<string, unknown>)
      : {};
  return {
    id: row.id,
    actorId:
      typeof row.actor_id === "string" ? row.actor_id : "00000000-0000-4000-8000-0000000000ae",
    action: row.action,
    resourceType: typeof row.resource_type === "string" ? row.resource_type : "",
    resourceId: typeof row.resource_id === "string" ? row.resource_id : "",
    reason: typeof row.reason === "string" ? row.reason : "",
    traceId: typeof row.request_id === "string" ? row.request_id : null,
    metadata,
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
  };
}

function logPersistence(message: string, fields: Record<string, unknown>): void {
  console.warn(JSON.stringify({ level: "warn", message, ...fields }));
}

function productEventNameMatches(eventName: string, filter: string): boolean {
  if (filter.endsWith("*")) {
    return eventName.startsWith(filter.slice(0, -1));
  }
  if (filter.endsWith(".")) {
    return eventName.startsWith(filter);
  }
  return eventName === filter;
}

function productEventNameQuery(filter: string): string {
  if (filter.includes("*")) {
    return `like.${filter}`;
  }
  if (filter.endsWith(".")) {
    return `like.${filter}*`;
  }
  return `eq.${filter}`;
}

function pendingHasSubstantiveWrite(pending: Record<string, unknown>): boolean {
  return Object.keys(pending).some((key) => key !== "updated_at");
}

function mappedWriteRow<T>(
  response: { status: number; body: unknown },
  map: (row: Record<string, unknown> | undefined) => T | undefined,
): T | undefined {
  if (!restOk(response) || isErrorBody(response.body)) {
    return undefined;
  }
  return map(restRow(response.body));
}

/**
 * PATCH with Prefer: return=representation, drop unknown columns, never treat a
 * 2xx of the previous row as success. If the only remaining field is updated_at,
 * the operator's change was not stored.
 */
async function patchRestRow<T>(input: {
  rest: RestClient;
  path: string;
  query: Record<string, string>;
  refetchQuery: Record<string, string>;
  pending: Record<string, unknown>;
  resource: string;
  id: string;
  map: (row: Record<string, unknown> | undefined) => T | undefined;
  applied: (value: T, pending: Record<string, unknown>) => boolean;
  notKeptDetail: string;
}): Promise<T | undefined> {
  const pending = input.pending;
  logPersistence(`${input.resource}_patch_start`, {
    id: input.id,
    columns: Object.keys(pending).filter((key) => key !== "updated_at"),
  });
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const response = await input.rest.request({
      method: "PATCH",
      path: input.path,
      query: input.query,
      prefer: "return=representation",
      body: pending,
    });
    const mapped = mappedWriteRow(response, input.map);
    if (restOk(response) && !isErrorBody(response.body)) {
      if (mapped !== undefined && input.applied(mapped, pending)) {
        logPersistence(`${input.resource}_patch_ok`, { id: input.id, outcome: "representation" });
        return mapped;
      }
      const refetch = await input.rest.request({
        method: "GET",
        path: input.path,
        query: input.refetchQuery,
      });
      const current = mappedWriteRow(refetch, input.map);
      if (current !== undefined && input.applied(current, pending)) {
        logPersistence(`${input.resource}_patch_ok`, { id: input.id, outcome: "refetch" });
        return current;
      }
      if (current === undefined && mapped === undefined) {
        logPersistence(`${input.resource}_patch_missing`, {
          id: input.id,
          status: response.status,
        });
        return undefined;
      }
      logPersistence(`${input.resource}_patch_not_kept`, { id: input.id, status: response.status });
      throw new RestPersistenceError(502, input.notKeptDetail);
    }
    if (response.status === 0) {
      logPersistence(`${input.resource}_patch_unreachable`, { id: input.id });
      throw new RestPersistenceError(502, "Could not reach Postgres to save the change.");
    }
    const unknown = unknownRestColumn(response.body);
    if (unknown !== undefined && Object.prototype.hasOwnProperty.call(pending, unknown)) {
      logPersistence(`${input.resource}_patch_unknown_column`, {
        column: unknown,
        id: input.id,
      });
      Reflect.deleteProperty(pending, unknown);
      if (!pendingHasSubstantiveWrite(pending)) {
        logPersistence(`${input.resource}_patch_empty_after_unknown_columns`, { id: input.id });
        throw new RestPersistenceError(
          502,
          `Postgres rejected the ${input.resource} update because it did not recognize the patched columns.`,
        );
      }
      continue;
    }
    logPersistence(`${input.resource}_patch_rejected`, {
      id: input.id,
      status: response.status,
    });
    throw new RestPersistenceError(
      502,
      restErrorDetail(response.body) ??
        `Postgres rejected the ${input.resource} update (${String(response.status)}).`,
    );
  }
  throw new RestPersistenceError(502, `Postgres rejected the ${input.resource} update.`);
}

async function patchModelPolicy(
  rest: RestClient,
  id: string,
  patch: Partial<Omit<OpsPolicy, "id" | "createdAt">>,
): Promise<OpsPolicy | undefined> {
  const pending: Record<string, unknown> = {
    updated_at: new Date().toISOString(),
  };
  if (patch.model !== undefined) {
    pending.model = patch.model;
  }
  if (patch.enabled !== undefined) {
    pending.enabled = patch.enabled;
  }
  if (patch.promptVersion !== undefined) {
    pending.prompt_version = patch.promptVersion;
  }
  if (patch.systemPrompt !== undefined) {
    pending.system_prompt = patch.systemPrompt;
  }
  if (patch.userPrompt !== undefined) {
    pending.user_prompt = patch.userPrompt;
  }
  if (patch.schemaVersion !== undefined) {
    pending.schema_version = patch.schemaVersion;
  }
  if (patch.policyVersion !== undefined) {
    pending.policy_version = patch.policyVersion;
  }
  if (patch.canaryPercent !== undefined) {
    pending.canary_percent = patch.canaryPercent;
  }
  if (patch.maxInputTokens !== undefined) {
    pending.max_input_tokens = patch.maxInputTokens;
  }
  if (patch.maxOutputTokens !== undefined) {
    pending.max_output_tokens = patch.maxOutputTokens;
  }
  if (patch.timeoutMs !== undefined) {
    pending.timeout_ms = patch.timeoutMs;
  }
  if (patch.region !== undefined) {
    pending.region = patch.region;
  }
  if (patch.task !== undefined) {
    pending.task = patch.task;
  }
  return patchRestRow({
    rest,
    path: "/model_policies",
    query: { id: `eq.${id}`, select: "*" },
    refetchQuery: { select: "*", id: `eq.${id}`, limit: "1" },
    pending,
    resource: "model_policy",
    id,
    map: mapPolicyRow,
    applied: policyWriteApplied,
    notKeptDetail:
      "Postgres did not keep the Qwen policy change. The previous model is still stored.",
  });
}

async function patchFeatureFlag(
  rest: RestClient,
  key: string,
  patch: Partial<Omit<OpsFeatureFlag, "key">>,
): Promise<OpsFeatureFlag | undefined> {
  const pending: Record<string, unknown> = {
    updated_at: new Date().toISOString(),
  };
  if (patch.enabled !== undefined) {
    pending.enabled = patch.enabled;
  }
  if (patch.variant !== undefined) {
    pending.variant = patch.variant;
  }
  if (patch.rolloutPercent !== undefined) {
    pending.rollout_percent = patch.rolloutPercent;
  }
  if (patch.minAppVersion !== undefined) {
    pending.min_app_version = patch.minAppVersion;
  }
  if (patch.platforms !== undefined) {
    pending.platforms = patch.platforms;
  }
  return patchRestRow({
    rest,
    path: "/feature_flags",
    query: { key: `eq.${key}`, select: "*" },
    refetchQuery: { select: "*", key: `eq.${key}`, limit: "1" },
    pending,
    resource: "feature_flag",
    id: key,
    map: mapFlagRow,
    applied: flagWriteApplied,
    notKeptDetail: "Postgres did not keep the feature flag change.",
  });
}

async function persistQuotaLimit(
  rest: RestClient,
  memory: OpsStore,
  key: QuotaKey,
  limit: number,
): Promise<OpsQuota | undefined> {
  logPersistence("quota_patch_start", { key, limit });
  const body = { key, limit_value: limit, updated_at: new Date().toISOString() };
  const response = await rest.request({
    method: "POST",
    path: "/quota_limits",
    query: { on_conflict: "key" },
    prefer: "resolution=merge-duplicates,return=representation",
    body,
  });
  let row = mappedWriteRow(response, (item) => item);
  if (quotaLimitMatches(row, key, limit)) {
    await memory.patchQuota(key, limit);
    logPersistence("quota_patch_ok", { key, outcome: "representation" });
    return quotaFromMemory(memory, key);
  }
  if (response.status === 0) {
    logPersistence("quota_patch_unreachable", { key });
    throw new RestPersistenceError(502, "Could not reach Postgres to save the quota.");
  }
  if (!restOk(response) || isErrorBody(response.body)) {
    logPersistence("quota_patch_rejected", { key, status: response.status });
    throw new RestPersistenceError(
      502,
      restErrorDetail(response.body) ??
        `Postgres rejected the quota update (${String(response.status)}).`,
    );
  }
  const refetch = await rest.request({
    method: "GET",
    path: "/quota_limits",
    query: { select: "*", key: `eq.${key}`, limit: "1" },
  });
  row = mappedWriteRow(refetch, (item) => item);
  if (quotaLimitMatches(row, key, limit)) {
    await memory.patchQuota(key, limit);
    logPersistence("quota_patch_ok", { key, outcome: "refetch" });
    return quotaFromMemory(memory, key);
  }
  logPersistence("quota_patch_not_kept", { key, status: refetch.status });
  throw new RestPersistenceError(502, "Postgres did not keep the quota limit.");
}

function quotaLimitMatches(
  row: Record<string, unknown> | undefined,
  key: string,
  limit: number,
): boolean {
  return row !== undefined && row.key === key && finiteNumber(row.limit_value) === limit;
}

async function quotaFromMemory(memory: OpsStore, key: string): Promise<OpsQuota | undefined> {
  const [updated] = (await memory.quotasFor("")).filter((item) => item.key === key);
  return updated;
}

async function persistOperatorSettings(
  rest: RestClient,
  input: Omit<OperatorSettingsRecord, "updatedAt">,
): Promise<OperatorSettingsRecord> {
  logPersistence("operator_settings_put_start", {
    id: input.id,
    payloadKeys: Object.keys(input.payload),
    ciphertextPresent: input.ciphertext !== null && input.ciphertext !== "",
  });
  const writeBody = {
    id: input.id,
    payload: input.payload,
    ciphertext: input.ciphertext,
    nonce: input.nonce,
    updated_at: new Date().toISOString(),
    updated_by: input.updatedBy,
  };
  const posted = await rest.request({
    method: "POST",
    path: "/operator_settings",
    query: { on_conflict: "id" },
    prefer: "resolution=merge-duplicates,return=representation",
    body: writeBody,
  });
  let mapped = mappedWriteRow(posted, mapOperatorSettingsRow);
  if (mapped !== undefined && operatorSettingsWriteApplied(mapped, input)) {
    logPersistence("operator_settings_put_ok", { id: input.id, outcome: "insert" });
    return mapped;
  }
  if (posted.status === 0) {
    logPersistence("operator_settings_put_unreachable", { id: input.id });
    throw new RestPersistenceError(502, "Could not reach Postgres to save operator settings.");
  }
  if (!restOk(posted) || isErrorBody(posted.body)) {
    logPersistence("operator_settings_put_rejected", { id: input.id, status: posted.status });
    throw new RestPersistenceError(
      502,
      restErrorDetail(posted.body) ??
        `Postgres rejected the operator settings update (${String(posted.status)}).`,
    );
  }
  const patched = await rest.request({
    method: "PATCH",
    path: "/operator_settings",
    query: { id: `eq.${input.id}`, select: "*" },
    prefer: "return=representation",
    body: {
      payload: input.payload,
      ciphertext: input.ciphertext,
      nonce: input.nonce,
      updated_at: writeBody.updated_at,
      updated_by: input.updatedBy,
    },
  });
  mapped = mappedWriteRow(patched, mapOperatorSettingsRow);
  if (mapped !== undefined && operatorSettingsWriteApplied(mapped, input)) {
    logPersistence("operator_settings_put_ok", { id: input.id, outcome: "patch" });
    return mapped;
  }
  if (patched.status === 0) {
    logPersistence("operator_settings_put_unreachable", { id: input.id });
    throw new RestPersistenceError(502, "Could not reach Postgres to save operator settings.");
  }
  if (!restOk(patched) || isErrorBody(patched.body)) {
    logPersistence("operator_settings_put_rejected", { id: input.id, status: patched.status });
    throw new RestPersistenceError(
      502,
      restErrorDetail(patched.body) ??
        `Postgres rejected the operator settings update (${String(patched.status)}).`,
    );
  }
  const refetch = await rest.request({
    method: "GET",
    path: "/operator_settings",
    query: { select: "*", id: `eq.${input.id}`, limit: "1" },
  });
  mapped = mappedWriteRow(refetch, mapOperatorSettingsRow);
  if (mapped !== undefined && operatorSettingsWriteApplied(mapped, input)) {
    logPersistence("operator_settings_put_ok", { id: input.id, outcome: "refetch" });
    return mapped;
  }
  logPersistence("operator_settings_put_not_kept", { id: input.id, status: refetch.status });
  throw new RestPersistenceError(502, "Postgres did not keep the operator settings.");
}

function operatorSettingsWriteApplied(
  row: OperatorSettingsRecord,
  input: Omit<OperatorSettingsRecord, "updatedAt">,
): boolean {
  return (
    row.id === input.id &&
    JSON.stringify(row.payload) === JSON.stringify(input.payload) &&
    row.ciphertext === input.ciphertext &&
    row.nonce === input.nonce
  );
}

async function persistAuditEvent(
  rest: RestClient,
  event: Omit<OpsAuditEvent, "id" | "createdAt">,
): Promise<OpsAuditEvent> {
  logPersistence("audit_append_start", {
    action: event.action,
    resourceType: event.resourceType,
    resourceId: event.resourceId,
  });
  const response = await rest.request({
    method: "POST",
    path: "/audit_events",
    prefer: "return=representation",
    body: {
      actor_id: event.actorId,
      actor_type: "admin",
      action: event.action,
      resource_type: event.resourceType,
      resource_id: event.resourceId,
      reason: event.reason,
      request_id: event.traceId,
      metadata: event.metadata,
    },
  });
  const mapped = mappedWriteRow(response, mapAuditRow);
  if (mapped !== undefined) {
    logPersistence("audit_append_ok", { id: mapped.id, action: event.action });
    return mapped;
  }
  logPersistence("audit_append_failed", { action: event.action, status: response.status });
  if (response.status === 0) {
    throw new RestPersistenceError(502, "Could not reach Postgres to record the audit event.");
  }
  throw new RestPersistenceError(
    502,
    restErrorDetail(response.body) ?? "Postgres did not store the audit event.",
  );
}

async function persistProductEvent(
  rest: RestClient,
  event: Omit<OpsProductEvent, "id" | "createdAt"> & { createdAt?: string },
): Promise<OpsProductEvent> {
  logPersistence("product_event_append_start", {
    name: event.name,
    outcome: event.outcome,
    accountId: event.accountId,
  });
  const response = await rest.request({
    method: "POST",
    path: "/product_events",
    prefer: "return=representation",
    body: {
      user_id: event.accountId,
      device_id: event.deviceId,
      name: event.name,
      outcome: event.outcome,
      request_id: event.requestId,
      properties: event.properties,
      ...(event.createdAt === undefined ? {} : { created_at: event.createdAt }),
    },
  });
  const mapped = mappedWriteRow(response, mapProductEventRow);
  if (mapped !== undefined) {
    logPersistence("product_event_append_ok", { id: mapped.id, name: event.name });
    return mapped;
  }
  logPersistence("product_event_append_failed", { name: event.name, status: response.status });
  throw new RestPersistenceError(
    response.status === 0 ? 502 : 502,
    restErrorDetail(response.body) ?? "Postgres did not store the product event.",
  );
}

async function fetchCacheByKey(
  rest: RestClient,
  cacheKey: string,
): Promise<OpsCacheEntry | undefined> {
  const response = await rest.request({
    method: "GET",
    path: "/assistant_cache_entries",
    query: {
      select: "*",
      cache_key: `eq.${cacheKey}`,
      state: "eq.active",
      limit: "1",
    },
  });
  if (!restOk(response) || isErrorBody(response.body)) {
    logPersistence("cache_lookup_failed", { status: response.status });
    return undefined;
  }
  return mapCacheRow(restRow(response.body));
}

async function fetchCacheById(rest: RestClient, id: string): Promise<OpsCacheEntry | undefined> {
  const response = await rest.request({
    method: "GET",
    path: "/assistant_cache_entries",
    query: { select: "*", id: `eq.${id}`, limit: "1" },
  });
  if (!restOk(response) || isErrorBody(response.body)) {
    logPersistence("cache_get_failed", { id, status: response.status });
    return undefined;
  }
  return mapCacheRow(restRow(response.body));
}

/**
 * Shared translation/summary cache is Postgres-backed. A silent in-memory
 * fallback hid rows from the admin Cache rail and the table editor.
 */
async function persistCacheEntry(
  rest: RestClient,
  input: Omit<
    OpsCacheEntry,
    "hitCount" | "acceptCount" | "rejectCount" | "createdAt" | "lastHitAt"
  > & {
    payload: Record<string, unknown>;
  },
): Promise<OpsCacheEntry> {
  logPersistence("cache_put_start", { cacheKey: input.cacheKey, task: input.task, id: input.id });
  const existing = await fetchCacheByKey(rest, input.cacheKey);
  if (existing !== undefined) {
    logPersistence("cache_put_existing", { id: existing.id, cacheKey: input.cacheKey });
    return existing;
  }
  const response = await rest.request({
    method: "POST",
    path: "/assistant_cache_entries",
    prefer: "return=representation",
    body: {
      id: input.id,
      cache_key: input.cacheKey,
      task_type: input.task,
      source_language: input.sourceLanguage,
      target_language: input.targetLanguage,
      edition_fingerprint: input.editionFingerprint,
      state: input.state,
      policy_version: input.policyVersion,
      result: input.payload,
    },
  });
  const mapped = mappedWriteRow(response, mapCacheRow);
  if (mapped !== undefined) {
    logPersistence("cache_put_ok", { id: mapped.id, cacheKey: input.cacheKey, task: input.task });
    return mapped;
  }
  const replay = await fetchCacheByKey(rest, input.cacheKey);
  if (replay !== undefined) {
    logPersistence("cache_put_replay", {
      id: replay.id,
      cacheKey: input.cacheKey,
      status: response.status,
    });
    return replay;
  }
  logPersistence("cache_put_failed", {
    cacheKey: input.cacheKey,
    status: response.status,
    detail: restErrorDetail(response.body) ?? "",
  });
  throw new RestPersistenceError(
    response.status === 0 ? 502 : 502,
    restErrorDetail(response.body) ?? "Postgres did not store the assistant cache entry.",
  );
}

function policyWriteApplied(policy: OpsPolicy, written: Record<string, unknown>): boolean {
  if (typeof written.model === "string" && policy.model !== written.model) {
    return false;
  }
  if (typeof written.enabled === "boolean" && policy.enabled !== written.enabled) {
    return false;
  }
  if (
    typeof written.prompt_version === "string" &&
    policy.promptVersion !== written.prompt_version
  ) {
    return false;
  }
  if (typeof written.system_prompt === "string" && policy.systemPrompt !== written.system_prompt) {
    return false;
  }
  if (typeof written.user_prompt === "string" && policy.userPrompt !== written.user_prompt) {
    return false;
  }
  const canary = finiteNumber(written.canary_percent);
  if (canary !== undefined && policy.canaryPercent !== canary) {
    return false;
  }
  return true;
}

function flagWriteApplied(flag: OpsFeatureFlag, written: Record<string, unknown>): boolean {
  if (typeof written.enabled === "boolean" && flag.enabled !== written.enabled) {
    return false;
  }
  if (Object.prototype.hasOwnProperty.call(written, "variant")) {
    const expected = typeof written.variant === "string" ? written.variant : null;
    if (flag.variant !== expected) {
      return false;
    }
  }
  const rollout = finiteNumber(written.rollout_percent);
  if (rollout !== undefined && flag.rolloutPercent !== rollout) {
    return false;
  }
  if (Object.prototype.hasOwnProperty.call(written, "min_app_version")) {
    const expected = typeof written.min_app_version === "string" ? written.min_app_version : null;
    if (flag.minAppVersion !== expected) {
      return false;
    }
  }
  if (Array.isArray(written.platforms)) {
    const expected = written.platforms.filter((item): item is string => typeof item === "string");
    if (
      flag.platforms.length !== expected.length ||
      flag.platforms.some((item, index) => item !== expected[index])
    ) {
      return false;
    }
  }
  return true;
}

function restErrorDetail(body: unknown): string | undefined {
  if (typeof body === "string" && body.trim() !== "") {
    return body.trim().slice(0, 280);
  }
  if (isRecord(body) && typeof body.message === "string" && body.message.trim() !== "") {
    return body.message.trim().slice(0, 280);
  }
  return undefined;
}

function unknownRestColumn(body: unknown): string | undefined {
  const message = restErrorDetail(body);
  if (message === undefined) {
    return undefined;
  }
  const match = /Could not find the '([^']+)' column/i.exec(message);
  return match?.[1];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteNumber(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return undefined;
}

function mapPolicyRow(row: Record<string, unknown> | undefined): OpsPolicy | undefined {
  if (
    row === undefined ||
    isErrorBody(row) ||
    typeof row.id !== "string" ||
    typeof row.task !== "string" ||
    typeof row.model !== "string"
  ) {
    return undefined;
  }
  return {
    id: row.id,
    task: row.task,
    region: typeof row.region === "string" ? row.region : "",
    model: row.model,
    promptVersion: typeof row.prompt_version === "string" ? row.prompt_version : "",
    systemPrompt:
      typeof row.system_prompt === "string" && row.system_prompt.trim() !== ""
        ? row.system_prompt
        : defaultAssistantPrompt(row.task),
    userPrompt:
      typeof row.user_prompt === "string" && row.user_prompt.trim() !== ""
        ? row.user_prompt
        : defaultAssistantUserPrompt(row.task),
    schemaVersion: typeof row.schema_version === "string" ? row.schema_version : "",
    policyVersion: typeof row.policy_version === "string" ? row.policy_version : "",
    enabled: row.enabled !== false,
    canaryPercent: finiteNumber(row.canary_percent) ?? 0,
    maxInputTokens: finiteNumber(row.max_input_tokens) ?? null,
    maxOutputTokens: finiteNumber(row.max_output_tokens) ?? null,
    timeoutMs: finiteNumber(row.timeout_ms) ?? null,
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
    updatedAt: typeof row.updated_at === "string" ? row.updated_at : new Date().toISOString(),
  };
}

function mapProductEventRow(row: Record<string, unknown> | undefined): OpsProductEvent | undefined {
  if (
    row === undefined ||
    isErrorBody(row) ||
    typeof row.id !== "string" ||
    row.id === "" ||
    typeof row.name !== "string"
  ) {
    return undefined;
  }
  const properties =
    typeof row.properties === "object" && row.properties !== null && !Array.isArray(row.properties)
      ? (row.properties as Record<string, unknown>)
      : {};
  const outcome =
    row.outcome === "failed" || row.outcome === "cancelled" || row.outcome === "started"
      ? row.outcome
      : "ok";
  return {
    id: row.id,
    accountId: typeof row.user_id === "string" ? row.user_id : "",
    deviceId: typeof row.device_id === "string" ? row.device_id : null,
    name: row.name,
    outcome,
    requestId: typeof row.request_id === "string" ? row.request_id : null,
    properties,
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
  };
}

function mapOperatorSettingsRow(
  row: Record<string, unknown> | undefined,
): OperatorSettingsRecord | undefined {
  if (row === undefined || isErrorBody(row) || typeof row.id !== "string" || row.id === "") {
    return undefined;
  }
  const payload =
    typeof row.payload === "object" && row.payload !== null && !Array.isArray(row.payload)
      ? (row.payload as Record<string, unknown>)
      : {};
  return {
    id: row.id,
    payload,
    ciphertext: typeof row.ciphertext === "string" ? row.ciphertext : null,
    nonce: typeof row.nonce === "string" ? row.nonce : null,
    updatedAt: typeof row.updated_at === "string" ? row.updated_at : new Date().toISOString(),
    updatedBy: typeof row.updated_by === "string" ? row.updated_by : null,
  };
}

export type { IdentityProfile };
