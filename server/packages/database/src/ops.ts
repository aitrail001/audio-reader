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
import type { SyncEntityType, SyncStore } from "./sync-store";

/** Operator-visible Postgres write failure. Admin routes map this to 502; never treat it as an in-memory success. */
export class RestPersistenceError extends Error {
  readonly status: number;

  constructor(status: number, detail: string) {
    super(detail);
    this.name = "RestPersistenceError";
    this.status = status;
  }
}

export class AssetReservationError extends Error {
  constructor(
    readonly code:
      "pending_asset_count_exceeded" | "cloud_media_quota_exceeded" | "asset_book_deleted",
  ) {
    super(code);
    this.name = "AssetReservationError";
  }
}

export type AssetKind =
  | "audio"
  | "epub"
  | "cover"
  | "transcriptRevision"
  | "epubReadingPackage"
  | "alignmentPackage"
  | "mediaAnalysis"
  | "transcriptExport"
  | "accountExport"
  | "assistantArtifact"
  | "otherLargeImmutable";
export type AssetStatus = "pending" | "ready" | "failed" | "deleting";

export type OpsAsset = {
  id: string;
  uploadId: string;
  accountId: string;
  kind: AssetKind;
  contentType: string;
  compressedBytes: number;
  originalBytes: number;
  sha256: string;
  encoding: string;
  revisionId: string | null;
  bookId: string | null;
  chapterId: string | null;
  segmentCount: number | null;
  fileName: string;
  status: AssetStatus;
  objectKey: string;
  uploadObjectKey: string;
  createdAt: string;
  deletedAt: string | null;
  uploadAuthorizedUntil: string | null;
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

export type OpsAssistantResult = {
  id: string;
  accountId: string;
  task: string;
  resultKind: string | null;
  status: "pending" | "accepted" | "rejected" | "stale" | "edited" | "replaced";
  cacheEntryId: string | null;
  outputText: string | null;
  privateContent: Record<string, unknown> | null;
  language: string | null;
  sourceText: string | null;
  contextText: string | null;
  bookTitle: string | null;
  chapterTitle: string | null;
  targetId: string | null;
  timestampSeconds: number | null;
  replacedText: string | null;
  replacedModel: string | null;
  privateEditedOutput: string | null;
  privateNotes: string | null;
  model: string | null;
  promptVersion: string | null;
  modelPolicyHash: string | null;
  history: Record<string, unknown>[];
  createdAt: string;
  updatedAt: string;
  decidedAt: string | null;
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
  purpose: "learning_analytics" | "operational";
  name: string;
  outcome: "ok" | "failed" | "cancelled" | "started";
  requestId: string | null;
  properties: Record<string, unknown>;
  createdAt: string;
};

export type OpsTimeIdCursor = { createdAt: string; id: string };

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

export type AnalyticsPreferenceRecord = {
  operatorLearningAnalyticsEnabled: boolean;
  updatedAt: string;
};

/** Safe aggregate only. Synced payload text must never cross this database boundary. */
export type UserProgressSummaryRecord = {
  generatedAt: string;
  expiresAt: string | null;
  sync: {
    lastSuccessfulAt: string | null;
    lastDevice: { id: string; platform: string; name: string | null } | null;
    entityCounts: Array<{ entityType: string; count: number }>;
    pendingCount: number | null;
    conflictCount: number;
  };
  reading: {
    lastActivityAt: string | null;
    activeBooks: number;
    completedBooks: number;
    currentChapter: number | null;
    completionPercent: number | null;
  } | null;
  review: {
    due: number;
    new: number;
    learning: number;
    reviewsLast30Days: number;
    reviewsPerActiveDay: number;
    retentionRate: number | null;
    streakDays: number;
  } | null;
  learning: {
    vocabulary: number;
    known: number;
    learning: number;
    aiUsesLast30Days: number;
    aiUsesByFeature: Array<{ feature: string; count: number }>;
  } | null;
};

export type OperatorSettingsRecord = {
  id: string;
  payload: Record<string, unknown>;
  ciphertext: string | null;
  nonce: string | null;
  updatedAt: string;
  updatedBy: string | null;
};

export type ObjectWriteLease = {
  id: string;
  accountId: string;
  objectKey: string;
  expiresAt: string;
};
export type AbandonedAssetUpload = { id: string; objectKeys: string[] };
export type ReadyAssetUploadCleanup = { id: string; uploadObjectKey: string };
export type DeletedBookAssetCleanup = {
  id: string;
  objectKey: string;
  uploadObjectKey: string;
  deleteAfter: string | null;
};

function latestDeleteAfter(
  asset: OpsAsset,
  leases: ReadonlyMap<string, ObjectWriteLease>,
): string | null {
  const deadlines = [
    asset.uploadAuthorizedUntil,
    ...[...leases.values()]
      .filter(
        (lease) =>
          lease.accountId === asset.accountId &&
          (lease.objectKey === asset.objectKey || lease.objectKey === asset.uploadObjectKey) &&
          Date.parse(lease.expiresAt) > Date.now(),
      )
      .map((lease) => lease.expiresAt),
  ].filter((value): value is string => value !== null);
  return deadlines.sort().at(-1) ?? null;
}
export type LegacyCleanupResult = {
  changes: number;
  outcomes: number;
  batches: number;
  transcriptRevisions: number;
  transcriptSegments: number;
  assets: number;
  objectKeys: string[];
  executed: boolean;
};

export type OperatorSettingsReadResult =
  | { ok: true; value: OperatorSettingsRecord | undefined }
  | { ok: false; error: "unavailable" | "invalid_response" };

export type OpsStore = {
  createAsset(
    userId: string,
    input: {
      kind: AssetKind;
      contentType: string;
      compressedBytes: number;
      originalBytes: number;
      sha256: string;
      encoding: string;
      revisionId: string | null;
      bookId: string | null;
      chapterId: string | null;
      segmentCount: number | null;
      fileName: string;
      objectKey: string;
      uploadObjectKey: string;
      uploadId: string;
    },
  ): Promise<OpsAsset>;
  getAsset(userId: string, assetId: string): Promise<OpsAsset | undefined>;
  listAssets(
    userId: string,
    filter?: { kind?: AssetKind; bookId?: string; chapterId?: string },
  ): Promise<OpsAsset[]>;
  getAssetByContent(userId: string, kind: AssetKind, sha256: string): Promise<OpsAsset | undefined>;
  getAssetByUpload(userId: string, uploadId: string): Promise<OpsAsset | undefined>;
  authorizeAssetUpload(
    userId: string,
    uploadId: string,
    authorizedUntil: string,
  ): Promise<OpsAsset | undefined>;
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
  claimJobs(limit?: number): Promise<OpsJob[]>;
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
    resourceId?: string;
    cursor?: OpsTimeIdCursor;
    limit?: number;
  }): Promise<OpsAuditEvent[]>;
  recordProductEvent(
    event: Omit<OpsProductEvent, "id" | "createdAt" | "purpose"> & {
      createdAt?: string;
      purpose?: OpsProductEvent["purpose"];
    },
  ): Promise<OpsProductEvent>;
  listProductEvents(filter?: {
    accountId?: string;
    name?: string;
    requestId?: string;
    from?: string;
    to?: string;
    cursor?: OpsTimeIdCursor;
    limit?: number;
  }): Promise<OpsProductEvent[]>;
  purgeExpiredProductEvents(): Promise<number>;
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
  analyticsPreference(userId: string): Promise<AnalyticsPreferenceRecord>;
  putAnalyticsPreference(userId: string, enabled: boolean): Promise<AnalyticsPreferenceRecord>;
  userProgressSummary(userId: string): Promise<UserProgressSummaryRecord | undefined>;
  purgeExpiredUserProgressSummaries(): Promise<number>;
  gcAbandonedAssetUploads(before: string, limit: number): Promise<AbandonedAssetUpload[]>;
  finishAbandonedAssetUploadGc(ids: readonly string[]): Promise<void>;
  claimReadyAssetUploadCleanup(limit: number): Promise<ReadyAssetUploadCleanup[]>;
  finishReadyAssetUploadCleanup(ids: readonly string[]): Promise<void>;
  claimDeletedBookAssets(
    userId: string,
    bookIds: readonly string[],
  ): Promise<DeletedBookAssetCleanup[]>;
  cleanupObsoleteV1Data(userId: string, execute: boolean): Promise<LegacyCleanupResult>;
  deleteAccountData(userId: string): Promise<boolean>;
  requestAccountDeletion(
    userId: string,
    reason: string,
    requestId: string,
  ): Promise<{ request: OpsPrivacyRequest; job: OpsJob }>;
  accountObjectKeys(userId: string): Promise<string[]>;
  beginObjectWrite(userId: string, objectKey: string): Promise<ObjectWriteLease>;
  beginAssetObjectWrite(
    userId: string,
    assetId: string,
    objectKey: string,
  ): Promise<ObjectWriteLease | undefined>;
  finishObjectWrite(leaseId: string): Promise<void>;
  accountObjectWriteLeases(userId: string): Promise<ObjectWriteLease[]>;
  recordAssistantUse(
    userId: string,
    input: {
      resultId: string;
      task: string;
      status?: "pending" | "replaced";
      cacheEntryId: string | null;
      outputText: string;
      privateContent?: Record<string, unknown>;
      resultKind?: string;
      language?: string;
      sourceText?: string;
      contextText?: string;
      bookTitle?: string;
      chapterTitle?: string;
      targetId?: string;
      timestampSeconds?: number;
      model?: string;
      promptVersion?: string;
      modelPolicyHash?: string;
    },
  ): Promise<OpsAssistantResult>;
  listAssistantResults(userId: string): Promise<OpsAssistantResult[]>;
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
  readOperatorSettings(): Promise<OperatorSettingsReadResult>;
  putOperatorSettings(
    input: Omit<OperatorSettingsRecord, "updatedAt">,
  ): Promise<OperatorSettingsRecord>;
};

