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
  result_kind text,
  status text not null,
  language text,
  source_text text,
  context_text text,
  book_title text,
  chapter_title text,
  timestamp_seconds double precision,
  thread_id uuid,
  segment_id text,
  target_id text,
  private_notes text,
  private_edited_output text,
  private_content jsonb,
  output_text text,
  model text,
  prompt_version text,
  model_policy_hash text,
  replaced_text text,
  replaced_model text,
  history jsonb not null default '[]'::jsonb,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint user_assistant_results_status_check
    check (status in ('pending', 'accepted', 'rejected', 'stale', 'edited', 'replaced')),
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

-- Private result history contains the user's own text and model provenance. Cache identifiers are
-- references only; every snapshot remains complete after that shared row expires or is deleted.
create function public.append_user_assistant_result_history()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_snapshot jsonb;
begin
  v_snapshot := jsonb_build_object(
    'status', new.status,
    'outputText', new.output_text,
    'resultKind', new.result_kind,
    'language', new.language,
    'sourceText', new.source_text,
    'contextText', new.context_text,
    'bookTitle', new.book_title,
    'chapterTitle', new.chapter_title,
    'targetId', new.target_id,
    'timestampSeconds', new.timestamp_seconds,
    'privateContent', new.private_content,
    'privateEditedOutput', new.private_edited_output,
    'privateNotes', new.private_notes,
    'model', new.model,
    'promptVersion', new.prompt_version,
    'modelPolicyHash', new.model_policy_hash,
    'replacedText', new.replaced_text,
    'replacedModel', new.replaced_model,
    'sharedCacheReference', case
      when new.cache_entry_id is null then null
      else jsonb_build_object('entryId', new.cache_entry_id)
    end,
    'recordedAt', coalesce(new.decided_at, new.updated_at, new.created_at, clock_timestamp())
  );
  if tg_op = 'INSERT' then
    new.history := jsonb_build_array(v_snapshot);
  elsif row(
    old.status, old.output_text, old.result_kind, old.language, old.source_text, old.context_text,
    old.book_title, old.chapter_title, old.target_id, old.timestamp_seconds, old.private_content,
    old.private_edited_output, old.private_notes, old.model, old.prompt_version,
    old.model_policy_hash, old.replaced_text, old.replaced_model, old.cache_entry_id
  ) is distinct from row(
    new.status, new.output_text, new.result_kind, new.language, new.source_text, new.context_text,
    new.book_title, new.chapter_title, new.target_id, new.timestamp_seconds, new.private_content,
    new.private_edited_output, new.private_notes, new.model, new.prompt_version,
    new.model_policy_hash, new.replaced_text, new.replaced_model, new.cache_entry_id
  ) then
    new.history := coalesce(old.history, '[]'::jsonb) || jsonb_build_array(v_snapshot);
  else
    new.history := old.history;
  end if;
  return new;
end;
$$;

create trigger append_user_assistant_result_history
before insert or update on public.user_assistant_results
for each row execute function public.append_user_assistant_result_history();

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
