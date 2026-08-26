# AudioReader Cross-Device, Multi-User Redesign

## Product architecture, backend/admin design, research synthesis, and phased TDD implementation plan

**Repository:** `aitrail001/audio-reader`  
**Baseline:** `main` at commit `e22685ae2c3b6c14eb53de8ebd2d4d3e017d6c3b`  
**Plan date:** 26 August 2026  
**Initial managed LLM provider:** Alibaba Cloud Model Studio / Qwen  
**Target clients:** native macOS, iPadOS and an iPhone-adaptive iOS presentation; web admin console  
**Execution branch:** `feature/cross-device-multi-user` in an isolated worktree

---

## 1. Executive decision

Keep AudioReader native and local-first. Add an account, synchronization, managed-Qwen and administration platform around the existing reader instead of replacing it with a web application.

The redesigned product will have four main parts:

1. **Native Apple clients** retain local media, playback, dictionary integration, on-device transcription, EPUB alignment, offline reading and immediate study interactions.
2. **A versioned OpenAPI backend** owns user identity mappings, sync, private library metadata, optional cloud media, transcript revisions, learning history, Qwen work, quotas and audit events.
3. **A shared exact-content language cache** reuses eligible Qwen results for another user who supplies or owns identical content, while keeping each user's books, notes, vocabulary, review state and acceptance decisions private.
4. **A separate admin console** lets operators manage users, quotas, jobs, Qwen model policies, prompt versions, cache quality, storage, feature flags, privacy requests and system health.

The free-to-start deployment is:

- **Supabase Free** for Auth and PostgreSQL;
- **Cloudflare Workers** for the API/BFF and Qwen gateway;
- **Cloudflare Queues** for durable asynchronous jobs;
- **Cloudflare R2** for optional media, transcript blobs and backups;
- **Cloudflare Pages** for the admin web application;
- **Resend Free** for development/early production email OTP delivery;
- **Alibaba Cloud Model Studio in Singapore** for Qwen, using server-held credentials and an OpenAI-compatible interface.

This stack starts without a standing infrastructure bill under published free allowances, but Qwen's free quota is introductory and time-limited. AI usage therefore needs quotas, caching and cost monitoring from the first release.

---

## 2. What AudioReader already does well

The current application is an immersion reader with unusually strong native behavior:

- local audiobook and folder import;
- M4B chapter extraction;
- Apple SpeechAnalyzer transcription with word timing;
- the spoken transcript as timing authority;
- EPUB validation and probabilistic sentence alignment;
- Spoken, Ebook and Both views;
- sentence seeking, replay, loop and Deep Reading;
- dictionary lookup and contextual vocabulary capture;
- known/learning/unknown word state and chapter coverage;
- cloze, reverse and recognition review;
- sentence shadowing and chapter quizzes;
- structured translation, summary and chapter chat contracts;
- explicit pending/accepted/rejected generated content;
- native macOS/iPadOS presentation and parity tests.

The migration must not weaken these capabilities. The current local reader is the foundation; the backend is a coordination and managed-service layer.

See the companion audit: [`audio_reader_repo_audit.md`](audio_reader_repo_audit.md).

---

## 3. Product goals and non-goals

### 3.1 Goals

1. A user can sign in with Google, Microsoft or a one-time email code.
2. The same user can continue a book on another device with settings, progress, vocabulary, known-word state, reviews, transcripts and accepted study material synchronized.
3. Reading, playback, lookup, review and local transcription continue offline.
4. Users never configure Qwen credentials, endpoints or model names.
5. Eligible identical translation/explanation requests reuse a shared cache and do not call Qwen again.
6. Private user data remains isolated even when a shared language result is reused.
7. Imports and uploads are resumable, deduplicated and explain failures clearly.
8. The backend and admin console are defined by OpenAPI and can be implemented/tested by coding agents independently.
9. Every phase follows test-first development and has measurable exit criteria.
10. The system can begin on free tiers and has explicit scale-up thresholds.

### 3.2 Non-goals for the first multi-user release

- public book sharing or a marketplace;
- social feeds, leaderboards or an XP economy;
- organization/team tenancy;
- collaborative transcript editing;
- user-selectable LLM providers;
- server-side transcription as the normal path;
- hosting DRM-protected content or bypassing platform protections;
- a browser-based replacement for the native reader;
- automatic global sharing of every generated result.

### 3.3 Product success measures

Track product outcomes, not vanity activity:

- successful sign-in rate by provider;
- first sync completion rate;
- percentage of sessions that resume within one sentence of the previous device;
- import completion rate and median recovery time after interruption;
- transcript/ebook alignment acceptance and correction rate;
- Qwen task success rate and p50/p95 latency;
- eligible cache hit rate and estimated provider cost avoided;
- percentage of generated results accepted, regenerated or rejected;
- due-review completion and return-to-source rate;
- sync conflicts per 1,000 mutations;
- user-reported data-loss incidents: target zero;
- unauthorized cross-user access findings: target zero.

---

## 4. Research-derived product direction

The market already validates reading/listening from real content, click-to-translate, word status, contextual vocabulary and SRS. Public feedback shows persistent dissatisfaction with unreliable imports, audio/text drift, manual card creation, detached flashcards and poor continuity.

The product opportunity is not “another AI language tutor.” It is a dependable book-centered system that connects:

- exact narration timing;
- trusted ebook wording;
- context-aware language help;
- private learning state;
- cross-device continuity;
- low-friction review;
- managed AI with cost-saving reuse.

The companion research report contains the product matrix and source links: [`audio_reader_user_research.md`](audio_reader_user_research.md).

### 4.1 Highest-value uncommon combination

Few products combine all of the following well:

1. user-owned audiobook plus ebook;
2. on-device word-timed transcription;
3. document-level alignment safety;
4. exact sentence replay and shadowing;
5. known-word coverage in a full book;
6. vocabulary occurrences that return to the original audio;
7. offline local-first behavior;
8. account sync without uploading all media by default;
9. structured learner-focused explanations;
10. privacy-safe cross-user reuse of identical generated language work.

That combination should define AudioReader's roadmap.

---

## 5. Architecture options considered

### Option A — Supabase client-direct architecture

Native clients call Supabase Auth, PostgREST, Storage and Realtime directly. Edge Functions proxy Qwen.

**Advantages**

- fastest prototype;
- less custom API code;
- Row Level Security can protect common CRUD.

**Disadvantages**

- clients become coupled to Supabase schemas and SDK behavior;
- complex sync/conflict logic leaks into every client;
- OpenAPI is incomplete or secondary;
- service-role operations and cache coordination are harder to keep disciplined;
- future migration is expensive.

