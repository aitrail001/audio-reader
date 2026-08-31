create table public.quota_limits (
  key text primary key,
  limit_value numeric not null,
  updated_at timestamptz not null default now(),
  constraint quota_limits_limit_value_check check (limit_value >= 0)
);

alter table public.quota_limits enable row level security;
alter table public.quota_limits force row level security;

insert into public.feature_flags (key, enabled, rollout_percent)
values
  ('managed_qwen', true, 100),
  ('account_sync', false, 100),
  ('cloud_media', true, 100),
  ('maintenance_mode', false, 100)
on conflict (key) do nothing;

insert into public.quota_limits (key, limit_value)
values
  ('qwen_tasks_day', 50),
  ('cloud_media_bytes', 262144000),
  ('cloud_books', 3),
  ('devices', 2)
on conflict (key) do nothing;
