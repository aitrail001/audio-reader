create table if not exists public.service_schema_versions (
  component text primary key,
  migration_version text not null,
  updated_at timestamptz not null default now()
);

alter table public.service_schema_versions enable row level security;
alter table public.service_schema_versions force row level security;

insert into public.service_schema_versions (component, migration_version)
values ('account_sync', '20260831120000')
on conflict (component) do update
set migration_version = excluded.migration_version,
    updated_at = now();

create function public.account_sync_schema_version()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select migration_version
  from public.service_schema_versions
  where component = 'account_sync'
$$;

revoke all on table public.service_schema_versions from public, anon, authenticated;
grant select on table public.service_schema_versions to service_role;
revoke all on function public.account_sync_schema_version() from public, anon, authenticated;
grant execute on function public.account_sync_schema_version() to service_role;