### Option B — Cloudflare-only architecture using D1

Cloudflare Workers, D1, R2, Queues and Pages host everything; a separate auth service is built or added.

**Advantages**

- one operational platform;
- generous free edge allowances;
- simple R2 and Queue bindings.

**Disadvantages**

- robust Google/Microsoft/email OTP account work becomes a project of its own;
- D1 is less convenient for PostgreSQL-style RLS, transactional claims and analytics;
- migrating existing and future relational learning data is less flexible.

### Option C — Recommended: Supabase identity/data plus a Cloudflare OpenAPI BFF

Supabase supplies Auth and PostgreSQL. Native clients only use the product API contract. Cloudflare Workers validate Supabase JWTs, enforce product policy, create signed R2 transfers, coordinate jobs and call Qwen. Queues run asynchronous work; Pages hosts admin.

**Why this is recommended**

- fast, supported OAuth/OTP start;
- PostgreSQL constraints, transactions and RLS;
- a stable product contract independent of infrastructure vendors;
- server-held provider secrets;
- inexpensive object storage for large assets;
- simple scale path: keep the API while replacing Supabase, R2 or Qwen behind it.

---

## 6. Target system architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Native macOS / iPadOS / iOS client                                  │
│                                                                     │
│ SwiftUI UI · AVFoundation player · Apple SpeechAnalyzer             │
│ EPUB parser/aligner · Dictionary · Local SQLite · Local files       │
│ Outbox + pull cursor · Generated OpenAPI Swift client               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ HTTPS / JSON / signed asset transfers
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Cloudflare Worker: AudioReader API / BFF                            │
│                                                                     │
│ JWT validation · authorization · idempotency · sync · quotas        │
│ R2 upload sessions · job submission · Qwen gateway · admin API      │
└───────────────┬────────────────────┬─────────────────────┬──────────┘
                │                    │                     │
                ▼                    ▼                     ▼
┌──────────────────────┐  ┌──────────────────────┐  ┌─────────────────┐
│ Supabase              │  │ Cloudflare R2        │  │ Cloudflare      │
│ Auth + PostgreSQL     │  │ private media        │  │ Queues/Workers  │
│ RLS + change log      │  │ transcript blobs     │  │ async jobs      │
└──────────────────────┘  │ backups/exports      │  └────────┬────────┘
                          └──────────────────────┘           │
                                                             ▼
                                                   ┌──────────────────┐
                                                   │ Qwen Model Studio │
                                                   │ server key only   │
                                                   └──────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ Admin web app on Cloudflare Pages                                   │
│ Generated TypeScript client · admin RBAC · no service key in browser│
└─────────────────────────────────────────────────────────────────────┘
```

### 6.1 Trust boundaries

- The native device is trusted for its user's local data but not trusted to assert ownership, quotas or cache eligibility.
- The Worker is the public product boundary and is the only component allowed to invoke Qwen.
- Supabase Auth issues sessions; the Worker validates issuer, audience, expiry and subject.
- PostgreSQL is the system of record for synchronized metadata and event history.
- R2 objects are private. Access is through short-lived scoped URLs or Worker streaming.
- The admin browser never receives Supabase service-role, R2 or Qwen secrets.

---

## 7. Client architecture

### 7.1 Preserve local-first behavior

Each client has:

- a local SQLite database;
- a local asset store;
- an immutable mutation outbox;
- a server pull cursor;
- local transcript revisions;
- local review-event history;
- Keychain-held refresh/session/device secrets;
- background sync that can stop and resume safely.

A user action follows this order:

1. validate locally;
2. commit the domain change and outbox mutation in one local transaction;
3. update the UI immediately;
4. push when connectivity and authentication permit;
5. apply server acknowledgements or conflicts;
6. pull remote changes and merge with explicit policy.

### 7.2 Proposed Swift package boundaries

Do not move every file at once. Establish targets incrementally:

```text
Sources/
  AudioReaderDomain/
    Identity/
    Library/
    Reader/
    Transcript/
    Learning/
    Assistant/
    Sync/
  AudioReaderLocalStore/
    Migrations/
    Repositories/
    Outbox/
  AudioReaderNetworking/
    Generated/
    APIClient.swift
    AuthSession.swift
    MediaTransfer.swift
  AudioReaderPlatform/
    AppleSpeechTranscriber.swift
    DictionaryAdapter.swift
    KeychainStore.swift
  AudioReaderApp/
    Features/
    AppComposition.swift
