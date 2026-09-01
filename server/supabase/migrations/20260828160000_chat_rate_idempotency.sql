-- Shared Worker coordination. Isolates must not keep OTP buckets, idempotency
-- claims, or chat rows in memory. service_role only; JWT cannot read these.

alter table public.idempotency_records
  drop constraint if exists idempotency_records_user_id_fkey;

-- Anonymous OTP writes use a stable UUID that is not a profiles row.

create table public.chat_messages (
  thread_id uuid not null,
  message_id uuid not null,
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  role text not null,
  text text not null,
  created_at timestamptz not null default now(),
  primary key (thread_id, message_id),
  constraint chat_messages_role_check check (role in ('user', 'assistant'))
);

create index chat_messages_user_id_idx
  on public.chat_messages (user_id, created_at desc);

create table public.passwordless_hits (
  id uuid primary key default gen_random_uuid(),
  bucket_key text not null,
  hit_at timestamptz not null default now()
);

create index passwordless_hits_bucket_key_hit_at_idx
  on public.passwordless_hits (bucket_key, hit_at desc);

create table public.passwordless_cooldowns (
  email_hash text primary key,
  until_at timestamptz not null
);

create table public.passwordless_blocked_attempts (
  id uuid primary key default gen_random_uuid(),
  action text not null,
  reason text not null,
  email_hash text not null,
  ip_hash text not null,
  device_id text,
  request_id text,
  created_at timestamptz not null default now(),
  constraint passwordless_blocked_attempts_action_check
    check (action in ('email_otp_request', 'email_otp_verify')),
  constraint passwordless_blocked_attempts_reason_check
    check (reason in ('rate_limited', 'challenge_required'))
);

create index passwordless_blocked_attempts_created_at_idx
  on public.passwordless_blocked_attempts (created_at desc);

alter table public.chat_messages enable row level security;
alter table public.chat_messages force row level security;
alter table public.passwordless_hits enable row level security;
alter table public.passwordless_hits force row level security;
alter table public.passwordless_cooldowns enable row level security;
alter table public.passwordless_cooldowns force row level security;
alter table public.passwordless_blocked_attempts enable row level security;
alter table public.passwordless_blocked_attempts force row level security;

revoke all on table public.chat_messages from public;
revoke all on table public.chat_messages from anon, authenticated;
grant all on table public.chat_messages to service_role;

revoke all on table public.passwordless_hits from public;
revoke all on table public.passwordless_hits from anon, authenticated;
grant all on table public.passwordless_hits to service_role;

revoke all on table public.passwordless_cooldowns from public;
revoke all on table public.passwordless_cooldowns from anon, authenticated;
grant all on table public.passwordless_cooldowns to service_role;

revoke all on table public.passwordless_blocked_attempts from public;
revoke all on table public.passwordless_blocked_attempts from anon, authenticated;
grant all on table public.passwordless_blocked_attempts to service_role;
