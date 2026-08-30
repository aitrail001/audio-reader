create table public.sync_batches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  batch_id uuid not null,
  mutation_fingerprint text not null,
  created_at timestamptz not null default now(),
  unique (user_id, batch_id)
);

create table public.sync_mutation_outcomes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  mutation_id uuid not null,
  status text not null,
  entity_revision bigint,
  problem jsonb not null,
  created_at timestamptz not null default now(),
  unique (user_id, mutation_id),
  constraint sync_mutation_outcomes_status_check check (status in ('conflict', 'rejected')),
  constraint sync_mutation_outcomes_revision_check
    check (entity_revision is null or entity_revision >= 0)
);

alter table public.sync_batches enable row level security;
alter table public.sync_batches force row level security;
alter table public.sync_mutation_outcomes enable row level security;
alter table public.sync_mutation_outcomes force row level security;

create function public.push_sync_batch(
  p_user_id uuid,
  p_device_id uuid,
  p_batch_id uuid,
  p_mutations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mutation jsonb;
  v_mutation_id uuid;
  v_entity_type text;
  v_entity_id text;
  v_operation text;
  v_base_revision bigint;
  v_current_revision bigint;
  v_entity_revision bigint;
  v_sequence bigint;
  v_existing public.sync_changes%rowtype;
  v_outcome public.sync_mutation_outcomes%rowtype;
  v_settings public.user_settings%rowtype;
  v_batch_fingerprint text;
  v_existing_batch_fingerprint text;
  v_problem jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_mutations) <> 'array' then
    raise exception 'p_mutations must be an array';
  end if;
  if jsonb_array_length(p_mutations) > 500 then
    raise exception 'p_mutations exceeds the 500 item limit';
  end if;
  if (
    select count(*) <> count(distinct value ->> 'mutationId')
    from jsonb_array_elements(p_mutations)
  ) then
    raise exception 'mutationId must be unique within the batch';
  end if;

  -- One profile lock serializes sequence allocation and entity revision checks for this account.
  perform 1 from public.profiles where user_id = p_user_id for update;
  if not found then
    raise exception 'profile not found';
  end if;

  perform 1
  from public.devices
  where user_id = p_user_id and id = p_device_id and revoked = false;
  if not found then
    raise exception 'active device not found';
  end if;

  v_batch_fingerprint := md5(p_mutations::text);
  select mutation_fingerprint
  into v_existing_batch_fingerprint
  from public.sync_batches
  where user_id = p_user_id and batch_id = p_batch_id;
  if found then
    if v_existing_batch_fingerprint <> v_batch_fingerprint then
      raise exception 'batchId was already used for different mutations';
    end if;
  else
    insert into public.sync_batches (user_id, batch_id, mutation_fingerprint)
    values (p_user_id, p_batch_id, v_batch_fingerprint);
  end if;

  select coalesce(max(sequence), 0)
  into v_sequence
  from public.sync_changes
  where user_id = p_user_id;

  for v_mutation in select value from jsonb_array_elements(p_mutations)
  loop
    v_mutation_id := (v_mutation ->> 'mutationId')::uuid;
    v_entity_type := v_mutation ->> 'entityType';
    v_entity_id := v_mutation ->> 'entityId';
    v_operation := v_mutation ->> 'operation';
    v_base_revision := coalesce((v_mutation ->> 'baseRevision')::bigint, 0);

    if v_entity_type not in (
      'settings', 'book', 'chapter', 'progress', 'vocabulary', 'lexeme_state',
      'review_event', 'transcript', 'transcript_overlay', 'translation_decision',
      'summary_decision', 'chat_message', 'study_activity'
    ) then
      raise exception 'unknown sync entity type: %', v_entity_type;
    end if;
    if v_operation not in ('upsert', 'delete', 'append') then
      raise exception 'unknown sync operation: %', v_operation;
    end if;
    select *
    into v_existing
    from public.sync_changes
    where user_id = p_user_id and mutation_id = v_mutation_id;
    if found then
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'mutationId', v_mutation_id,
        'status', 'duplicate',
        'entityRevision', v_existing.revision,
        'problem', null
      ));
      continue;
    end if;

    select *
    into v_outcome
    from public.sync_mutation_outcomes
    where user_id = p_user_id and mutation_id = v_mutation_id;
    if found then
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'mutationId', v_mutation_id,
        'status', 'duplicate',
        'entityRevision', v_outcome.entity_revision,
        'problem', null
      ));
      continue;
    end if;

    if v_entity_type = 'settings' and v_operation <> 'upsert' then
      v_problem := jsonb_build_object(
        'title', 'Rejected',
        'detail', 'Settings only support upsert.'
      );
      insert into public.sync_mutation_outcomes (
        user_id, mutation_id, status, entity_revision, problem
      ) values (p_user_id, v_mutation_id, 'rejected', null, v_problem);
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'mutationId', v_mutation_id,
        'status', 'rejected',
        'entityRevision', null,
        'problem', v_problem
      ));
      continue;
    end if;

    if v_entity_type = 'settings' then
      select *
      into v_settings
      from public.user_settings
      where user_id = p_user_id
      for update;
      if not found then
        raise exception 'settings not found';
      end if;
      v_current_revision := v_settings.server_version;
    else
      select revision
      into v_current_revision
      from public.sync_changes
      where user_id = p_user_id
        and entity_type = v_entity_type
        and entity_id = v_entity_id
      order by sequence desc
      limit 1;
      v_current_revision := coalesce(v_current_revision, 0);
    end if;

    if v_base_revision < 0 or v_base_revision > v_current_revision then
      v_problem := jsonb_build_object(
        'title', 'Rejected',
        'detail', 'baseRevision is invalid.'
      );
      insert into public.sync_mutation_outcomes (
        user_id, mutation_id, status, entity_revision, problem
      ) values (p_user_id, v_mutation_id, 'rejected', null, v_problem);
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'mutationId', v_mutation_id,
        'status', 'rejected',
        'entityRevision', null,
        'problem', v_problem
      ));
      continue;
    end if;

    if v_current_revision > 0 and v_base_revision < v_current_revision then
      v_problem := jsonb_build_object(
        'title', 'Conflict',
        'detail', 'The entity was updated on another device.'
      );
      insert into public.sync_mutation_outcomes (
        user_id, mutation_id, status, entity_revision, problem
      ) values (p_user_id, v_mutation_id, 'conflict', v_current_revision, v_problem);
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'mutationId', v_mutation_id,
        'status', 'conflict',
        'entityRevision', v_current_revision,
        'problem', v_problem
      ));
      continue;
    end if;

    v_entity_revision := v_current_revision + 1;
    if v_entity_type = 'settings' and v_operation = 'upsert' then
      if v_settings.server_version <> v_base_revision then
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'mutationId', v_mutation_id,
          'status', 'conflict',
          'entityRevision', v_settings.server_version,
          'problem', jsonb_build_object(
            'title', 'Conflict',
            'detail', 'Settings were updated on another device.'
          )
        ));
        continue;
      end if;

      update public.user_settings
      set source_language = case
            when jsonb_typeof(v_mutation -> 'payload' -> 'sourceLanguage') = 'string'
              then v_mutation -> 'payload' ->> 'sourceLanguage'
            else source_language
          end,
          target_language = case
            when jsonb_typeof(v_mutation -> 'payload' -> 'targetLanguage') = 'string'
              then v_mutation -> 'payload' ->> 'targetLanguage'
            else target_language
          end,
          reader_level = case
            when v_mutation -> 'payload' ->> 'readerLevel' in (
              'beginner', 'elementary', 'intermediate', 'upper_intermediate', 'advanced'
            ) then v_mutation -> 'payload' ->> 'readerLevel'
            else reader_level
          end,
          playback_rate = case
            when jsonb_typeof(v_mutation -> 'payload' -> 'playbackRate') = 'number'
              and (v_mutation -> 'payload' ->> 'playbackRate')::numeric between 0.5 and 3
              then (v_mutation -> 'payload' ->> 'playbackRate')::numeric
            else playback_rate
          end,
          skip_seconds = case
            when jsonb_typeof(v_mutation -> 'payload' -> 'skipSeconds') = 'number'
              and (v_mutation -> 'payload' ->> 'skipSeconds')::numeric between 1 and 60
              then (v_mutation -> 'payload' ->> 'skipSeconds')::numeric
            else skip_seconds
          end,
          appearance = case
            when v_mutation -> 'payload' ->> 'appearance' in ('system', 'light', 'dark')
              then v_mutation -> 'payload' ->> 'appearance'
            else appearance
          end,
          server_version = server_version + 1,
          updated_at = clock_timestamp(),
          last_mutation_id = v_mutation_id
      where user_id = p_user_id
      returning server_version into v_entity_revision;
    end if;

    v_sequence := v_sequence + 1;
    insert into public.sync_changes (
      user_id,
      sequence,
      entity_type,
      entity_id,
      operation,
      revision,
      mutation_id,
      payload,
      changed_at
    ) values (
      p_user_id,
      v_sequence,
      v_entity_type,
      v_entity_id,
      v_operation,
      v_entity_revision,
      v_mutation_id,
      coalesce(v_mutation -> 'payload', '{}'::jsonb),
      coalesce((v_mutation ->> 'occurredAt')::timestamptz, clock_timestamp())
    );

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'mutationId', v_mutation_id,
      'status', 'applied',
      'entityRevision', v_entity_revision,
      'problem', null
    ));
  end loop;

  return jsonb_build_object(
    'batchId', p_batch_id,
    'cursor', v_sequence::text,
    'results', v_results
  );
end;
$$;

create index if not exists sync_changes_user_entity_sequence_idx
  on public.sync_changes (user_id, entity_type, entity_id, sequence desc);

comment on function public.push_sync_batch is
  'Applies one authenticated sync batch inside Postgres so Worker CPU does not scale with mutation count.';

revoke all on table public.sync_batches from public, anon, authenticated, service_role;
revoke all on table public.sync_mutation_outcomes from public, anon, authenticated, service_role;
revoke all on function public.push_sync_batch from public, anon, authenticated;
grant execute on function public.push_sync_batch to service_role;
