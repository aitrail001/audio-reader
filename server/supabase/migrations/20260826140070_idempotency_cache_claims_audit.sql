-- Phase 4.3/4.4 transaction functions: idempotency record/replay, sync
-- versioning, single-flight cache claims, atomic job complete/fail, and
-- immutable audit events. Unique indexes remain the final concurrency
-- guarantee. EXECUTE is service_role only.

create function public.redact_audit_metadata(p_value jsonb)
returns jsonb
language plpgsql
immutable
strict
set search_path = public
as $$
declare
  v_out jsonb;
  v_key text;
  v_normalized text;
  v_i integer;
begin
  if jsonb_typeof(p_value) = 'array' then
    v_out := '[]'::jsonb;
    for v_i in 0 .. jsonb_array_length(p_value) - 1 loop
      v_out := v_out || jsonb_build_array(public.redact_audit_metadata(p_value -> v_i));
    end loop;
    return v_out;
  end if;

  if jsonb_typeof(p_value) <> 'object' then
    return p_value;
  end if;

  v_out := '{}'::jsonb;
  for v_key in select jsonb_object_keys(p_value)
  loop
    v_normalized := regexp_replace(lower(v_key), '[-_]', '', 'g');
    if v_normalized in (
      'password',
      'secret',
      'token',
      'apikey',
      'authorization',
      'accesstoken',
      'refreshtoken',
      'idtoken',
      'cookie',
      'setcookie',
      'privatekey',
      'sourcetext',
      'sourcepassage',
      'spokentext',
      'rawaudio'
    ) then
      v_out := v_out || jsonb_build_object(v_key, '<redacted>');
    else
      v_out := v_out || jsonb_build_object(v_key, public.redact_audit_metadata(p_value -> v_key));
    end if;
  end loop;
  return v_out;
end;
$$;

create function public.protect_audit_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := clock_timestamp();
    new.metadata := public.redact_audit_metadata(new.metadata);
    new.before_metadata := public.redact_audit_metadata(new.before_metadata);
    new.after_metadata := public.redact_audit_metadata(new.after_metadata);
    return new;
  end if;
  raise exception 'audit_events are immutable';
end;
$$;

create trigger audit_events_protect
  before insert or update or delete on public.audit_events
  for each row execute function public.protect_audit_events();