```

During migration, existing `Sources/AudioReader` remains the app target. New protocols and repositories are introduced beside it, then large responsibilities are moved out of `AppState` and `PlayerView` in tested slices.

### 7.3 Account states

- **Local guest:** no remote Qwen; all current local functionality remains available where practical.
- **Signed in, sync off:** managed Qwen available; data remains local until the user enables sync/import migration.
- **Signed in, sync on:** selected learning data synchronizes.
- **Cloud media enabled per book:** private audio/EPUB assets can be downloaded on another device.

This staged model avoids forcing existing users to upload books or create an account before reading.

---

## 8. Authentication and device identity

### 8.1 Supported login

- Google OAuth via PKCE;
- Microsoft OAuth through Microsoft Entra/Azure provider via PKCE;
- email one-time code;
- future Sign in with Apple can be added without changing product sessions.

Supabase currently documents native Google login, Azure/Microsoft login, and passwordless email OTP. The product API wraps the infrastructure so clients are not coupled to Supabase endpoints.

### 8.2 Native flow

1. Client calls the API for provider configuration/authorization URL.
2. `ASWebAuthenticationSession` completes OAuth with a universal-link/custom-scheme callback.
3. Client exchanges the authorization code and PKCE verifier through the API.
4. API/Supabase returns access and refresh sessions.
5. Refresh token is stored in Keychain; access token stays in memory or protected storage.
6. Client registers a device with a generated device ID, app version and capabilities.

### 8.3 Email-code protections

- response does not reveal whether an address exists;
- per-IP, per-email-hash and per-device rate limits;
- six-digit or equivalent high-entropy OTP with short expiry;
- single use;
- resend cooldown;
- custom SMTP required outside a closed test group;
- security event for repeated failure;
- optional CAPTCHA/Turnstile after abuse threshold.

### 8.4 Account linking

Do not auto-merge accounts solely because two providers return the same unverified address. Link only when:

- both identities have verified email and Supabase/provider policy supports safe linking; or
- an already-authenticated user explicitly links another provider.

### 8.5 Admin authentication

Admins use the same identity provider but require:

- an explicit role record;
- MFA before sensitive operations;
- short admin sessions;
- step-up confirmation for suspension, cache purge, data export and deletion;
- immutable audit events.

---

## 9. Data model

### 9.1 Ownership model

Every private row has `user_id` and is protected by RLS even though the API also checks authorization. Global operational/cache tables are inaccessible to normal user JWTs.

### 9.2 Core tables

| Table | Scope | Purpose |
|---|---|---|
| `profiles` | private | locale, display preferences, account status |
| `devices` | private | device identity, capabilities, last sync, revoked state |
| `user_settings` | private | per-field versioned product settings, no provider secrets |
| `books` | private | one user's library record and cloud/local availability |
| `book_assets` | private | audio, EPUB, cover metadata, exact hash and R2 object state |
| `canonical_works` | global internal | optional normalized title/author/ISBN grouping |
| `canonical_editions` | global internal | normalized text/edition fingerprints |
| `chapters` | private | stable chapter identity and ordering |
| `reading_progress` | private | position, completed state, playback preferences |
| `transcript_revisions` | private | immutable transcript metadata and R2 blob reference |
| `transcript_segments` | private | sentence text/timing index used by sync and assistant tasks |
| `vocabulary_occurrences` | private | exact word/phrase/sentence occurrence and source anchor |
| `known_lemmas` | private | explicit language+lemma familiarity state |
| `review_cards` | private | prompt type and current derived schedule |
| `review_events` | private append-only | deterministic learner responses |
| `user_assistant_results` | private | pending/accepted/rejected result linked to source and cache |
| `assistant_cache_entries` | global internal | reusable exact-content structured result |
| `assistant_jobs` | private + admin | queued/running/completed/failed Qwen work |
| `usage_ledger` | private + admin | token, request, storage and quota accounting |
| `sync_changes` | private | ordered server change feed |
| `idempotency_records` | private | safe retry responses |
| `feature_flags` | operational | rollout policy |
| `model_policies` | operational | Qwen model/prompt/schema versions and budgets |
| `admin_roles` | operational | RBAC assignment |
| `audit_events` | append-only | operator and security actions |
| `privacy_requests` | private + admin | export/deletion workflow |

### 9.3 Required columns on synchronized entities

```text
id UUID
user_id UUID
created_at timestamptz
updated_at timestamptz
server_version bigint
deleted_at timestamptz null
last_mutation_id UUID
```

Fields that need independent merge behavior additionally store a field-level hybrid logical clock or update timestamp.

### 9.4 Content identity

Use separate IDs for separate concerns:

- `book_id`: the user's private library object;
- `asset_id`: one private file record;
- `asset_sha256`: exact byte identity;
- `edition_fingerprint`: normalized EPUB/text edition identity;
- `chapter_id`: stable private UUID;
- `transcript_revision_id`: immutable revision;
- `sentence_hash`: normalized sentence digest;
- `cache_key`: server-keyed HMAC over the complete reusable task contract.

Never use an absolute local path as a remote identity.

---

## 10. Offline synchronization design

### 10.1 Protocol

The API supports both ordinary resource endpoints and a dedicated device sync protocol:

- `POST /v1/sync/push`
- `GET /v1/sync/pull?cursor=...&limit=...`
- `POST /v1/sync/ack`
- `POST /v1/sync/resnapshot` for a stale cursor or repaired device.

Each pushed mutation contains:

```json
{
  "mutationId": "uuid",
  "entityType": "vocabularyOccurrence",
  "entityId": "uuid",
  "operation": "upsert",
  "baseVersion": 7,
  "clientHlc": "2026-08-26T07:15:20.123Z-0004-device",
  "payload": {}
}
```

The server applies each `mutationId` once. Retrying a timed-out request returns the stored acknowledgement.

### 10.2 Pull cursor

`sync_changes` assigns a monotonically increasing per-user sequence. A device stores the last fully applied cursor. Pull responses are applied in a local transaction before the cursor advances.

### 10.3 Merge rules

| Entity | Merge policy |
|---|---|
| settings | field-level last-write by HLC; server validates range/type |
| book metadata | field-level last-write; assets immutable; deletion is tombstoned |
| reading position | latest explicit interaction wins; `completed_at` is separately monotonic |
| known lemma | latest explicit state wins; never inferred from scrolling/playback |
| vocabulary occurrence | stable occurrence ID; field-level last-write; delete tombstone |
| assistant acceptance | private latest decision; shared cache entry remains unchanged |
| review event | append-only by event ID; duplicates ignored |
| review schedule | deterministically recomputed from ordered events |
| transcript | immutable revisions; active revision pointer uses latest explicit selection |
| chapter order | server validates complete ordering transaction |

### 10.4 Conflict presentation

Most conflicts resolve automatically. Show a user-facing conflict only when preserving both choices matters, for example:

- two devices replace the same EPUB with different editions;
- two transcript revisions are both explicitly made active;
- a note is edited substantially on two devices.

The conflict UI shows both values, source device and timestamp. It never exposes raw server internals.

### 10.5 Tombstones and stale devices

- keep tombstones and change-log rows for at least 90 days initially;
- a device older than retention receives `cursor_expired` and performs a bounded resnapshot;
- account deletion bypasses normal retention and enters a documented purge workflow.

---

## 11. Library, media and import design

### 11.1 Default data policy

Sync small learning data by default after opt-in. Keep audio and EPUB files local unless the user enables cloud media for that book.

A book can therefore be:

- **local only** — metadata/progress can sync, but another device must re-import the asset;
- **matched locally** — another device imports the same exact file and links by hash;
- **cloud available** — private asset uploaded to R2 and downloadable on authorized devices.

### 11.2 Import transaction

1. Inspect selected files locally.
2. Reject DRM-protected/inaccessible content without bypass attempts.
3. Hash exact bytes incrementally.
4. Extract safe metadata and chapter structure.
5. Create or match a local book record idempotently.
6. If signed in, query hash matches for this user.
7. Create remote library metadata.
8. Optionally create R2 multipart upload sessions.
9. Run local transcription and EPUB validation independently.
10. Sync immutable transcript/alignment revisions.

### 11.3 Multipart upload

- API checks user quota and permitted MIME/extension/size.
- API creates an upload record and short-lived signed part URLs.
- Client uploads directly to R2 and records completed ETags locally.
- Completion API validates part list and final object size/hash.
- Interrupted sessions resume; expired sessions are recreated without duplicating completed local work.
- Orphaned multipart uploads are cleaned by scheduled jobs.

### 11.4 Security controls

- private R2 bucket;
- object key is random and never user-supplied path text;
- EPUB extraction limits file count, compressed/uncompressed ratio and nested archives;
- content type is derived, not trusted from the client;
- no HTML/JavaScript from imported books executes in the admin origin;
- user attests they are authorized to process uploaded content;
- no public object URLs;
- per-user storage and bandwidth quotas;
- optional malware scanning is a scale-up requirement before broad public uploads.

---

## 12. Transcription and alignment

### 12.1 Preferred path

Apple SpeechAnalyzer remains the preferred transcription engine on compatible devices. Microphone dictation and shadowing also remain on-device.

### 12.2 Capability registration

Each device reports:

- OS and app version;
- supported speech locales;
- local Foundation Models availability;
- background processing capability;
- free storage;
- whether cloud media is enabled.

The backend uses this for feature presentation and diagnostics, not to force a server transcription call.

### 12.3 Transcript storage

- full word-timed transcript is compressed JSON in R2;
- searchable sentence text and timing live in `transcript_segments`;
- transcript revisions are immutable;
- alignment assessment is a separate versioned object;
- active revision is user-scoped;
- partial local checkpoints stay local until coherent enough to upload, unless explicit resumable transcript sync is enabled.

### 12.4 Server fallback

Not in the first release. A later controlled fallback may use Qwen ASR or another service when:

- the device has no local locale support;
- the user explicitly requests cloud transcription;
- content policy and quota allow it.

It must never silently upload audio because local transcription failed.

---

## 13. Vocabulary and study system

### 13.1 Separate shared language data from private learning data

A vocabulary item has three layers:

1. **Lexeme:** normalized language, lemma and optional morphology.
2. **Occurrence:** exact private book/chapter/sentence/timestamp/word range.
3. **Review card/state:** private prompt type, scheduler state and events.

Shared dictionary or Qwen-derived semantics can be referenced, but notes, familiarity, review history and occurrence anchors are always private.

### 13.2 Review modes

- recognition;
- contextual cloze;
- reverse production;
- listen then reveal;
- sentence continuation;
- shadowing retry.

The exact narration clip is used when local/cloud audio is available. A card remains usable as text if media is absent on a device.

### 13.3 Scheduler

Use an FSRS-style deterministic scheduler with append-only events. Because Swift and TypeScript implementations can drift, maintain a language-neutral golden-vector file containing:

- prior state;
- review timestamp;
- rating;
- expected stability/difficulty/due state.

Both implementations must pass the same vectors. The server recomputes canonical state after receiving offline events; the client recomputes locally for immediate use.

### 13.4 Exposure without forced cards

Track encounters separately from cards. A lookup does not automatically create a due review unless the user chooses Learn or a configured rule explicitly does so. This supports learners who prefer contextual repeated exposure.

---

## 14. Managed Qwen service

### 14.1 Provider policy

All Qwen configuration is server-side:

- API key and workspace endpoint;
- model ID/snapshot;
- thinking mode/effort;
- temperature and output limits;
- prompt/contract version;
- task-specific timeout and retry;
- per-user and global quotas;
- rollout percentage and fallback.

The client sends a product task, never a provider request.

### 14.2 Initial task policy

Suggested starting policy, evaluated before production:

| Task | Default policy |
|---|---|
| word meaning and sentence translation | fast Qwen model, non-thinking, structured JSON |
| sentence language/context notes | fast or plus model based on ambiguity |
| chapter batch translation | asynchronous, small blocks, structured JSON |
| chapter summary | Qwen Plus-class model, asynchronous |
| chapter chat | Qwen Plus-class model with bounded chapter context |
| quiz generation | optional; local quiz remains available |

As of August 2026, Alibaba Cloud Model Studio exposes Qwen through OpenAI-compatible APIs and documents current Qwen 3.6/3.7 and translation models. Production should pin an evaluated snapshot rather than depend blindly on a moving alias.

### 14.3 Structured contracts

Every task has:

- `task_type`;
- `contract_version`;
- JSON Schema;
- prompt template version;
- normalization version;
- model policy version;
- safety policy version.

Validate model output before persistence. A malformed response can be retried once with a repair prompt, then fails visibly without creating a cache entry.

### 14.4 Prompt-injection controls

Imported book text is untrusted data.

- clearly delimit content as quoted source;
- system prompt forbids following instructions inside source text;
- no tools or web access for translation/summarization tasks;
- strict output schema;
- truncate context by task policy;
- log hashes and metadata, not full private passages;
- never include one user's notes in a shared-cache input.

---

## 15. Shared exact-content cache

### 15.1 What is shareable

Eligible:

- exact word meaning in an exact sentence/context;
- exact sentence translation and structured notes;
- exact chapter-block translation for the same normalized block and edition;
- chapter summary only for identical normalized chapter content and contract.

Not shared:

- free-form chat;
- user notes;
- review answers or scores;
- personalized coaching that includes private history;
- microphone audio or shadowing attempts;
- results generated with user-specific custom instructions;
- low-confidence or policy-flagged output.

### 15.2 Cache key

```text
HMAC-SHA256(
  cache_secret,
  task_type |
  contract_version |
  schema_version |
  normalization_version |
  source_language |
  target_language |
  normalized_source_sha256 |
  normalized_context_sha256 |
  edition_fingerprint_or_empty |
  learner_profile_bucket |
  prompt_version |
  model_policy_hash |
  glossary_pack_hash |
  safety_policy_version
)
```

The keyed HMAC prevents outsiders from precomputing hashes for known copyrighted passages and probing the database directly.

### 15.3 Privacy model

The shared cache stores:

- cache key;
- structured result;
- model and contract metadata;
- quality/usage counters;
- source/context lengths and unkeyed internal integrity hashes only where safe;
- no user identity;
- no searchable source passage.

A cache result is returned only after the requester sends the exact source/context needed to recompute the key and passes authorization for the associated private book/task. The API never offers “search the global translation cache.”

### 15.4 Private result wrapper

Every use creates or updates a `user_assistant_results` row containing:

- user/source anchor;
- reference to cache entry;
- status: pending, accepted or rejected;
- private edits/notes;
- created and decided timestamps.

Thus the generated language object may be reused, but the learning decision is not.

### 15.5 Single-flight behavior

On a cache miss:

1. transaction inserts an `assistant_jobs` row with unique `cache_key` and generation state;
2. if another job already owns that key, attach the requester to the existing job;
3. enqueue exactly one provider job;
4. worker calls Qwen and validates output;
5. transaction writes cache entry, completes all attached user results and usage ledger entries;
6. clients poll job status or receive a realtime/push notification.

A unique database constraint is the final guarantee that two simultaneous requests do not produce two successful provider generations.

### 15.6 Quality management

- cache entries have `active`, `quarantined`, `superseded` or `purged` state;
- user rejection increments a signal but does not globally remove an entry;
- admins can inspect redacted metadata, compare output, quarantine and regenerate;
- prompt/model version changes naturally produce a new key;
- an emergency denylist can invalidate a contract/model combination;
- bad-output reports retain audit history.

---

## 16. Admin operations system

### 16.1 Technology

React + TypeScript + Vite on Cloudflare Pages, using a generated TypeScript OpenAPI client. The browser has only the admin user's JWT; all privileged operations pass through the Worker.

### 16.2 Roles

- `support_readonly`: user/account metadata and sync status, no content bodies;
- `operator`: jobs, flags, quotas and cache quarantine;
- `privacy_officer`: export/deletion requests;
- `billing_operator`: usage and limits;
- `superadmin`: role assignment and model policies.

Deny by default. Sensitive actions require MFA/step-up and an audit reason.

### 16.3 Screens

#### Overview

- sign-ins, active users and active devices;
- API error rate and latency;
- queue depth and oldest message;
- Qwen calls/tokens/cost estimate;
- cache hit ratio;
- storage by class;
- sync conflicts and stale devices;
- active incidents and flags.

#### Users

- search by internal ID or verified email;
- account status, providers and creation date;
- devices and last sync;
- quota use;
- book/media counts without exposing content by default;
- suspend/reactivate;
- revoke sessions/devices;
- start export or deletion workflow;
- support notes and audit trail.

#### Jobs

- queued/running/retry/dead-letter filters;
- job type, user, age, attempts and redacted failure;
- retry/cancel/quarantine;
- inspect linked model policy and cache key prefix;
- bulk actions with confirmation.

#### Qwen and prompts

- task-to-model policy;
- dated model snapshot;
- prompt and schema version;
- rollout percentage;
- timeout/retry/token limits;
- evaluation scorecard;
- estimated unit cost;
- promote/rollback with audit entry.

#### Shared cache

- hits, misses and savings by task/language;
- rejection/report rate;
- stale model/contract distribution;
- quarantine/regenerate/purge;
- no global source-text search.

#### Storage and content operations

- R2 usage by user and asset type;
- unfinished uploads and orphaned objects;
- duplicate exact hashes within a user;
- cleanup jobs;
- account purge progress.

#### Feature flags and releases

- percentage/device/app-version targeting;
- kill switches for cloud media, sync entity classes and Qwen task types;
- read-only maintenance mode;
- client minimum-version policy.

#### Audit and privacy

- immutable operator events;
- security events;
- export/deletion state;
- retention exceptions with reason and expiry.

---

## 17. OpenAPI contract

The companion file [`audio-reader-openapi-v1.yaml`](audio-reader-openapi-v1.yaml) is the initial OpenAPI 3.1 contract.

### 17.1 Contract rules

- `/v1` major version prefix;
- UUID resource IDs;
- RFC 3339 timestamps;
- `Idempotency-Key` on retryable writes and job submissions;
- cursor pagination rather than page numbers for change feeds;
- consistent `ProblemDetails` errors;
- explicit `operationId` for generated clients;
- bearer session auth plus an `AdminBearer` requirement for admin operations;
- long work returns `202 Accepted` and a job resource;
- signed media URLs are short-lived and scoped;
- schemas use additive evolution inside v1;
- breaking changes require v2.

### 17.2 Generated clients

- Swift: `swift-openapi-generator` into `AudioReaderNetworking/Generated`;
- TypeScript: `openapi-typescript` or equivalent into the admin/server contract package;
- CI fails when generated code differs from the checked contract;
- mock server/contract tests run before backend implementation tests.

---

## 18. Free-to-start deployment and scale path

### 18.1 Initial providers

| Capability | Initial provider | Published free allowance relevant to this plan | Important limitation |
|---|---|---|---|
| Auth + PostgreSQL | Supabase Free | 500 MB database, 1 GB Supabase Storage | no automatic backups on Free; use R2 backup workflow |
| API/BFF | Cloudflare Workers Free | 100,000 requests/day | 10 ms CPU per invocation; keep heavy work queued/external |
| Async jobs | Cloudflare Queues Free | 10,000 operations/day | 24-hour retention on Free |
| Object storage | Cloudflare R2 | 10 GB-month, 1M Class A and 10M Class B operations | total project allowance is small for audiobooks; enforce quotas |
| Admin static app | Cloudflare Pages | static asset requests free; Pages Functions share Worker quota | keep admin mostly static client + API |
| Transactional email | Resend Free | 3,000/month and 100/day | verify domain; upgrade as login volume grows |
| Qwen | Alibaba Cloud Model Studio | new-user quotas are typically per-model and valid for 90 days | not a permanent free service; track cost from day one |

Free-tier values change. Reconfirm before deployment.

### 18.2 Recommended starter quotas

- 250 MB cloud media per user during closed beta;
- 3 cloud-enabled books per user;
- 50 managed Qwen tasks/day/user;
- chapter operations limited by input tokens and concurrent jobs;
- 2 devices initially, configurable by admin;
- local-only books unlimited subject to device storage.

### 18.3 Scale triggers

Upgrade or migrate when any of these is sustained:

- Supabase DB > 350 MB;
- R2 > 8 GB;
- queue operations > 7,000/day;
- Worker request usage > 70,000/day;
- email OTP > 70/day;
- p95 sync latency > 2 seconds;
- cache claim contention or provider jobs exceed target latency;
- Qwen spend crosses the monthly budget threshold.

### 18.4 Scale path

1. Supabase Pro for backups, database/storage headroom and production support.
2. Cloudflare Workers Paid for longer CPU, larger queue retention and predictable capacity.
3. Raise R2 quotas; preserve S3-compatible object interface.
4. Move background workers to paid Workers/Containers if document processing grows.
5. Add a read replica/warehouse for admin analytics instead of querying transactional tables.
6. Retain the OpenAPI contract so clients do not change when infrastructure moves.

---

## 19. Security, privacy and content rights

### 19.1 Required controls

- RLS on every private table with automated policy tests;
- authorization in the Worker as defense in depth;
- secret rotation and environment separation;
- short-lived signed URLs;
- no Qwen/provider keys in client binaries or settings;
- redacted logs and structured error codes;
- per-user/IP/device quotas and abuse detection;
- encrypted transport everywhere;
- database and R2 backup/restore drills;
- dependency and secret scanning in CI;
- admin MFA and audit events;
- deletion/export workflow;
- retention schedule for jobs, logs, tombstones and backups.

### 19.2 Data minimization

- microphone audio remains local by default;
- local books may sync metadata without media;
- full source passages are not written to ordinary logs;
- shared cache has no user identity and no text-search interface;
- Qwen receives only the bounded source/context needed for the task;
- analytics use aggregate identifiers and avoid content bodies.

### 19.3 Copyright and DRM

- do not remove or bypass DRM;
- require users to process only content they are authorized to use;
- private media is not shared between users;
- a shared generated result is delivered only when a requester supplies/matches the exact authorized content;
- no public catalog of user imports;
- provide takedown and account-response procedures before public launch.

### 19.4 Threat cases to test

- user A requests user B's book/transcript ID;
- guessed cache hash/probe for a famous passage;
- stolen signed upload URL;
- oversized/zip-bomb EPUB;
- replayed sync mutation;
- conflicting account identities;
- prompt injection inside book text;
- Qwen response containing unsafe HTML;
- compromised admin session;
- denial-of-wallet through repeated cache-busting contexts.

---

## 20. Observability and operations

### 20.1 Correlation

Every request has:

- request ID;
- user and device IDs in protected structured fields;
- idempotency key where relevant;
- job ID;
- cache-key prefix only;
- model-policy version;
- app version and platform.

Never log access tokens, provider keys, full imported passages or raw microphone data.

### 20.2 Service-level objectives for beta

- API availability: 99.5%;
- cached assistant response p95 < 500 ms;
- new small assistant task accepted/queued p95 < 800 ms;
- sync push/pull p95 < 2 s for 100 changes;
- job completion p95 < 30 s for sentence tasks, < 5 min for chapter tasks;
- upload completion integrity: 99.9%;
- restore drill succeeds at least monthly.

### 20.3 Alerts

- auth failure spike;
- queue oldest age;
- Qwen failure/rate-limit spike;
- cache hit collapse after a deployment;
- database/R2 quota thresholds;
- RLS test regression;
- account deletion stuck;
- orphan upload growth;
- sync conflict or cursor-expiry spike.

---

## 21. TDD and verification strategy

### 21.1 Non-negotiable cycle

For each behavior change:

1. write the smallest failing test;
2. run it and confirm the expected failure;
3. implement the minimum behavior;
4. run focused tests;
5. run affected suites;
6. refactor while green;
7. build both Apple targets for shared changes;
8. commit a reviewable slice.

### 21.2 Test layers

#### Pure domain tests

- normalization and cache-key vectors;
- merge policies and HLC ordering;
- transcript revision selection;
- review scheduler golden vectors;
- quota calculations;
- content fingerprinting;
- prompt-contract parsing.

#### Database/RLS tests

- every private table denies another user;
- service/admin roles have only documented access;
- unique cache job claim;
- idempotent mutation replay;
- tombstone and change-log behavior;
- account purge cascades and retained audit exceptions.

#### API contract tests

- every operation matches OpenAPI request/response schema;
- generated Swift and TypeScript clients compile;
- problem responses are consistent;
- idempotency semantics;
- pagination and cursor expiry;
- OAuth/OTP errors do not enumerate accounts.

#### Integration tests

- local Supabase + Worker-compatible test server + fake R2 + fake Qwen;
- multipart resume and hash verification;
- queue retry/dead letter;
- Qwen malformed output repair and failure;
- duplicate simultaneous cache miss results in one provider call.

#### Native tests

- legacy local migration;
- offline mutation then reconnect;
- two-device conflict fixtures;
- local transcription while signed in and offline;
- asset local/cloud availability;
- account sign-out keeps or deletes local data according to user choice;
- macOS/iPad/iPhone navigation and accessibility.

#### End-to-end scenarios

1. New user signs in with Google on iPad, imports a book, transcribes locally, saves a word and opens the same state on Mac.
2. User reviews offline on two devices; all review events survive and due state converges.
3. User A translates an exact sentence; User B imports the identical edition and receives a cache hit with zero second Qwen call.
4. Same sentence with different disambiguating context produces a different key.
5. User B cannot retrieve User A's book, notes, result status or source by ID/hash guessing.
6. Upload stops halfway, app relaunches, and resumes without duplicate object or database row.
7. Qwen is unavailable; reading and existing cached results continue, job retries are bounded and visible.
8. Account deletion revokes sessions, purges private rows/objects and records completion without retaining content in logs.

### 21.3 Performance tests

- 10,000-book metadata list pagination;
- 100,000 vocabulary occurrences per user;
- 500-change sync batch;
- 100 concurrent requests for one cache key;
- chapter with 20,000 transcript words;
- R2 multipart upload under network interruption;
- admin queries against production-like indexes.

---

## 22. Worktree, branch and proposed repository layout

### 22.1 Create the isolated worktree

Run from the existing repository checkout:

```bash
git fetch origin main

