-- A clean protocol generation: no v1 sync row or object is eligible in this namespace.
insert into public.service_schema_versions (component, migration_version)
values ('account_sync', '20260831133000')
on conflict (component) do update
set migration_version = excluded.migration_version,
    updated_at = now();

create table public.asset_manifests_v2 (
  id uuid primary key default gen_random_uuid(),
  upload_id uuid not null unique default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  kind text not null,
  content_type text not null,
  encoding text not null,
  compressed_bytes bigint not null,
  original_bytes bigint not null,
  sha256 text not null,
  object_key text not null unique,
  upload_object_key text not null unique,
  revision_id uuid,
  book_id uuid,
  chapter_id uuid,
  segment_count integer,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  ready_at timestamptz,
  upload_cleaned_at timestamptz,
  expires_at timestamptz not null default (now() + interval '1 day'),
  deleted_at timestamptz,
  constraint asset_manifests_v2_kind_check check (kind in (
    'audio', 'epub', 'cover', 'transcriptRevision', 'epubReadingPackage',
    'alignmentPackage', 'mediaAnalysis', 'transcriptExport', 'accountExport',
    'assistantArtifact', 'otherLargeImmutable'
  )),
  constraint asset_manifests_v2_status_check
    check (status in ('pending', 'ready', 'failed', 'deleting')),
  constraint asset_manifests_v2_sha256_check check (sha256 ~ '^[0-9a-f]{64}$'),
  constraint asset_manifests_v2_compressed_bytes_check
    check (compressed_bytes between 1 and 2147483648),
  constraint asset_manifests_v2_original_bytes_check
    check (original_bytes between compressed_bytes and 4294967296),
  constraint asset_manifests_v2_segment_count_check
    check (segment_count is null or segment_count between 0 and 2000000),
  constraint asset_manifests_v2_transcript_metadata_check check (
    kind <> 'transcriptRevision'
    or (
      revision_id is not null
      and chapter_id is not null
      and segment_count is not null
      and encoding = 'identity-json-v1'
      and compressed_bytes = original_bytes
      and compressed_bytes <= 67108864
    )
  ),
  constraint asset_manifests_v2_user_id_id_key unique (user_id, id),
  constraint asset_manifests_v2_user_kind_sha256_key unique (user_id, kind, sha256)
);

create table public.sync_v2_changes (
  sequence bigint generated always as identity primary key,
  id uuid not null unique default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  operation text not null,
  revision bigint not null,
  changed_at timestamptz not null default now(),
  payload jsonb not null,
  constraint sync_v2_changes_entity_type_check check (entity_type in (
    'settings', 'book', 'chapter', 'progress', 'vocabulary', 'lexeme_state',
    'review_event', 'transcript', 'asset', 'transcript_overlay',
    'assistant_result', 'chat_message', 'study_activity'
  )),
  constraint sync_v2_changes_operation_check check (operation in ('upsert', 'delete', 'append')),
  constraint sync_v2_changes_revision_check check (revision >= 1),
  constraint sync_v2_changes_user_sequence_key unique (user_id, sequence)
);

create table public.sync_v2_batches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  device_id uuid not null,
  batch_id uuid not null,
  created_at timestamptz not null default now(),
  constraint sync_v2_batches_user_batch_key unique (user_id, batch_id)
);

create table public.sync_v2_mutation_outcomes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  mutation_id uuid not null,
  status text not null,
  entity_revision bigint,
  problem jsonb,
  created_at timestamptz not null default now(),
  constraint sync_v2_mutation_outcomes_status_check
    check (status in ('applied', 'duplicate', 'conflict', 'rejected')),
  constraint sync_v2_mutation_outcomes_user_mutation_key unique (user_id, mutation_id)
);

create index asset_manifests_v2_ready_quota_idx
  on public.asset_manifests_v2 (user_id, status, compressed_bytes);
create index asset_manifests_v2_pending_gc_idx
  on public.asset_manifests_v2 (status, expires_at);
create index asset_manifests_v2_ready_cleanup_idx
  on public.asset_manifests_v2 (ready_at, id) where status = 'ready' and upload_cleaned_at is null;
create index sync_v2_changes_pull_idx
  on public.sync_v2_changes (user_id, sequence);

alter table public.asset_manifests_v2 enable row level security;
alter table public.asset_manifests_v2 force row level security;
alter table public.sync_v2_changes enable row level security;
alter table public.sync_v2_changes force row level security;
alter table public.sync_v2_batches enable row level security;
alter table public.sync_v2_batches force row level security;
alter table public.sync_v2_mutation_outcomes enable row level security;
alter table public.sync_v2_mutation_outcomes force row level security;

