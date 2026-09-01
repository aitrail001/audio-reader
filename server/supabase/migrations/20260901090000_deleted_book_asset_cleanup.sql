begin;

-- A successfully accepted book tombstone makes every object-backed child unreachable in the same
-- transaction. The Worker removes returned object keys before deleting the durable manifests.

-- Clients before 2.0.1 can still enqueue assets for locally tombstoned books.
update public.feature_flags
set min_app_version = '2.0.1'
where key = 'account_sync';

-- A direct-upload URL cannot be revoked after issuance. Keep the manifest as durable retry state
-- until that capability expires, and serialize new write leases with book cleanup on the profile row.
alter table public.asset_manifests_v2
add column upload_authorized_until timestamptz;

-- The prior Worker could reissue an untracked 15-minute direct URL for an existing row. A full-day
-- rollout guard safely covers migration-to-deployment time plus that final capability lifetime.
update public.asset_manifests_v2
set upload_authorized_until = clock_timestamp() + interval '24 hours'
where status in ('pending', 'ready')
  and compressed_bytes > 8388608;

-- Old Workers can already be holding a bounded request body without a manifest-scoped lease.
-- Retain deleting manifests for a full rollout drain so any late recreation remains GC-addressable.
update public.asset_manifests_v2
set deleted_at = coalesce(deleted_at, clock_timestamp())
where status = 'deleting';

create or replace function public.reserve_v2_asset_upload(
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
  if p_book_id is not null and (
    select changes.operation
    from public.sync_v2_changes changes
    where changes.user_id = p_user_id
      and changes.entity_type = 'book'
      and changes.entity_id = p_book_id
    order by changes.sequence desc
    limit 1
  ) = 'delete' then
    raise exception 'asset book is deleted';
  end if;
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
    sha256, object_key, upload_object_key, revision_id, book_id, chapter_id, segment_count,
    upload_authorized_until
  ) values (
    p_upload_id, p_user_id, p_kind, p_content_type, p_encoding, p_compressed_bytes,
    p_original_bytes, p_sha256, p_object_key, p_upload_object_key, p_revision_id,
    p_book_id, p_chapter_id, p_segment_count,
    case when p_compressed_bytes > 8388608 then clock_timestamp() + interval '15 minutes' end
  ) returning * into v_manifest;
  return v_manifest;
end;
$$;

create function public.authorize_v2_asset_upload(
  p_user_id uuid,
  p_upload_id uuid,
  p_authorized_until timestamptz
)
returns public.asset_manifests_v2
language plpgsql
security definer
set search_path = public
as $$
declare v_manifest public.asset_manifests_v2%rowtype;
begin
  perform 1 from public.profiles where user_id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  select * into v_manifest from public.asset_manifests_v2
  where user_id = p_user_id and upload_id = p_upload_id
  for update;
  if not found or v_manifest.status <> 'pending' then return null; end if;
  if v_manifest.book_id is not null and (
    select changes.operation from public.sync_v2_changes changes
    where changes.user_id = p_user_id and changes.entity_type = 'book'
      and changes.entity_id = v_manifest.book_id
    order by changes.sequence desc limit 1
  ) = 'delete' then return null; end if;
  update public.asset_manifests_v2
  set upload_authorized_until = greatest(
    coalesce(upload_authorized_until, '-infinity'::timestamptz), p_authorized_until
  )
  where id = v_manifest.id returning * into v_manifest;
  return v_manifest;
end;
$$;

create function public.begin_v2_asset_object_write(
  p_user_id uuid,
  p_asset_id uuid,
  p_object_key text
)
returns public.object_write_leases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manifest public.asset_manifests_v2%rowtype;
  v_lease public.object_write_leases%rowtype;
begin
  perform 1 from public.profiles where user_id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  select * into v_manifest from public.asset_manifests_v2
  where user_id = p_user_id and id = p_asset_id
  for update;
  if not found or v_manifest.status <> 'pending'
     or p_object_key <> all(array[v_manifest.object_key, v_manifest.upload_object_key]) then
    return null;
  end if;
  if v_manifest.book_id is not null and (
    select changes.operation from public.sync_v2_changes changes
    where changes.user_id = p_user_id and changes.entity_type = 'book'
      and changes.entity_id = v_manifest.book_id
    order by changes.sequence desc limit 1
  ) = 'delete' then return null; end if;
  insert into public.object_write_leases (user_id, object_key)
  values (p_user_id, p_object_key) returning * into v_lease;
  return v_lease;
end;
$$;

