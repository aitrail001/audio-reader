-- Phase 4.1 identity tables. RLS policies are a later PR.

create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique,
  email text,
  display_name text,
  avatar_url text,
  locale text not null default 'en',
  account_status text not null default 'active',
  deletion_pending_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint profiles_account_status_check
    check (account_status in ('active', 'suspended', 'deletion_pending', 'deleted')),
  constraint profiles_server_version_check check (server_version >= 0)
);

create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  platform text not null,
  name text,
  app_version text not null,
  build_number text,
  os_version text,
  speech_locales text[] not null default '{}',
  foundation_models_available boolean not null default false,
  background_processing boolean not null default false,
  cloud_media_enabled boolean not null default false,
  last_sync_at timestamptz,
  last_seen_at timestamptz not null default now(),
  revoked boolean not null default false,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint devices_platform_check check (platform in ('macos', 'ios', 'ipados')),
  constraint devices_server_version_check check (server_version >= 0),
  constraint devices_user_id_id_key unique (user_id, id)
);

create table public.user_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles (user_id) on delete cascade,
  source_language text not null default 'en',
  target_language text not null default 'en',
  reader_level text not null default 'intermediate',
  playback_rate numeric not null default 1,
  skip_seconds numeric not null default 15,
  appearance text not null default 'system',
  preferred_dictionary text,
  reader_font text,
  reader_font_scale numeric not null default 1,
  reader_bold boolean not null default false,
  reader_line_spacing numeric not null default 1.4,
  reader_word_spacing numeric not null default 0,
  reader_margin numeric not null default 24,
  review_preferred_faces text[] not null default '{}',
  review_daily_limit integer,
  sync_policy text not null default 'learning_data_only',
  field_clocks jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint user_settings_reader_level_check
    check (reader_level in (
      'beginner',
      'elementary',
      'intermediate',
      'upper_intermediate',
      'advanced'
    )),
  constraint user_settings_playback_rate_check
    check (playback_rate >= 0.5 and playback_rate <= 3.0),
  constraint user_settings_skip_seconds_check
    check (skip_seconds >= 1 and skip_seconds <= 60),
  constraint user_settings_appearance_check
    check (appearance in ('system', 'light', 'dark')),
  constraint user_settings_reader_font_scale_check
    check (reader_font_scale >= 0.7 and reader_font_scale <= 2.5),
  constraint user_settings_reader_line_spacing_check
    check (reader_line_spacing >= 0.5 and reader_line_spacing <= 3),
  constraint user_settings_reader_word_spacing_check
    check (reader_word_spacing >= 0 and reader_word_spacing <= 20),
  constraint user_settings_reader_margin_check
    check (reader_margin >= 0 and reader_margin <= 120),
  constraint user_settings_review_daily_limit_check
    check (review_daily_limit is null or (review_daily_limit >= 1 and review_daily_limit <= 1000)),
  constraint user_settings_sync_policy_check
    check (sync_policy in (
      'learning_data_only',
      'learning_data_and_transcripts',
      'learning_data_transcripts_and_assets'
    )),
  constraint user_settings_server_version_check check (server_version >= 0)
);

create index devices_user_id_idx
  on public.devices (user_id)
  where deleted_at is null;

create index devices_user_last_seen_idx
  on public.devices (user_id, last_seen_at desc);