create policy asset_manifests_v2_own_read on public.asset_manifests_v2
  for select to authenticated using (
    user_id = (select auth.uid()) and public.current_user_is_active()
  );
create policy sync_v2_changes_own_read on public.sync_v2_changes
  for select to authenticated using (
    user_id = (select auth.uid()) and public.current_user_is_active()
  );

-- Serializing on the profile row makes pending-count and reserved-byte enforcement atomic.
update public.feature_flags set min_app_version = '2.0.0' where key = 'account_sync';

create function public.reserve_v2_asset_upload(
  p_user_id uuid,
  p_upload_id uuid,
  p_kind text,
  p_content_type text,
  p_encoding text,
  p_compressed_bytes bigint,
  p_original_bytes bigint,
  p_sha256 text,
  p_object_key text,
  p_upload_object_key text,
  p_revision_id uuid,
  p_book_id uuid,
  p_chapter_id uuid,
  p_segment_count integer
)
returns public.asset_manifests_v2
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manifest public.asset_manifests_v2%rowtype;
  v_pending_count bigint;
  v_reserved_bytes bigint;
  v_limit bigint;
begin
  perform 1 from public.profiles where user_id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  select count(*) filter (where status = 'pending'), coalesce(sum(compressed_bytes), 0)
  into v_pending_count, v_reserved_bytes
  from public.asset_manifests_v2
  where user_id = p_user_id and status in ('pending', 'ready');
  select limit_value into v_limit from public.quota_limits where key = 'cloud_media_bytes';
  v_limit := coalesce(v_limit, 10737418240);
  if v_pending_count >= 32 then raise exception 'pending_asset_count_exceeded'; end if;
  if v_reserved_bytes + p_compressed_bytes > v_limit then
    raise exception 'cloud_media_quota_exceeded';
  end if;
  insert into public.asset_manifests_v2 (
    upload_id, user_id, kind, content_type, encoding, compressed_bytes, original_bytes,
    sha256, object_key, upload_object_key, revision_id, book_id, chapter_id, segment_count
  ) values (
    p_upload_id, p_user_id, p_kind, p_content_type, p_encoding, p_compressed_bytes,
    p_original_bytes, p_sha256, p_object_key, p_upload_object_key, p_revision_id,
    p_book_id, p_chapter_id, p_segment_count
  ) returning * into v_manifest;
  return v_manifest;
end;
$$;

