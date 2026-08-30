-- Apply privacy enforcement additively even when the original progress-summary migration was
-- already recorded in staging. The unchecked implementation remains executable only by its owner;
-- every service-role call crosses the consent-checking wrapper below.

begin;

-- Hosted jobs must be database-backed so API and Job Worker isolates share one queue. The deletion
-- transaction scrubs this payload before the profile foreign key is detached below.
alter table public.assistant_jobs
  add column if not exists payload jsonb not null default '{}'::jsonb;
alter table public.assistant_jobs
  add column if not exists lease_expires_at timestamptz;

-- Object storage is outside Postgres, so each write holds a durable lease. Account deletion waits
-- for live requests and treats an expired lease's key as deletion input before cascading the row.
create table if not exists public.object_write_leases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  object_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default (clock_timestamp() + interval '30 minutes'),
  constraint object_write_leases_object_key_check check (length(trim(object_key)) > 0)
);
create index if not exists object_write_leases_user_expiry_idx
  on public.object_write_leases (user_id, expires_at);
alter table public.object_write_leases enable row level security;
alter table public.object_write_leases force row level security;

-- Every service-role child write takes a key-share lock on a non-deleted profile. This closes the
-- authenticate-before-delete race: either the write commits first and is cascaded, or deletion
-- commits first and the later write is rejected. Deletion jobs alone may advance while the profile
-- is deletion_pending.
create or replace function public.enforce_live_profile_child_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.user_id is null then
    return new;
  end if;
  perform 1
  from public.profiles
  where user_id = new.user_id
    and deleted_at is null
    and (
      account_status in ('active', 'suspended')
      or (
        account_status = 'deletion_pending'
        and tg_table_name = 'assistant_jobs'
        and to_jsonb(new)->>'kind' = 'account_deletion'
      )
    )
  for key share;
  if not found then
    raise exception 'account is not writable' using errcode = '23514';
  end if;
  return new;
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'devices', 'user_settings', 'books', 'book_assets', 'chapters', 'reading_progress',
    'transcript_revisions', 'transcript_segments', 'vocabulary_occurrences', 'known_lemmas',
    'review_cards', 'review_events', 'user_assistant_results', 'assistant_jobs', 'usage_ledger',
    'sync_changes', 'sync_batches', 'sync_mutation_outcomes', 'idempotency_records', 'admin_roles',
    'privacy_requests', 'chat_messages', 'product_events', 'user_analytics_preferences',
    'user_progress_summaries', 'object_write_leases'
  ] loop
    execute format('drop trigger if exists enforce_live_profile_child_write on public.%I', v_table);
    execute format(
      'create trigger enforce_live_profile_child_write before insert or update on public.%I '
      'for each row execute function public.enforce_live_profile_child_write()',
      v_table
    );
  end loop;
end;
$$;

create or replace function public.claim_assistant_jobs(p_limit integer default 16)
returns setof public.assistant_jobs
language sql
security definer
set search_path = public
as $$
  with terminal as (
    update public.assistant_jobs
    set status = case
          when kind = 'account_deletion' and user_id is null then 'succeeded'
          else 'dead_letter'
        end,
        finished_at = clock_timestamp(),
        lease_expires_at = null,
        updated_at = clock_timestamp()
    where status = 'running'
      and lease_expires_at <= clock_timestamp()
      and attempts >= max_attempts
      and (
        (kind = 'account_deletion' and user_id is null)
        or exists (
          select 1
          from public.profiles profile
          where profile.user_id = assistant_jobs.user_id
            and profile.deleted_at is null
            and (
              profile.account_status in ('active', 'suspended')
              or (
                profile.account_status = 'deletion_pending'
                and assistant_jobs.kind = 'account_deletion'
              )
            )
        )
      )
    returning id
  ), candidates as (
    select job.id
    from public.assistant_jobs job
    where job.attempts < job.max_attempts
      and (
        job.status = 'queued'
        or (job.status = 'running' and job.lease_expires_at <= clock_timestamp())
      )
      and (
        (job.kind = 'account_deletion' and job.user_id is null)
        or exists (
          select 1
          from public.profiles profile
          where profile.user_id = job.user_id
            and profile.deleted_at is null
            and (
              profile.account_status in ('active', 'suspended')
              or (
                profile.account_status = 'deletion_pending'
                and job.kind = 'account_deletion'
              )
            )
        )
      )
    order by job.created_at, job.id
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 16), 100))
  )
  update public.assistant_jobs job
  set status = 'running',
      attempts = job.attempts + 1,
      started_at = coalesce(job.started_at, clock_timestamp()),
      lease_expires_at = clock_timestamp() + interval '5 minutes',
      updated_at = clock_timestamp()
  from candidates
  left join terminal on false
  where job.id = candidates.id
  returning job.*;
