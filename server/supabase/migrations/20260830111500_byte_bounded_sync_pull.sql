-- Bound sync pull responses inside Postgres so transcript-heavy accounts do not
-- materialize multi-megabyte pages in the Worker isolate.
create function public.pull_sync_page(
  p_user_id uuid,
  p_cursor bigint,
  p_limit integer,
  p_max_payload_bytes bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_changes jsonb;
  v_cursor bigint;
  v_has_more boolean;
begin
  if p_cursor < 0 then
    raise exception 'p_cursor must be nonnegative';
  end if;
  if p_limit < 1 or p_limit > 500 then
    raise exception 'p_limit must be between 1 and 500';
  end if;
  if p_max_payload_bytes < 65536 or p_max_payload_bytes > 1572864 then
    raise exception 'p_max_payload_bytes is outside the allowed range';
  end if;

  with candidates as materialized (
    select
      sequence,
      entity_type,
      entity_id,
      operation,
      revision,
      changed_at,
      payload,
      octet_length(payload::text) + 512 as encoded_bytes
    from public.sync_changes
    where user_id = p_user_id and sequence > p_cursor
    order by sequence asc
    limit p_limit
  ), sized as (
    select
      candidates.*,
      row_number() over (order by sequence asc) as row_number,
      sum(encoded_bytes) over (order by sequence asc) as cumulative_bytes
    from candidates
  ), page as (
    select *
    from sized
    -- Always return one row so an older oversized entity cannot permanently block the cursor.
    where row_number = 1 or cumulative_bytes <= p_max_payload_bytes
    order by sequence asc
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'sequence', sequence,
      'entity_type', entity_type,
      'entity_id', entity_id,
      'operation', operation,
      'revision', revision,
      'changed_at', changed_at,
      'payload', payload
    ) order by sequence asc), '[]'::jsonb),
    coalesce(max(sequence), p_cursor)
  into v_changes, v_cursor
  from page;

  select exists (
    select 1
    from public.sync_changes
    where user_id = p_user_id and sequence > v_cursor
  ) into v_has_more;

  return jsonb_build_object(
    'changes', v_changes,
    'cursor', v_cursor::text,
    'hasMore', v_has_more
  );
end;
$$;

comment on function public.pull_sync_page is
  'Returns a sequence-ordered sync page bounded by row count and encoded payload bytes.';

revoke all on function public.pull_sync_page from public, anon, authenticated;
grant execute on function public.pull_sync_page to service_role;
