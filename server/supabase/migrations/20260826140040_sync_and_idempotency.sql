create table public.sync_changes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  sequence bigint not null,
  entity_type text not null,
  entity_id text not null,
  operation text not null,
  revision bigint not null default 0,
  mutation_id uuid,
  payload jsonb not null default '{}',
  changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint sync_changes_sequence_check check (sequence >= 1),
  constraint sync_changes_operation_check check (operation in ('upsert', 'delete', 'append')),
  constraint sync_changes_revision_check check (revision >= 0),
  constraint sync_changes_user_sequence_key unique (user_id, sequence)
);

create table public.idempotency_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  key text not null,
  method text not null,
  pathname text not null,
  fingerprint text not null,
  status text not null,
  response_status integer,
  response_headers jsonb,
  response_body text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz,
  constraint idempotency_records_status_check
    check (status in ('in_progress', 'completed')),
  constraint idempotency_records_key_length_check
    check (char_length(key) >= 16 and char_length(key) <= 128),
  constraint idempotency_records_user_method_pathname_key_key
    unique (user_id, method, pathname, key)
);

create unique index sync_changes_user_mutation_uidx
  on public.sync_changes (user_id, mutation_id)
  where mutation_id is not null;

create index sync_changes_user_sequence_idx
  on public.sync_changes (user_id, sequence);

create index idempotency_records_expires_idx
  on public.idempotency_records (expires_at)
  where expires_at is not null;
