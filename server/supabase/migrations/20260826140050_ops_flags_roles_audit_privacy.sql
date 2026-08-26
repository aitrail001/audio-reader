create table public.feature_flags (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  enabled boolean not null default false,
  variant text,
  rollout_percent numeric not null default 100,
  min_app_version text,
  platforms text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint feature_flags_rollout_percent_check
    check (rollout_percent >= 0 and rollout_percent <= 100)
);

create table public.model_policies (
  id uuid primary key default gen_random_uuid(),
  task text not null,
  region text not null,
  model text not null,
  prompt_version text not null,
  schema_version text not null,
  policy_version text not null,
  enabled boolean not null default true,
  canary_percent numeric not null default 0,
  max_input_tokens integer,
  max_output_tokens integer,
  timeout_ms integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint model_policies_canary_percent_check
    check (canary_percent >= 0 and canary_percent <= 100),
  constraint model_policies_max_input_tokens_check
    check (max_input_tokens is null or max_input_tokens >= 1),
  constraint model_policies_max_output_tokens_check
    check (max_output_tokens is null or max_output_tokens >= 1),
  constraint model_policies_timeout_ms_check
    check (timeout_ms is null or timeout_ms >= 1000),
  constraint model_policies_task_policy_version_key unique (task, policy_version)
);

create table public.admin_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  role text not null,
  granted_at timestamptz not null default now(),
  granted_by uuid,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint admin_roles_role_check
    check (role in (
      'support_readonly',
      'operator',
      'privacy_officer',
      'billing_operator',
      'superadmin'
    ))
);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid,
  actor_type text not null,
  action text not null,
  resource_type text not null,
  resource_id text not null,
  reason_code text,
  reason text not null,
  request_id text,
  source_ip_hash text,
  metadata jsonb,
  before_metadata jsonb,
  after_metadata jsonb,
  created_at timestamptz not null default now(),
  constraint audit_events_actor_type_check
    check (actor_type in ('user', 'admin', 'system'))
);

create table public.privacy_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  kind text not null,
  status text not null,
  format text,
  include text[] not null default '{}',
  asset_id uuid references public.book_assets (id) on delete set null,
  confirmation text,
  reason text,
  export_first boolean not null default true,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  expires_at timestamptz,
  constraint privacy_requests_kind_check check (kind in ('export', 'deletion')),
  constraint privacy_requests_status_check
    check (status in ('queued', 'running', 'ready', 'failed', 'expired', 'cancelled')),
  constraint privacy_requests_format_check
    check (format is null or format in ('zip_json', 'csv', 'anki_package'))
);

create unique index admin_roles_user_role_uidx
  on public.admin_roles (user_id, role)
  where revoked_at is null;

create index admin_roles_user_id_idx
  on public.admin_roles (user_id);

create index audit_events_created_at_idx
  on public.audit_events (created_at desc);

create index audit_events_actor_idx
  on public.audit_events (actor_id, created_at desc);

create index audit_events_resource_idx
  on public.audit_events (resource_type, resource_id);

create index privacy_requests_user_id_idx
  on public.privacy_requests (user_id, created_at desc);

create index privacy_requests_status_idx
  on public.privacy_requests (status, created_at);

create index model_policies_task_enabled_idx
  on public.model_policies (task, enabled);