-- Object bytes have already been checked by the Worker. This transaction is the only
-- boundary that makes a revision ready and advances the v2 cursor.
create function public.complete_v2_asset_and_publish(
  p_user_id uuid,
  p_upload_id uuid,
  p_verified_compressed_bytes bigint,
  p_verified_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manifest public.asset_manifests_v2%rowtype;
  v_sequence bigint;
begin
  select * into v_manifest
  from public.asset_manifests_v2
  where user_id = p_user_id and upload_id = p_upload_id
  for update;
  if not found then raise exception 'asset upload not found'; end if;
  if v_manifest.status = 'ready' then
    select max(sequence) into v_sequence
    from public.sync_v2_changes
    where user_id = p_user_id
      and entity_id = case when v_manifest.kind = 'transcriptRevision'
        then v_manifest.revision_id else v_manifest.id end;
    return jsonb_build_object('assetId', v_manifest.id, 'cursor', coalesce(v_sequence, 0));
  end if;
  if v_manifest.status <> 'pending' or v_manifest.expires_at <= now() then
    raise exception 'asset upload is not completable';
  end if;
  if v_manifest.compressed_bytes <> p_verified_compressed_bytes
     or v_manifest.sha256 <> p_verified_sha256 then
    raise exception 'asset verification does not match manifest';
  end if;

  update public.asset_manifests_v2
  set status = 'ready', ready_at = now()
  where id = v_manifest.id;

  insert into public.sync_v2_changes (
      user_id, entity_type, entity_id, operation, revision, payload
    ) values (
      p_user_id,
      case when v_manifest.kind = 'transcriptRevision' then 'transcript' else 'asset' end,
      case when v_manifest.kind = 'transcriptRevision' then v_manifest.revision_id else v_manifest.id end,
      'upsert',
      1,
      jsonb_build_object(
        'assetId', v_manifest.id,
        'kind', v_manifest.kind,
        'revisionId', v_manifest.revision_id,
        'bookId', v_manifest.book_id,
        'objectKey', v_manifest.object_key,
        'sha256', v_manifest.sha256,
        'encoding', v_manifest.encoding,
        'compressedBytes', v_manifest.compressed_bytes,
        'originalBytes', v_manifest.original_bytes,
        'segmentCount', v_manifest.segment_count,
        'chapterId', v_manifest.chapter_id
      )
    ) returning sequence into v_sequence;
  return jsonb_build_object('assetId', v_manifest.id, 'cursor', v_sequence);
end;
$$;

-- A ready manifest retains its temporary upload key until storage deletion is confirmed. Jobs may
-- safely claim the same row again after a crash because object deletion is idempotent.
create function public.claim_v2_ready_upload_cleanup(p_limit integer)
returns table(id uuid, upload_object_key text)
language sql
security definer
set search_path = public
as $$
  select m.id, m.upload_object_key
  from public.asset_manifests_v2 m
  where m.status = 'ready' and m.upload_cleaned_at is null
  order by m.ready_at asc, m.id asc
  limit greatest(0, least(p_limit, 1000))
  for update skip locked;
$$;

create function public.finish_v2_ready_upload_cleanup(p_ids uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.asset_manifests_v2
  set upload_cleaned_at = now()
  where id = any(p_ids) and status = 'ready' and upload_cleaned_at is null;
$$;

-- Recursive immutable validation also protects callers that bypass the Worker and invoke the
-- service-role RPC directly. Object bytes have no valid representation in compact sync JSON.
create function public.sync_v2_json_is_bounded(
  p_value jsonb,
  p_depth integer,
  p_schema_key text
)
returns boolean
language plpgsql
immutable
strict
set search_path = public
as $$
declare
  v_item jsonb;
  v_key text;
  v_nested jsonb;
  v_allowed text[];
  v_normalized_key text;
begin
  if p_depth > 8 then return false; end if;
  case jsonb_typeof(p_value)
    when 'string' then return octet_length(p_value #>> '{}') <= 65536;
    when 'number', 'boolean', 'null' then return true;
    when 'array' then
      if jsonb_array_length(p_value) > 4096 then return false; end if;
      for v_item in select value from jsonb_array_elements(p_value)
      loop
        if not public.sync_v2_json_is_bounded(v_item, p_depth + 1, p_schema_key) then
          return false;
        end if;
      end loop;
      return true;
    when 'object' then
      if p_depth > 0 then
        v_allowed := case p_schema_key
          when 'chapters' then array['localId','index','title','duration','startTime']
          when 'result' then array['id','kind','status','language','model','bookID','bookTitle','chapterID','chapterTitle','source','text','context','timestamp','createdAt','decidedAt','replacedText','replacedModel','promptVersion','modelPolicyHash','sharedCacheEntryID','targetID','privateContentJSON']
          when 'vocabulary' then array['id','bookID','chapterID','bookTitle','chapterTitle','word','translation','definition','context','timestamp','addedAt','category','segmentID','wordID','spokenText','ebookText','translationLanguage','translationModel','sourceLanguage','canonicalForm','partOfSpeech','senseID','canonicalizationSource','canonicalizationConfidence','canonicalizationStatus','canonicalizationTraceID','captureSource','reviewEligible','reviewCount','nextReview','lastReviewedAt','lastReviewQuality','reviewIntervalDays','reviewEaseFactor','isInLearnList']
          else null end;
        if v_allowed is null then return false; end if;
      end if;
      for v_key, v_nested in select key, value from jsonb_each(p_value)
      loop
        v_normalized_key := lower(regexp_replace(v_key, '([a-z0-9])([A-Z])', '\1_\2', 'g'));
        if v_normalized_key ~ '(^|_)(bytes?|blob|binary|base64|data|content|body)($|_)' then
          return false;
        end if;
        if v_allowed is not null and v_key <> all(v_allowed) then return false; end if;
        if not public.sync_v2_json_is_bounded(v_nested, p_depth + 1, v_key) then
          return false;
        end if;
      end loop;
      return true;
    else return false;
  end case;
end;
$$;

create function public.push_sync_v2_batch(
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
  v_entity_id uuid;
  v_operation text;
  v_base_revision bigint;
  v_current_revision bigint;
  v_revision bigint;
  v_sequence bigint;
  v_results jsonb := '[]'::jsonb;
  v_assistant_result jsonb;
  v_cache_entry_id uuid;
begin
  if jsonb_typeof(p_mutations) <> 'array' or jsonb_array_length(p_mutations) > 100 then
    raise exception 'v2 mutation batch is invalid';
  end if;
  perform 1 from public.profiles where user_id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;

  insert into public.sync_v2_batches (user_id, device_id, batch_id)
  values (p_user_id, p_device_id, p_batch_id)
  on conflict (user_id, batch_id) do nothing;

  for v_mutation in select value from jsonb_array_elements(p_mutations)
  loop
    v_mutation_id := (v_mutation ->> 'mutationId')::uuid;
    v_entity_type := v_mutation ->> 'entityType';
    v_entity_id := (v_mutation ->> 'entityId')::uuid;
    v_operation := v_mutation ->> 'operation';
    v_base_revision := (v_mutation ->> 'baseRevision')::bigint;
    if v_entity_type is null or v_entity_type <> all(array[
      'settings', 'book', 'chapter', 'progress', 'vocabulary', 'lexeme_state',
      'review_event', 'transcript_overlay', 'assistant_result',
      'chat_message', 'study_activity'
    ]) then
      raise exception 'unsupported v2 entity type';
    end if;
    if pg_column_size(coalesce(v_mutation -> 'payload', '{}'::jsonb)) > 262144 then
      raise exception 'v2 payload exceeds compact sync limit';
    end if;
    if not public.sync_v2_json_is_bounded(
      coalesce(v_mutation -> 'payload', '{}'::jsonb), 0, '__top__'
    ) then
      raise exception 'v2 payload violates recursive compact entity schema';
    end if;
    if v_entity_type in ('transcript', 'asset')
       or (v_mutation -> 'payload') ?| array[
         'transcriptJSON', 'transcriptData', 'transcriptEncoding', 'transcriptOriginalBytes',
         'audioData', 'epubData', 'coverData'
       ] then
      raise exception 'large immutable content is not accepted by sync v2';
    end if;
    if exists (
      select 1 from jsonb_object_keys(coalesce(v_mutation -> 'payload', '{}'::jsonb)) key
      where key <> all(case v_entity_type
        when 'settings' then array['sourceLanguage','targetLanguage','readerLevel','playbackRate','skipSeconds','appearance']
        when 'book' then array['localId','title','author','source','chapters']
        when 'chapter' then array['localId','index','title','duration','startTime','bookId','localBookId']
        when 'progress' then array['progressKind','localProgressId','bookId','chapterId','localBookId','localChapterId','relativeSeconds','updatedAt','deviceId','revision','vocabularyId','reviewCount','nextReview','lastReviewedAt','lastReviewQuality','reviewIntervalDays','reviewEaseFactor']
        when 'vocabulary' then array['vocabularySchemaVersion','bookId','chapterId','localBookId','localChapterId','bookTitle','chapterTitle','surface','lemma','partOfSpeech','senseId','canonicalizationSource','canonicalizationConfidence','canonicalizationStatus','canonicalizationTraceId','captureSource','reviewEligible','category','context','timestampSeconds','state','definition','note','segmentId','wordId','spokenText','ebookText','translationLanguage','translationModel','sourceLanguage','localId']
        when 'lexeme_state' then array['language','lemma','state']
        when 'review_event' then array['vocabularyId','cardId','face','rating','reviewedAt']
        when 'transcript_overlay' then array['chapterId','localChapterId','segmentId','overlayJSON']
        when 'assistant_result' then array['result','vocabulary','removedVocabularyIDs']
        when 'chat_message' then array['threadId','messageId','role','text','createdAt']
        when 'study_activity' then array['day']
        else array[]::text[] end)
    ) then
      raise exception 'v2 payload contains a field outside its entity schema';
    end if;

    select entity_revision into v_revision
    from public.sync_v2_mutation_outcomes
    where user_id = p_user_id and mutation_id = v_mutation_id;
    if found then
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'mutationId', v_mutation_id, 'status', 'duplicate',
        'entityRevision', v_revision, 'problem', null
      ));
      continue;
    end if;

    select revision into v_current_revision
    from public.sync_v2_changes
    where user_id = p_user_id and entity_type = v_entity_type and entity_id = v_entity_id
    order by sequence desc limit 1;
    v_current_revision := coalesce(v_current_revision, 0);
    if v_base_revision <> v_current_revision then
      insert into public.sync_v2_mutation_outcomes (
        user_id, mutation_id, status, entity_revision, problem
      ) values (
        p_user_id, v_mutation_id, 'conflict', v_current_revision,
        jsonb_build_object('title', 'Conflict', 'detail', 'The entity changed on another device.')
      );
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'mutationId', v_mutation_id, 'status', 'conflict',
        'entityRevision', v_current_revision,
        'problem', jsonb_build_object('title', 'Conflict', 'detail', 'The entity changed on another device.')
      ));
      continue;
    end if;

    v_revision := v_current_revision + 1;
    if v_entity_type = 'assistant_result' then
      v_assistant_result := v_mutation -> 'payload' -> 'result';
      if jsonb_typeof(v_assistant_result) <> 'object'
         or coalesce(v_assistant_result ->> 'id', '') <> v_entity_id::text
         or coalesce(v_assistant_result ->> 'status', '') <> all(array[
           'pending', 'accepted', 'rejected', 'stale', 'edited', 'replaced'
         ]) then
        raise exception 'assistant_result payload identity or status is invalid';
      end if;
      v_cache_entry_id := case
        when nullif(v_assistant_result ->> 'sharedCacheEntryID', '') is null then null
        else (v_assistant_result ->> 'sharedCacheEntryID')::uuid
      end;
      if v_cache_entry_id is not null and not exists (
        select 1 from public.assistant_cache_entries where id = v_cache_entry_id
      ) then
        v_cache_entry_id := null;
      end if;
      insert into public.user_assistant_results (
        id, user_id, cache_entry_id, task_type, result_kind, status, language,
        source_text, context_text, book_title, chapter_title, timestamp_seconds,
        output_text, private_content, model, prompt_version, model_policy_hash, decided_at,
        replaced_text, replaced_model, server_version, updated_at
      ) values (
        v_entity_id, p_user_id, v_cache_entry_id,
        case v_assistant_result ->> 'kind'
          when 'chapterSummary' then 'chapter_summary'
          when 'chapterTranslation' then 'chapter_translation'
          else 'translation'
        end,
        v_assistant_result ->> 'kind', v_assistant_result ->> 'status',
        v_assistant_result ->> 'language', v_assistant_result ->> 'source',
        nullif(v_assistant_result ->> 'context', ''),
        nullif(v_assistant_result ->> 'bookTitle', ''),
        nullif(v_assistant_result ->> 'chapterTitle', ''),
        nullif(v_assistant_result ->> 'timestamp', '')::double precision,
        v_assistant_result ->> 'text',
        coalesce(
          nullif(v_assistant_result ->> 'privateContentJSON', '')::jsonb,
          jsonb_build_object('text', v_assistant_result ->> 'text')
        ),
        v_assistant_result ->> 'model',
        v_assistant_result ->> 'promptVersion', v_assistant_result ->> 'modelPolicyHash',
        nullif(v_assistant_result ->> 'decidedAt', '')::timestamptz,
        nullif(v_assistant_result ->> 'replacedText', ''),
        nullif(v_assistant_result ->> 'replacedModel', ''),
        v_revision, clock_timestamp()
      )
      on conflict (id) do update set
        cache_entry_id = excluded.cache_entry_id,
        task_type = excluded.task_type,
        result_kind = excluded.result_kind,
        status = excluded.status,
        language = excluded.language,
        source_text = excluded.source_text,
        context_text = excluded.context_text,
        book_title = excluded.book_title,
        chapter_title = excluded.chapter_title,
        timestamp_seconds = excluded.timestamp_seconds,
        output_text = excluded.output_text,
        private_content = excluded.private_content,
        model = excluded.model,
        prompt_version = excluded.prompt_version,
        model_policy_hash = excluded.model_policy_hash,
        decided_at = excluded.decided_at,
        replaced_text = excluded.replaced_text,
        replaced_model = excluded.replaced_model,
        server_version = excluded.server_version,
        updated_at = excluded.updated_at
      where public.user_assistant_results.user_id = p_user_id;
      if not found then
        raise exception 'assistant_result does not belong to user';
      end if;
    end if;
    insert into public.sync_v2_changes (
      user_id, entity_type, entity_id, operation, revision, changed_at, payload
    ) values (
      p_user_id, v_entity_type, v_entity_id, v_operation, v_revision,
      coalesce((v_mutation ->> 'occurredAt')::timestamptz, clock_timestamp()),
      coalesce(v_mutation -> 'payload', '{}'::jsonb)
    ) returning sequence into v_sequence;
    insert into public.sync_v2_mutation_outcomes (
      user_id, mutation_id, status, entity_revision
    ) values (p_user_id, v_mutation_id, 'applied', v_revision);
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'mutationId', v_mutation_id, 'status', 'applied',
      'entityRevision', v_revision, 'problem', null
    ));
  end loop;
  select coalesce(max(sequence), 0) into v_sequence
  from public.sync_v2_changes where user_id = p_user_id;
  return jsonb_build_object('batchId', p_batch_id, 'cursor', v_sequence::text, 'results', v_results);
