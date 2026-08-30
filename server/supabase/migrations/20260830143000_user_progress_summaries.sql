-- Privacy-safe Operator progress summaries. The snapshot contains counts, coarse progress,
-- timestamps, and opaque device ids only; raw sync payloads never leave this function.

alter table public.sync_batches
  add column if not exists device_id uuid;

create index if not exists sync_batches_user_created_idx
  on public.sync_batches (user_id, created_at desc);

create table public.user_analytics_preferences (
  user_id uuid primary key references public.profiles (user_id) on delete cascade,
  operator_learning_analytics_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.user_progress_summaries (
  user_id uuid primary key references public.profiles (user_id) on delete cascade,
  sync_last_successful_at timestamptz,
  sync_last_device_id uuid,
  sync_entity_counts jsonb not null default '[]'::jsonb,
  sync_pending_count integer,
  sync_conflict_count integer not null default 0,
  reading_last_activity_at timestamptz,
  reading_active_books integer not null default 0,
  reading_completed_books integer not null default 0,
  reading_current_chapter integer,
  reading_completion_percent numeric,
  review_due integer not null default 0,
  review_new integer not null default 0,
  review_learning integer not null default 0,
  reviews_last_30_days integer not null default 0,
  reviews_per_active_day numeric not null default 0,
  review_retention_rate numeric,
  review_streak_days integer not null default 0,
  learning_vocabulary integer not null default 0,
  learning_known integer not null default 0,
  learning_learning integer not null default 0,
  ai_uses_last_30_days integer not null default 0,
  ai_uses_by_feature jsonb not null default '[]'::jsonb,
  generated_at timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint user_progress_summaries_counts_check check (
    (sync_pending_count is null or sync_pending_count >= 0) and sync_conflict_count >= 0 and
    reading_active_books >= 0 and reading_completed_books >= 0 and
    review_due >= 0 and review_new >= 0 and review_learning >= 0 and
    reviews_last_30_days >= 0 and reviews_per_active_day >= 0 and
    review_streak_days >= 0 and learning_vocabulary >= 0 and
    learning_known >= 0 and learning_learning >= 0 and ai_uses_last_30_days >= 0
  ),
  constraint user_progress_summaries_percentages_check check (
    (reading_completion_percent is null or reading_completion_percent between 0 and 100) and
    (review_retention_rate is null or review_retention_rate between 0 and 1)
  )
);

alter table public.user_analytics_preferences enable row level security;
alter table public.user_analytics_preferences force row level security;
alter table public.user_progress_summaries enable row level security;
alter table public.user_progress_summaries force row level security;

create function public.purge_expired_user_progress_summaries()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  delete from public.user_progress_summaries where expires_at <= clock_timestamp();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create function public.set_user_analytics_preference(p_user_id uuid, p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_at timestamptz;
begin
  if not exists (select 1 from public.profiles where user_id = p_user_id) then
    return null;
  end if;

  insert into public.user_analytics_preferences (
    user_id, operator_learning_analytics_enabled, updated_at
  ) values (p_user_id, p_enabled, clock_timestamp())
  on conflict (user_id) do update
  set operator_learning_analytics_enabled = excluded.operator_learning_analytics_enabled,
      updated_at = excluded.updated_at
  returning updated_at into v_updated_at;

  -- Opt-out removes the previously materialized detailed snapshot in the same transaction.
  if not p_enabled then
    delete from public.user_progress_summaries where user_id = p_user_id;
  end if;

  return jsonb_build_object(
    'operatorLearningAnalyticsEnabled', p_enabled,
    'updatedAt', v_updated_at
  );
end;
$$;

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
  if not exists (
    select 1 from public.profiles
    where user_id = p_user_id and account_status in ('active', 'suspended')
  ) then
    return null;
  end if;

  select coalesce(operator_learning_analytics_enabled, false)
  into v_consented
  from public.user_analytics_preferences
  where user_id = p_user_id;
  v_consented := coalesce(v_consented, false);

  if not v_consented then
    -- Sync health is support metadata. Detailed payload-derived learning analytics are neither
    -- computed nor persisted until the account explicitly opts in.
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
  end if;

  with latest_entities as (
    select distinct on (entity_type, entity_id)
      entity_type, entity_id, operation, payload, changed_at
    from public.sync_changes
    where user_id = p_user_id
    order by entity_type, entity_id, sequence desc
  ),
  active_entities as (
    select * from latest_entities where operation <> 'delete'
  ),
  entity_counts as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object('entityType', entity_type, 'count', entity_count)
        order by entity_type
      ), '[]'::jsonb
    ) value
    from (
      select entity_type, count(*)::integer entity_count
      from active_entities
      group by entity_type
    ) counts
  ),
  last_batch as (
    select b.created_at, b.device_id, d.platform, d.name
    from public.sync_batches b
    left join public.devices d
      on d.user_id = b.user_id and d.id = b.device_id
    where b.user_id = p_user_id
    order by b.created_at desc
    limit 1
  ),
  book_entities as (
    select payload
    from active_entities
    where entity_type = 'book'
  ),
  reader_progress as (
    select payload, changed_at
    from active_entities
    where entity_type = 'progress' and payload ->> 'progressKind' = 'reader'
  ),
  reader_metrics as (
    select
      p.changed_at,
      coalesce(chapter.ordinality - 1, 0)::integer chapter_index,
      coalesce(jsonb_array_length(b.payload -> 'chapters'), 0)::integer chapter_count,
      coalesce((p.payload ->> 'relativeSeconds')::numeric, 0) relative_seconds,
      coalesce((chapter.value ->> 'duration')::numeric, 0) chapter_duration,
      coalesce((
        select sum(coalesce((prior.value ->> 'duration')::numeric, 0))
        from jsonb_array_elements(b.payload -> 'chapters') with ordinality prior(value, ordinality)
        where prior.ordinality < chapter.ordinality
      ), 0) elapsed_before,
      coalesce((
        select sum(coalesce((part.value ->> 'duration')::numeric, 0))
        from jsonb_array_elements(b.payload -> 'chapters') part(value)
      ), 0) total_duration
    from reader_progress p
    join book_entities b on b.payload ->> 'localId' = p.payload ->> 'localBookId'
    left join lateral jsonb_array_elements(b.payload -> 'chapters') with ordinality chapter(value, ordinality)
      on chapter.value ->> 'localId' = p.payload ->> 'localChapterId'
  ),
  latest_reader as (
    select * from reader_metrics order by changed_at desc limit 1
  ),
  learning_progress as (
    select payload
    from active_entities
    where entity_type = 'progress'
      and payload ->> 'progressKind' is distinct from 'reader'
      and payload ? 'vocabularyId'
  ),
  vocabulary_count as (
    select count(*)::integer value from active_entities where entity_type = 'vocabulary'
  ),
  known_count as (
    select count(*)::integer value
    from active_entities
    where entity_type = 'lexeme_state' and payload ->> 'state' = 'known'
  ),
  review_stats as (
    select
      count(*) filter (
        where coalesce((payload ->> 'reviewCount')::integer, 0) > 0
          and nullif(payload ->> 'nextReview', '')::timestamptz <= clock_timestamp()
      )::integer due,
      count(*) filter (
        where coalesce((payload ->> 'reviewCount')::integer, 0) > 0
          and coalesce((payload ->> 'reviewIntervalDays')::numeric, 0) < 7
      )::integer learning
    from learning_progress
  ),
  recent_reviews as (
    select
      changed_at::date review_day,
      case lower(payload ->> 'rating')
        when 'forgot' then 1
        when 'vague' then 2
        when 'remember' then 4
        else case
          when payload ->> 'rating' ~ '^[0-9]+$' then (payload ->> 'rating')::integer
        end
      end rating
    from public.sync_changes
    where user_id = p_user_id
      and entity_type = 'review_event'
      and operation <> 'delete'
      and changed_at >= clock_timestamp() - interval '30 days'
  ),
  review_rollup as (
    select
      count(*)::integer reviews,
      count(distinct review_day)::integer active_days,
      case when count(rating) = 0 then null
        else count(*) filter (where rating >= 3)::numeric / count(rating)::numeric end retention
    from recent_reviews
  ),
  latest_review_day as (
    select max(review_day) value from recent_reviews
  ),
  review_streak as (
    select case
      when latest.value is null or latest.value < current_date - 1 then 0
      else coalesce((
        select min(offset_days)
        from generate_series(0, 365) offset_days
        where not exists (
          select 1 from recent_reviews r where r.review_day = latest.value - offset_days
        )
      ), 366)::integer
    end value
    from latest_review_day latest
  ),
  ai_features as (
    select
      coalesce(nullif(properties ->> 'feature', ''), split_part(name, '.', 2), 'other') feature,
      count(*)::integer feature_count
    from public.product_events
    where user_id = p_user_id
      and name like 'ai.%'
      and outcome = 'ok'
      and created_at >= clock_timestamp() - interval '30 days'
    group by 1
  ),
  ai_rollup as (
    select
      coalesce(sum(feature_count), 0)::integer uses,
      coalesce(jsonb_agg(
        jsonb_build_object('feature', feature, 'count', feature_count)
        order by feature_count desc, feature
      ), '[]'::jsonb) features
    from ai_features
  )
  select jsonb_build_object(
    'generatedAt', clock_timestamp(),
    'expiresAt', clock_timestamp() + interval '90 days',
    'sync', jsonb_build_object(
      'lastSuccessfulAt', (select created_at from last_batch),
      'lastDevice', (
        select case when device_id is null then null else jsonb_build_object(
          'id', device_id, 'platform', coalesce(platform, 'unknown'), 'name', name
        ) end from last_batch
      ),
      'entityCounts', (select value from entity_counts),
      -- Pending outbox mutations exist only on a device until uploaded; null avoids a false zero.
      'pendingCount', null,
      'conflictCount', (
        select count(*)::integer from public.sync_mutation_outcomes
        where user_id = p_user_id and status = 'conflict'
      )
    ),
    'reading', jsonb_build_object(
      'lastActivityAt', (select max(changed_at) from reader_metrics),
      'activeBooks', (select count(*)::integer from reader_metrics where not (
        chapter_count > 0 and chapter_index = chapter_count - 1
        and chapter_duration > 0 and relative_seconds >= chapter_duration * 0.98
      )),
      'completedBooks', (select count(*)::integer from reader_metrics where
        chapter_count > 0 and chapter_index = chapter_count - 1
        and chapter_duration > 0 and relative_seconds >= chapter_duration * 0.98
      ),
      'currentChapter', (select chapter_index + 1 from latest_reader),
      'completionPercent', (select case when total_duration <= 0 then null else
        round(least(100, greatest(0, ((elapsed_before + relative_seconds) / total_duration) * 100)), 1)
        end from latest_reader)
    ),
    'review', jsonb_build_object(
      'due', (select due from review_stats),
      'new', greatest(0, (select value from vocabulary_count) - (select count(*)::integer from learning_progress)),
      'learning', (select learning from review_stats),
      'reviewsLast30Days', (select reviews from review_rollup),
      'reviewsPerActiveDay', (select case when active_days = 0 then 0 else round(reviews::numeric / active_days, 1) end from review_rollup),
      'retentionRate', (select round(retention, 3) from review_rollup),
      'streakDays', (select value from review_streak)
    ),
    'learning', jsonb_build_object(
      'vocabulary', (select value from vocabulary_count),
      'known', (select value from known_count),
      'learning', (select learning from review_stats),
      'aiUsesLast30Days', (select uses from ai_rollup),
      'aiUsesByFeature', (select features from ai_rollup)
    )
  ) into v_summary;

  insert into public.user_progress_summaries (
    user_id, sync_last_successful_at, sync_last_device_id, sync_entity_counts,
    sync_pending_count, sync_conflict_count, reading_last_activity_at,
    reading_active_books, reading_completed_books, reading_current_chapter,
    reading_completion_percent, review_due, review_new, review_learning,
    reviews_last_30_days, reviews_per_active_day, review_retention_rate,
    review_streak_days, learning_vocabulary, learning_known, learning_learning,
    ai_uses_last_30_days, ai_uses_by_feature, generated_at, expires_at
  )
  values (
    p_user_id,
    nullif(v_summary #>> '{sync,lastSuccessfulAt}', '')::timestamptz,
    nullif(v_summary #>> '{sync,lastDevice,id}', '')::uuid,
    coalesce(v_summary #> '{sync,entityCounts}', '[]'::jsonb),
    nullif(v_summary #>> '{sync,pendingCount}', '')::integer,
    coalesce((v_summary #>> '{sync,conflictCount}')::integer, 0),
    nullif(v_summary #>> '{reading,lastActivityAt}', '')::timestamptz,
    coalesce((v_summary #>> '{reading,activeBooks}')::integer, 0),
    coalesce((v_summary #>> '{reading,completedBooks}')::integer, 0),
    nullif(v_summary #>> '{reading,currentChapter}', '')::integer,
    nullif(v_summary #>> '{reading,completionPercent}', '')::numeric,
    coalesce((v_summary #>> '{review,due}')::integer, 0),
    coalesce((v_summary #>> '{review,new}')::integer, 0),
    coalesce((v_summary #>> '{review,learning}')::integer, 0),
    coalesce((v_summary #>> '{review,reviewsLast30Days}')::integer, 0),
    coalesce((v_summary #>> '{review,reviewsPerActiveDay}')::numeric, 0),
    nullif(v_summary #>> '{review,retentionRate}', '')::numeric,
    coalesce((v_summary #>> '{review,streakDays}')::integer, 0),
    coalesce((v_summary #>> '{learning,vocabulary}')::integer, 0),
    coalesce((v_summary #>> '{learning,known}')::integer, 0),
    coalesce((v_summary #>> '{learning,learning}')::integer, 0),
    coalesce((v_summary #>> '{learning,aiUsesLast30Days}')::integer, 0),
    coalesce(v_summary #> '{learning,aiUsesByFeature}', '[]'::jsonb),
    (v_summary ->> 'generatedAt')::timestamptz,
    (v_summary ->> 'expiresAt')::timestamptz
  )
  on conflict (user_id) do update
  set sync_last_successful_at = excluded.sync_last_successful_at,
      sync_last_device_id = excluded.sync_last_device_id,
      sync_entity_counts = excluded.sync_entity_counts,
      sync_pending_count = excluded.sync_pending_count,
      sync_conflict_count = excluded.sync_conflict_count,
      reading_last_activity_at = excluded.reading_last_activity_at,
      reading_active_books = excluded.reading_active_books,
      reading_completed_books = excluded.reading_completed_books,
      reading_current_chapter = excluded.reading_current_chapter,
      reading_completion_percent = excluded.reading_completion_percent,
      review_due = excluded.review_due,
      review_new = excluded.review_new,
      review_learning = excluded.review_learning,
      reviews_last_30_days = excluded.reviews_last_30_days,
      reviews_per_active_day = excluded.reviews_per_active_day,
      review_retention_rate = excluded.review_retention_rate,
      review_streak_days = excluded.review_streak_days,
      learning_vocabulary = excluded.learning_vocabulary,
      learning_known = excluded.learning_known,
      learning_learning = excluded.learning_learning,
      ai_uses_last_30_days = excluded.ai_uses_last_30_days,
      ai_uses_by_feature = excluded.ai_uses_by_feature,
      generated_at = excluded.generated_at,
      expires_at = excluded.expires_at;

  return v_summary;
end;
$$;

create function public.delete_account_data(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  -- Delete the owning row so private dependencies cascade, then retain an anonymous tombstone so
  -- a still-valid hosted identity cannot recreate the account on its next authentication attempt.
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

revoke all on table public.user_analytics_preferences from public, anon, authenticated;
revoke all on table public.user_progress_summaries from public, anon, authenticated;
grant all on table public.user_analytics_preferences to service_role;
grant all on table public.user_progress_summaries to service_role;
revoke all on function public.admin_user_progress_summary from public, anon, authenticated;
revoke all on function public.purge_expired_user_progress_summaries from public, anon, authenticated;
revoke all on function public.set_user_analytics_preference from public, anon, authenticated;
revoke all on function public.delete_account_data from public, anon, authenticated;
grant execute on function public.admin_user_progress_summary to service_role;
grant execute on function public.purge_expired_user_progress_summaries to service_role;
grant execute on function public.set_user_analytics_preference to service_role;
grant execute on function public.delete_account_data to service_role;

comment on function public.admin_user_progress_summary(uuid) is
  'Materializes a 90-day support-safe aggregate without returning sync payload text.';
