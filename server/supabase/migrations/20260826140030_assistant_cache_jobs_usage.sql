create table public.assistant_cache_entries (
  id uuid primary key default gen_random_uuid(),
  cache_key text not null unique,
  task_type text not null,
  contract_version text,
  schema_version text,
  normalization_version text,
  source_language text not null,
  target_language text not null,
  learner_profile_bucket text,
  prompt_version text,
  model_policy_hash text,
  edition_fingerprint text,
  state text not null,
  policy_version text,
  result jsonb,
  hit_count bigint not null default 0,
  accept_count bigint not null default 0,
  reject_count bigint not null default 0,
  source_length integer,
  context_length integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_hit_at timestamptz,
  constraint assistant_cache_entries_state_check
    check (state in ('active', 'quarantined', 'superseded', 'expired', 'purged')),
  constraint assistant_cache_entries_hit_count_check check (hit_count >= 0),
  constraint assistant_cache_entries_accept_count_check check (accept_count >= 0),
  constraint assistant_cache_entries_reject_count_check check (reject_count >= 0)
);

create table public.assistant_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles (user_id) on delete set null,
  cache_key text,
  cache_entry_id uuid references public.assistant_cache_entries (id) on delete set null,
  kind text not null,
  status text not null,
  attempts integer not null default 0,
  max_attempts integer not null default 3,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  constraint assistant_jobs_status_check
    check (status in ('queued', 'running', 'succeeded', 'failed', 'cancelled', 'dead_letter')),
  constraint assistant_jobs_attempts_check check (attempts >= 0),
  constraint assistant_jobs_max_attempts_check check (max_attempts >= 1)
);

create table public.user_assistant_results (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  cache_entry_id uuid references public.assistant_cache_entries (id) on delete set null,
  job_id uuid references public.assistant_jobs (id) on delete set null,
  book_id uuid,
  chapter_id uuid,
  task_type text not null,
  status text not null,
  thread_id uuid,
  segment_id text,
  target_id text,
  private_notes text,
  private_edited_output text,
  output_text text,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint user_assistant_results_status_check
    check (status in ('pending', 'accepted', 'rejected')),
  constraint user_assistant_results_server_version_check check (server_version >= 0),
  constraint user_assistant_results_user_book_fkey
    foreign key (user_id, book_id) references public.books (user_id, id)
    on delete set null (book_id),
  constraint user_assistant_results_user_chapter_fkey
    foreign key (user_id, chapter_id) references public.chapters (user_id, id)
    on delete set null (chapter_id),
  constraint user_assistant_results_book_chapter_fkey
    foreign key (book_id, chapter_id) references public.chapters (book_id, id) on delete set null,
  constraint user_assistant_results_user_id_id_key unique (user_id, id)
);

create table public.usage_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  metric_key text not null,
  quantity numeric not null,
  unit text not null,
  job_id uuid references public.assistant_jobs (id) on delete set null,
  cache_entry_id uuid references public.assistant_cache_entries (id) on delete set null,
  occurred_at timestamptz not null default now(),
  period_starts_at timestamptz,
  period_ends_at timestamptz,
  created_at timestamptz not null default now(),
  constraint usage_ledger_quantity_check check (quantity >= 0)
);

alter table public.vocabulary_occurrences
  add constraint vocabulary_occurrences_translation_id_fkey
  foreign key (user_id, translation_id) references public.user_assistant_results (user_id, id)
  on delete set null (translation_id);

create index assistant_cache_entries_task_state_idx
  on public.assistant_cache_entries (task_type, state, created_at desc);

create index assistant_cache_entries_languages_idx
  on public.assistant_cache_entries (source_language, target_language, state);

create unique index assistant_jobs_inflight_cache_key_uidx
  on public.assistant_jobs (cache_key)
  where status in ('queued', 'running') and cache_key is not null;

create index assistant_jobs_user_status_idx
  on public.assistant_jobs (user_id, status, created_at desc);

create index assistant_jobs_status_created_idx
  on public.assistant_jobs (status, created_at);

create index user_assistant_results_user_chapter_idx
  on public.user_assistant_results (user_id, chapter_id, task_type, status)
  where deleted_at is null;

create index user_assistant_results_cache_entry_id_idx
  on public.user_assistant_results (cache_entry_id)
  where cache_entry_id is not null;

create index user_assistant_results_job_id_idx
  on public.user_assistant_results (job_id)
  where job_id is not null;

create index usage_ledger_user_metric_key_idx
  on public.usage_ledger (user_id, metric_key, occurred_at desc);

create index usage_ledger_user_period_idx
  on public.usage_ledger (user_id, period_ends_at);