end;
$$;

-- Server generation materializes private content and its bootstrap snapshot atomically. The shared
-- cache reference is optional and is discarded when a concurrent/failing cache write left no row.
create function public.record_user_assistant_result(
  p_user_id uuid,
  p_result jsonb
)
returns setof public.user_assistant_results
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := (p_result ->> 'id')::uuid;
  v_cache_entry_id uuid;
  v_revision bigint;
  v_created_at timestamptz := coalesce(
    nullif(p_result ->> 'createdAt', '')::timestamptz,
    clock_timestamp()
  );
  v_row public.user_assistant_results%rowtype;
begin
  perform 1 from public.profiles where user_id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  if coalesce(p_result ->> 'status', '') <> all(array['pending','replaced']) then
    raise exception 'server assistant result status is invalid';
  end if;
  v_cache_entry_id := case
    when nullif(p_result ->> 'cacheEntryId', '') is null then null
    else (p_result ->> 'cacheEntryId')::uuid
  end;
  if v_cache_entry_id is not null and not exists (
    select 1 from public.assistant_cache_entries where id = v_cache_entry_id
  ) then
    v_cache_entry_id := null;
  end if;
  select coalesce(max(revision), 0) + 1 into v_revision
  from public.sync_v2_changes
  where user_id = p_user_id and entity_type = 'assistant_result' and entity_id = v_id;

  insert into public.user_assistant_results (
    id, user_id, cache_entry_id, task_type, result_kind, status, language,
    source_text, context_text, book_title, chapter_title, timestamp_seconds,
    target_id, output_text, private_content, model, prompt_version,
    model_policy_hash, server_version, created_at, updated_at
  ) values (
    v_id, p_user_id, v_cache_entry_id, p_result ->> 'task',
    nullif(p_result ->> 'resultKind', ''), p_result ->> 'status',
    nullif(p_result ->> 'language', ''), nullif(p_result ->> 'sourceText', ''),
    nullif(p_result ->> 'contextText', ''), nullif(p_result ->> 'bookTitle', ''),
    nullif(p_result ->> 'chapterTitle', ''),
    nullif(p_result ->> 'timestampSeconds', '')::double precision,
    nullif(p_result ->> 'targetId', ''), p_result ->> 'outputText',
    p_result -> 'privateContent', nullif(p_result ->> 'model', ''),
    nullif(p_result ->> 'promptVersion', ''), nullif(p_result ->> 'modelPolicyHash', ''),
    v_revision, v_created_at, clock_timestamp()
  )
  on conflict (id) do update set
    cache_entry_id = excluded.cache_entry_id,
    task_type = excluded.task_type,
    result_kind = excluded.result_kind,
    status = excluded.status,
    language = excluded.language,
    source_text = excluded.source_text,
    context_text = excluded.context_text,
    book_title = excluded.book_title,
    chapter_title = excluded.chapter_title,
    timestamp_seconds = excluded.timestamp_seconds,
    target_id = excluded.target_id,
    output_text = excluded.output_text,
    private_content = excluded.private_content,
    model = excluded.model,
    prompt_version = excluded.prompt_version,
    model_policy_hash = excluded.model_policy_hash,
    server_version = excluded.server_version,
    updated_at = excluded.updated_at
  where public.user_assistant_results.user_id = p_user_id
  returning * into v_row;
  if not found then raise exception 'assistant_result does not belong to user'; end if;

  if v_row.result_kind is not null then
    insert into public.sync_v2_changes (
      user_id, entity_type, entity_id, operation, revision, changed_at, payload
    ) values (
      p_user_id, 'assistant_result', v_id, 'upsert', v_revision, clock_timestamp(),
      jsonb_build_object(
        'result', jsonb_strip_nulls(jsonb_build_object(
        'id', v_row.id,
        'kind', v_row.result_kind,
        'status', v_row.status,
        'language', coalesce(v_row.language, ''),
        'model', coalesce(v_row.model, ''),
        'promptVersion', coalesce(v_row.prompt_version, ''),
        'modelPolicyHash', coalesce(v_row.model_policy_hash, ''),
        'source', coalesce(v_row.source_text, ''),
        'text', coalesce(v_row.output_text, ''),
        'context', v_row.context_text,
        'bookTitle', v_row.book_title,
        'chapterTitle', v_row.chapter_title,
        'targetID', v_row.target_id,
        'timestamp', v_row.timestamp_seconds,
        'createdAt', v_row.created_at,
        'sharedCacheEntryID', v_row.cache_entry_id,
        'privateContentJSON', case
          when v_row.private_content is null then null
          else v_row.private_content::text
        end
        )),
        'vocabulary', '[]'::jsonb
      )
    );
  end if;
  return next v_row;
