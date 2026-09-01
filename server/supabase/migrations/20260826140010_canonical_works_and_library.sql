create table public.canonical_works (
  id uuid primary key default gen_random_uuid(),
  normalized_title text not null,
  normalized_author text,
  isbn text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index canonical_works_title_author_uidx
  on public.canonical_works (normalized_title, normalized_author)
  nulls not distinct;

create unique index canonical_works_isbn_uidx
  on public.canonical_works (isbn)
  where isbn is not null;

create table public.canonical_editions (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.canonical_works (id) on delete cascade,
  edition_fingerprint text not null unique,
  fingerprint_version integer not null,
  language text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint canonical_editions_fingerprint_version_check check (fingerprint_version >= 1)
);

create table public.books (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  work_id uuid references public.canonical_works (id) on delete set null,
  edition_id uuid references public.canonical_editions (id) on delete set null,
  title text not null,
  author text,
  cover_asset_id uuid,
  edition_fingerprint text not null,
  fingerprint_version integer not null,
  audio_manifest_hash text,
  ebook_text_hash text,
  source text not null,
  chapter_count integer not null default 0,
  cloud_media_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint books_source_check
    check (source in ('local_folder', 'files', 'device_audiobooks', 'remote_backup')),
  constraint books_fingerprint_version_check check (fingerprint_version >= 1),
  constraint books_chapter_count_check check (chapter_count >= 0),
  constraint books_server_version_check check (server_version >= 0),
  constraint books_user_id_id_key unique (user_id, id)
);

create table public.book_assets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  book_id uuid not null,
  kind text not null,
  content_type text not null,
  size_bytes bigint not null,
  sha256 text not null,
  status text not null,
  object_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint book_assets_kind_check
    check (kind in ('audio', 'ebook', 'cover', 'transcript_export', 'account_export')),
  constraint book_assets_status_check
    check (status in ('pending', 'ready', 'failed', 'deleting')),
  constraint book_assets_size_bytes_check check (size_bytes >= 0),
  constraint book_assets_server_version_check check (server_version >= 0),
  constraint book_assets_user_book_fkey
    foreign key (user_id, book_id) references public.books (user_id, id) on delete cascade,
  constraint book_assets_user_id_id_key unique (user_id, id),
  constraint book_assets_book_id_id_key unique (book_id, id)
);

alter table public.books
  add constraint books_cover_asset_user_fkey
  foreign key (user_id, cover_asset_id) references public.book_assets (user_id, id)
  on delete set null (cover_asset_id)
  deferrable initially deferred;

alter table public.books
  add constraint books_cover_asset_book_fkey
  foreign key (id, cover_asset_id) references public.book_assets (book_id, id)
  on delete set null (cover_asset_id)
  deferrable initially deferred;

create table public.chapters (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  book_id uuid not null,
  index integer not null,
  title text not null,
  chapter_fingerprint text not null,
  duration_seconds numeric not null,
  start_seconds numeric,
  audio_asset_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint chapters_index_check check (index >= 0),
  constraint chapters_duration_seconds_check check (duration_seconds >= 0),
  constraint chapters_start_seconds_check check (start_seconds is null or start_seconds >= 0),
  constraint chapters_server_version_check check (server_version >= 0),
  constraint chapters_user_book_fkey
    foreign key (user_id, book_id) references public.books (user_id, id) on delete cascade,
  constraint chapters_user_audio_asset_fkey
    foreign key (user_id, audio_asset_id) references public.book_assets (user_id, id)
    on delete set null (audio_asset_id),
  constraint chapters_book_audio_asset_fkey
    foreign key (book_id, audio_asset_id) references public.book_assets (book_id, id)
    on delete set null (audio_asset_id),
  constraint chapters_user_id_id_key unique (user_id, id),
  constraint chapters_book_id_id_key unique (book_id, id),
  constraint chapters_book_index_deleted_at_key
    unique nulls not distinct (book_id, index, deleted_at)
    deferrable initially deferred
);

create table public.reading_progress (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  book_id uuid not null,
  chapter_id uuid not null,
  position_seconds numeric not null default 0,
  segment_id text,
  word_id text,
  completed boolean not null default false,
  completed_at timestamptz,
  explicit_seek boolean not null default false,
  device_id uuid,
  last_interaction_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint reading_progress_position_seconds_check check (position_seconds >= 0),
  constraint reading_progress_server_version_check check (server_version >= 0),
  constraint reading_progress_user_book_fkey
    foreign key (user_id, book_id) references public.books (user_id, id) on delete cascade,
  constraint reading_progress_user_chapter_fkey
    foreign key (user_id, chapter_id) references public.chapters (user_id, id) on delete cascade,
  constraint reading_progress_book_chapter_fkey
    foreign key (book_id, chapter_id) references public.chapters (book_id, id) on delete cascade,
  constraint reading_progress_user_device_fkey
    foreign key (user_id, device_id) references public.devices (user_id, id)
    on delete set null (device_id)
);

create index books_user_id_updated_idx
  on public.books (user_id, updated_at desc)
  where deleted_at is null;

create index books_user_edition_idx
  on public.books (user_id, edition_fingerprint)
  where deleted_at is null;

create index books_work_id_idx
  on public.books (work_id)
  where work_id is not null;

create unique index book_assets_user_sha256_uidx
  on public.book_assets (user_id, sha256)
  where deleted_at is null;

create index book_assets_user_book_idx
  on public.book_assets (user_id, book_id)
  where deleted_at is null;

create unique index book_assets_object_key_uidx
  on public.book_assets (object_key)
  where object_key is not null;

create unique index reading_progress_user_chapter_uidx
  on public.reading_progress (user_id, chapter_id);

create index reading_progress_user_updated_idx
  on public.reading_progress (user_id, updated_at desc);