git worktree add \
  ../audio-reader-cross-device \
  -b feature/cross-device-multi-user \
  origin/main

cd ../audio-reader-cross-device
```

Before any implementation, record:

```bash
git rev-parse HEAD
git status --short
swift test
xcodebuild -project AudioReader.xcodeproj \
  -scheme AudioReader-macOS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AudioReader.xcodeproj \
  -scheme AudioReader-iOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

If baseline tests fail, stop and document whether the failure is reproducible on `main`. Do not hide a dirty baseline inside this project.

### 22.2 Proposed top-level layout

```text
contracts/
  openapi-v1.yaml
  examples/
  generated/
server/
  package.json
  pnpm-workspace.yaml
  apps/
    api-worker/
    job-worker/
    admin-web/
  packages/
    contract/
    domain/
    auth/
    database/
    qwen/
    observability/
supabase/
  config.toml
  migrations/
  tests/
Sources/
  AudioReader/                 # existing app during migration
  AudioReaderDomain/
  AudioReaderLocalStore/
  AudioReaderNetworking/
  AudioReaderPlatform/
Tests/
  AudioReaderTests/            # existing tests
  AudioReaderDomainTests/
  AudioReaderLocalStoreTests/
  AudioReaderNetworkingTests/
tests/
  contract/
  integration/
  e2e/
docs/
  architecture/
  runbooks/
```

