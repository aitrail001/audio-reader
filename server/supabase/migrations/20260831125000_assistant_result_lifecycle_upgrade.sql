-- Applied migrations are immutable. Upgrade the original private-result table before sync v2
-- creates functions that read and write the lifecycle columns below.
alter table public.user_assistant_results
  add column if not exists result_kind text,
  add column if not exists language text,
  add column if not exists source_text text,
  add column if not exists context_text text,
  add column if not exists book_title text,
  add column if not exists chapter_title text,
  add column if not exists timestamp_seconds double precision,
  add column if not exists private_content jsonb,
  add column if not exists model text,
  add column if not exists prompt_version text,
  add column if not exists model_policy_hash text,
  add column if not exists replaced_text text,
  add column if not exists replaced_model text,
  add column if not exists history jsonb not null default '[]'::jsonb;

alter table public.user_assistant_results
  drop constraint if exists user_assistant_results_status_check;
alter table public.user_assistant_results
  add constraint user_assistant_results_status_check
  check (status in ('pending', 'accepted', 'rejected', 'stale', 'edited', 'replaced'));

-- Existing rows predate lifecycle history. Seed one complete private snapshot without changing the
-- row, its owner, or any cache/job/book/chapter foreign-key reference.
update public.user_assistant_results
set history = jsonb_build_array(jsonb_build_object(
  'status', status,
  'outputText', output_text,
  'resultKind', result_kind,
  'language', language,
  'sourceText', source_text,
  'contextText', context_text,
  'bookTitle', book_title,
  'chapterTitle', chapter_title,
  'targetId', target_id,
  'timestampSeconds', timestamp_seconds,
  'privateContent', private_content,
  'privateEditedOutput', private_edited_output,
  'privateNotes', private_notes,
  'model', model,
  'promptVersion', prompt_version,
  'modelPolicyHash', model_policy_hash,
  'replacedText', replaced_text,
  'replacedModel', replaced_model,
  'sharedCacheReference', case
    when cache_entry_id is null then null
    else jsonb_build_object('entryId', cache_entry_id)
  end,
  'recordedAt', coalesce(decided_at, updated_at, created_at, clock_timestamp())
))
where history is null or history = '[]'::jsonb;

-- Private history is append-only and remains complete if the optional shared cache row disappears.
create or replace function public.append_user_assistant_result_history()
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

drop trigger if exists append_user_assistant_result_history
  on public.user_assistant_results;
create trigger append_user_assistant_result_history
before insert or update on public.user_assistant_results
for each row execute function public.append_user_assistant_result_history();

-- The v2 launch is requested-off on both upgraded and clean environments. Preserve any operator
-- rollout percentage and quota override while repairing rows that are missing entirely.
insert into public.feature_flags (key, enabled, rollout_percent)
values ('account_sync', false, 100)
on conflict (key) do update set enabled = excluded.enabled;

insert into public.quota_limits (key, limit_value)
values
  ('qwen_tasks_day', 50),
  ('cloud_media_bytes', 262144000),
  ('cloud_books', 3),
  ('devices', 2)
on conflict (key) do nothing;
