create table public.transcript_revisions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  book_id uuid not null,
  chapter_id uuid not null,
  version integer not null,
  engine text not null,
  engine_version text,
  locale text not null,
  chapter_fingerprint text not null,
  object_key text,
  is_active boolean not null default false,
  quality jsonb,
  ebook_alignment jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint transcript_revisions_version_check check (version >= 1),
  constraint transcript_revisions_server_version_check check (server_version >= 0),
  constraint transcript_revisions_user_book_fkey
    foreign key (user_id, book_id) references public.books (user_id, id) on delete cascade,
  constraint transcript_revisions_user_chapter_fkey
    foreign key (user_id, chapter_id) references public.chapters (user_id, id) on delete cascade,
  constraint transcript_revisions_book_chapter_fkey
    foreign key (book_id, chapter_id) references public.chapters (book_id, id) on delete cascade,
  constraint transcript_revisions_user_id_id_key unique (user_id, id),
  constraint transcript_revisions_chapter_id_id_key unique (chapter_id, id)
);

create table public.transcript_segments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  revision_id uuid not null,
  chapter_id uuid not null,
  sequence integer not null,
  start_seconds numeric not null,
  end_seconds numeric not null,
  spoken_text text not null,
  ebook_text text,
  sentence_hash text,
  alignment_score numeric,
  individual_ebook_match_trusted boolean,
  client_segment_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint transcript_segments_sequence_check check (sequence >= 0),
  constraint transcript_segments_start_seconds_check check (start_seconds >= 0),
  constraint transcript_segments_end_seconds_check check (end_seconds >= start_seconds),
  constraint transcript_segments_alignment_score_check
    check (alignment_score is null or (alignment_score >= 0 and alignment_score <= 1)),
  constraint transcript_segments_server_version_check check (server_version >= 0),
  constraint transcript_segments_user_revision_fkey
    foreign key (user_id, revision_id) references public.transcript_revisions (user_id, id)
    on delete cascade,
  constraint transcript_segments_user_chapter_fkey
    foreign key (user_id, chapter_id) references public.chapters (user_id, id) on delete cascade,
  constraint transcript_segments_chapter_revision_fkey
    foreign key (chapter_id, revision_id) references public.transcript_revisions (chapter_id, id)
    on delete cascade
);

create table public.vocabulary_occurrences (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  book_id uuid not null,
  chapter_id uuid not null,
  segment_id text,
  word_id text,
  surface text not null,
  lemma text not null,
  language text,
  sense_key text,
  category text not null,
  context text not null,
  previous_context text,
  next_context text,
  timestamp_seconds numeric not null,
  clip_start_seconds numeric,
  clip_end_seconds numeric,
  definition text,
  translation_id uuid,
  note text,
  tags text[] not null default '{}',
  state text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint vocabulary_occurrences_category_check
    check (category in ('word', 'phrase', 'sentence')),
  constraint vocabulary_occurrences_state_check
    check (state in ('unknown', 'learning', 'known', 'ignored')),
  constraint vocabulary_occurrences_timestamp_seconds_check check (timestamp_seconds >= 0),
  constraint vocabulary_occurrences_clip_start_seconds_check
    check (clip_start_seconds is null or clip_start_seconds >= 0),
  constraint vocabulary_occurrences_clip_end_seconds_check
    check (clip_end_seconds is null or clip_end_seconds >= 0),
  constraint vocabulary_occurrences_server_version_check check (server_version >= 0),
  constraint vocabulary_occurrences_user_book_fkey
    foreign key (user_id, book_id) references public.books (user_id, id) on delete cascade,
  constraint vocabulary_occurrences_user_chapter_fkey
    foreign key (user_id, chapter_id) references public.chapters (user_id, id) on delete cascade,
  constraint vocabulary_occurrences_book_chapter_fkey
    foreign key (book_id, chapter_id) references public.chapters (book_id, id) on delete cascade,
  constraint vocabulary_occurrences_user_id_id_key unique (user_id, id)
);

