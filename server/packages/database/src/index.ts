import { ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION } from "./schema";
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
export type ReadinessStatus = "ok" | "unavailable";
export {
  AUDIT_ACTOR_TYPES,
  ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION,
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
  IdentityAdminRole,
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
  DEFAULT_ASSISTANT_USER_PROMPTS,
  CHAPTER_BATCH_TRANSLATION_INSTRUCTIONS,
  CHAPTER_SUMMARY_INSTRUCTIONS,
  CHAT_INSTRUCTIONS,
  SENTENCE_TRANSLATION_INSTRUCTIONS,
  WORD_IN_SENTENCE_INSTRUCTIONS,
  chapterBatchTranslationInstructions,
  chapterSummaryInstructions,
  clampContextCount,
  composeAssistantSystemPrompt,
  defaultAssistantPrompt,
  defaultAssistantUserPrompt,
  formatManagedChapterBatchContext,
  formatManagedSentenceContext,
  HEARD_QUIZ_INSTRUCTIONS,
  isAssistantTask,
  isChapterBatchTask,
  isWordTranslationTask,
  promptLanguageName,
  renderAssistantUserPrompt,
  sentenceTranslationInstructions,
  stringList,
  wordInSentenceInstructions,
  assembleManagedPrompt,
  validateAssistantPromptDraft,
  validateManagedPromptOutput,
} from "./assistant-prompts";
export type {
  AssistantTask,
  AssistantPromptValidation,
  ManagedPromptAssembly,
  ManagedPromptSubtask,
  ManagedPromptOutputValidation,
} from "./assistant-prompts";
export {
  AssetReservationError,
  RestPersistenceError,
  createMemoryOpsStore,
  createSupabaseOpsStore,
  createUnavailableOpsStore,
} from "./ops";
export type {
  AdminUserRecord,
  AnalyticsPreferenceRecord,
  CacheState,
  JobStatus,
  ObjectWriteLease,
  OperatorSettingsRecord,
  OperatorSettingsReadResult,
  OpsAsset,
  OpsAssistantResult,
  OpsAuditEvent,
  OpsCacheEntry,
  OpsExport,
  OpsFeatureFlag,
  OpsJob,
  OpsPolicy,
  OpsPrivacyRequest,
  OpsProductEvent,
  OpsQuota,
  OpsStore,
  UserProgressSummaryRecord,
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
  SyncStoreWriteError,
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
  accountSyncSchemaVersion(): Promise<string | undefined>;
  identity: IdentityStore;
  sync: SyncStore;
  syncV2: SyncStore;
  catalog: CatalogStore;
  ops: OpsStore;
};

export function createFakeDatabaseClient(
  options: { status?: ReadinessStatus; accountSyncSchemaVersion?: string | null } = {},
): DatabaseClient {
  const status = options.status ?? "ok";
  const schemaVersion =
    options.accountSyncSchemaVersion === null
      ? undefined
      : (options.accountSyncSchemaVersion ?? ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION);
  const identity = createMemoryIdentityStore();
  const catalog = createMemoryCatalogStore();
  const sync = createMemorySyncStore({ identity });
  const hooks: {
    markDeletedBookAssets?: (userId: string, bookId: string) => Promise<unknown>;
  } = {};
  const syncV2 = createMemorySyncStore({
    identity,
    async afterAppliedMutation(userId, mutation) {
      if (mutation.entityType === "book" && mutation.operation === "delete") {
        await hooks.markDeletedBookAssets?.(userId, mutation.entityId);
      }
    },
  });
  const ops = createMemoryOpsStore({ identity, catalog, syncV2 });
  const durableBookTransition = ops.claimDeletedBookAssets.bind(ops);
  hooks.markDeletedBookAssets = (userId, bookId) => durableBookTransition(userId, [bookId]);
  return {
    ping: () => Promise.resolve(status),
    accountSyncSchemaVersion: () => Promise.resolve(schemaVersion),
    identity,
    sync,
    syncV2,
    catalog,
    ops,
  };
}

export function createUnavailableDatabaseClient(): DatabaseClient {
  return {
    ping: () => Promise.resolve("unavailable"),
    accountSyncSchemaVersion: () => Promise.resolve(undefined),
    identity: createUnavailableIdentityStore(),
    sync: createUnavailableSyncStore(),
    syncV2: createUnavailableSyncStore(),
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
    async accountSyncSchemaVersion() {
      const response = await rest.request({
        method: "POST",
        path: "/rpc/account_sync_schema_version",
        body: {},
      });
      if (response.status < 200 || response.status >= 300) return undefined;
      return typeof response.body === "string" ? response.body : undefined;
    },
    identity,
    sync: createSupabaseSyncStore(rest),
    syncV2: createSupabaseSyncStore(rest, "v2"),
    catalog,
    ops: createSupabaseOpsStore(rest, { identity, catalog }),
  };
}
