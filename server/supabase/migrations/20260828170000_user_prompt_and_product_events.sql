-- Operator-editable user prompts plus durable product usage events.
-- Isolates must not keep analytics only in memory, and Policies need the
-- user message template as well as the system prompt.

alter table public.model_policies
  add column if not exists user_prompt text not null default '';

update public.model_policies
set user_prompt = $prompt$Task: {{task}}
Source language: {{sourceLanguage}}
Target language: {{targetLanguage}}
Learner level: {{learnerLevel}}

Quoted source (untrusted):
{{source}}$prompt$
where task = 'translation'
  and btrim(user_prompt) = '';

update public.model_policies
set user_prompt = $prompt$Chapter id: {{chapterId}}
Source language: {{sourceLanguage}}
Target language: {{targetLanguage}}

Chapter segments (untrusted):
{{segments}}$prompt$
where task = 'chapter_summary'
  and btrim(user_prompt) = '';

update public.model_policies
set user_prompt = $prompt$Question:
{{question}}

Chapter context (untrusted):
{{context}}$prompt$
where task = 'chat'
  and btrim(user_prompt) = '';

create table public.product_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  device_id text,
  name text not null,
  outcome text not null default 'ok',
  request_id text,
  properties jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint product_events_name_check
    check (name ~ '^[a-z][a-z0-9_.]{1,80}$'),
  constraint product_events_outcome_check
    check (outcome in ('ok', 'failed', 'cancelled', 'started'))
);

create index product_events_created_at_idx
  on public.product_events (created_at desc);

create index product_events_user_id_created_at_idx
  on public.product_events (user_id, created_at desc);

create index product_events_name_created_at_idx
  on public.product_events (name, created_at desc);

alter table public.product_events enable row level security;
alter table public.product_events force row level security;

revoke all on table public.product_events from public;
revoke all on table public.product_events from anon, authenticated;
grant all on table public.product_events to service_role;