end;
$$;

create function public.pull_sync_v2_page(
  p_user_id uuid,
  p_cursor bigint,
  p_limit integer,
  p_max_payload_bytes bigint
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with page as materialized (
    select sequence, entity_type, entity_id, operation, revision, changed_at, payload
    from public.sync_v2_changes
    where user_id = p_user_id and sequence > greatest(p_cursor, 0)
    order by sequence
    limit greatest(1, least(p_limit, 500))
  ), bounded as (
    select *, sum(octet_length(payload::text) + 512) over (order by sequence) bytes,
      row_number() over (order by sequence) row_number
    from page
  ), selected as (
    select * from bounded where row_number = 1 or bytes <= p_max_payload_bytes
  ), cursor_value as (
    select coalesce(max(sequence), greatest(p_cursor, 0)) cursor from selected
  )
  select jsonb_build_object(
    'changes', coalesce((select jsonb_agg(jsonb_build_object(
      'sequence', sequence, 'entity_type', entity_type, 'entity_id', entity_id,
      'operation', operation, 'revision', revision, 'changed_at', changed_at, 'payload', payload
    ) order by sequence) from selected), '[]'::jsonb),
    'cursor', (select cursor::text from cursor_value),
    'hasMore', exists(select 1 from public.sync_v2_changes
      where user_id = p_user_id and sequence > (select cursor from cursor_value))
  )
$$;

create function public.bootstrap_sync_v2_page(
  p_user_id uuid,
  p_cursor bigint,
  p_offset integer,
  p_limit integer,
  p_max_payload_bytes bigint
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with high_water as (
    select case when p_cursor is null then coalesce(max(sequence), 0) else p_cursor end cursor
    from public.sync_v2_changes where user_id = p_user_id
  ), latest as materialized (
    select distinct on (entity_type, entity_id)
      sequence, entity_type, entity_id, operation, revision, changed_at, payload
    from public.sync_v2_changes, high_water
    where user_id = p_user_id and sequence <= high_water.cursor
    order by entity_type, entity_id, sequence desc
  ), candidate_page as (
    select * from latest order by entity_type, entity_id
    offset greatest(p_offset, 0) limit greatest(1, least(p_limit, 500))
  ), bounded as (
    select *, sum(octet_length(payload::text) + 512) over (order by entity_type, entity_id) bytes,
      row_number() over (order by entity_type, entity_id) row_number
    from candidate_page
  ), page as (
    select * from bounded where row_number = 1 or bytes <= p_max_payload_bytes
  )
  select jsonb_build_object(
    'entities', coalesce((select jsonb_agg(jsonb_build_object(
      'sequence', sequence, 'entity_type', entity_type, 'entity_id', entity_id,
      'operation', operation, 'revision', revision, 'changed_at', changed_at, 'payload', payload
    ) order by entity_type, entity_id) from page), '[]'::jsonb),
    'cursor', (select cursor::text from high_water),
    'nextOffset', greatest(p_offset, 0) + (select count(*) from page),
    'hasMore', (select count(*) from latest) > greatest(p_offset, 0) + (select count(*) from page)
  )
$$;

-- Explicit scheduled maintenance; deployment never deletes legacy or pending data automatically.
create function public.gc_abandoned_v2_uploads(p_before timestamptz, p_limit integer)
returns table (id uuid, upload_object_key text, object_key text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  update public.asset_manifests_v2 manifests
  set status = 'deleting'
  where manifests.id in (
    select candidate.id from public.asset_manifests_v2 candidate
    where (candidate.status = 'pending' and candidate.expires_at < p_before)
       or candidate.status = 'deleting'
    order by candidate.expires_at
    limit greatest(0, least(p_limit, 1000))
    for update skip locked
  )
  returning manifests.id, manifests.upload_object_key, manifests.object_key;
end;
$$;

-- Manifests remain durable in deleting state until every referenced object deletion succeeds.
create function public.finish_v2_asset_upload_gc(p_ids uuid[])
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_deleted bigint;
begin
  delete from public.asset_manifests_v2 where status = 'deleting' and id = any(p_ids);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- A separate operator job may call this after an explicit approval; it is never invoked by cutover.
create function public.cleanup_obsolete_v1_data(p_user_id uuid, p_execute boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_changes bigint;
  v_outcomes bigint;
  v_batches bigint;
  v_revisions bigint;
  v_segments bigint;
  v_assets bigint;
  v_object_keys jsonb;
begin
  select count(*) into v_changes from public.sync_changes where user_id = p_user_id;
  select count(*) into v_outcomes from public.sync_mutation_outcomes where user_id = p_user_id;
  select count(*) into v_batches from public.sync_batches where user_id = p_user_id;
  select count(*) into v_revisions from public.transcript_revisions where user_id = p_user_id;
  select count(*) into v_segments from public.transcript_segments where user_id = p_user_id;
  select count(*) into v_assets from public.book_assets where user_id = p_user_id;
  select coalesce(jsonb_agg(object_key order by object_key), '[]'::jsonb) into v_object_keys
  from (
    select object_key from public.book_assets where user_id = p_user_id and object_key is not null
    union
    select object_key from public.transcript_revisions where user_id = p_user_id and object_key is not null
  ) keys;
  if p_execute then
    delete from public.transcript_segments where user_id = p_user_id;
    delete from public.transcript_revisions where user_id = p_user_id;
    delete from public.book_assets where user_id = p_user_id;
    delete from public.sync_mutation_outcomes where user_id = p_user_id;
    delete from public.sync_batches where user_id = p_user_id;
    delete from public.sync_changes where user_id = p_user_id;
  end if;
  return jsonb_build_object(
    'changes', v_changes, 'outcomes', v_outcomes, 'batches', v_batches,
    'transcriptRevisions', v_revisions, 'transcriptSegments', v_segments,
    'assets', v_assets, 'objectKeys', v_object_keys, 'executed', p_execute
  );
end;
$$;

revoke all on table public.asset_manifests_v2 from public, anon, authenticated;
revoke all on table public.sync_v2_changes from public, anon, authenticated;
revoke all on table public.sync_v2_batches from public, anon, authenticated;
revoke all on table public.sync_v2_mutation_outcomes from public, anon, authenticated;
grant select on table public.asset_manifests_v2, public.sync_v2_changes to authenticated;
grant all on table public.asset_manifests_v2, public.sync_v2_changes,
  public.sync_v2_batches, public.sync_v2_mutation_outcomes to service_role;
revoke all on function public.complete_v2_asset_and_publish from public, anon, authenticated;
grant execute on function public.complete_v2_asset_and_publish to service_role;
revoke all on function public.claim_v2_ready_upload_cleanup(integer)
  from public, anon, authenticated;
grant execute on function public.claim_v2_ready_upload_cleanup(integer) to service_role;
revoke all on function public.finish_v2_ready_upload_cleanup(uuid[])
  from public, anon, authenticated;
grant execute on function public.finish_v2_ready_upload_cleanup(uuid[]) to service_role;
revoke all on function public.reserve_v2_asset_upload from public, anon, authenticated;
grant execute on function public.reserve_v2_asset_upload to service_role;
revoke all on function public.sync_v2_json_is_bounded(jsonb, integer, text)
  from public, anon, authenticated;
grant execute on function public.sync_v2_json_is_bounded(jsonb, integer, text) to service_role;
revoke all on function public.push_sync_v2_batch from public, anon, authenticated;
grant execute on function public.push_sync_v2_batch to service_role;
revoke all on function public.record_user_assistant_result(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.record_user_assistant_result(uuid, jsonb) to service_role;
revoke all on function public.pull_sync_v2_page from public, anon, authenticated;
grant execute on function public.pull_sync_v2_page to service_role;
revoke all on function public.bootstrap_sync_v2_page from public, anon, authenticated;
grant execute on function public.bootstrap_sync_v2_page to service_role;
revoke all on function public.gc_abandoned_v2_uploads(timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.gc_abandoned_v2_uploads(timestamptz, integer) to service_role;
revoke all on function public.finish_v2_asset_upload_gc(uuid[]) from public, anon, authenticated;
grant execute on function public.finish_v2_asset_upload_gc(uuid[]) to service_role;
revoke all on function public.cleanup_obsolete_v1_data(uuid, boolean) from public, anon, authenticated;
grant execute on function public.cleanup_obsolete_v1_data(uuid, boolean) to service_role;
