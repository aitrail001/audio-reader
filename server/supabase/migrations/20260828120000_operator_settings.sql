-- Operator-managed runtime config (Qwen, GCS, Turnstile overlays).
-- Secrets are stored as AES-GCM ciphertext; the wrapping key stays in Worker env.

create table public.operator_settings (
  id text primary key default 'default',
  payload jsonb not null default '{}'::jsonb,
  ciphertext text,
  nonce text,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint operator_settings_singleton_check check (id = 'default')
);

alter table public.operator_settings enable row level security;
alter table public.operator_settings force row level security;

revoke all on table public.operator_settings from public;
revoke all on table public.operator_settings from anon, authenticated;
grant all on table public.operator_settings to service_role;

insert into public.operator_settings (id, payload)
values ('default', '{}'::jsonb)
on conflict (id) do nothing;

insert into public.model_policies (
  id,
  task,
  region,
  model,
  prompt_version,
  schema_version,
  policy_version,
  enabled,
  canary_percent,
  max_input_tokens,
  max_output_tokens,
  timeout_ms
)
values
  (
    '00000000-0000-4000-8000-0000000000aa',
    'translation',
    'ap-southeast-1',
    'qwen3.7-plus',
    'qwen-managed-v1',
    '1',
    'qwen-managed-v1',
    true,
    0,
    8000,
    2000,
    30000
  ),
  (
    '00000000-0000-4000-8000-0000000000ab',
    'chapter_summary',
    'ap-southeast-1',
    'qwen3.7-plus',
    'qwen-managed-v1',
    '1',
    'qwen-managed-v1',
    true,
    0,
    8000,
    2000,
    30000
  ),
  (
    '00000000-0000-4000-8000-0000000000ac',
    'chat',
    'ap-southeast-1',
    'qwen3.7-plus',
    'qwen-managed-v1',
    '1',
    'qwen-managed-v1',
    true,
    0,
    8000,
    2000,
    30000
  )
on conflict (id) do nothing;
