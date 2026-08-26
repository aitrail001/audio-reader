-- Phase 4.2 row-level isolation.
-- Authenticated JWTs are scoped to auth.uid() while the profile is active.
-- service_role is BYPASSRLS and is for server-side Workers only.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

do $$
begin
  if to_regnamespace('auth') is null then
    execute 'create schema auth';
  end if;
  if to_regprocedure('auth.uid()') is null then
    execute $fn$
      create function auth.uid()
      returns uuid
      language sql
      stable
      as $uid$
        select nullif(
          coalesce(
            nullif(current_setting('request.jwt.claim.sub', true), ''),
            (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
          ),
          ''
        )::uuid
      $uid$
    $fn$;
    execute 'grant usage on schema auth to anon, authenticated, service_role';
    execute 'grant execute on function auth.uid() to anon, authenticated, service_role';
  end if;
end
$$;

create or replace function public.current_user_is_active()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where user_id = (select auth.uid())
      and account_status = 'active'
      and deleted_at is null
  );
$$;

revoke all on function public.current_user_is_active() from public;
grant execute on function public.current_user_is_active() to authenticated, service_role;

alter table public.profiles enable row level security;
alter table public.profiles force row level security;
alter table public.devices enable row level security;
alter table public.devices force row level security;
alter table public.user_settings enable row level security;
alter table public.user_settings force row level security;
alter table public.books enable row level security;
alter table public.books force row level security;
alter table public.book_assets enable row level security;
alter table public.book_assets force row level security;
alter table public.canonical_works enable row level security;
alter table public.canonical_works force row level security;
alter table public.canonical_editions enable row level security;
alter table public.canonical_editions force row level security;
alter table public.chapters enable row level security;
alter table public.chapters force row level security;
alter table public.reading_progress enable row level security;
alter table public.reading_progress force row level security;
alter table public.transcript_revisions enable row level security;
alter table public.transcript_revisions force row level security;
alter table public.transcript_segments enable row level security;
alter table public.transcript_segments force row level security;
alter table public.vocabulary_occurrences enable row level security;
alter table public.vocabulary_occurrences force row level security;
alter table public.known_lemmas enable row level security;
alter table public.known_lemmas force row level security;
alter table public.review_cards enable row level security;
alter table public.review_cards force row level security;
alter table public.review_events enable row level security;
alter table public.review_events force row level security;
alter table public.user_assistant_results enable row level security;
alter table public.user_assistant_results force row level security;
alter table public.assistant_cache_entries enable row level security;
alter table public.assistant_cache_entries force row level security;
alter table public.assistant_jobs enable row level security;
alter table public.assistant_jobs force row level security;
alter table public.usage_ledger enable row level security;
alter table public.usage_ledger force row level security;
alter table public.sync_changes enable row level security;
alter table public.sync_changes force row level security;
alter table public.idempotency_records enable row level security;
alter table public.idempotency_records force row level security;
alter table public.feature_flags enable row level security;
alter table public.feature_flags force row level security;
alter table public.model_policies enable row level security;
alter table public.model_policies force row level security;
alter table public.admin_roles enable row level security;
alter table public.admin_roles force row level security;
alter table public.audit_events enable row level security;
alter table public.audit_events force row level security;
alter table public.privacy_requests enable row level security;
alter table public.privacy_requests force row level security;

create policy profiles_own on public.profiles
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy devices_own on public.devices
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy user_settings_own on public.user_settings
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy books_own on public.books
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy book_assets_own on public.book_assets
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy chapters_own on public.chapters
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy reading_progress_own on public.reading_progress
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy transcript_revisions_own on public.transcript_revisions
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy transcript_segments_own on public.transcript_segments
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy vocabulary_occurrences_own on public.vocabulary_occurrences
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy known_lemmas_own on public.known_lemmas
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy review_cards_own on public.review_cards
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy review_events_own on public.review_events
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy user_assistant_results_own on public.user_assistant_results
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy privacy_requests_own on public.privacy_requests
  for all to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active())
  with check (user_id = (select auth.uid()) and public.current_user_is_active());

create policy assistant_jobs_select_own on public.assistant_jobs
  for select to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active());

create policy usage_ledger_select_own on public.usage_ledger
  for select to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active());

create policy sync_changes_select_own on public.sync_changes
  for select to authenticated
  using (user_id = (select auth.uid()) and public.current_user_is_active());

grant usage on schema public to anon, authenticated, service_role;

revoke all on all tables in schema public from public;
revoke all on all tables in schema public from anon;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;

alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant all on tables to service_role;