$$;

create or replace function public.request_account_deletion(
  p_user_id uuid,
  p_reason text,
  p_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.privacy_requests%rowtype;
  v_job public.assistant_jobs%rowtype;
begin
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'deletion reason is required' using errcode = '22023';
  end if;
  perform 1
  from public.profiles
  where user_id = p_user_id and account_status = 'active' and deleted_at is null
  for update;
  if not found then
    return null;
  end if;

  insert into public.privacy_requests (user_id, kind, status, reason)
  values (p_user_id, 'deletion', 'queued', p_reason)
  returning * into v_request;
  insert into public.assistant_jobs (
    user_id, kind, status, attempts, max_attempts, payload
  ) values (p_user_id, 'account_deletion', 'queued', 0, 5, '{}'::jsonb)
  returning * into v_job;
  -- A pending account may no longer run or retain private inputs in unrelated jobs. Detaching the
  -- rows also prevents a legacy queued job from aborting a global service-role claim batch.
  update public.assistant_jobs
  set user_id = null,
      status = case when status in ('queued', 'running') then 'cancelled' else status end,
      payload = '{}'::jsonb,
      cache_key = null,
      last_error = null,
      lease_expires_at = null,
      finished_at = case
        when status in ('queued', 'running') then clock_timestamp()
        else finished_at
      end,
      updated_at = clock_timestamp()
  where user_id = p_user_id
    and kind <> 'account_deletion';
  perform public.append_audit_event(
    'user', 'request_deletion', 'account', p_user_id::text,
    'User requested account deletion.', p_user_id, 'user_requested', p_request_id,
    null, '{}'::jsonb, null, null
  );
  update public.profiles
  set account_status = 'deletion_pending',
      deletion_pending_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where user_id = p_user_id;

  return jsonb_build_object(
    'privacy_request', to_jsonb(v_request),
    'job', to_jsonb(v_job)
  );
end;
$$;

alter function public.admin_user_progress_summary(uuid)
  rename to admin_user_progress_summary_unchecked;

revoke all on function public.admin_user_progress_summary_unchecked
  from public, anon, authenticated, service_role;

create function public.admin_user_progress_summary(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_summary jsonb;
  v_consented boolean;
begin
  perform public.purge_expired_user_progress_summaries();
  -- The shared profile lock serializes this materialization with opt-out and deletion. If opt-out
  -- waits behind an in-flight read, it removes that read's snapshot before it returns to the API.
  perform 1 from public.profiles
  where user_id = p_user_id and account_status in ('active', 'suspended')
  for share;
  if not found then
    return null;
  end if;

  select coalesce(operator_learning_analytics_enabled, false)
  into v_consented
  from public.user_analytics_preferences
  where user_id = p_user_id;

  if coalesce(v_consented, false) then
    return public.admin_user_progress_summary_unchecked(p_user_id);
  end if;

  delete from public.user_progress_summaries where user_id = p_user_id;
  with latest_entities as (
    select distinct on (entity_type, entity_id)
      entity_type, entity_id, operation
    from public.sync_changes
    where user_id = p_user_id
    order by entity_type, entity_id, sequence desc
  ), entity_counts as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object('entityType', entity_type, 'count', entity_count)
        order by entity_type
      ), '[]'::jsonb
    ) value
    from (
      select entity_type, count(*)::integer entity_count
      from latest_entities
      where operation <> 'delete'
      group by entity_type
    ) counts
  ), last_batch as (
    select b.created_at, b.device_id, d.platform, d.name
    from public.sync_batches b
    left join public.devices d
      on d.user_id = b.user_id and d.id = b.device_id
    where b.user_id = p_user_id
    order by b.created_at desc
    limit 1
  )
  select jsonb_build_object(
    'generatedAt', clock_timestamp(),
    'expiresAt', null,
    'sync', jsonb_build_object(
      'lastSuccessfulAt', (select created_at from last_batch),
      'lastDevice', (
        select case when device_id is null then null else jsonb_build_object(
          'id', device_id, 'platform', coalesce(platform, 'unknown'), 'name', name
        ) end from last_batch
      ),
      'entityCounts', (select value from entity_counts),
      'pendingCount', null,
      'conflictCount', (
        select count(*)::integer from public.sync_mutation_outcomes
        where user_id = p_user_id and status = 'conflict'
      )
    ),
    'reading', null,
    'review', null,
    'learning', null
  ) into v_summary;
  return v_summary;