Do not move all current Swift files in one commit. Add boundaries, migrate one behavior, then remove the old path after parity tests pass.

---

## 23. Grok 4.6 High execution model

### 23.1 Orchestrator rules

The main Grok 4.6 High agent is the orchestrator. It must:

1. read this plan, the OpenAPI contract, `AGENTS.md`, `PRODUCT.md` and affected source/tests before dispatch;
2. execute phases strictly in order;
3. create one fresh implementation subagent per independently reviewable task;
4. prevent two subagents from editing overlapping files concurrently;
5. require a failing test before production code;
6. require the implementation subagent to return commands and exact test output;
7. dispatch a separate reviewer subagent after each task;
8. fix review findings before merging the task commit;
9. run the phase gate suite itself, not rely only on subagent claims;
10. stop at every phase exit criterion and produce a checkpoint report.

### 23.2 Standard implementation-subagent prompt

```text
You are a Grok 4.6 High implementation subagent working in the
feature/cross-device-multi-user worktree.

Read first:
- AGENTS.md
- PRODUCT.md
- Audio-Reader-Cross-Device-Multi-User-Design-and-Plan.md
- audio-reader-openapi-v1.yaml
- every file listed in this task

Implement only TASK <number/name>. Do not broaden scope.

Mandatory workflow:
1. State the behavior and the production change that will make the test pass.
2. Write the smallest failing test first.
3. Run it and include the expected RED output.
4. Implement the minimum code.
5. Run focused tests and include GREEN output.
6. Run all suites required by the task.
7. Refactor only while tests stay green.
8. Run formatter/linter and relevant Apple builds.
9. Commit with the exact task commit message.

Do not:
- edit files owned by another active task;
- add provider keys or secrets;
- bypass OpenAPI or RLS;
- replace local-first behavior with network-required behavior;
- claim runtime verification that you did not perform.

Return:
- files changed;
- tests added;
- RED command/result;
- GREEN commands/results;
- build/runtime evidence;
- commit SHA;
- risks or follow-up limited to this task.
```

