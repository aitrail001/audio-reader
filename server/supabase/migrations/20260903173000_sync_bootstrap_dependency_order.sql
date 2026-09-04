begin;

-- Order the fixed snapshot by dependency so existing clients commit vocabulary
-- parents before progress and review rows on a new device.
create or replace function public.bootstrap_sync_v2_page(
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
  ), ranked as materialized (
    select *, case entity_type
      when 'book' then 1
      when 'chapter' then 2
      when 'vocabulary' then 3
      when 'settings' then 4
      when 'transcript' then 5
      when 'transcript_overlay' then 6
      when 'lexeme_state' then 7
      when 'progress' then 8
      when 'review_event' then 9
      when 'asset' then 10
      when 'assistant_result' then 11
      when 'study_activity' then 12
      when 'chat_message' then 13
      else 99
    end dependency_rank
    from latest
  ), candidate_page as (
    select * from ranked
    order by dependency_rank, entity_type, entity_id
    offset greatest(p_offset, 0) limit greatest(1, least(p_limit, 500))
  ), bounded as (
    select *, sum(octet_length(payload::text) + 512)
      over (order by dependency_rank, entity_type, entity_id) bytes,
      row_number() over (order by dependency_rank, entity_type, entity_id) row_number
    from candidate_page
  ), page as (
    select * from bounded where row_number = 1 or bytes <= p_max_payload_bytes
  )
  select jsonb_build_object(
    'entities', coalesce((select jsonb_agg(jsonb_build_object(
      'sequence', sequence, 'entity_type', entity_type, 'entity_id', entity_id,
      'operation', operation, 'revision', revision, 'changed_at', changed_at, 'payload', payload
    ) order by dependency_rank, entity_type, entity_id) from page), '[]'::jsonb),
    'cursor', (select cursor::text from high_water),
    'nextOffset', greatest(p_offset, 0) + (select count(*) from page),
    'hasMore', (select count(*) from latest) > greatest(p_offset, 0) + (select count(*) from page)
  )
$$;

insert into public.service_schema_versions (component, migration_version)
values ('account_sync', '20260903173000')
on conflict (component) do update
set migration_version = excluded.migration_version,
    updated_at = now();

commit;