export function createMemoryOpsStore(
  options: {
    identity?: IdentityStore;
    catalog?: CatalogStore;
    syncV2?: SyncStore;
  } = {},
): OpsStore {
  const assets = new Map<string, OpsAsset>();
  const cleanedReadyAssetUploads = new Set<string>();
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
  const analyticsPreferences = new Map<string, AnalyticsPreferenceRecord>();
  const objectWriteLeases = new Map<string, ObjectWriteLease>();
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
  const assistantResults: OpsAssistantResult[] = [];
  const now = () => new Date().toISOString();
  seedDefaultPolicies(policies, now());
  seedDefaultFlags(flags);
  seedDefaultQuotaLimits(quotaLimits);
  let operatorSettings: OperatorSettingsRecord | undefined;

  return {
    async createAsset(userId, input) {
      if (
        input.bookId !== null &&
        options.syncV2 !== undefined &&
        (await options.syncV2.latestEntityOperation(userId, "book", input.bookId)) === "delete"
      ) {
        throw new AssetReservationError("asset_book_deleted");
      }
      const owned = [
        ...new Map(
          [...assets.values()]
            .filter((asset) => asset.accountId === userId)
            .map((asset) => [asset.id, asset]),
        ).values(),
      ].filter((asset) => asset.status === "pending" || asset.status === "ready");
      if (owned.filter((asset) => asset.status === "pending").length >= 32) {
        throw new AssetReservationError("pending_asset_count_exceeded");
      }
      const reserved = owned.reduce((sum, asset) => sum + asset.compressedBytes, 0);
      const limit = quotaLimits.get("cloud_media_bytes") ?? 10 * 1_024 * 1_024 * 1_024;
      if (reserved + input.compressedBytes > limit) {
        throw new AssetReservationError("cloud_media_quota_exceeded");
      }
      const id = crypto.randomUUID();
      const uploadId = input.uploadId;
      const created: OpsAsset = {
        id,
        uploadId,
        accountId: userId,
        kind: input.kind,
        contentType: input.contentType,
        compressedBytes: input.compressedBytes,
        originalBytes: input.originalBytes,
        sha256: input.sha256,
        encoding: input.encoding,
        revisionId: input.revisionId,
        bookId: input.bookId,
        chapterId: input.chapterId,
        segmentCount: input.segmentCount,
        fileName: input.fileName,
        status: "pending",
        objectKey: input.objectKey,
        uploadObjectKey: input.uploadObjectKey,
        createdAt: now(),
        deletedAt: null,
        uploadAuthorizedUntil:
          input.compressedBytes > 8 * 1_024 * 1_024
            ? new Date(Date.now() + 15 * 60_000).toISOString()
            : null,
      };
      assets.set(`${userId}:${id}`, created);
      assets.set(`upload:${userId}:${uploadId}`, created);
      return { ...created };
    },

    getAsset(userId, assetId) {
      const asset = assets.get(`${userId}:${assetId}`);
      return Promise.resolve(asset === undefined ? undefined : { ...asset });
    },

    listAssets(userId, filter) {
      const rows = [...new Map([...assets.values()].map((asset) => [asset.id, asset])).values()]
        .filter((asset) => asset.accountId === userId && asset.status === "ready")
        .filter((asset) => filter?.kind === undefined || asset.kind === filter.kind)
        .filter((asset) => filter?.bookId === undefined || asset.bookId === filter.bookId)
        .filter((asset) => filter?.chapterId === undefined || asset.chapterId === filter.chapterId)
        .sort((left, right) => left.createdAt.localeCompare(right.createdAt));
      return Promise.resolve(rows.map((asset) => ({ ...asset })));
    },

    getAssetByContent(userId, kind, sha256) {
      const asset = [...assets.values()].find(
        (candidate) =>
          candidate.accountId === userId && candidate.kind === kind && candidate.sha256 === sha256,
      );
      return Promise.resolve(asset === undefined ? undefined : { ...asset });
    },

    getAssetByUpload(userId, uploadId) {
      const asset = assets.get(`upload:${userId}:${uploadId}`);
      return Promise.resolve(asset === undefined ? undefined : { ...asset });
    },

    async authorizeAssetUpload(userId, uploadId, authorizedUntil) {
      const asset = assets.get(`upload:${userId}:${uploadId}`);
      if (asset === undefined || asset.status !== "pending") return undefined;
      if (
        asset.bookId !== null &&
        options.syncV2 !== undefined &&
        (await options.syncV2.latestEntityOperation(userId, "book", asset.bookId)) === "delete"
      ) {
        return undefined;
      }
      asset.uploadAuthorizedUntil = authorizedUntil;
      return { ...asset };
    },

    async completeAsset(userId, uploadId) {
      const asset = assets.get(`upload:${userId}:${uploadId}`);
      if (asset === undefined) {
        return undefined;
      }
      if (asset.status === "ready") {
        return { ...asset };
      }
      if (options.syncV2 !== undefined) {
        const isTranscript =
          asset.kind === "transcriptRevision" &&
          asset.revisionId !== null &&
          asset.chapterId !== null;
        await options.syncV2.push({
          userId,
          deviceId: "00000000-0000-4000-8000-000000000000",
          batchId: asset.id,
          mutations: [
            {
              mutationId: asset.id,
              entityType: isTranscript ? "transcript" : "asset",
              entityId: isTranscript ? (asset.revisionId ?? asset.id) : asset.id,
              operation: "upsert",
              baseRevision: 0,
              occurredAt: asset.createdAt,
              payload: {
                assetId: asset.id,
                kind: asset.kind,
                revisionId: asset.revisionId,
                bookId: asset.bookId,
                objectKey: asset.objectKey,
                sha256: asset.sha256,
                encoding: asset.encoding,
                compressedBytes: asset.compressedBytes,
                originalBytes: asset.originalBytes,
                segmentCount: asset.segmentCount,
                chapterId: asset.chapterId,
              },
            },
          ],
        });
      }
      asset.status = "ready";
      return { ...asset };
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

    claimJobs(limit = 16) {
      const claimed = [...jobs.values()]
        .filter((job) => job.status === "queued" && job.attempts < job.maxAttempts)
        .sort((left, right) => left.createdAt.localeCompare(right.createdAt))
        .slice(0, Math.max(1, Math.min(100, Math.trunc(limit))));
      for (const job of claimed) {
        job.status = "running";
        job.attempts += 1;
        job.startedAt ??= now();
        job.updatedAt = now();
      }
      return Promise.resolve(claimed.map((job) => ({ ...job, payload: { ...job.payload } })));
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
      const resourceId = filter?.resourceId?.trim() ?? "";
      const cursor = filter?.cursor;
      const limit = Math.min(Math.max(filter?.limit ?? 100, 1), 5001);
      return Promise.resolve(
        [...audit]
          .filter((event) => (actorId === "" ? true : event.actorId === actorId))
          .filter((event) => (action === "" ? true : event.action === action))
          .filter((event) => (requestId === "" ? true : event.traceId === requestId))
          .filter((event) => (resourceType === "" ? true : event.resourceType === resourceType))
          .filter((event) => (resourceId === "" ? true : event.resourceId === resourceId))
          .sort(compareTimeIdDescending)
          .filter((event) => cursor === undefined || timeIdPrecedesCursor(event, cursor))
          .slice(0, limit)
          .map((event) => ({ ...event, metadata: { ...event.metadata } })),
      );
    },

    recordProductEvent(event) {
      const created: OpsProductEvent = {
        id: crypto.randomUUID(),
        accountId: event.accountId,
        deviceId: event.deviceId,
        purpose: event.purpose ?? "learning_analytics",
        name: event.name,
        outcome: event.outcome,
        requestId: event.requestId,
        properties: { ...event.properties },
        createdAt: event.createdAt ?? now(),
      };
      productEvents.unshift(created);
      return Promise.resolve({ ...created, properties: { ...created.properties } });
    },

    listProductEvents(filter) {
      const accountId = filter?.accountId?.trim() ?? "";
      const name = filter?.name?.trim() ?? "";
      const requestId = filter?.requestId?.trim() ?? "";
      const from = filter?.from?.trim() ?? "";
      const to = filter?.to?.trim() ?? "";
      const cursor = filter?.cursor;
      const limit = Math.min(Math.max(filter?.limit ?? 100, 1), 5001);
      return Promise.resolve(
        productEvents
          .filter((event) => (accountId === "" ? true : event.accountId === accountId))
          .filter((event) => (name === "" ? true : productEventNameMatches(event.name, name)))
          .filter((event) => (requestId === "" ? true : event.requestId === requestId))
          .filter((event) => (from === "" ? true : event.createdAt >= from))
          .filter((event) => (to === "" ? true : event.createdAt < to))
          .sort(compareTimeIdDescending)
          .filter((event) => cursor === undefined || timeIdPrecedesCursor(event, cursor))
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

    analyticsPreference(userId) {
      return Promise.resolve(
        analyticsPreferences.get(userId) ?? {
          operatorLearningAnalyticsEnabled: false,
          updatedAt: now(),
        },
      );
    },

    putAnalyticsPreference(userId, enabled) {
      const value = {
        operatorLearningAnalyticsEnabled: enabled,
        updatedAt: now(),
      };
      analyticsPreferences.set(userId, value);
      if (!enabled) {
        for (let index = productEvents.length - 1; index >= 0; index -= 1) {
          const event = productEvents[index];
          if (event?.accountId === userId && event.purpose === "learning_analytics") {
            productEvents.splice(index, 1);
          }
        }
      }
      return Promise.resolve({ ...value });
    },

    userProgressSummary() {
      return Promise.resolve(undefined);
    },

    purgeExpiredUserProgressSummaries() {
      return Promise.resolve(0);
    },

    purgeExpiredProductEvents() {
      const cutoff = Date.now() - 90 * 86_400_000;
      let purged = 0;
      for (let index = productEvents.length - 1; index >= 0; index -= 1) {
        const event = productEvents[index];
        if (event !== undefined && Date.parse(event.createdAt) < cutoff) {
          productEvents.splice(index, 1);
          purged += 1;
        }
      }
      return Promise.resolve(purged);
    },

    gcAbandonedAssetUploads(before, limit) {
      const cutoff = Date.parse(before);
      const timestamp = Date.now();
      const pending = [...new Map([...assets.values()].map((asset) => [asset.id, asset])).values()]
        .filter(
          (asset) =>
            ((asset.status === "pending" && Date.parse(asset.createdAt) < cutoff) ||
              asset.status === "deleting") &&
            (asset.uploadAuthorizedUntil === null ||
              Date.parse(asset.uploadAuthorizedUntil) <= timestamp) &&
            ![...objectWriteLeases.values()].some(
              (lease) =>
                lease.accountId === asset.accountId &&
                (lease.objectKey === asset.objectKey ||
                  lease.objectKey === asset.uploadObjectKey) &&
                Date.parse(lease.expiresAt) > timestamp,
            ),
        )
        .slice(0, Math.max(0, Math.min(Math.floor(limit), 1_000)));
      for (const asset of pending) {
        asset.status = "deleting";
        asset.deletedAt ??= new Date(timestamp).toISOString();
      }
      return Promise.resolve(
        pending.map((asset) => ({
          id: asset.id,
          objectKeys: [...new Set([asset.uploadObjectKey, asset.objectKey])],
        })),
      );
    },

    finishAbandonedAssetUploadGc(ids) {
      const timestamp = Date.now();
      for (const id of ids) {
        const asset = [...assets.values()].find((candidate) => candidate.id === id);
        if (
          asset === undefined ||
          asset.status !== "deleting" ||
          asset.deletedAt === null ||
          Date.parse(asset.deletedAt) > timestamp - 24 * 60 * 60_000 ||
          (asset.uploadAuthorizedUntil !== null &&
            Date.parse(asset.uploadAuthorizedUntil) > timestamp) ||
          [...objectWriteLeases.values()].some(
            (lease) =>
              lease.accountId === asset.accountId &&
              (lease.objectKey === asset.objectKey || lease.objectKey === asset.uploadObjectKey) &&
              Date.parse(lease.expiresAt) > timestamp,
          )
        ) {
          continue;
        }
        assets.delete(`${asset.accountId}:${asset.id}`);
        assets.delete(`upload:${asset.accountId}:${asset.uploadId}`);
      }
      return Promise.resolve();
    },

    claimReadyAssetUploadCleanup(limit) {
      const timestamp = Date.now();
      const ready = [...new Map([...assets.values()].map((asset) => [asset.id, asset])).values()]
        .filter(
          (asset) =>
            asset.status === "ready" &&
            !cleanedReadyAssetUploads.has(asset.id) &&
            (asset.uploadAuthorizedUntil === null ||
              Date.parse(asset.uploadAuthorizedUntil) <= timestamp) &&
            ![...objectWriteLeases.values()].some(
              (lease) =>
                lease.accountId === asset.accountId &&
                lease.objectKey === asset.uploadObjectKey &&
                Date.parse(lease.expiresAt) > timestamp,
            ),
        )
        .slice(0, Math.max(0, Math.min(Math.floor(limit), 1_000)));
      return Promise.resolve(
        ready.map((asset) => ({
          id: asset.id,
          uploadObjectKey: asset.uploadObjectKey,
        })),
      );
    },

    finishReadyAssetUploadCleanup(ids) {
      const timestamp = Date.now();
      for (const id of ids) {
        const asset = [...assets.values()].find((candidate) => candidate.id === id);
        if (
          asset?.status === "ready" &&
          (asset.uploadAuthorizedUntil === null ||
            Date.parse(asset.uploadAuthorizedUntil) <= timestamp) &&
          ![...objectWriteLeases.values()].some(
            (lease) =>
              lease.accountId === asset.accountId &&
              lease.objectKey === asset.uploadObjectKey &&
              Date.parse(lease.expiresAt) > timestamp,
          )
        ) {
          cleanedReadyAssetUploads.add(id);
        }
      }
      return Promise.resolve();
    },

    async claimDeletedBookAssets(userId, bookIds) {
      const deletedBookIds = new Set(bookIds);
      const syncV2 = options.syncV2;
      const verifiedDeletedBookIds =
        syncV2 === undefined
          ? deletedBookIds
          : new Set(
              (
                await Promise.all(
                  [...deletedBookIds].map(async (bookId) => ({
                    bookId,
                    operation: await syncV2.latestEntityOperation(userId, "book", bookId),
                  })),
                )
              )
                .filter((entry) => entry.operation === "delete")
                .map((entry) => entry.bookId),
            );
      const candidates = [
        ...new Map([...assets.values()].map((asset) => [asset.id, asset])).values(),
      ].filter(
        (asset) =>
          asset.accountId === userId &&
          asset.bookId !== null &&
          verifiedDeletedBookIds.has(asset.bookId) &&
          (asset.status === "pending" || asset.status === "ready" || asset.status === "deleting"),
      );
      const announced = candidates.filter((asset) => asset.status === "ready");
      if (syncV2 !== undefined && announced.length > 0) {
        const deletions = await Promise.all(
          announced.map(async (asset) => {
            const entityType: SyncEntityType =
              asset.kind === "transcriptRevision" ? "transcript" : "asset";
            const entityId =
              asset.kind === "transcriptRevision" && asset.revisionId !== null
                ? asset.revisionId
                : asset.id;
            return {
              mutationId: crypto.randomUUID(),
              entityType,
              entityId,
              operation: "delete" as const,
              baseRevision: await syncV2.currentRevision(userId, entityType, entityId),
              occurredAt: now(),
              payload: {},
            };
          }),
        );
        await syncV2.push({
          userId,
          deviceId: "00000000-0000-4000-8000-000000000000",
          batchId: crypto.randomUUID(),
          mutations: deletions,
        });
      }
      for (const asset of candidates) {
        asset.status = "deleting";
        asset.deletedAt ??= now();
      }
      return candidates.map((asset) => ({
        id: asset.id,
        objectKey: asset.objectKey,
        uploadObjectKey: asset.uploadObjectKey,
        deleteAfter: latestDeleteAfter(asset, objectWriteLeases),
      }));
    },

    cleanupObsoleteV1Data(_userId, execute) {
      return Promise.resolve({
        changes: 0,
        outcomes: 0,
        batches: 0,
        transcriptRevisions: 0,
        transcriptSegments: 0,
        assets: 0,
        objectKeys: [],
        executed: execute,
      });
    },

    async deleteAccountData(userId) {
      for (const [key, asset] of assets) {
        if (asset.accountId === userId) assets.delete(key);
      }
      for (let index = assistantResults.length - 1; index >= 0; index -= 1) {
        if (assistantResults[index]?.accountId === userId) assistantResults.splice(index, 1);
      }
      const profile = await options.identity?.setAccountStatus(userId, "deleted");
      analyticsPreferences.delete(userId);
      return profile !== undefined;
    },

    async requestAccountDeletion(userId, reason, requestId) {
      const timestamp = now();
      const request: OpsPrivacyRequest = {
        id: crypto.randomUUID(),
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
      };
      const job: OpsJob = {
        id: crypto.randomUUID(),
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
      };
      privacyRequests.set(request.id, request);
      jobs.set(job.id, job);
      await options.identity?.setAccountStatus(userId, "deletion_pending");
      audit.push({
        id: crypto.randomUUID(),
        actorId: userId,
        action: "request_deletion",
        resourceType: "account",
        resourceId: userId,
        reason: "User requested account deletion.",
        traceId: requestId,
        metadata: {},
        createdAt: timestamp,
      });
      return { request: { ...request }, job: { ...job, payload: {} } };
    },

    accountObjectKeys(userId) {
      return Promise.resolve(
        [
          ...new Set(
            [...assets.values()]
              .filter((asset) => asset.accountId === userId)
              .flatMap((asset) => [asset.objectKey, asset.uploadObjectKey]),
          ),
        ].sort(),
      );
    },

    beginObjectWrite(userId, objectKey) {
      const lease: ObjectWriteLease = {
        id: crypto.randomUUID(),
        accountId: userId,
        objectKey,
        expiresAt: new Date(Date.now() + 30 * 60_000).toISOString(),
      };
      objectWriteLeases.set(lease.id, lease);
      return Promise.resolve({ ...lease });
    },

    beginAssetObjectWrite(userId, assetId, objectKey) {
      const asset = assets.get(`${userId}:${assetId}`);
      if (
        asset === undefined ||
        asset.status !== "pending" ||
        (objectKey !== asset.objectKey && objectKey !== asset.uploadObjectKey)
      ) {
        return Promise.resolve(undefined);
      }
      const lease: ObjectWriteLease = {
        id: crypto.randomUUID(),
        accountId: userId,
        objectKey,
        expiresAt: new Date(Date.now() + 30 * 60_000).toISOString(),
      };
      objectWriteLeases.set(lease.id, lease);
      return Promise.resolve({ ...lease });
    },

    finishObjectWrite(leaseId) {
      objectWriteLeases.delete(leaseId);
      return Promise.resolve();
    },

    accountObjectWriteLeases(userId) {
      return Promise.resolve(
        [...objectWriteLeases.values()]
          .filter((lease) => lease.accountId === userId)
          .map((lease) => ({ ...lease })),
      );
    },

    async recordAssistantUse(userId, input) {
      const timestamp = now();
      const existingIndex = assistantResults.findIndex(
        (result) => result.accountId === userId && result.id === input.resultId,
      );
      const prior = existingIndex < 0 ? undefined : assistantResults[existingIndex];
      const created: OpsAssistantResult = {
        id: input.resultId,
        accountId: userId,
        task: input.task,
        resultKind: input.resultKind ?? null,
        status: input.status ?? (prior === undefined ? "pending" : "replaced"),
        cacheEntryId: input.cacheEntryId,
        outputText: input.outputText,
        privateContent: input.privateContent ?? null,
        language: input.language ?? null,
        sourceText: input.sourceText ?? null,
        contextText: input.contextText ?? null,
        bookTitle: input.bookTitle ?? null,
        chapterTitle: input.chapterTitle ?? null,
        targetId: input.targetId ?? null,
        timestampSeconds: input.timestampSeconds ?? null,
        replacedText: null,
        replacedModel: null,
        privateEditedOutput: null,
        privateNotes: null,
        model: input.model ?? null,
        promptVersion: input.promptVersion ?? null,
        modelPolicyHash: input.modelPolicyHash ?? null,
        history: [
          ...(prior?.history ?? []),
          {
            status: input.status ?? (prior === undefined ? "pending" : "replaced"),
            outputText: input.outputText,
            privateContent: input.privateContent ?? null,
            resultKind: input.resultKind ?? null,
            language: input.language ?? null,
            sourceText: input.sourceText ?? null,
            contextText: input.contextText ?? null,
            bookTitle: input.bookTitle ?? null,
            chapterTitle: input.chapterTitle ?? null,
            targetId: input.targetId ?? null,
            timestampSeconds: input.timestampSeconds ?? null,
            model: input.model ?? null,
            promptVersion: input.promptVersion ?? null,
            modelPolicyHash: input.modelPolicyHash ?? null,
            sharedCacheReference:
              input.cacheEntryId === null ? null : { entryId: input.cacheEntryId },
            recordedAt: timestamp,
          },
        ],
        createdAt: prior?.createdAt ?? timestamp,
        updatedAt: timestamp,
        decidedAt: null,
      };
      if (existingIndex < 0) assistantResults.push(created);
      else assistantResults[existingIndex] = created;
      if (options.syncV2 !== undefined && input.resultKind !== undefined) {
        await options.syncV2.push({
          userId,
          deviceId: "00000000-0000-4000-8000-000000000000",
          batchId: crypto.randomUUID(),
          mutations: [
            {
              mutationId: crypto.randomUUID(),
              entityType: "assistant_result",
              entityId: input.resultId,
              operation: "upsert",
              baseRevision: prior?.history.length ?? 0,
              occurredAt: timestamp,
              payload: {
                result: assistantResultSyncPayload(created),
                vocabulary: [],
              },
            },
          ],
        });
      }
      return { ...created, history: created.history.map((item) => ({ ...item })) };
    },

    listAssistantResults(userId) {
      return Promise.resolve(
        assistantResults
          .filter((result) => result.accountId === userId)
          .map((result) => ({ ...result, history: result.history.map((item) => ({ ...item })) })),
      );
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

    async readOperatorSettings() {
      return { ok: true, value: await this.getOperatorSettings() };
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
    listAssets: () => Promise.resolve([]),
    getAssetByContent: () => Promise.resolve(undefined),
    getAssetByUpload: () => Promise.resolve(undefined),
    authorizeAssetUpload: () => Promise.resolve(undefined),
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
    claimJobs: fail,
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
    analyticsPreference: () =>
      Promise.resolve({
        operatorLearningAnalyticsEnabled: false,
        updatedAt: new Date(0).toISOString(),
      }),
    putAnalyticsPreference: fail,
    userProgressSummary: () => Promise.resolve(undefined),
    purgeExpiredUserProgressSummaries: fail,
    purgeExpiredProductEvents: fail,
    gcAbandonedAssetUploads: fail,
    finishAbandonedAssetUploadGc: fail,
    claimReadyAssetUploadCleanup: fail,
    finishReadyAssetUploadCleanup: fail,
    claimDeletedBookAssets: fail,
    cleanupObsoleteV1Data: fail,
    deleteAccountData: fail,
    requestAccountDeletion: fail,
    accountObjectKeys: fail,
    beginObjectWrite: fail,
    beginAssetObjectWrite: fail,
    finishObjectWrite: fail,
    accountObjectWriteLeases: fail,
    recordAssistantUse: (_userId, input) =>
      Promise.resolve({
        id: input.resultId,
        accountId: "",
        task: input.task,
        resultKind: null,
        status: "pending",
        cacheEntryId: input.cacheEntryId,
        outputText: input.outputText,
        privateContent: input.privateContent ?? null,
        language: null,
        sourceText: null,
        contextText: null,
        bookTitle: null,
        chapterTitle: null,
        targetId: null,
        timestampSeconds: null,
        replacedText: null,
        replacedModel: null,
        privateEditedOutput: null,
        privateNotes: null,
        model: input.model ?? null,
        promptVersion: input.promptVersion ?? null,
        modelPolicyHash: input.modelPolicyHash ?? null,
        history: [],
        createdAt: new Date(0).toISOString(),
        updatedAt: new Date(0).toISOString(),
        decidedAt: null,
      }),
    listAssistantResults: () => Promise.resolve([]),
    putChatMessage: () => Promise.resolve(),
    getChatMessage: () => Promise.resolve(undefined),
    getOperatorSettings: () => Promise.resolve(undefined),
    readOperatorSettings: () => Promise.resolve({ ok: false, error: "unavailable" }),
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
    async createAsset(userId, input) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/reserve_v2_asset_upload",
        body: {
          p_upload_id: input.uploadId,
          p_user_id: userId,
          p_kind: input.kind,
          p_content_type: input.contentType,
          p_encoding: input.encoding,
          p_compressed_bytes: input.compressedBytes,
          p_original_bytes: input.originalBytes,
          p_sha256: input.sha256,
          p_object_key: input.objectKey,
          p_upload_object_key: input.uploadObjectKey,
          p_revision_id: input.revisionId,
          p_book_id: input.bookId,
          p_chapter_id: input.chapterId,
          p_segment_count: input.segmentCount,
        },
      });
      const asset = mapAssetManifestRow(restRow(response.body));
      if (!restOk(response) || asset === undefined) {
        const detail = restErrorDetail(response.body);
        if (detail?.includes("pending_asset_count_exceeded") === true) {
          throw new AssetReservationError("pending_asset_count_exceeded");
        }
        if (detail?.includes("cloud_media_quota_exceeded") === true) {
          throw new AssetReservationError("cloud_media_quota_exceeded");
        }
        if (detail?.includes("asset book is deleted") === true) {
          throw new AssetReservationError("asset_book_deleted");
        }
        throw new RestPersistenceError(502, "Postgres did not create the asset manifest.");
      }
      return asset;
    },
    async getAsset(userId, assetId) {
      return fetchAssetManifest(rest, userId, { id: assetId });
    },
    async authorizeAssetUpload(userId, uploadId, authorizedUntil) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/authorize_v2_asset_upload",
        body: {
          p_user_id: userId,
          p_upload_id: uploadId,
          p_authorized_until: authorizedUntil,
        },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not authorize the asset upload.");
      }
      return mapAssetManifestRow(restRow(response.body));
    },
    async listAssets(userId, filter) {
      const response = await rest.request({
        method: "GET",
        path: "/asset_manifests_v2",
        query: {
          user_id: `eq.${userId}`,
          status: "eq.ready",
          ...(filter?.kind === undefined ? {} : { kind: `eq.${filter.kind}` }),
          ...(filter?.bookId === undefined ? {} : { book_id: `eq.${filter.bookId}` }),
          ...(filter?.chapterId === undefined ? {} : { chapter_id: `eq.${filter.chapterId}` }),
          order: "created_at.asc",
          limit: "500",
        },
      });
      if (!restOk(response) || isErrorBody(response.body)) return [];
      return restRows(response.body)
        .map(mapAssetManifestRow)
        .filter((asset): asset is OpsAsset => asset !== undefined);
    },
    async getAssetByContent(userId, kind, sha256) {
      return fetchAssetManifest(rest, userId, { kind, sha256 });
    },
    async getAssetByUpload(userId, uploadId) {
      return fetchAssetManifest(rest, userId, { upload_id: uploadId });
    },
    async completeAsset(userId, uploadId) {
      const stored = await fetchAssetManifest(rest, userId, { upload_id: uploadId });
      if (stored === undefined) return undefined;
      const response = await rest.request({
        method: "POST",
        path: "/rpc/complete_v2_asset_and_publish",
        body: {
          p_user_id: userId,
          p_upload_id: uploadId,
          p_verified_compressed_bytes: stored.compressedBytes,
          p_verified_sha256: stored.sha256,
        },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres did not publish the verified asset.");
      }
      return fetchAssetManifest(rest, userId, { upload_id: uploadId });
    },
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
    async createJob(input) {
      const timestamp = new Date().toISOString();
      const response = await rest.request({
        method: "POST",
        path: "/assistant_jobs",
        prefer: "return=representation",
        body: {
          id: crypto.randomUUID(),
          user_id: input.accountId,
          kind: input.kind,
          status: "queued",
          attempts: 0,
          max_attempts: 5,
          last_error: null,
          payload: input.payload ?? {},
          created_at: timestamp,
          updated_at: timestamp,
        },
      });
      const mapped = mappedWriteRow(response, mapJobRow);
      if (mapped === undefined) {
        throw new RestPersistenceError(502, "Postgres did not create the job.");
      }
      return mapped;
    },
    async getJob(id) {
      const response = await rest.request({
        method: "GET",
        path: "/assistant_jobs",
        query: { id: `eq.${id}`, select: "*", limit: "1" },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not load the job.");
      }
      return mapJobRow(restRow(response.body));
    },
    async listJobs(filter) {
      const query: Record<string, string> = { select: "*", order: "created_at.asc,id.asc" };
      if ((filter?.status?.trim() ?? "") !== "") {
        query.status = `eq.${filter?.status?.trim() ?? ""}`;
      }
      const response = await rest.request({ method: "GET", path: "/assistant_jobs", query });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not list jobs.");
      }
      return restRows(response.body).flatMap((row) => {
        const mapped = mapJobRow(row);
        return mapped === undefined ? [] : [mapped];
      });
    },
    async claimJobs(limit = 16) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/claim_assistant_jobs",
        body: { p_limit: Math.max(1, Math.min(100, Math.trunc(limit))) },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not claim jobs.");
      }
      const rows = restRows(response.body);
      const mapped = rows.map(mapJobRow);
      if (mapped.some((job) => job === undefined)) {
        throw new RestPersistenceError(502, "Postgres returned an invalid claimed job.");
      }
      return mapped.filter((job): job is OpsJob => job !== undefined);
    },
    async updateJob(id, patch) {
      const body: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (patch.status !== undefined) body.status = patch.status;
      if (patch.attempts !== undefined) body.attempts = patch.attempts;
      if (patch.lastError !== undefined) body.last_error = patch.lastError;
      if (patch.startedAt !== undefined) body.started_at = patch.startedAt;
      if (patch.finishedAt !== undefined) body.finished_at = patch.finishedAt;
      if (patch.payload !== undefined) body.payload = patch.payload;
      if (patch.status !== undefined && patch.status !== "running") body.lease_expires_at = null;
      const response = await rest.request({
        method: "PATCH",
        path: "/assistant_jobs",
        query: { id: `eq.${id}` },
        prefer: "return=representation",
        body,
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not update the job.");
      }
      return mapJobRow(restRow(response.body));
    },
    async recordAssistantUse(userId, input) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/record_user_assistant_result",
        body: {
          p_user_id: userId,
          p_result: {
            id: input.resultId,
            task: input.task,
            status: input.status ?? "pending",
            cacheEntryId: input.cacheEntryId,
            outputText: input.outputText.slice(0, 20000),
            ...(input.privateContent === undefined ? {} : { privateContent: input.privateContent }),
            ...(input.resultKind === undefined ? {} : { resultKind: input.resultKind }),
            ...(input.language === undefined ? {} : { language: input.language }),
            ...(input.sourceText === undefined
              ? {}
              : { sourceText: input.sourceText.slice(0, 20000) }),
            ...(input.contextText === undefined
              ? {}
              : { contextText: input.contextText.slice(0, 20000) }),
            ...(input.bookTitle === undefined ? {} : { bookTitle: input.bookTitle }),
            ...(input.chapterTitle === undefined ? {} : { chapterTitle: input.chapterTitle }),
            ...(input.targetId === undefined ? {} : { targetId: input.targetId }),
            ...(input.timestampSeconds === undefined
              ? {}
              : { timestampSeconds: input.timestampSeconds }),
            ...(input.model === undefined ? {} : { model: input.model }),
            ...(input.promptVersion === undefined ? {} : { promptVersion: input.promptVersion }),
            ...(input.modelPolicyHash === undefined
              ? {}
              : { modelPolicyHash: input.modelPolicyHash }),
            createdAt: new Date().toISOString(),
          },
        },
      });
      const mapped = mapAssistantResultRow(restRow(response.body));
      if (!restOk(response) || mapped === undefined) {
        throw new RestPersistenceError(
          502,
          "Postgres did not persist the private assistant result.",
        );
      }
      return mapped;
    },
    async listAssistantResults(userId) {
      const response = await rest.request({
        method: "GET",
        path: "/user_assistant_results",
        query: { user_id: `eq.${userId}`, select: "*", order: "created_at.asc,id.asc" },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not list private assistant results.");
      }
      return restRows(response.body)
        .map(mapAssistantResultRow)
        .filter((result): result is OpsAssistantResult => result !== undefined);
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
    async analyticsPreference(userId) {
      const response = await rest.request({
        method: "GET",
        path: "/user_analytics_preferences",
        query: {
          user_id: `eq.${userId}`,
          select: "operator_learning_analytics_enabled,updated_at",
          limit: "1",
        },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        return memory.analyticsPreference(userId);
      }
      return mapAnalyticsPreference(restRow(response.body)) ?? memory.analyticsPreference(userId);
    },
    async putAnalyticsPreference(userId, enabled) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/set_user_analytics_preference",
        body: { p_user_id: userId, p_enabled: enabled },
      });
      const mapped = mapAnalyticsPreference(isRecord(response.body) ? response.body : undefined);
      if (!restOk(response) || mapped === undefined) {
        throw new RestPersistenceError(
          response.status === 0 ? 502 : response.status,
          "Postgres did not store the analytics preference.",
        );
      }
      return mapped;
    },
    async userProgressSummary(userId) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/admin_user_progress_summary",
        body: { p_user_id: userId },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(
          response.status === 0 ? 502 : response.status,
          "Postgres could not load the user progress summary.",
        );
      }
      if (response.body === null) {
        return undefined;
      }
      const mapped = mapUserProgressSummary(response.body);
      if (mapped === undefined) {
        throw new RestPersistenceError(502, "Postgres returned an invalid user progress summary.");
      }
      return mapped;
    },
    async purgeExpiredUserProgressSummaries() {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/purge_expired_user_progress_summaries",
        body: {},
      });
      const count = finiteNumber(response.body);
      if (!restOk(response) || count === undefined || count < 0) {
        throw new RestPersistenceError(
          response.status === 0 ? 502 : response.status,
          "Postgres could not purge expired user progress summaries.",
        );
      }
      return Math.floor(count);
    },
    async purgeExpiredProductEvents() {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/purge_expired_product_events",
        body: {},
      });
      const count = finiteNumber(response.body);
      if (!restOk(response) || count === undefined || count < 0) {
        throw new RestPersistenceError(
          response.status === 0 ? 502 : response.status,
          "Postgres could not purge expired product events.",
        );
      }
      return Math.floor(count);
    },
    async gcAbandonedAssetUploads(before, limit) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/gc_abandoned_v2_uploads",
        body: { p_before: before, p_limit: Math.max(0, Math.min(Math.floor(limit), 1_000)) },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not claim abandoned asset uploads.");
      }
      return restRows(response.body).flatMap((row) =>
        typeof row.id === "string"
          ? [
              {
                id: row.id,
                objectKeys: [
                  ...new Set(
                    [row.upload_object_key, row.object_key].filter(
                      (key): key is string => typeof key === "string" && key !== "",
                    ),
                  ),
                ],
              },
            ]
          : [],
      );
    },
    async finishAbandonedAssetUploadGc(ids) {
      if (ids.length === 0) return;
      const response = await rest.request({
        method: "POST",
        path: "/rpc/finish_v2_asset_upload_gc",
        body: { p_ids: ids },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not finish asset upload GC.");
      }
    },
    async claimReadyAssetUploadCleanup(limit) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/claim_v2_ready_upload_cleanup",
        body: { p_limit: Math.max(0, Math.min(Math.floor(limit), 1_000)) },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not claim ready upload cleanup.");
      }
      return restRows(response.body).flatMap((row) =>
        typeof row.id === "string" && typeof row.upload_object_key === "string"
          ? [{ id: row.id, uploadObjectKey: row.upload_object_key }]
          : [],
      );
    },
    async finishReadyAssetUploadCleanup(ids) {
      if (ids.length === 0) return;
      const response = await rest.request({
        method: "POST",
        path: "/rpc/finish_v2_ready_upload_cleanup",
        body: { p_ids: ids },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not finish ready upload cleanup.");
      }
    },
    async claimDeletedBookAssets(userId, bookIds) {
      if (bookIds.length === 0) return [];
      const response = await rest.request({
        method: "POST",
        path: "/rpc/claim_deleted_book_v2_assets",
        body: { p_user_id: userId, p_book_ids: [...new Set(bookIds)] },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not claim deleted-book assets.");
      }
      const rows = restRows(response.body);
      const claimed = rows.flatMap((row) =>
        typeof row.id === "string" &&
        typeof row.object_key === "string" &&
        typeof row.upload_object_key === "string"
          ? [
              {
                id: row.id,
                objectKey: row.object_key,
                uploadObjectKey: row.upload_object_key,
                deleteAfter: typeof row.delete_after === "string" ? row.delete_after : null,
              },
            ]
          : [],
      );
      if (claimed.length !== rows.length) {
        throw new RestPersistenceError(502, "Postgres returned invalid deleted-book asset keys.");
      }
      return claimed;
    },
    async cleanupObsoleteV1Data(userId, execute) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/cleanup_obsolete_v1_data",
        body: { p_user_id: userId, p_execute: execute },
      });
      if (!restOk(response) || !isRecord(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not inspect obsolete v1 data.");
      }
      const body = response.body;
      const count = (key: string) => Math.max(0, finiteNumber(body[key]) ?? 0);
      return {
        changes: count("changes"),
        outcomes: count("outcomes"),
        batches: count("batches"),
        transcriptRevisions: count("transcriptRevisions"),
        transcriptSegments: count("transcriptSegments"),
        assets: count("assets"),
        objectKeys: Array.isArray(body.objectKeys)
          ? body.objectKeys.filter((key): key is string => typeof key === "string")
          : [],
        executed: body.executed === true,
      };
    },
    async deleteAccountData(userId) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/delete_account_data",
        body: { p_user_id: userId },
      });
      if (!restOk(response) || typeof response.body !== "boolean") {
        throw new RestPersistenceError(
          response.status === 0 ? 502 : response.status,
          "Postgres could not erase the account data.",
        );
      }
      return response.body;
    },
    async requestAccountDeletion(userId, reason, requestId) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/request_account_deletion",
        body: { p_user_id: userId, p_reason: reason, p_request_id: requestId },
      });
      if (!restOk(response) || !isRecord(response.body)) {
        throw new RestPersistenceError(502, "Postgres did not queue account deletion.");
      }
      const request = mapPrivacyRow(
        isRecord(response.body.privacy_request) ? response.body.privacy_request : undefined,
      );
      const job = mapJobRow(isRecord(response.body.job) ? response.body.job : undefined);
      if (request === undefined || job === undefined) {
        throw new RestPersistenceError(502, "Postgres returned an invalid deletion request.");
      }
      return { request, job };
    },
    async accountObjectKeys(userId) {
      const [assets, transcripts, v2] = await Promise.all([
        rest.request({
          method: "GET",
          path: "/book_assets",
          query: { user_id: `eq.${userId}`, select: "object_key" },
        }),
        rest.request({
          method: "GET",
          path: "/transcript_revisions",
          query: { user_id: `eq.${userId}`, select: "object_key" },
        }),
        rest.request({
          method: "GET",
          path: "/asset_manifests_v2",
          query: { user_id: `eq.${userId}`, select: "object_key,upload_object_key" },
        }),
      ]);
      if (
        !restOk(assets) ||
        isErrorBody(assets.body) ||
        !restOk(transcripts) ||
        isErrorBody(transcripts.body) ||
        !restOk(v2) ||
        isErrorBody(v2.body)
      ) {
        throw new RestPersistenceError(502, "Postgres could not enumerate account objects.");
      }
      return [
        ...new Set(
          [...restRows(assets.body), ...restRows(transcripts.body), ...restRows(v2.body)].flatMap(
            (row) =>
              [row.object_key, row.upload_object_key].filter(
                (key): key is string => typeof key === "string" && key !== "",
              ),
          ),
        ),
      ].sort();
    },
    async beginObjectWrite(userId, objectKey) {
      const response = await rest.request({
        method: "POST",
        path: "/object_write_leases",
        prefer: "return=representation",
        body: { user_id: userId, object_key: objectKey },
      });
      const lease = mapObjectWriteLease(restRow(response.body));
      if (!restOk(response) || lease === undefined) {
        throw new RestPersistenceError(502, "Postgres could not begin the object write.");
      }
      return lease;
    },
    async beginAssetObjectWrite(userId, assetId, objectKey) {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/begin_v2_asset_object_write",
        body: { p_user_id: userId, p_asset_id: assetId, p_object_key: objectKey },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not begin the asset object write.");
      }
      return mapObjectWriteLease(restRow(response.body));
    },
    async finishObjectWrite(leaseId) {
      const response = await rest.request({
        method: "DELETE",
        path: "/object_write_leases",
        query: { id: `eq.${leaseId}` },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not finish the object write.");
      }
    },
    async accountObjectWriteLeases(userId) {
      const response = await rest.request({
        method: "GET",
        path: "/object_write_leases",
        query: { user_id: `eq.${userId}`, select: "*", order: "created_at" },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        throw new RestPersistenceError(502, "Postgres could not enumerate object writes.");
      }
      const leases = restRows(response.body).map(mapObjectWriteLease);
      if (leases.some((lease) => lease === undefined)) {
        throw new RestPersistenceError(502, "Postgres returned an invalid object write lease.");
      }
      return leases.filter((lease): lease is ObjectWriteLease => lease !== undefined);
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
      const [response, readyAssets] = await Promise.all([
        rest.request({
          method: "GET",
          path: "/quota_limits",
          query: { select: "*" },
        }),
        rest.request({
          method: "GET",
          path: "/asset_manifests_v2",
          query: {
            user_id: `eq.${userId}`,
            status: "eq.ready",
            select: "compressed_bytes",
          },
        }),
      ]);
      if (response.status >= 400 || response.status === 0) {
        return memory.quotasFor(userId);
      }
      const rows = restRows(response.body);
      for (const row of rows) {
        if (typeof row.key === "string" && isQuotaKey(row.key)) {
          const limit = finiteNumber(row.limit_value);
          if (limit !== undefined) {
            await memory.patchQuota(row.key, limit);
          }
        }
      }
      const quotas = await memory.quotasFor(userId);
      if (!restOk(readyAssets) || isErrorBody(readyAssets.body)) return quotas;
      const readyBytes = restRows(readyAssets.body).reduce(
        (total, row) => total + (finiteNumber(row.compressed_bytes) ?? 0),
        0,
      );
      return quotas.map((quota) =>
        quota.key === "cloud_media_bytes" ? { ...quota, used: readyBytes } : quota,
      );
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
    async readOperatorSettings() {
      const response = await rest.request({
        method: "GET",
        path: "/operator_settings",
        query: { select: "*", id: "eq.default", limit: "1" },
      });
      if (!restOk(response) || isErrorBody(response.body)) {
        return { ok: false, error: "unavailable" };
      }
      if (!Array.isArray(response.body)) {
        return { ok: false, error: "invalid_response" };
      }
      if (response.body.length === 0) {
        return { ok: true, value: undefined };
      }
      const value = mapOperatorSettingsRow(restRow(response.body));
      return value === undefined ? { ok: false, error: "invalid_response" } : { ok: true, value };
    },
    async putOperatorSettings(input) {
      return persistOperatorSettings(rest, input);
    },
    async listAudit(filter) {
      const query: Record<string, string> = {
        select: "*",
        order: "created_at.desc,id.desc",
        limit: String(Math.min(Math.max(filter?.limit ?? 100, 1), 5001)),
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
      if ((filter?.resourceId?.trim() ?? "") !== "") {
        query.resource_id = `eq.${filter?.resourceId?.trim() ?? ""}`;
      }
      if (filter?.cursor !== undefined) {
        query.or = timeIdCursorQuery(filter.cursor);
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
        order: "created_at.desc,id.desc",
        limit: String(Math.min(Math.max(filter?.limit ?? 100, 1), 5001)),
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
      const from = filter?.from?.trim() ?? "";
      const to = filter?.to?.trim() ?? "";
      if (from !== "" && to !== "") query.and = `(created_at.gte.${from},created_at.lt.${to})`;
      else if (from !== "") query.created_at = `gte.${from}`;
      else if (to !== "") query.created_at = `lt.${to}`;
      if (filter?.cursor !== undefined) {
        query.or = timeIdCursorQuery(filter.cursor);
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

function mapAnalyticsPreference(
  row: Record<string, unknown> | undefined,
): AnalyticsPreferenceRecord | undefined {
  const enabled = row?.operator_learning_analytics_enabled ?? row?.operatorLearningAnalyticsEnabled;
  if (row === undefined || typeof enabled !== "boolean") {
    return undefined;
  }
  return {
    operatorLearningAnalyticsEnabled: enabled,
    updatedAt:
      typeof row.updated_at === "string"
        ? row.updated_at
        : typeof row.updatedAt === "string"
          ? row.updatedAt
          : new Date(0).toISOString(),
  };
}

function mapUserProgressSummary(value: unknown): UserProgressSummaryRecord | undefined {
  if (
    !isRecord(value) ||
    !isRecord(value.sync) ||
    (value.reading !== null && !isRecord(value.reading)) ||
    (value.review !== null && !isRecord(value.review)) ||
    (value.learning !== null && !isRecord(value.learning))
  ) {
    return undefined;
  }
  const sync = value.sync;
  const reading = isRecord(value.reading) ? value.reading : null;
  const review = isRecord(value.review) ? value.review : null;
  const learning = isRecord(value.learning) ? value.learning : null;
  const device = isRecord(sync.lastDevice) ? sync.lastDevice : undefined;
  return {
    generatedAt:
      typeof value.generatedAt === "string" ? value.generatedAt : new Date().toISOString(),
    expiresAt: typeof value.expiresAt === "string" ? value.expiresAt : null,
    sync: {
      lastSuccessfulAt: typeof sync.lastSuccessfulAt === "string" ? sync.lastSuccessfulAt : null,
      lastDevice:
        device !== undefined && typeof device.id === "string" && typeof device.platform === "string"
          ? {
              id: device.id,
              platform: device.platform,
              name: typeof device.name === "string" ? device.name : null,
            }
          : null,
      entityCounts: Array.isArray(sync.entityCounts)
        ? sync.entityCounts.flatMap((item): Array<{ entityType: string; count: number }> =>
            isRecord(item) && typeof item.entityType === "string"
              ? [{ entityType: item.entityType, count: asNonNegativeInt(item.count) }]
              : [],
          )
        : [],
      pendingCount:
        sync.pendingCount === null || sync.pendingCount === undefined
          ? null
          : asNonNegativeInt(sync.pendingCount),
      conflictCount: asNonNegativeInt(sync.conflictCount),
    },
    reading:
      reading === null
        ? null
        : {
            lastActivityAt:
              typeof reading.lastActivityAt === "string" ? reading.lastActivityAt : null,
            activeBooks: asNonNegativeInt(reading.activeBooks),
            completedBooks: asNonNegativeInt(reading.completedBooks),
            currentChapter:
              reading.currentChapter === null || reading.currentChapter === undefined
                ? null
                : asNonNegativeInt(reading.currentChapter),
            completionPercent:
              typeof reading.completionPercent === "number" &&
              Number.isFinite(reading.completionPercent)
                ? Math.min(100, Math.max(0, reading.completionPercent))
                : null,
          },
    review:
      review === null
        ? null
        : {
            due: asNonNegativeInt(review.due),
            new: asNonNegativeInt(review.new),
            learning: asNonNegativeInt(review.learning),
            reviewsLast30Days: asNonNegativeInt(review.reviewsLast30Days),
            reviewsPerActiveDay:
              typeof review.reviewsPerActiveDay === "number" ? review.reviewsPerActiveDay : 0,
            retentionRate:
              typeof review.retentionRate === "number"
                ? Math.min(1, Math.max(0, review.retentionRate))
                : null,
            streakDays: asNonNegativeInt(review.streakDays),
          },
    learning:
      learning === null
        ? null
        : {
            vocabulary: asNonNegativeInt(learning.vocabulary),
            known: asNonNegativeInt(learning.known),
            learning: asNonNegativeInt(learning.learning),
            aiUsesLast30Days: asNonNegativeInt(learning.aiUsesLast30Days),
            aiUsesByFeature: Array.isArray(learning.aiUsesByFeature)
              ? learning.aiUsesByFeature.flatMap(
                  (item): Array<{ feature: string; count: number }> =>
                    isRecord(item) && typeof item.feature === "string"
                      ? [{ feature: item.feature, count: asNonNegativeInt(item.count) }]
                      : [],
                )
              : [],
          },
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

function mapObjectWriteLease(
  row: Record<string, unknown> | undefined,
): ObjectWriteLease | undefined {
  if (
    row === undefined ||
    isErrorBody(row) ||
    typeof row.id !== "string" ||
    typeof row.user_id !== "string" ||
    typeof row.object_key !== "string" ||
    typeof row.expires_at !== "string"
  ) {
    return undefined;
  }
  return {
    id: row.id,
    accountId: row.user_id,
    objectKey: row.object_key,
    expiresAt: row.expires_at,
  };
}

function mapJobRow(row: Record<string, unknown> | undefined): OpsJob | undefined {
  if (
    row === undefined ||
    isErrorBody(row) ||
    typeof row.id !== "string" ||
    typeof row.kind !== "string" ||
    typeof row.status !== "string"
  ) {
    return undefined;
  }
  const status: JobStatus | undefined =
    row.status === "queued" ||
    row.status === "running" ||
    row.status === "succeeded" ||
    row.status === "failed" ||
    row.status === "cancelled" ||
    row.status === "dead_letter"
      ? row.status
      : undefined;
  if (status === undefined) {
    return undefined;
  }
  return {
    id: row.id,
    accountId: typeof row.user_id === "string" ? row.user_id : null,
    kind: row.kind,
    status,
    attempts: asNonNegativeInt(row.attempts),
    maxAttempts: Math.max(1, asNonNegativeInt(row.max_attempts)),
    lastError: typeof row.last_error === "string" ? row.last_error : null,
    payload: isRecord(row.payload) ? row.payload : {},
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
    updatedAt: typeof row.updated_at === "string" ? row.updated_at : new Date().toISOString(),
    startedAt: typeof row.started_at === "string" ? row.started_at : null,
    finishedAt: typeof row.finished_at === "string" ? row.finished_at : null,
  };
}

function mapAssistantResultRow(
  row: Record<string, unknown> | undefined,
): OpsAssistantResult | undefined {
  if (
    row === undefined ||
    typeof row.id !== "string" ||
    typeof row.user_id !== "string" ||
    typeof row.task_type !== "string"
  ) {
    return undefined;
  }
  const status = row.status;
  if (
    status !== "pending" &&
    status !== "accepted" &&
    status !== "rejected" &&
    status !== "stale" &&
    status !== "edited" &&
    status !== "replaced"
  ) {
    return undefined;
  }
  return {
    id: row.id,
    accountId: row.user_id,
    task: row.task_type,
    resultKind: typeof row.result_kind === "string" ? row.result_kind : null,
    status,
    cacheEntryId: typeof row.cache_entry_id === "string" ? row.cache_entry_id : null,
    outputText: typeof row.output_text === "string" ? row.output_text : null,
    privateContent: isRecord(row.private_content) ? row.private_content : null,
    language: typeof row.language === "string" ? row.language : null,
    sourceText: typeof row.source_text === "string" ? row.source_text : null,
    contextText: typeof row.context_text === "string" ? row.context_text : null,
    bookTitle: typeof row.book_title === "string" ? row.book_title : null,
    chapterTitle: typeof row.chapter_title === "string" ? row.chapter_title : null,
    targetId: typeof row.target_id === "string" ? row.target_id : null,
    timestampSeconds: typeof row.timestamp_seconds === "number" ? row.timestamp_seconds : null,
    replacedText: typeof row.replaced_text === "string" ? row.replaced_text : null,
    replacedModel: typeof row.replaced_model === "string" ? row.replaced_model : null,
    privateEditedOutput:
      typeof row.private_edited_output === "string" ? row.private_edited_output : null,
    privateNotes: typeof row.private_notes === "string" ? row.private_notes : null,
    model: typeof row.model === "string" ? row.model : null,
    promptVersion: typeof row.prompt_version === "string" ? row.prompt_version : null,
    modelPolicyHash: typeof row.model_policy_hash === "string" ? row.model_policy_hash : null,
    history: Array.isArray(row.history)
      ? row.history.filter(
          (item): item is Record<string, unknown> =>
            typeof item === "object" && item !== null && !Array.isArray(item),
        )
      : [],
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date(0).toISOString(),
    updatedAt: typeof row.updated_at === "string" ? row.updated_at : new Date(0).toISOString(),
    decidedAt: typeof row.decided_at === "string" ? row.decided_at : null,
  };
}

/** Server-generated private results use the same compact shape native lifecycle mutations publish. */
function assistantResultSyncPayload(result: OpsAssistantResult): Record<string, unknown> {
  return {
    id: result.id,
    kind:
      result.resultKind ?? (result.task === "chapter_summary" ? "chapterSummary" : "sentenceGloss"),
    status: result.status,
    language: result.language ?? "",
    model: result.model ?? "",
    promptVersion: result.promptVersion ?? "",
    modelPolicyHash: result.modelPolicyHash ?? "",
    source: result.sourceText ?? "",
    text: result.outputText ?? "",
    context: result.contextText,
    bookTitle: result.bookTitle,
    chapterTitle: result.chapterTitle,
    targetID: result.targetId,
    timestamp: result.timestampSeconds,
    createdAt: result.createdAt,
    decidedAt: result.decidedAt,
    sharedCacheEntryID: result.cacheEntryId,
    privateContentJSON:
      result.privateContent === null ? null : JSON.stringify(result.privateContent),
  };
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
      if (key.startsWith(`${userId}:`) && !key.startsWith("upload:") && asset.status === "ready") {
        storageBytes += asset.compressedBytes;
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

function compareTimeIdDescending(left: OpsTimeIdCursor, right: OpsTimeIdCursor): number {
  const createdAt = right.createdAt.localeCompare(left.createdAt);
  return createdAt === 0 ? right.id.localeCompare(left.id) : createdAt;
}

function timeIdPrecedesCursor(event: OpsTimeIdCursor, cursor: OpsTimeIdCursor): boolean {
  return (
    event.createdAt < cursor.createdAt ||
    (event.createdAt === cursor.createdAt && event.id < cursor.id)
  );
}

/** Mirrors the descending `(created_at, id)` keyset boundary used by the memory store. */
function timeIdCursorQuery(cursor: OpsTimeIdCursor): string {
  return `(created_at.lt.${cursor.createdAt},and(created_at.eq.${cursor.createdAt},id.lt.${cursor.id}))`;
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
  event: Omit<OpsProductEvent, "id" | "createdAt" | "purpose"> & {
    createdAt?: string;
    purpose?: OpsProductEvent["purpose"];
  },
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
      purpose: event.purpose ?? "learning_analytics",
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

async function fetchAssetManifest(
  rest: RestClient,
  userId: string,
  identity: { id?: string; upload_id?: string; kind?: AssetKind; sha256?: string },
): Promise<OpsAsset | undefined> {
  const response = await rest.request({
    method: "GET",
    path: "/asset_manifests_v2",
    query: {
      user_id: `eq.${userId}`,
      ...(identity.id === undefined ? {} : { id: `eq.${identity.id}` }),
      ...(identity.upload_id === undefined ? {} : { upload_id: `eq.${identity.upload_id}` }),
      ...(identity.kind === undefined ? {} : { kind: `eq.${identity.kind}` }),
      ...(identity.sha256 === undefined ? {} : { sha256: `eq.${identity.sha256}` }),
      limit: "1",
    },
  });
  if (!restOk(response) || isErrorBody(response.body)) return undefined;
  return mapAssetManifestRow(restRows(response.body)[0]);
}

function mapAssetManifestRow(row: Record<string, unknown> | undefined): OpsAsset | undefined {
  if (
    row === undefined ||
    typeof row.id !== "string" ||
    typeof row.upload_id !== "string" ||
    typeof row.user_id !== "string" ||
    typeof row.kind !== "string" ||
    typeof row.content_type !== "string" ||
    typeof row.encoding !== "string" ||
    typeof row.sha256 !== "string" ||
    typeof row.object_key !== "string" ||
    typeof row.upload_object_key !== "string"
  ) {
    return undefined;
  }
  const kind = row.kind as AssetKind;
  const status = row.status as AssetStatus;
  const compressedBytes = finiteNumber(row.compressed_bytes);
  const originalBytes = finiteNumber(row.original_bytes);
  if (compressedBytes === undefined || originalBytes === undefined) return undefined;
  return {
    id: row.id,
    uploadId: row.upload_id,
    accountId: row.user_id,
    kind,
    contentType: row.content_type,
    compressedBytes,
    originalBytes,
    sha256: row.sha256,
    encoding: row.encoding,
    revisionId: typeof row.revision_id === "string" ? row.revision_id : null,
    bookId: typeof row.book_id === "string" ? row.book_id : null,
    chapterId: typeof row.chapter_id === "string" ? row.chapter_id : null,
    segmentCount: finiteNumber(row.segment_count) ?? null,
    fileName: "",
    status,
    objectKey: row.object_key,
    uploadObjectKey: row.upload_object_key,
    createdAt: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
    deletedAt: typeof row.deleted_at === "string" ? row.deleted_at : null,
    uploadAuthorizedUntil:
      typeof row.upload_authorized_until === "string" ? row.upload_authorized_until : null,
  };
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
    purpose: row.purpose === "operational" ? "operational" : "learning_analytics",
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
