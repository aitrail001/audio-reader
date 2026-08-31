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
  "sync_batches",
  "sync_mutation_outcomes",
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
  "user_analytics_preferences",
  "user_progress_summaries",
  "object_write_leases",
  "service_schema_versions",
  "asset_manifests_v2",
  "sync_v2_changes",
  "sync_v2_batches",
  "sync_v2_mutation_outcomes",
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
  "sync_batches",
  "sync_mutation_outcomes",
  "idempotency_records",
  "admin_roles",
  "privacy_requests",
  "object_write_leases",
  "asset_manifests_v2",
  "sync_v2_changes",
  "sync_v2_batches",
  "sync_v2_mutation_outcomes",
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
  "asset_manifests_v2",
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
  "service_schema_versions",
] as const;

/** Synchronized private rows plus user-filed privacy requests. */
export const USER_OWNED_TABLES = [...SYNC_TABLES, "privacy_requests"] as const;

/** Server-written private rows a user JWT may read for themselves only. */
export const USER_READ_OWN_TABLES = [
  "assistant_jobs",
  "usage_ledger",
  "sync_changes",
  "asset_manifests_v2",
  "sync_v2_changes",
] as const;

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
  "user_analytics_preferences",
  "user_progress_summaries",
  "object_write_leases",
  "service_schema_versions",
  "sync_v2_batches",
  "sync_v2_mutation_outcomes",
] as const;

/** RLS enabled, no authenticated policies. Includes JWT-denied tables. */
export const SERVER_ONLY_TABLES = [
  "idempotency_records",
  "sync_batches",
  "sync_mutation_outcomes",
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
  "reserve_v2_asset_upload",
  "sync_v2_json_is_bounded",
  "complete_v2_asset_and_publish",
  "push_sync_v2_batch",
  "record_user_assistant_result",
  "pull_sync_v2_page",
  "bootstrap_sync_v2_page",
  "gc_abandoned_v2_uploads",
  "finish_v2_asset_upload_gc",
  "cleanup_obsolete_v1_data",
  "push_sync_batch",
  "pull_sync_page",
  "append_sync_change",
  "claim_assistant_generation",
  "attach_user_assistant_result",
  "complete_assistant_job",
  "fail_assistant_job",
  "append_audit_event",
  "admin_user_progress_summary",
  "purge_expired_user_progress_summaries",
  "set_user_analytics_preference",
  "delete_account_data",
  "request_account_deletion",
  "claim_assistant_jobs",
] as const;

/** Latest database contract that account sync must prove before it can become effective. */
export const ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION = "20260831133000" as const;

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
