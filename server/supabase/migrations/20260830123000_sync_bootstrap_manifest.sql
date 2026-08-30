-- Initial sync reads latest entity state at one fixed high-water cursor. Historical
-- changes remain available only to the incremental pull path after this bootstrap.
create function public.bootstrap_sync_page(
  p_user_id uuid,
  p_cursor bigint,
  p_offset integer,
  p_limit integer,
  p_max_payload_bytes bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_snapshot_cursor bigint;
  v_entities jsonb;
  v_count integer;
  v_has_more boolean;
begin
  if p_offset < 0 then raise exception 'p_offset must be nonnegative'; end if;
  if p_limit < 1 or p_limit > 500 then raise exception 'p_limit must be between 1 and 500'; end if;
  if p_max_payload_bytes < 65536 or p_max_payload_bytes > 1572864 then
    raise exception 'p_max_payload_bytes is outside the allowed range';
  end if;

  select coalesce(max(sequence), 0)
  into v_snapshot_cursor
  from public.sync_changes
  where user_id = p_user_id;
  if p_cursor is not null then
    if p_cursor < 0 or p_cursor > v_snapshot_cursor then
      raise exception 'p_cursor is outside the available history';
    end if;
    v_snapshot_cursor := p_cursor;
  end if;

  with latest as materialized (
    select distinct on (entity_type, entity_id)
      sequence, entity_type, entity_id, operation, revision, changed_at, payload
    from public.sync_changes
    where user_id = p_user_id and sequence <= v_snapshot_cursor
    order by entity_type, entity_id, sequence desc
  ), candidates as materialized (
    select *, octet_length(payload::text) + 512 as encoded_bytes
    from latest
    order by entity_type, entity_id
    offset p_offset
    limit p_limit
  ), sized as (
    select *, row_number() over (order by entity_type, entity_id) as row_number,
      sum(encoded_bytes) over (order by entity_type, entity_id) as cumulative_bytes
    from candidates
  ), page as (
    select * from sized
    where row_number = 1 or cumulative_bytes <= p_max_payload_bytes
    order by entity_type, entity_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'sequence', sequence,
      'entity_type', entity_type,
      'entity_id', entity_id,
      'operation', operation,
      'revision', revision,
      'changed_at', changed_at,
      'payload', payload
    ) order by entity_type, entity_id), '[]'::jsonb), count(*)::integer
  into v_entities, v_count
  from page;

  with latest as (
    select distinct entity_type, entity_id
    from public.sync_changes
    where user_id = p_user_id and sequence <= v_snapshot_cursor
  )
  select count(*) > p_offset + v_count into v_has_more from latest;

  return jsonb_build_object(
    'entities', v_entities,
    'cursor', v_snapshot_cursor::text,
    'nextOffset', p_offset + v_count,
    'hasMore', v_has_more
  );
end;
$$;

comment on function public.bootstrap_sync_page is
  'Returns paged latest entity state at a fixed cursor for initial sync manifests.';

revoke all on function public.bootstrap_sync_page from public, anon, authenticated;
grant execute on function public.bootstrap_sync_page to service_role;
