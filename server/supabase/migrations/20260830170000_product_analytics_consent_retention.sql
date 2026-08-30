-- Make learner analytics opt-in at the persistence boundary and bound every event to 90 days.

begin;

alter table public.product_events
  add column if not exists purpose text not null default 'learning_analytics';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'product_events_purpose_check'
      and conrelid = 'public.product_events'::regclass
  ) then
    alter table public.product_events
      add constraint product_events_purpose_check
      check (purpose in ('learning_analytics', 'operational'));
  end if;
end;
$$;

-- Operator probes and privacy exports are required operational records, not learner behavior.
update public.product_events
set purpose = 'operational'
where name in ('operator.qwen_probe', 'operator.prompt_probe', 'account.export.created');

-- Existing learner rows without an active opt-in must not become visible after this migration.
delete from public.product_events as event
where event.purpose = 'learning_analytics'
  and not exists (
    select 1
    from public.user_analytics_preferences as preference
    where preference.user_id = event.user_id
      and preference.operator_learning_analytics_enabled
  );

create or replace function public.enforce_product_event_analytics_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.purpose = 'learning_analytics'
    and not exists (
      select 1
      from public.user_analytics_preferences as preference
      where preference.user_id = new.user_id
        and preference.operator_learning_analytics_enabled
    ) then
    raise exception using
      errcode = '42501',
      message = 'learning analytics consent is required';
  end if;
  return new;
end;
$$;

drop trigger if exists product_events_require_analytics_consent on public.product_events;
create trigger product_events_require_analytics_consent
before insert or update of user_id, purpose on public.product_events
for each row execute function public.enforce_product_event_analytics_consent();

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
  -- Serialize opt-out with account writes so summaries and learner events disappear atomically.
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
    delete from public.product_events
    where user_id = p_user_id
      and purpose = 'learning_analytics';
  end if;

  return jsonb_build_object(
    'operatorLearningAnalyticsEnabled', p_enabled,
    'updatedAt', v_updated_at
  );
end;
$$;

create or replace function public.purge_expired_product_events()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  delete from public.product_events
  where created_at < clock_timestamp() - interval '90 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.enforce_product_event_analytics_consent from public, anon, authenticated;
revoke all on function public.purge_expired_product_events from public, anon, authenticated;
grant execute on function public.purge_expired_product_events to service_role;

comment on column public.product_events.purpose is
  'Separates optional learner analytics from required operational and security telemetry.';
comment on function public.purge_expired_product_events() is
  'Deletes product and operational event rows older than the fixed 90-day retention window.';

commit;