create table public.known_lemmas (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  language text not null,
  lemma text not null,
  state text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint known_lemmas_state_check
    check (state in ('unknown', 'learning', 'known', 'ignored')),
  constraint known_lemmas_server_version_check check (server_version >= 0)
);

create table public.review_cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  vocabulary_id uuid not null,
  face text not null,
  due_at timestamptz,
  stability numeric not null default 0,
  difficulty numeric not null default 0,
  review_count integer not null default 0,
  last_reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint review_cards_face_check
    check (face in (
      'recognition',
      'cloze',
      'reverse',
      'listening',
      'dictation',
      'shadowing',
      'sequencing'
    )),
  constraint review_cards_stability_check check (stability >= 0),
  constraint review_cards_difficulty_check check (difficulty >= 0),
  constraint review_cards_review_count_check check (review_count >= 0),
  constraint review_cards_server_version_check check (server_version >= 0),
  constraint review_cards_user_vocabulary_fkey
    foreign key (user_id, vocabulary_id) references public.vocabulary_occurrences (user_id, id)
    on delete cascade,
  constraint review_cards_user_id_id_key unique (user_id, id)
);

create table public.review_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  vocabulary_id uuid not null,
  card_id uuid,
  face text not null,
  rating integer not null,
  response_time_ms integer,
  reviewed_at timestamptz not null,
  device_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  server_version bigint not null default 0,
  deleted_at timestamptz,
  last_mutation_id uuid,
  constraint review_events_face_check
    check (face in (
      'recognition',
      'cloze',
      'reverse',
      'listening',
      'dictation',
      'shadowing',
      'sequencing'
    )),
  constraint review_events_rating_check check (rating >= 1 and rating <= 4),
  constraint review_events_response_time_ms_check
    check (response_time_ms is null or response_time_ms >= 0),
  constraint review_events_server_version_check check (server_version >= 0),
  constraint review_events_user_vocabulary_fkey
    foreign key (user_id, vocabulary_id) references public.vocabulary_occurrences (user_id, id)
    on delete cascade,
  constraint review_events_user_card_fkey
    foreign key (user_id, card_id) references public.review_cards (user_id, id)
    on delete set null (card_id),
  constraint review_events_user_device_fkey
    foreign key (user_id, device_id) references public.devices (user_id, id)
    on delete set null (device_id)
);

create unique index transcript_revisions_chapter_version_uidx
  on public.transcript_revisions (chapter_id, version);

create unique index transcript_revisions_active_uidx
  on public.transcript_revisions (chapter_id)
  where is_active and deleted_at is null;

create unique index transcript_revisions_object_key_uidx
  on public.transcript_revisions (object_key)
  where object_key is not null;

create unique index transcript_segments_revision_seq_uidx
  on public.transcript_segments (revision_id, sequence);

create index transcript_segments_sentence_hash_idx
  on public.transcript_segments (sentence_hash)
  where sentence_hash is not null;

create index transcript_segments_user_chapter_idx
  on public.transcript_segments (user_id, chapter_id);

create index vocabulary_occurrences_user_book_idx
  on public.vocabulary_occurrences (user_id, book_id)
  where deleted_at is null;

create index vocabulary_occurrences_user_chapter_idx
  on public.vocabulary_occurrences (user_id, chapter_id)
  where deleted_at is null;

create index vocabulary_occurrences_user_lemma_idx
  on public.vocabulary_occurrences (user_id, lemma)
  where deleted_at is null;

create unique index known_lemmas_user_language_lemma_uidx
  on public.known_lemmas (user_id, language, lemma)
  where deleted_at is null;

create index known_lemmas_user_updated_idx
  on public.known_lemmas (user_id, updated_at desc);

create unique index review_cards_user_vocab_face_uidx
  on public.review_cards (user_id, vocabulary_id, face)
  where deleted_at is null;

create index review_cards_user_due_idx
  on public.review_cards (user_id, due_at)
  where deleted_at is null;

create index review_events_user_vocabulary_id_idx
  on public.review_events (user_id, vocabulary_id, reviewed_at);