### 23.3 Standard reviewer-subagent prompt

```text
You are a Grok 4.6 High review subagent. Review TASK <number/name>
against the design, OpenAPI contract, AGENTS.md and its exit criteria.

Inspect the diff and rerun the most important focused tests.
Prioritize findings as Blocker, High, Medium or Low.
Check:
- test-first evidence and whether tests would fail on regression;
- cross-user isolation and authorization;
- offline/local-first invariants;
- idempotency and conflict behavior;
- API/schema compatibility;
- macOS/iPadOS parity where applicable;
- secrets, logging and privacy;
- unnecessary scope or architectural coupling.

Do not rewrite the feature. Return concrete findings with file/line,
expected correction and verification command. Say APPROVED only when
no Blocker or High finding remains.
```

### 23.4 Phase checkpoint report

At each phase boundary, the orchestrator writes:

```text
Phase:
Baseline commit:
Task commits:
Exit criteria: pass/fail for each item
Tests: commands, counts and failures
macOS build:
iOS build:
Contract/RLS/security evidence:
Runtime evidence actually obtained:
Known limitations:
Next phase:
```

---

## 24. Phased implementation plan

## Phase 0 — Baseline, worktree and contract lock

**Goal:** Create a clean isolated execution environment and make the contract/design reproducible without changing product behavior.

