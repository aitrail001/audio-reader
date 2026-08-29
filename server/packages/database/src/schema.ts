export const CORE_TABLES = [
  "profiles",
  "devices",
  "user_settings",
  "books",
  "book_assets",
  "canonical_works",
  "canonical_editions",
  "chapters",
  "reading_progress",
  "transcript_revisions",
  "transcript_segments",
  "vocabulary_occurrences",
  "known_lemmas",
  "review_cards",
  "review_events",
  "user_assistant_results",
  "assistant_cache_entries",
  "assistant_jobs",
  "usage_ledger",
  "sync_changes",
  "idempotency_records",
  "feature_flags",
  "model_policies",
  "admin_roles",
  "audit_events",
  "privacy_requests",
  "operator_settings",
  "quota_limits",
  "chat_messages",
  "passwordless_hits",
  "passwordless_cooldowns",
  "passwordless_blocked_attempts",
  "product_events",
] as const;

export type CoreTable = (typeof CORE_TABLES)[number];

export const SYNC_TABLES = [
  "profiles",
  "devices",
  "user_settings",
  "books",
  "book_assets",
  "chapters",
  "reading_progress",
  "transcript_revisions",
  "transcript_segments",
  "vocabulary_occurrences",
  "known_lemmas",
  "review_cards",
  "review_events",
  "user_assistant_results",
] as const;

export const PRIVATE_TABLES = [
  ...SYNC_TABLES,
  "usage_ledger",
  "sync_changes",
  "idempotency_records",
  "admin_roles",
  "privacy_requests",
] as const;

export const OPTIONAL_OWNER_TABLES = ["assistant_jobs"] as const;

export const TENANT_PARENT_TABLES = [
  "books",
  "book_assets",
  "chapters",
  "devices",
  "vocabulary_occurrences",
  "transcript_revisions",
  "review_cards",
  "user_assistant_results",
] as const;

export const GLOBAL_TABLES = [
  "canonical_works",
  "canonical_editions",
  "assistant_cache_entries",
  "feature_flags",
  "quota_limits",
  "model_policies",
  "audit_events",
  "operator_settings",
] as const;

/** Synchronized private rows plus user-filed privacy requests. */
export const USER_OWNED_TABLES = [...SYNC_TABLES, "privacy_requests"] as const;

/** Server-written private rows a user JWT may read for themselves only. */
export const USER_READ_OWN_TABLES = ["assistant_jobs", "usage_ledger", "sync_changes"] as const;

/** Named tables a normal user JWT must not read or write. */
export const JWT_DENIED_TABLES = [
  "assistant_cache_entries",
  "model_policies",
  "admin_roles",
  "audit_events",
  "operator_settings",
  "chat_messages",
  "passwordless_hits",
  "passwordless_cooldowns",
  "passwordless_blocked_attempts",
  "product_events",
] as const;

/** RLS enabled, no authenticated policies. Includes JWT-denied tables. */
export const SERVER_ONLY_TABLES = [
  "idempotency_records",
  "canonical_works",
  "canonical_editions",
  "feature_flags",
  "quota_limits",
  ...JWT_DENIED_TABLES,
] as const;

/** Privileged transaction RPCs; EXECUTE is service_role only. */
export const TRANSACTION_FUNCTIONS = [
  "claim_idempotency_record",
  "record_idempotency_response",
  "abort_idempotency_record",
  "append_sync_change",
  "claim_assistant_generation",
  "attach_user_assistant_result",
  "complete_assistant_job",
  "fail_assistant_job",
  "append_audit_event",
] as const;

export const AUDIT_ACTOR_TYPES = ["user", "admin", "system"] as const;

export const SYNC_COLUMNS = [
  "id",
  "user_id",
  "created_at",
  "updated_at",
  "server_version",
  "deleted_at",
  "last_mutation_id",
] as const;