end;
$$;

create or replace function public.set_user_analytics_preference(
  p_user_id uuid,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_at timestamptz;
begin
  -- Serialize preference changes with summary materialization for this account.
  perform 1 from public.profiles
  where user_id = p_user_id
    and account_status in ('active', 'suspended')
    and deleted_at is null
  for update;
  if not found then
    return null;
  end if;
  insert into public.user_analytics_preferences (
    user_id, operator_learning_analytics_enabled, updated_at
  ) values (p_user_id, p_enabled, clock_timestamp())
  on conflict (user_id) do update
  set operator_learning_analytics_enabled = excluded.operator_learning_analytics_enabled,
      updated_at = excluded.updated_at
  returning updated_at into v_updated_at;
  if not p_enabled then
    delete from public.user_progress_summaries where user_id = p_user_id;
  end if;
  return jsonb_build_object(
    'operatorLearningAnalyticsEnabled', p_enabled,
    'updatedAt', v_updated_at
  );
end;
$$;

create or replace function public.delete_account_data(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.assistant_jobs
  set payload = '{}'::jsonb,
      cache_key = null,
      last_error = null,
      user_id = null,
      updated_at = clock_timestamp()
  where user_id = p_user_id;

  delete from public.profiles where user_id = p_user_id;
  get diagnostics v_count = row_count;
  if v_count > 0 then
    insert into public.profiles (
      user_id, email, display_name, avatar_url, locale, account_status,
      deletion_pending_at, deleted_at, updated_at
    ) values (
      p_user_id, null, null, null, 'en', 'deleted',
      clock_timestamp(), clock_timestamp(), clock_timestamp()
    );
  end if;
  return v_count > 0;
end;
$$;

revoke all on function public.admin_user_progress_summary from public, anon, authenticated;
revoke all on function public.set_user_analytics_preference from public, anon, authenticated;
revoke all on function public.delete_account_data from public, anon, authenticated;
revoke all on function public.claim_assistant_jobs from public, anon, authenticated;
revoke all on function public.request_account_deletion from public, anon, authenticated;
revoke all on table public.object_write_leases from public, anon, authenticated;
grant execute on function public.admin_user_progress_summary to service_role;
grant execute on function public.set_user_analytics_preference to service_role;
grant execute on function public.delete_account_data to service_role;
grant execute on function public.claim_assistant_jobs to service_role;
grant execute on function public.request_account_deletion to service_role;
grant select, insert, delete on table public.object_write_leases to service_role;

comment on function public.admin_user_progress_summary(uuid) is
  'Returns sync health for all accounts and detailed progress only after explicit analytics consent.';
comment on function public.delete_account_data(uuid) is
  'Cascades private rows and retains only an anonymous deleted tombstone before the job completes.';

commit;
