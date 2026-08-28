import type { ReadinessStatus } from "@audio-reader/domain";
import {
  createMemoryCatalogStore,
  createSupabaseCatalogStore,
  createUnavailableCatalogStore,
  type CatalogStore,
} from "./catalog";
import {
  createMemoryIdentityStore,
  createSupabaseIdentityStore,
  createUnavailableIdentityStore,
  type IdentityStore,
} from "./identity";
import {
  createMemoryOpsStore,
  createSupabaseOpsStore,
  createUnavailableOpsStore,
  type OpsStore,
} from "./ops";
import { createSupabaseRestClient, type SupabaseRestOptions } from "./rest";
import {
  createMemorySyncStore,
  createSupabaseSyncStore,
  createUnavailableSyncStore,
  type SyncStore,
} from "./sync-store";

export const packageId = "@audio-reader/database" as const;
export type { ReadinessStatus };
export {
  AUDIT_ACTOR_TYPES,
  CORE_TABLES,
  GLOBAL_TABLES,
  JWT_DENIED_TABLES,
  OPTIONAL_OWNER_TABLES,
  PRIVATE_TABLES,
  SERVER_ONLY_TABLES,
  SYNC_COLUMNS,
  SYNC_TABLES,
  TENANT_PARENT_TABLES,
  TRANSACTION_FUNCTIONS,
  USER_OWNED_TABLES,
  USER_READ_OWN_TABLES,
} from "./schema";
export type { CoreTable } from "./schema";
export {
  createMemoryIdentityStore,
  createSupabaseIdentityStore,
  createUnavailableIdentityStore,
  defaultIdentitySettings,
} from "./identity";
export type {
  IdentityAccountStatus,
  IdentityBootstrapInput,
  IdentityDevice,
  IdentityProfile,
  IdentityProfilePatch,
  IdentitySettings,
  IdentityStore,
} from "./identity";
export {
  createMemoryCatalogStore,
  createSupabaseCatalogStore,
  createUnavailableCatalogStore,
} from "./catalog";
export type {
  CatalogBook,
  CatalogChapter,
  CatalogLemma,
  CatalogProgress,
  CatalogReviewEvent,
  CatalogReviewSchedule,
  CatalogStore,
  CatalogTranscript,
  CatalogVocabulary,
} from "./catalog";
export {
  DEFAULT_ASSISTANT_PROMPTS,
  composeAssistantSystemPrompt,
  defaultAssistantPrompt,
  isAssistantTask,
} from "./assistant-prompts";
export type { AssistantTask } from "./assistant-prompts";
export { createMemoryOpsStore, createSupabaseOpsStore, createUnavailableOpsStore } from "./ops";
export type {
  AdminUserRecord,
  CacheState,
  JobStatus,
  OperatorSettingsRecord,
  OpsAsset,
  OpsAuditEvent,
  OpsCacheEntry,
  OpsExport,
  OpsFeatureFlag,
  OpsJob,
  OpsPolicy,
  OpsPrivacyRequest,
  OpsQuota,
  OpsStore,
} from "./ops";
export {
  DEFAULT_FEATURE_FLAGS,
  DEFAULT_QUOTA_LIMITS,
  FEATURE_FLAG_KEYS,
  QUOTA_KEYS,
  endOfUtcDay,
  isQuotaKey,
  utcDay,
} from "./product-limits";
export type {
  FeatureFlagKey,
  ProductFeatureFlag,
  ProductQuotaLimit,
  QuotaKey,
} from "./product-limits";
export { decryptOperatorSecrets, encryptOperatorSecrets } from "./operator-crypto";
export type { OperatorCipher, OperatorSecrets } from "./operator-crypto";
export { createSupabaseRestClient } from "./rest";
export type { RestClient, RestFetch, RestRequest, RestResponse, SupabaseRestOptions } from "./rest";
export {
  SYNC_ENTITY_TYPES,
  createMemorySyncStore,
  createSupabaseSyncStore,
  createUnavailableSyncStore,
  isSyncEntityType,
} from "./sync-store";
export type {
  SyncChange,
  SyncEntityType,
  SyncMutation,
  SyncMutationResult,
  SyncPullResult,
  SyncPushResult,
  SyncStore,
} from "./sync-store";

export type DatabaseClient = {
  ping(): Promise<ReadinessStatus>;
  identity: IdentityStore;
  sync: SyncStore;
  catalog: CatalogStore;
  ops: OpsStore;
};

export function createFakeDatabaseClient(
  options: { status?: ReadinessStatus } = {},
): DatabaseClient {
  const status = options.status ?? "ok";
  const identity = createMemoryIdentityStore();
  const catalog = createMemoryCatalogStore();
  return {
    ping: () => Promise.resolve(status),
    identity,
    sync: createMemorySyncStore({ identity }),
    catalog,
    ops: createMemoryOpsStore({ identity, catalog }),
  };
}

export function createUnavailableDatabaseClient(): DatabaseClient {
  return {
    ping: () => Promise.resolve("unavailable"),
    identity: createUnavailableIdentityStore(),
    sync: createUnavailableSyncStore(),
    catalog: createUnavailableCatalogStore(),
    ops: createUnavailableOpsStore(),
  };
}

export function createSupabaseDatabaseClient(options: SupabaseRestOptions): DatabaseClient {
  const rest = createSupabaseRestClient(options);
  const identity = createSupabaseIdentityStore(rest);
  const catalog = createSupabaseCatalogStore(rest);
  return {
    async ping() {
      const response = await rest.request({
        method: "GET",
        path: "/profiles",
        query: { select: "id", limit: "1" },
      });
      return response.status >= 200 && response.status < 300 ? "ok" : "unavailable";
    },
    identity,
    sync: createSupabaseSyncStore(rest, { identity }),
    catalog,
    ops: createSupabaseOpsStore(rest, { identity, catalog }),
  };
}