create function public.claim_idempotency_record(
  p_user_id uuid,
  p_key text,
  p_method text,
  p_pathname text,
  p_fingerprint text,
  p_expires_at timestamptz default now() + interval '24 hours'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method text := upper(p_method);
  v_id uuid;
  v_row public.idempotency_records%rowtype;
  v_try integer;
begin
  for v_try in 1..5 loop
    insert into public.idempotency_records (
      user_id, key, method, pathname, fingerprint, status, expires_at
    ) values (
      p_user_id, p_key, v_method, p_pathname, p_fingerprint, 'in_progress', p_expires_at
    )
    on conflict (user_id, method, pathname, key) do nothing
    returning id into v_id;

    if v_id is not null then
      return jsonb_build_object(
        'status', 'claimed',
        'id', v_id,
        'fingerprint', p_fingerprint
      );
    end if;

    select * into v_row
    from public.idempotency_records
    where user_id = p_user_id
      and method = v_method
      and pathname = p_pathname
      and key = p_key;

    if not found then
      continue;
    end if;

    if v_row.expires_at is not null and v_row.expires_at < clock_timestamp() then
      delete from public.idempotency_records where id = v_row.id;
      continue;
    end if;

    if v_row.fingerprint <> p_fingerprint then
      return jsonb_build_object(
        'status', 'conflict',
        'id', v_row.id,
        'fingerprint', v_row.fingerprint
      );
    end if;

    if v_row.status = 'completed' then
      return jsonb_build_object(
        'status', 'replay',
        'id', v_row.id,
        'fingerprint', v_row.fingerprint,
        'response_status', v_row.response_status,
        'response_headers', v_row.response_headers,
        'response_body', v_row.response_body
      );
    end if;

    return jsonb_build_object(
      'status', 'in_progress',
      'id', v_row.id,
      'fingerprint', v_row.fingerprint
    );
  end loop;

  raise exception 'could not claim idempotency record';
end;
$$;

create function public.record_idempotency_response(
  p_user_id uuid,
  p_key text,
  p_method text,
  p_pathname text,
  p_fingerprint text,
  p_response_status integer,
  p_response_headers jsonb,
  p_response_body text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method text := upper(p_method);
  v_row public.idempotency_records%rowtype;
begin
  select * into v_row
  from public.idempotency_records
  where user_id = p_user_id
    and method = v_method
    and pathname = p_pathname
    and key = p_key
  for update;

  if not found then
    raise exception 'idempotency record not found';
  end if;

  if v_row.fingerprint <> p_fingerprint then
    return jsonb_build_object(
      'status', 'conflict',
      'id', v_row.id,
      'fingerprint', v_row.fingerprint
    );
  end if;

  if v_row.status = 'completed' then
    return jsonb_build_object(
      'status', 'completed',
      'id', v_row.id,
      'fingerprint', v_row.fingerprint,
      'response_status', v_row.response_status,
      'response_headers', v_row.response_headers,
      'response_body', v_row.response_body
    );
  end if;

  update public.idempotency_records
  set
    status = 'completed',
    response_status = p_response_status,
    response_headers = p_response_headers,
    response_body = p_response_body,
    updated_at = clock_timestamp()
  where id = v_row.id
  returning * into v_row;

  return jsonb_build_object(
    'status', 'completed',
    'id', v_row.id,
    'fingerprint', v_row.fingerprint,
    'response_status', v_row.response_status,
    'response_headers', v_row.response_headers,
    'response_body', v_row.response_body
  );
end;
$$;

create function public.abort_idempotency_record(
  p_user_id uuid,
  p_key text,
  p_method text,
  p_pathname text,
  p_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  delete from public.idempotency_records
  where user_id = p_user_id
    and method = upper(p_method)
    and pathname = p_pathname
    and key = p_key
    and fingerprint = p_fingerprint
    and status = 'in_progress'
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('status', 'missing');
  end if;

  return jsonb_build_object('status', 'aborted', 'id', v_id);
end;
$$;

create function public.append_sync_change(
  p_user_id uuid,
  p_entity_type text,
  p_entity_id text,
  p_operation text,
  p_mutation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.sync_changes%rowtype;
  v_entity_uuid uuid;
  v_revision bigint;
  v_seq bigint;
  v_id uuid;
begin
  if p_entity_type not in (
    'profiles',
    'devices',
    'user_settings',
    'books',
    'book_assets',
    'chapters',
    'reading_progress',
    'transcript_revisions',
    'transcript_segments',
    'vocabulary_occurrences',
    'known_lemmas',
    'review_cards',
    'review_events',
    'user_assistant_results'
  ) then
    raise exception 'unknown sync entity type: %', p_entity_type;
  end if;

  if p_operation not in ('upsert', 'delete', 'append') then
    raise exception 'unknown sync operation: %', p_operation;
  end if;

  v_entity_uuid := p_entity_id::uuid;

  perform 1 from public.profiles where user_id = p_user_id for update;
  if not found then
    raise exception 'profile not found';
  end if;

  if p_mutation_id is not null then
    select * into v_existing
    from public.sync_changes
    where user_id = p_user_id and mutation_id = p_mutation_id;
    if found then
      return jsonb_build_object(
        'status', 'replay',
        'id', v_existing.id,
        'sequence', v_existing.sequence,
        'revision', v_existing.revision
      );
    end if;
  end if;

  execute format(
    'update public.%I
        set server_version = server_version + 1,
            updated_at = clock_timestamp(),
            last_mutation_id = $1,
            deleted_at = case
              when $2 = ''delete'' then coalesce(deleted_at, clock_timestamp())
              else deleted_at
            end
      where user_id = $3 and id = $4
      returning server_version',
    p_entity_type
  )
  into v_revision
  using p_mutation_id, p_operation, p_user_id, v_entity_uuid;

  if v_revision is null then
    raise exception 'sync entity % % not found', p_entity_type, p_entity_id;
  end if;

  select coalesce(max(sequence), 0) + 1
  into v_seq
  from public.sync_changes
  where user_id = p_user_id;

  insert into public.sync_changes (
    user_id, sequence, entity_type, entity_id, operation, revision, mutation_id, payload
  ) values (
    p_user_id,
    v_seq,
    p_entity_type,
    p_entity_id,
    p_operation,
    v_revision,
    p_mutation_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  returning id into v_id;

  return jsonb_build_object(
    'status', 'appended',
    'id', v_id,
    'sequence', v_seq,
    'revision', v_revision
  );
end;
$$;

create function public.attach_user_assistant_result(
  p_user_id uuid,
  p_job_id uuid,
  p_book_id uuid default null,
  p_chapter_id uuid default null,
  p_task_type text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.assistant_jobs%rowtype;
  v_task text;
  v_result_id uuid;
  v_cache_id uuid;
  v_output text;
begin
  select * into v_job
  from public.assistant_jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'assistant job not found';
  end if;

  if v_job.status not in ('queued', 'running', 'succeeded') then
    return jsonb_build_object(
      'status', 'unavailable',
      'job_id', v_job.id,
      'job_status', v_job.status
    );
  end if;

  v_task := coalesce(nullif(p_task_type, ''), v_job.kind);
  v_cache_id := v_job.cache_entry_id;
  if v_job.status = 'succeeded' and v_cache_id is not null then
    select coalesce(result->>'text', result->>'output')
    into v_output
    from public.assistant_cache_entries
    where id = v_cache_id;
  end if;

  select id into v_result_id
  from public.user_assistant_results
  where user_id = p_user_id
    and job_id = p_job_id
    and task_type = v_task
    and deleted_at is null
    and chapter_id is not distinct from p_chapter_id
  order by created_at
  limit 1;

  if v_result_id is null then
    insert into public.user_assistant_results (
      user_id, job_id, cache_entry_id, book_id, chapter_id, task_type, status, output_text
    ) values (
      p_user_id, p_job_id, v_cache_id, p_book_id, p_chapter_id, v_task, 'pending', v_output
    )
    returning id into v_result_id;
  elsif v_job.status = 'succeeded' then
    update public.user_assistant_results
    set
      cache_entry_id = coalesce(v_cache_id, cache_entry_id),
      output_text = coalesce(v_output, output_text),
      updated_at = clock_timestamp()
    where id = v_result_id;
  end if;

  return jsonb_build_object(
    'status', 'attached',
    'job_id', v_job.id,
    'result_id', v_result_id,
    'job_status', v_job.status,
    'cache_entry_id', v_cache_id,
    'output_text', v_output
  );
end;
$$;

-- Unique index assistant_jobs_inflight_cache_key_uidx is the final guarantee
-- that two in-flight jobs cannot own the same cache_key.
create function public.claim_assistant_generation(
  p_user_id uuid,
  p_cache_key text,
  p_kind text,
  p_book_id uuid default null,
  p_chapter_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cache public.assistant_cache_entries%rowtype;
  v_job public.assistant_jobs%rowtype;
  v_job_id uuid;
  v_result_id uuid;
  v_out jsonb;
  v_try integer;
begin
  if p_cache_key is null or length(trim(p_cache_key)) = 0 then
    raise exception 'cache_key is required';
  end if;

  for v_try in 1..8 loop
    select * into v_cache
    from public.assistant_cache_entries
    where cache_key = p_cache_key and state = 'active';

    if found then
      update public.assistant_cache_entries
      set
        hit_count = hit_count + 1,
        last_hit_at = clock_timestamp(),
        updated_at = clock_timestamp()
      where id = v_cache.id;

      select * into v_job
      from public.assistant_jobs
      where cache_key = p_cache_key and status = 'succeeded'
      order by finished_at desc nulls last
      limit 1;

      if found then
        v_out := public.attach_user_assistant_result(
          p_user_id, v_job.id, p_book_id, p_chapter_id, p_kind
        );
        if v_out->>'status' = 'unavailable' then
          continue;
        end if;
        return v_out || jsonb_build_object(
          'status', 'cache_hit',
          'cache_entry_id', v_cache.id
        );
      end if;

      insert into public.user_assistant_results (
        user_id, cache_entry_id, book_id, chapter_id, task_type, status, output_text
      ) values (
        p_user_id,
        v_cache.id,
        p_book_id,
        p_chapter_id,
        p_kind,
        'pending',
        coalesce(v_cache.result->>'text', v_cache.result->>'output')
      )
      returning id into v_result_id;

      return jsonb_build_object(
        'status', 'cache_hit',
        'job_id', null,
        'result_id', v_result_id,
        'job_status', null,
        'cache_entry_id', v_cache.id,
        'output_text', coalesce(v_cache.result->>'text', v_cache.result->>'output')
      );
    end if;

    select * into v_job
    from public.assistant_jobs
    where cache_key = p_cache_key and status in ('queued', 'running')
    order by created_at
    limit 1;

    if found then
      v_out := public.attach_user_assistant_result(
        p_user_id, v_job.id, p_book_id, p_chapter_id, p_kind
      );
      if v_out->>'status' = 'unavailable' then
        continue;
      end if;
      return v_out;
    end if;

    begin
      insert into public.assistant_jobs (user_id, cache_key, kind, status)
      values (p_user_id, p_cache_key, p_kind, 'queued')
      returning id into v_job_id;
    exception
      when unique_violation then
        continue;
    end;

    v_out := public.attach_user_assistant_result(
      p_user_id, v_job_id, p_book_id, p_chapter_id, p_kind
    );
    if v_out->>'status' = 'unavailable' then
      continue;
    end if;
    return v_out || jsonb_build_object('status', 'claimed', 'job_status', 'queued');
  end loop;

  raise exception 'could not claim assistant generation for cache_key %', p_cache_key;
end;
$$;

create function public.complete_assistant_job(
  p_job_id uuid,
  p_result jsonb,
  p_task_type text default null,
  p_source_language text default 'en',
  p_target_language text default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.assistant_jobs%rowtype;
  v_task text;
  v_cache_id uuid;
  v_cache_state text;
begin
  select * into v_job
  from public.assistant_jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'assistant job not found';
  end if;

  if v_job.status = 'succeeded' then
    return jsonb_build_object(
      'status', 'succeeded',
      'job_id', v_job.id,
      'cache_entry_id', v_job.cache_entry_id
    );
  end if;

  if v_job.status not in ('queued', 'running') then
    raise exception 'job % cannot be completed from status %', p_job_id, v_job.status;
  end if;

  if v_job.cache_key is null or length(trim(v_job.cache_key)) = 0 then
    raise exception 'job % has no cache_key', p_job_id;
  end if;

  v_task := coalesce(nullif(p_task_type, ''), v_job.kind);

  begin
    insert into public.assistant_cache_entries (
      cache_key, task_type, source_language, target_language, state, result
    ) values (
      v_job.cache_key, v_task, p_source_language, p_target_language, 'active', p_result
    )
    returning id into v_cache_id;
  exception
    when unique_violation then
      select id, state into v_cache_id, v_cache_state
      from public.assistant_cache_entries
      where cache_key = v_job.cache_key
      for update;
      if v_cache_id is null then
        raise exception 'cache entry for % missing after unique conflict', v_job.cache_key;
      end if;
      if v_cache_state is distinct from 'active' then
        raise exception 'cache entry % is not active (state %)', v_cache_id, v_cache_state;
      end if;
  end;

  update public.assistant_jobs
  set
    status = 'succeeded',
    cache_entry_id = v_cache_id,
    started_at = coalesce(started_at, clock_timestamp()),
    finished_at = clock_timestamp(),
    updated_at = clock_timestamp(),
    last_error = null
  where id = p_job_id;

  update public.user_assistant_results
  set
    cache_entry_id = v_cache_id,
    output_text = coalesce(p_result->>'text', output_text),
    updated_at = clock_timestamp()
  where job_id = p_job_id and deleted_at is null;

  return jsonb_build_object(
    'status', 'succeeded',
    'job_id', p_job_id,
    'cache_entry_id', v_cache_id
  );
end;
$$;

create function public.fail_assistant_job(
  p_job_id uuid,
  p_error text,
  p_dead_letter boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.assistant_jobs%rowtype;
  v_attempts integer;
  v_status text;
begin
  select * into v_job
  from public.assistant_jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'assistant job not found';
  end if;

  if v_job.status = 'succeeded' then
    raise exception 'cannot fail a succeeded job';
  end if;

  if v_job.status in ('failed', 'dead_letter', 'cancelled') and not p_dead_letter then
    return jsonb_build_object(
      'status', v_job.status,
      'job_id', v_job.id,
      'attempts', v_job.attempts
    );
  end if;

  if v_job.status = 'dead_letter' then
    return jsonb_build_object(
      'status', 'dead_letter',
      'job_id', v_job.id,
      'attempts', v_job.attempts
    );
  end if;

  v_attempts := v_job.attempts + 1;
  if p_dead_letter or v_attempts >= v_job.max_attempts then
    v_status := 'dead_letter';
  else
    v_status := 'failed';
  end if;

  update public.assistant_jobs
  set
    status = v_status,
    attempts = v_attempts,
    last_error = p_error,
    started_at = coalesce(started_at, clock_timestamp()),
    finished_at = clock_timestamp(),
    updated_at = clock_timestamp()
  where id = p_job_id;

  return jsonb_build_object(
    'status', v_status,
    'job_id', p_job_id,
    'attempts', v_attempts
  );
end;
$$;

create function public.append_audit_event(
  p_actor_type text,
  p_action text,
  p_resource_type text,
  p_resource_id text,
  p_reason text,
  p_actor_id uuid default null,
  p_reason_code text default null,
  p_request_id text default null,
  p_source_ip_hash text default null,
  p_metadata jsonb default null,
  p_before_metadata jsonb default null,
  p_after_metadata jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_created timestamptz;
begin
  insert into public.audit_events (
    actor_id,
    actor_type,
    action,
    resource_type,
    resource_id,
    reason_code,
    reason,
    request_id,
    source_ip_hash,
    metadata,
    before_metadata,
    after_metadata
  ) values (
    p_actor_id,
    p_actor_type,
    p_action,
    p_resource_type,
    p_resource_id,
    p_reason_code,
    p_reason,
    p_request_id,
    p_source_ip_hash,
    public.redact_audit_metadata(p_metadata),
    public.redact_audit_metadata(p_before_metadata),
    public.redact_audit_metadata(p_after_metadata)
  )
  returning id, created_at into v_id, v_created;

  return jsonb_build_object('id', v_id, 'created_at', v_created);
end;
$$;

revoke update, delete, truncate on table public.audit_events
  from public, anon, authenticated, service_role;
grant select, insert on table public.audit_events to service_role;

revoke all on function public.redact_audit_metadata from public, anon, authenticated;
revoke all on function public.protect_audit_events from public, anon, authenticated;
grant execute on function public.protect_audit_events to service_role;

revoke all on function public.claim_idempotency_record from public, anon, authenticated;
grant execute on function public.claim_idempotency_record to service_role;
revoke all on function public.record_idempotency_response from public, anon, authenticated;
grant execute on function public.record_idempotency_response to service_role;
revoke all on function public.abort_idempotency_record from public, anon, authenticated;
grant execute on function public.abort_idempotency_record to service_role;
revoke all on function public.append_sync_change from public, anon, authenticated;
grant execute on function public.append_sync_change to service_role;
revoke all on function public.claim_assistant_generation from public, anon, authenticated;
grant execute on function public.claim_assistant_generation to service_role;
revoke all on function public.attach_user_assistant_result from public, anon, authenticated;
grant execute on function public.attach_user_assistant_result to service_role;
revoke all on function public.complete_assistant_job from public, anon, authenticated;
grant execute on function public.complete_assistant_job to service_role;
revoke all on function public.fail_assistant_job from public, anon, authenticated;
grant execute on function public.fail_assistant_job to service_role;
revoke all on function public.append_audit_event from public, anon, authenticated;
grant execute on function public.append_audit_event to service_role;
