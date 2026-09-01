-- FORCE RLS with no policy denies every role that does not bypass RLS.
-- Explicit service_role policies so Worker PostgREST writes to cache and
-- product_events are visible in the admin console and table editor.

drop policy if exists assistant_cache_entries_service on public.assistant_cache_entries;
create policy assistant_cache_entries_service
  on public.assistant_cache_entries
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists product_events_service on public.product_events;
create policy product_events_service
  on public.product_events
  for all
  to service_role
  using (true)
  with check (true);