**Lead subagents:** repository-baseline, contract-validation  
**Reviewer:** architecture-guard

### Tasks

#### 0.1 Baseline evidence

- Create the worktree and branch from `origin/main`.
- Run complete Swift tests.
- Build macOS and iOS Simulator schemes.
- Record current application versions and package artifacts.
- Save evidence in `docs/architecture/phase-0-baseline.md`.

**Test commands**

```bash
swift test
xcodebuild -project AudioReader.xcodeproj -scheme AudioReader-macOS \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AudioReader.xcodeproj -scheme AudioReader-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

#### 0.2 Contract placement and validation

- Copy `audio-reader-openapi-v1.yaml` to `contracts/openapi-v1.yaml`.
- Add a script that parses YAML, verifies OpenAPI 3.1, resolves local component references and rejects duplicate `operationId` values.
- Add contract lint to CI.
- Add example payloads for auth, sync, cache-hit, queued-job and problem responses.

**Tests first**

- `test_openapi_parses`
- `test_operation_ids_are_unique`
- `test_all_local_refs_resolve`
- `test_every_write_declares_problem_response`
- `test_admin_routes_require_admin_security`

#### 0.3 Architecture decisions

Create concise ADRs:

- ADR-001: local-first native client;
- ADR-002: Supabase Auth/Postgres + Cloudflare BFF;
- ADR-003: optional cloud media;
- ADR-004: shared exact-content cache;
- ADR-005: OpenAPI as product boundary.

**Commit boundaries**

- `chore: record cross-device baseline`
- `docs: add v1 API contract and architecture decisions`

### Exit criteria

- Worktree is clean and on `feature/cross-device-multi-user`.
- Baseline Swift test/build results are recorded honestly.
- Contract validation runs locally and in CI.
- No production behavior changed.
- Architecture reviewer approves all ADRs and contract assumptions.

---

## Phase 1 — Domain boundaries and local schema v2

**Goal:** Prepare the native code for accounts and sync while preserving all local behavior.

**Lead subagents:** swift-domain, sqlite-migration, appstate-extraction  
**Reviewer:** apple-architecture

### Tasks

#### 1.1 Stable domain identifiers

Create typed IDs for:

- `UserID`, `DeviceID`, `BookID`, `AssetID`, `ChapterID`;
- `TranscriptRevisionID`, `VocabularyOccurrenceID`, `ReviewEventID`;
- `MutationID` and `ServerVersion`.

Add decoding compatibility for legacy string IDs. Do not rewrite every use site immediately.

**Failing tests**

- legacy `Book`/`Chapter` JSON decodes into stable IDs;
- IDs round-trip through Codable;
- newly created IDs are unique and path-independent;
- no absolute path is used to derive a remote ID.

#### 1.2 Repository protocols

Introduce protocols for settings, books, transcripts, vocabulary, known lemmas, review events, assistant results and sync outbox. Add adapters over current `Persistence`/`LibraryStore`.

Tests use in-memory repositories and assert current behavior without file-system globals.

#### 1.3 Local SQLite v2 migration

Add normalized tables:

- `local_books`, `local_assets`, `local_chapters`;
- `local_transcript_revisions`;
- `local_vocabulary_occurrences`, `local_known_lemmas`;
- `local_review_cards`, `local_review_events`;
- `local_assistant_results`;
- `sync_outbox`, `sync_state`, `entity_versions`.

Migration imports current SQLite/JSON data exactly once and writes a migration receipt.

**Failing migration fixtures**

- a real-shaped legacy transcript with EPUB assessment;
- vocabulary with dictionary HTML and review history;
- accepted and pending glosses;
- known lemmas and activity log;
- interrupted migration rollback;
- repeated launch does not duplicate rows.

#### 1.4 Extract `AppState` dependencies

Add an `AppComposition` that injects repositories and services. Move one vertical slice first—known lemmas and vocabulary persistence—behind injected dependencies.

Do not yet add network behavior.

**Cross-platform verification**

- existing study overlay, mark known and vocabulary review tests still pass;
- macOS and iOS builds pass;
- local app launches with migrated data fixture.

**Commit boundaries**

- `refactor: add stable domain identifiers`
- `refactor: introduce local repository contracts`
- `feat: migrate local learning data to schema v2`
- `refactor: inject learning repositories into app state`

### Exit criteria

- Legacy user data migrates with no count/content loss in fixtures.
- Migration is transactional and idempotent.
- Current app works fully offline with no backend.
- `AppState` no longer directly owns persistence for the migrated vertical slice.
- Both Apple targets build and full Swift suite passes.

---

## Phase 2 — Backend workspace and API skeleton

**Goal:** Establish a testable TypeScript backend/admin workspace that implements health, error, authentication middleware and generated contract types.

**Lead subagents:** server-scaffold, openapi-generation, worker-runtime  
**Reviewer:** backend-platform

### Tasks

#### 2.1 Workspace

Create a pinned Node/pnpm workspace under `server/` with:

- strict TypeScript;
- formatter/linter;
- unit test runner;
- `api-worker`, `job-worker`, `admin-web` applications;
- `contract`, `domain`, `database`, `auth`, `qwen`, `observability` packages.

Pin runtime and lockfile. Add `.env.example` containing names only, no secrets.

#### 2.2 Generated contract types

Generate TypeScript request/response types from `contracts/openapi-v1.yaml`. Add drift check in CI.

**Tests first**

- generated types include required auth/sync/admin operations;
- contract generation is deterministic;
- changing the contract without regeneration fails CI.

#### 2.3 Worker API skeleton

Implement:

- `/healthz` liveness;
- `/readyz` dependency readiness;
- request ID/correlation middleware;
- structured `application/problem+json` errors;
- body-size and content-type validation;
- CORS allowlist by environment;
- route-level idempotency middleware interface;
- fake authentication principal for tests only.

#### 2.4 Local development

Add:

- Supabase CLI config;
- local database startup script;
- Worker local runner;
- fake R2/Qwen adapters;
- one command to run contract/unit/integration suites.

**Commit boundaries**

- `chore: scaffold server workspace`
- `feat: add generated API contract types`
- `feat: add worker health and problem middleware`

### Exit criteria

- `pnpm test`, lint and typecheck pass.
- Contract generation is deterministic.
- Health and readiness endpoints match OpenAPI.
- No production secret is present in repository history.
- Local test environment starts from a clean checkout with documented commands.

---

## Phase 3 — Authentication, sessions and devices

**Goal:** Support Google, Microsoft and email-code login through the product API and securely register/revoke devices.

**Lead subagents:** auth-backend, apple-auth-client, auth-abuse  
**Reviewer:** identity-security

### Tasks

#### 3.1 Supabase Auth configuration

- Configure Google and Azure/Microsoft providers for local/staging/prod callback URLs.
- Configure email OTP templates and custom SMTP adapter.
- Add environment-specific allowlists.
- Document domain verification and secret rotation.

#### 3.2 API auth routes

Implement the OpenAPI auth operations:

- auth configuration;
- email-code request and verification;
- OAuth authorization and code exchange;
- token refresh and logout;
- current session;
- device register/list/revoke.

The Worker validates Supabase JWT issuer, audience, expiry and subject. It maps the subject to a product profile.

**Failing tests**

- email request returns the same public response for existing/non-existing addresses;
- expired/wrong OTP is rejected;
- resend and brute-force limits;
- invalid issuer/audience/signature rejected;
- revoked device cannot refresh;
- one user cannot list/revoke another user's devices;
- explicit identity linking only.

#### 3.3 Native session client

- Add `AuthSessionStore` using Keychain.
- Use `ASWebAuthenticationSession` with PKCE.
- Add email-code screens.
- Add signed-out/local, signed-in/sync-off and signed-in/sync-on states.
- Add account and device management surface on macOS/iPadOS/iPhone layout.

**Native tests**

- callback state/PKCE mismatch rejected;
- refresh and logout behavior;
- signing out does not silently delete local books;
- revoked device returns to local mode with clear recovery;
- VoiceOver labels and Dynamic Type.

#### 3.4 Abuse controls

- IP/email-hash/device buckets;
- Turnstile challenge threshold for email OTP;
- security events without raw email in ordinary logs;
- admin visibility into blocked attempts.

**Commit boundaries**

- `feat: add product authentication API`
- `feat: add secure device registration`
- `feat: add native account session flow`
- `security: rate limit passwordless authentication`

### Exit criteria

- Google and Microsoft work in staging with PKCE.
- Email OTP works through custom SMTP and does not enumerate accounts.
- Sessions survive app restart and refresh securely.
- Device revocation is enforced by API and client.
- Normal users cannot access admin routes.
- Auth E2E suite passes on macOS and iOS Simulator; physical-device callback gap is documented if not exercised.

---

## Phase 4 — PostgreSQL schema, RLS and audit foundation

**Goal:** Create the multi-user relational system of record with defense-in-depth access control.

**Lead subagents:** postgres-schema, rls-policy, audit-ledger  
**Reviewer:** database-security

### Tasks

#### 4.1 Core migrations

Create versioned migrations for profiles, devices, settings, books, assets, chapters, progress, transcripts, vocabulary, known lemmas, reviews, assistant results/jobs/cache, usage, sync, flags, roles, audit and privacy requests.

Use foreign keys, check constraints, unique constraints and indexes defined from expected queries. Avoid storing arbitrary JSON when relational fields drive authorization or operations.

#### 4.2 Row Level Security

For each private table:

- enable RLS;
- add select/insert/update/delete policies scoped to `auth.uid()`;
- deny normal JWT access to global cache, model policy, admin roles and full audit tables;
- expose privileged behavior only through server role/RPC.

**Failing RLS tests**

- user A cannot select/update/delete user B rows for every table;
- guessed UUIDs do not change outcome;
- user cannot assign own admin role or quota;
- user cannot read cache entries directly;
- suspended user is blocked;
- service role only used server-side.

#### 4.3 Idempotency and cache claims

Add transaction functions for:

- record/replay idempotency response;
- append sync change and version;
- claim one assistant generation per cache key;
- attach another user result to an existing job;
- complete/fail a job atomically;
- append immutable audit event.

#### 4.4 Audit model

Audit event fields:

- actor/admin/user/system;
- action and resource type/ID;
- reason code and free-text reason where required;
- request ID and source IP hash;
- before/after metadata with sensitive fields removed;
- immutable timestamp.

**Commit boundaries**

- `feat: add multi-user postgres schema`
- `security: enforce row level isolation`
- `feat: add idempotency cache claims and audit events`

### Exit criteria

- Migrations apply from empty database and upgrade one prior test schema.
- Every private table has passing cross-user denial tests.
- Cache claim concurrency test proves one owner.
- No normal client can query global operational tables.
- Schema documentation and ER diagram are generated from migrations.

---