-- This internal function is called by the sync-change trigger and by retry claims. It owns the
-- relational half of cleanup so an applied book tombstone can never commit with ready children.
create function public.mark_deleted_book_v2_assets(p_user_id uuid, p_book_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manifest public.asset_manifests_v2%rowtype;
  v_entity_type text;
  v_entity_id uuid;
  v_revision bigint;
begin
  perform 1 from public.profiles where user_id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  if (
    select changes.operation
    from public.sync_v2_changes changes
    where changes.user_id = p_user_id
      and changes.entity_type = 'book'
      and changes.entity_id = p_book_id
    order by changes.sequence desc
    limit 1
  ) is distinct from 'delete' then
    return;
  end if;

  for v_manifest in
    select manifests.*
    from public.asset_manifests_v2 manifests
    where manifests.user_id = p_user_id
      and manifests.book_id = p_book_id
      and manifests.status in ('pending', 'ready')
    order by manifests.id
    for update
  loop
    -- Pending assets were never announced. Ready assets need a child tombstone before their
    -- manifest becomes unreadable. Already-deleting retries never enter this loop.
    if v_manifest.status = 'ready' then
      v_entity_type := case
        when v_manifest.kind = 'transcriptRevision' then 'transcript'
        else 'asset'
      end;
      v_entity_id := case
        when v_manifest.kind = 'transcriptRevision' then v_manifest.revision_id
        else v_manifest.id
      end;
      select coalesce(max(changes.revision), 0) + 1 into v_revision
      from public.sync_v2_changes changes
      where changes.user_id = p_user_id
        and changes.entity_type = v_entity_type
        and changes.entity_id = v_entity_id;
      insert into public.sync_v2_changes (
        user_id, entity_type, entity_id, operation, revision, changed_at, payload
      ) values (
        p_user_id, v_entity_type, v_entity_id, 'delete', v_revision, clock_timestamp(),
        jsonb_build_object(
          'assetId', v_manifest.id,
          'bookId', v_manifest.book_id,
          'chapterId', v_manifest.chapter_id,
          'revisionId', v_manifest.revision_id,
          'kind', v_manifest.kind
        )
      );
    end if;

    update public.asset_manifests_v2 manifests
    set status = 'deleting', deleted_at = coalesce(manifests.deleted_at, clock_timestamp())
    where manifests.id = v_manifest.id;
  end loop;
  return;
end;
$$;

create function public.mark_deleted_book_v2_assets_after_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.entity_type = 'book' and new.operation = 'delete' then
    perform public.mark_deleted_book_v2_assets(new.user_id, new.entity_id);
  end if;
  return new;
end;
$$;

create trigger sync_v2_book_delete_asset_cleanup
after insert on public.sync_v2_changes
for each row execute function public.mark_deleted_book_v2_assets_after_change();

-- Repair book tombstones committed before the trigger existed. Latest upserts are intentionally
-- excluded, and resulting deleting rows are immediately visible to scheduled GC.
do $$
declare v_book record;
begin
  for v_book in
    select latest.user_id, latest.entity_id
    from (
      select distinct on (changes.user_id, changes.entity_id)
        changes.user_id, changes.entity_id, changes.operation
      from public.sync_v2_changes changes
      where changes.entity_type = 'book'
      order by changes.user_id, changes.entity_id, changes.sequence desc
    ) latest
    where latest.operation = 'delete'
  loop
    perform public.mark_deleted_book_v2_assets(v_book.user_id, v_book.entity_id);
  end loop;
end;
$$;

create function public.claim_deleted_book_v2_assets(
  p_user_id uuid,
  p_book_ids uuid[]
)
returns table (id uuid, object_key text, upload_object_key text, delete_after timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare v_book_id uuid;
begin
  if coalesce(cardinality(p_book_ids), 0) = 0 then return; end if;
  if cardinality(p_book_ids) > 100 then
    raise exception 'deleted-book cleanup cannot exceed 100 books';
  end if;
  foreach v_book_id in array p_book_ids loop
    if (
      select changes.operation from public.sync_v2_changes changes
      where changes.user_id = p_user_id and changes.entity_type = 'book'
        and changes.entity_id = v_book_id
      order by changes.sequence desc limit 1
    ) = 'delete' then
      perform public.mark_deleted_book_v2_assets(p_user_id, v_book_id);
    end if;
  end loop;
  return query
  select manifests.id, manifests.object_key, manifests.upload_object_key,
    (select max(deadline) from (
      select manifests.upload_authorized_until deadline
      union all
      select leases.expires_at from public.object_write_leases leases
      where leases.user_id = p_user_id
        and leases.object_key in (manifests.object_key, manifests.upload_object_key)
        and leases.expires_at > clock_timestamp()
    ) deadlines) delete_after
  from public.asset_manifests_v2 manifests
  where manifests.user_id = p_user_id
    and manifests.book_id = any(p_book_ids)
    and manifests.status = 'deleting'
    and (
      select changes.operation from public.sync_v2_changes changes
      where changes.user_id = p_user_id and changes.entity_type = 'book'
        and changes.entity_id = manifests.book_id
      order by changes.sequence desc limit 1
    ) = 'delete'
  order by manifests.id
  for update of manifests;
end;
$$;

-- Scheduled cleanup and ready-upload cleanup use the same safety boundary as synchronous cleanup.
create or replace function public.gc_abandoned_v2_uploads(p_before timestamptz, p_limit integer)
returns table (id uuid, upload_object_key text, object_key text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  update public.asset_manifests_v2 manifests
  set status = 'deleting', deleted_at = coalesce(manifests.deleted_at, clock_timestamp())
  where manifests.id in (
    select candidate.id from public.asset_manifests_v2 candidate
    where ((candidate.status = 'pending' and candidate.expires_at < p_before)
       or candidate.status = 'deleting')
      and (candidate.upload_authorized_until is null
        or candidate.upload_authorized_until <= clock_timestamp())
      and not exists (
        select 1 from public.object_write_leases leases
        where leases.user_id = candidate.user_id
          and leases.object_key in (candidate.object_key, candidate.upload_object_key)
          and leases.expires_at > clock_timestamp()
      )
    order by candidate.expires_at
    limit greatest(0, least(p_limit, 1000))
    for update skip locked
  )
  returning manifests.id, manifests.upload_object_key, manifests.object_key;
end;
$$;

create or replace function public.finish_v2_asset_upload_gc(p_ids uuid[])
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_deleted bigint;
begin
  delete from public.asset_manifests_v2 manifests
  where manifests.status = 'deleting' and manifests.id = any(p_ids)
    and manifests.deleted_at <= clock_timestamp() - interval '24 hours'
    and (manifests.upload_authorized_until is null
      or manifests.upload_authorized_until <= clock_timestamp())
    and not exists (
      select 1 from public.object_write_leases leases
      where leases.user_id = manifests.user_id
        and leases.object_key in (manifests.object_key, manifests.upload_object_key)
        and leases.expires_at > clock_timestamp()
    );
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

create or replace function public.claim_v2_ready_upload_cleanup(p_limit integer)
returns table(id uuid, upload_object_key text)
language sql
security definer
set search_path = public
as $$
  select m.id, m.upload_object_key
  from public.asset_manifests_v2 m
  where m.status = 'ready' and m.upload_cleaned_at is null
    and (m.upload_authorized_until is null or m.upload_authorized_until <= clock_timestamp())
    and not exists (
      select 1 from public.object_write_leases leases
      where leases.user_id = m.user_id and leases.object_key = m.upload_object_key
        and leases.expires_at > clock_timestamp()
    )
  order by m.ready_at asc, m.id asc
  limit greatest(0, least(p_limit, 1000))
  for update skip locked;
$$;

create or replace function public.finish_v2_ready_upload_cleanup(p_ids uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.asset_manifests_v2 m
  set upload_cleaned_at = clock_timestamp()
  where m.id = any(p_ids) and m.status = 'ready' and m.upload_cleaned_at is null
    and (m.upload_authorized_until is null or m.upload_authorized_until <= clock_timestamp())
    and not exists (
      select 1 from public.object_write_leases leases
      where leases.user_id = m.user_id and leases.object_key = m.upload_object_key
        and leases.expires_at > clock_timestamp()
    );
$$;

revoke all on function public.claim_deleted_book_v2_assets(uuid, uuid[])
  from public, anon, authenticated;
grant execute on function public.claim_deleted_book_v2_assets(uuid, uuid[]) to service_role;
revoke all on function public.mark_deleted_book_v2_assets(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.mark_deleted_book_v2_assets_after_change()
  from public, anon, authenticated;
revoke all on function public.authorize_v2_asset_upload(uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function public.authorize_v2_asset_upload(uuid, uuid, timestamptz) to service_role;
revoke all on function public.begin_v2_asset_object_write(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.begin_v2_asset_object_write(uuid, uuid, text) to service_role;

insert into public.service_schema_versions (component, migration_version)
values ('account_sync', '20260901090000')
on conflict (component) do update
set migration_version = excluded.migration_version,
    updated_at = now();

commit;
