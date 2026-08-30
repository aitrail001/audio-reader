# AudioReader operations

This guide covers building and installing the native apps, deploying the remote
API, day-to-day operation, and running a local Docker copy of the remote server
so macOS and iPad can exercise the same account flow.

The native apps stay **local-first**. Signing in is optional. Books, transcripts,
and vocabulary stay on the device even when the account API is down. Signed-in
devices can sync learning data and select **Managed Qwen (account)** so
translation, summary, and chat go through the product API.

## What this stack implements today

| Surface                         | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS app                       | Full local reading, transcription, study, optional LLM providers including Managed Qwen                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| iPadOS app                      | Same product contract as macOS (ChatGPT-plan Codex login remains macOS-only; Managed Qwen is on both)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Product API (Cloudflare Worker) | Health, CORS, problem+json, email OTP, Google/Microsoft PKCE, JWT refresh/logout, bootstrap, `GET`/`PATCH /v1/me`, `GET`/`PUT /v1/me/settings`, device list/revoke, `POST /v1/sync/push`, `GET /v1/sync/pull`, library/progress/vocab/reviews/transcripts, R2 upload tickets, privacy export/deletion and analytics preferences, scoped/audited admin user-progress summaries, admin users/jobs/policies/cache, managed Qwen `POST /v1/ai/{translations,translation-batches,chapter-summaries,chat,heard-quizzes}` plus `GET` chat messages, HMAC shared cache, lookup-only cache reads, single-flight generation, and daily quotas. Local completes OAuth via `GET /v1/auth/oauth/local-complete` 302 onto `audioreader://auth/callback`. Staging/production return a Supabase Auth (GoTrue) authorize URL and never expose local-complete.      |
| Postgres schema + RLS           | Versioned migrations in `server/supabase/migrations/`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Local Docker API                | Worker on `http://127.0.0.1:8787` with in-memory adapters + Postgres schema sandbox                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Hosted Qwen                     | Worker uses the QwenCloud Singapore token-plan endpoint (`token-plan.ap-southeast-1.maas.aliyuncs.com`) with `QWEN_API_KEY` (from repo-root `.env.local` `qwen-key`). Native **Managed Qwen (account)** in Settings sends product tasks to `/v1/ai/*`. Sentence/word translations, chapter-aligned sentence batches, and chapter summaries use HMAC-SHA256 shared cache keys (`CACHE_HMAC_SECRET`). Cache is checked before Qwen; `lookupOnly` never generates; a batch stores each sentence under its own key (neighbors are prompt context only). `refresh` / `refreshIds` skip cache for a generate. Native apps auto-load sentence and summary hits; word lookups stay on-demand. Single-flight generation and `user_assistant_results` wrappers apply. Daily quota counts a real Qwen call, not a cache hit. Chat is private and not cached. |
| Sync / profile persistence      | With `SUPABASE_SERVICE_ROLE_KEY`, the Worker persists profiles, devices, settings, library, and the sync changelog through PostgREST. Native 1.0.69 drains settings, books, transcripts, vocabulary, reviews, progress, and known lemmas when Settings → Account sync is on.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Object storage                  | Upload tickets PUT to `/v1/uploads/{id}/body`. Local/test uses an in-Worker memory store. Staging/production use Google Cloud Storage when a bucket and service-account JSON are set in the admin portal (`/v1/admin/runtime-config`) or Worker env (`GCS_BUCKET`, `GCS_SERVICE_ACCOUNT_JSON`). Health reports `storage`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Admin console                   | Hosted at `https://audio-reader-admin.pages.dev`. Sign in with product email OTP (or paste an admin JWT). Desk, Trace, Audit, Metrics, Flags, Quotas, Policies, users, jobs, cache, and privacy are all operator-facing. Desk shows live health and diagnostics. Policies validates editable prompt layers, renders the enforced task contract and final messages for all six subtasks, shows the output schema and cache impact, and can run a correlated Qwen probe. User detail shows consented aggregate progress only; every read is role-scoped and audited. Trace lists Managed Qwen events by request id. Audit stores mutations and probes without prompt or reading text. CORS allowlists that origin.                                                                                                                                  |

Local and test Workers mint sessions in-process (`LOCAL_DEV_OTP=123456`). Staging
and production **never** mint stub OTPs. With `SUPABASE_URL`,
`SUPABASE_JWT_SECRET`, and `SUPABASE_ANON_KEY` they issue real email OTP and
OAuth sessions through hosted GoTrue. JWT validation works with URL+secret even
before the anon key is set (login then returns `503`). With
`SUPABASE_SERVICE_ROLE_KEY` the Worker upserts `profiles`, `devices`, and
`user_settings` and records sync mutations in `sync_changes`. Without that
secret, profile/device rows stay isolate-local in the Worker.

---

## 1. Build and install the apps

### Requirements

- macOS 26 or later (to build either app)
- Xcode 26 with the macOS and iOS 26 SDKs
- For iPad device install: an Apple Developer team (the Xcode iOS target uses team `9XV58LJ624`)
- Optional SpeechAnalyzer language assets; the app requests them on first transcription

Work from the repository root.

### 1.1 macOS — Xcode

1. Open `AudioReader.xcodeproj`.
2. Select the **AudioReader-macOS** scheme and **My Mac**.
3. Run (⌘R).

Packaged apps use the production Worker in `ProductAPIBaseURL`
(`https://audio-reader-api-worker-production.audio-reader-service.workers.dev`).
`AUDIOREADER_API_BASE_URL` (process environment) still wins when set, so local
Docker remains `http://localhost:8787` or `http://127.0.0.1:8787`. Empty or
non-http plist values fall back to localhost. Start the Docker API first if you
want Settings → Account to hit a local server (section 5).

### 1.2 macOS — packaged app from Terminal

```bash
./scripts/package_app.sh
open AudioReader.app
```

The script builds the Swift package release binary, copies `Info.plist` and
icons into `AudioReader.app`, and ad-hoc signs it. `AudioReader.app` is
gitignored; rebuild it after every native change.

To point a packaged app at a non-default API (macOS 13+ `open --env`):

```bash
open --env AUDIOREADER_API_BASE_URL=http://127.0.0.1:8787 AudioReader.app
```

Or launch the binary so the environment is inherited:

```bash
AUDIOREADER_API_BASE_URL=http://127.0.0.1:8787 \
  ./AudioReader.app/Contents/MacOS/AudioReader
```

### 1.3 iPad Simulator — Xcode

1. Open `AudioReader.xcodeproj`.
2. Select **AudioReader-iOS**, destination **iPad Simulator**.
3. Run (⌘R).

The Simulator shares the Mac network namespace, so `http://localhost:8787` is
the Docker API on the Mac.

### 1.4 iPad Simulator — Terminal

```bash
./scripts/package_ipad_simulator.sh
xcrun simctl boot "iPad Pro 13-inch (M4)"   # or any booted iPad
xcrun simctl install booted AudioReader-iPad.app
xcrun simctl launch booted com.johnsonzhang.AudioReader
```

`AudioReader-iPad.app` is a tracked Simulator artifact. After native changes,
repackage it with `./scripts/package_ipad_simulator.sh` and confirm
`Info.plist` still shows the current marketing version.

To pass an API URL into a Simulator launch:

```bash
xcrun simctl spawn booted launchctl setenv AUDIOREADER_API_BASE_URL http://127.0.0.1:8787
xcrun simctl launch booted com.johnsonzhang.AudioReader
```

### 1.5 Physical iPad

1. Connect the iPad with a developer-trusted cable (or network debug).
2. In Xcode: **AudioReader-iOS → Signing & Capabilities**, select your team.
3. Choose the device as the run destination and Run.

A physical iPad cannot use `localhost` for the API on your Mac. Use the Mac’s
LAN address and bind the Worker to all interfaces (the Docker stack already
does):

```text
http://192.168.x.x:8787
```

Set `AUDIOREADER_API_BASE_URL` in the Xcode scheme’s environment variables, or
rebuild after exporting that variable in the scheme. Both apps allow **local
network HTTP** (`NSAllowsLocalNetworking`) so cleartext to the Docker host
works. They still require HTTPS for public internet hosts.

Apple Books discovery on iPad uses the device media library. The Simulator has
no real Apple Books catalog; validate that path on hardware.

---

## 2. Deploy the remote server

For the gated staging-first Operator/API promotion, request-ID trace, Arc
profiles, and evidence tuple, follow
[Operator deployment and end-to-end runbook](operator-deployment-e2e.md).

Production topology (ADR-002): **Supabase Auth + Postgres** as the system of
record, **Cloudflare Workers** as the only public OpenAPI boundary. Native apps
never talk to Supabase, R2, or Qwen directly.

### 2.1 One-time accounts

1. Cloudflare account with Workers (and later R2, Queues, Pages).
2. Supabase project (Auth + Postgres).
3. Optional later: Resend domain for real email OTP, Turnstile site key,
   Alibaba Cloud Model Studio for Qwen, R2 bucket.

Free-tier notes live in the design doc section 18. Reconfirm quotas before
launch.

### 2.2 Apply Postgres migrations

From a machine that can reach the project database:

```bash
cd server
pnpm install
# DATABASE_URL is the Supabase URI. Never commit it.
export DATABASE_URL='postgres://postgres.<project>:<password>@aws-0-....pooler.supabase.com:6543/postgres'
PGHOST=... PGPORT=5432 PGUSER=postgres PGDATABASE=postgres PGPASSWORD=... \
  ./scripts/apply-migrations.sh
```

`apply-migrations.sh` records filenames in `public.schema_migrations` and is
safe to re-run. Apply `20260828130000_quota_limits.sql` so hosted Workers persist
starter feature flags (`managed_qwen`, `account_sync`, `cloud_media`,
`maintenance_mode`) and plan 18.2 quota limits instead of isolate-local seeds. Migrations also create `anon` / `authenticated` / `service_role`
and `auth.uid()` when those Supabase objects are missing, so the same SQL works
on vanilla Postgres 18 (local Docker) and hosted Supabase.

Alternatively use the Supabase CLI against a linked project:

```bash
cd server
supabase db push
```

`server/supabase/config.toml` is CLI config only. It must not contain JWT
secrets, service-role keys, or OAuth client secrets.

### 2.3 Configure Worker secrets and vars

One-time Wrangler login on this machine:

```bash
cd server/apps/api-worker
pnpm exec wrangler login
```

```bash
cd server
cp .env.example .env          # names only; fill values locally, never commit
cd apps/api-worker

# Required for JWT validation:
wrangler secret put SUPABASE_JWT_SECRET --env production
wrangler secret put SUPABASE_URL --env production

# Required for hosted email OTP and Google/Microsoft OAuth (GoTrue):
wrangler secret put SUPABASE_ANON_KEY --env production

# Recommended before public passwordless:
wrangler secret put TURNSTILE_SECRET_KEY --env production
wrangler secret put PASSWORDLESS_HMAC_SECRET --env production
```

Repeat with `--env staging` for the staging Worker. The anon key is the
Supabase project **anon/public** key, not the service role. Do not put the
service-role key on the Worker.

In the Supabase Auth dashboard:

1. Enable **Email OTP** (six-digit codes). Built-in SMTP is enough for a first
   deploy; switch to Resend later if you want custom From addresses.
2. Enable **Google** and **Azure** (Microsoft) providers with their client IDs
   and secrets. Google/Azure redirect URIs stay on Supabase
   (`https://<project>.supabase.co/auth/v1/callback`), not in the app.
3. Add `audioreader://auth/callback` and `audioreader://**` to **Redirect URLs**.
   Set **Site URL** to `audioreader://auth/callback` (not `http://localhost:3000`).
   Do not put query parameters on the allow-listed callback; GoTrue treats
   `?state=` as a different URL and falls back to Site URL.
4. Confirm the JWT secret in Auth settings matches `SUPABASE_JWT_SECRET`.

Set non-secret vars in `apps/api-worker/wrangler.toml` under
`[env.production.vars]`:

- `ENVIRONMENT = "production"` (must not inherit `local`)
- `CORS_ALLOWED_ORIGINS` — comma-separated admin/web origins; empty for native-only
- `ADMIN_ORIGIN` when the admin app is hosted
- `APP_VERSION`
- `LOCAL_DEV_OTP = ""` — already set so production cannot mint the local code

### 2.4 Deploy named environments only

From `server/`:

```bash
pnpm preflight:deploy production   # checks wrangler.toml + wrangler login
pnpm deploy:production
pnpm deploy:staging                # optional
```

The scripts refuse anything except `staging` or `production` and always pass
`--env`. Do not `wrangler deploy` without `--env`. Top-level `[vars]` is for
`wrangler dev` (`ENVIRONMENT=local`, localhost CORS, `LOCAL_DEV_OTP=123456`).

The job worker (`apps/job-worker`) consumes `audio-reader-jobs` (production) and
`audio-reader-jobs-staging` (staging) and runs a one-minute cron to drain
queued assistant/privacy jobs. Deploy with `wrangler deploy --env staging|production`
from `server/apps/job-worker` after `wrangler secret put` for `SUPABASE_URL`,
`SUPABASE_SERVICE_ROLE_KEY`, and `QWEN_API_KEY`.

### 2.5 Smoke the hosted API

```bash
curl -i https://<worker-host>/healthz
curl -i https://<worker-host>/readyz
curl -i https://<worker-host>/v1/health
curl -s https://<worker-host>/v1/auth/config
```

Expect:

- `/healthz` → `200` even if adapters are down (liveness)
- `/readyz` → `200` when database and Qwen are attached; optional storage may still
  be `unavailable` until GCS is configured in the admin portal.
  `503` only when a required dependency (database or Qwen) is down
- `/v1/health` → `200` with `status: degraded` and `unavailable` dependencies
  in this phase
- `POST /v1/auth/email-otp/request` → `202` when GoTrue is configured
  (`SUPABASE_ANON_KEY` plus URL and JWT secret); `503` if the anon key is
  missing
- `POST /v1/auth/oauth/authorize` → `{ authorizationUrl, state }` pointing at
  `https://<project>.supabase.co/auth/v1/authorize` (Google or Azure). The
  `local-complete` path is `404` in staging/production.

Point native apps at the Worker with:

```bash
AUDIOREADER_API_BASE_URL=https://<worker-host>
```

Or set `ProductAPIBaseURL` in `Info.plist` and `Info-iPad.plist` (and the
Xcode Info plists) to that `https://` URL and rebuild both apps. Empty
`ProductAPIBaseURL` keeps `http://localhost:8787`.

---

## 3. How to operate

### 3.1 Local-first reading (no account)

This is the default. Import a book, transcribe, study, and use optional LLM
providers. Data lives in the platform application-support container (iPad
imports also in Documents). Signing out never deletes local books.

### 3.2 Optional product account

In **Settings → Account**:

1. **Sign in with Google / Microsoft** — hosted uses `ASWebAuthenticationSession`
   with callback `audioreader://auth/callback` against the GoTrue authorize URL.
   Local `ENVIRONMENT=local|test` authorizes against
   `GET /v1/auth/oauth/local-complete`; the app follows that 302 in-process (no
   Safari sheet) onto `audioreader://auth/callback`. Google and Azure client
   IDs live in the Supabase Auth dashboard, not in the app.
2. **Email code** — request a 6-digit OTP, then verify. The API returns the
   same `202` whether or not the address already has an account. Local code is
   `123456`. Hosted codes come from Supabase email.
3. After tokens arrive, the app **bootstraps** this device (`POST /v1/auth/bootstrap`
   with `X-Device-Id` and `Idempotency-Key`).
4. **Sync learning data across devices** is opt-in. It synchronizes small
   catalog, exact progress, vocabulary schedules and review history, transcript, and transcript-overlay
   records through the account API. Audiobook, EPUB, cover, credential, and
   Anki clip files stay local. Use **Sync now** and verify phase/entity/batch/item,
   pending/current/error/conflict presentation before treating the device as converged.
5. Concurrent progress and transcript-overlay revisions require an explicit
   resolution; do not assume a later timestamp silently wins.
6. **Revoke** another device from the list. That device returns to local mode
   on next refresh; its on-disk library is not deleted.

Session tokens live in the AES-GCM encrypted file session store, not in settings
JSON or Apple Keychain. LLM API keys stay in the separate AES-GCM credential vault.

### 3.3 Health and incidents

| Path             | Use                                                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------------------------------------- |
| `GET /healthz`   | Process up                                                                                                          |
| `GET /readyz`    | Gate traffic; `503` + `Problem` when database or Qwen is not `ok`. Optional object storage does not fail readiness. |
| `GET /v1/health` | Product payload with `database`, `storage`, `qwen`                                                                  |

Every response includes `X-Request-Id` (also `Problem.traceId`). Correlate
Worker logs with that header.

Sync push logs record only request ID, mutation count, content length, and cursor.
Sync pull logs record only request ID, cursor, page size, and `hasMore`; transcript
payloads and reading text are never logged. Push envelopes are limited to 3 MiB,
and database-side pull pages are limited to one MiB of encoded payload.

Per-user Operator progress is served by `GET /v1/admin/users/{userId}/progress`. It requires an
active `support_readonly`, `operator`, `privacy_officer`, or `superadmin` grant and appends an
`admin_user_progress_read` audit event. Sync health is always support-visible; reading, review,
learning, and AI-use counts remain hidden until the user enables them through
the shared macOS/iPadOS Settings → Account control, backed by the device-bound
`PUT /v1/me/analytics-preferences`. The database RPC returns only counts, coarse percentages,
timestamps, and device attribution—never sync payloads, titles, transcripts, context, definitions,
translations, or notes. Without consent the RPC computes sync health only and does not persist a
detailed snapshot. Learner behavior events are rejected unless that preference is active, and
opt-out atomically deletes both prior learning events and a prior snapshot. Required operational and
security events use a distinct purpose and never contribute to learning dashboards. The Job Worker's
scheduled path purges snapshots and product events after 90 days independently of Operator reads,
and account deletion completes only after
`delete_account_data` cascades private rows and retains an anonymous deleted tombstone that prevents
a still-valid identity token from recreating the account. `request_account_deletion` atomically writes
the temporary privacy request, durable deletion job, minimized audit event, and `deletion_pending`
status. A database trigger serializes every account-owned service-role insert/update with profile
deletion and rejects writes after the account becomes deletion-pending or deleted.

Hosted jobs are stored and atomically leased in Postgres so API and Job Worker isolates cannot claim
the same job. Upload and export writes first create a server-only `object_write_leases` row; account
deletion defers without spending its retry budget until live leases finish, and expired lease keys
join the deletion sweep. Before deleting metadata, the Job Worker enumerates database object keys plus the
account storage prefix, deletes and verifies audio, EPUB, cover, transcript, and export bodies through
the configured GCS/Supabase Storage/R2 provider, then executes the database cascade. Partial storage
failure leaves metadata and the job intact for retry. The Job Worker performs live database and
storage probes for health and fails scheduled/queue execution closed when either dependency is
unavailable. An unavailable or malformed hosted Operator-settings read is an unavailable storage
configuration, never permission to fall through to another provider. Supabase Storage is selected
only when both Workers have the same explicit `SUPABASE_STORAGE_BUCKET`. User-entered deletion
reasons live only in the cascading privacy request and are not
copied into durable jobs or immutable audit events. Transient failures return the leased job to queued
and dead-letter only at the configured attempt limit.

Passwordless rate limits in this phase are **isolate-local in-memory buckets**.
Do not treat them as production-grade abuse control; replace with Durable
Objects, KV, or the Cloudflare Rate Limiting API before public issuance.

### 3.4 Secrets rotation

- Rotate `SUPABASE_JWT_SECRET` together with Supabase JWT settings; existing
  access tokens fail until refresh.
- Rotate `PASSWORDLESS_HMAC_SECRET` to invalidate stored identifier hashes
  (rate-limit and admin blocked-attempt lists).
- Never put provider keys, JWT secrets, or OTP codes in app plists, settings
  JSON, or git.

### 3.5 Native vs server versioning

- Apple apps use `x.y.z` (`CFBundleShortVersionString`) plus integer
  `CFBundleVersion`. This release is `1.4.0 (88)` for both macOS and iPadOS.
- Server packages stay `0.0.0` private workspace versions. Worker
  `APP_VERSION` is independent. The API Worker is `1.5.0`. This release
  introduces the Job Worker's first tracked runtime version at `1.0.0`. The
  Operator console is `0.8.0`.
- Production OTP From is `AudioReader <audio.reader.service@gmail.com>`. Verify
  that address in Resend; `onboarding@resend.dev` only delivers to the Resend account.

---

## 4. Local server without Docker

Use this when you already have Node and (optionally) the Supabase CLI.

```bash
corepack enable
corepack prepare pnpm@11.22.0 --activate
cd server
pnpm install
pnpm dev:api    # wrangler dev, fake adapters, http://127.0.0.1:8787
# optional schema/auth stack:
pnpm dev:db     # supabase start (CLI required); API 54321, DB 54322
```

`wrangler.toml` top-level vars set `ENVIRONMENT=local` and
`LOCAL_DEV_OTP=123456`. Request an email code from the app and enter **123456**.
No mail is sent.

Checks:

```bash
cd server
pnpm test
pnpm typecheck
pnpm contract:check
curl -s http://127.0.0.1:8787/v1/health
```

---

## 5. Local remote server in Docker (end-to-end)

This is the supported way to stand up the **same process the apps call** plus a
Postgres 18 database with the multi-user migrations applied.

### 5.1 Start

Requires Docker Desktop or Engine.

```bash
cd server
pnpm dev:docker
```

That script:

1. `docker compose up --build -d --wait`
2. Applies `server/supabase/migrations/*.sql` into Postgres (idempotent)
3. Serves the API Worker at `http://127.0.0.1:8787`
4. Runs `pnpm test:e2e-local` (health, auth config, OTP, bootstrap, `/v1/me`,
   devices)

Compose services:

| Service    | Port on the host | Role                                       |
| ---------- | ---------------- | ------------------------------------------ |
| `api`      | `8787`           | Wrangler local Worker, `ENVIRONMENT=local` |
| `postgres` | `54329`          | Postgres 18, trust auth, user `postgres`   |
| `migrate`  | —                | One-shot SQL apply, then exits             |

Stop:

```bash
cd server
pnpm dev:docker:down
```

Reset the database volume:

```bash
cd server
docker compose down -v
pnpm dev:docker
```

### 5.2 What the Docker API can do

Because `ENVIRONMENT=local`, the Worker uses **in-memory** auth, database, R2,
and Qwen adapters (same as `pnpm dev:api`). That is enough for native
sign-in, bootstrap, device list/revoke, and health.

Postgres in Compose is the **schema sandbox**: inspect tables, run RLS checks,
and keep migrations honest. Profiles created through the local API are **not**
written to Postgres until a later PR attaches a real database client.

```bash
psql "postgres://postgres@127.0.0.1:54329/postgres" \
  -c '\dt public.*' \
  -c 'select filename from public.schema_migrations order by 1'
```

### 5.3 HTTP smoke (already run by `pnpm dev:docker`)

This command is an HTTP client only. Start `pnpm dev:api` or `pnpm dev:docker`
first and leave it running while the probe executes.

```bash
cd server
AUDIOREADER_API_BASE_URL=http://127.0.0.1:8787 pnpm test:e2e-local
```

The local OTP is `123456` (`LOCAL_DEV_OTP`). Staging/production ignore that
variable.

### 5.4 End-to-end with the macOS app

1. Leave Docker running (`http://127.0.0.1:8787/healthz` returns 200).
2. Launch AudioReader (Xcode **AudioReader-macOS**, or `./scripts/package_app.sh`
   then `open AudioReader.app`).
3. Open **Settings → Account**.
4. Enter any email (for example `you@example.com`) → **Send email sign-in code**.
5. Enter `123456` → verify.
6. Confirm the account caption becomes **Signed in — sync off** and this Mac
   appears under devices.
7. Toggle sync (flag only), then **Sign out**. Local books must still be there.

Default API base URL is `http://localhost:8787`
(`ProductAPI.defaultBaseURL`). Override with `AUDIOREADER_API_BASE_URL` or
`ProductAPIBaseURL` when the Worker is elsewhere.

### 5.5 End-to-end with iPad Simulator

1. Docker API up on the Mac.
2. Install/launch as in §1.4.
3. Same Settings → Account flow, code `123456`.

### 5.6 End-to-end with a physical iPad

1. Docker API up; confirm `curl http://<mac-lan-ip>:8787/healthz`.
2. Allow incoming TCP 8787 on the Mac firewall if needed.
3. Run **AudioReader-iOS** on the device with
   `AUDIOREADER_API_BASE_URL=http://<mac-lan-ip>:8787`.
4. Sign in with email + `123456`.

### 5.7 Direct compose (without pnpm)

```bash
cd server
docker compose up --build -d --wait
./scripts/e2e-local-api.sh
docker compose logs -f api
```

Rebuild the Worker image after TypeScript changes:

```bash
cd server
docker compose up --build -d api
```

---

## 6. Troubleshooting

| Symptom                                                 | Check                                                                                                                                                                                                                                                    |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App account calls fail immediately                      | `curl http://127.0.0.1:8787/healthz`; start `pnpm dev:docker`                                                                                                                                                                                            |
| OTP `401`                                               | Local code is `123456` only when `ENVIRONMENT=local` and `LOCAL_DEV_OTP` is set. Production never accepts it                                                                                                                                             |
| OTP `429`                                               | Isolate rate limits; wait or recreate the `api` container                                                                                                                                                                                                |
| Google/Microsoft sign-in hangs locally                  | The API must be local (`ENVIRONMENT=local`) so authorize returns `/v1/auth/oauth/local-complete`. Restart `pnpm dev:api` or `pnpm dev:docker`.                                                                                                           |
| Hosted Google/Microsoft opens Safari then fails         | Add `audioreader://auth/callback` and `audioreader://**` to Supabase redirect URLs and change Site URL off `http://localhost:3000`. Enable the provider; Worker must be `--env staging\|production` with `SUPABASE_ANON_KEY`.                            |
| Hosted OTP is `503`                                     | Set `SUPABASE_URL`, `SUPABASE_JWT_SECRET`, and `SUPABASE_ANON_KEY` as Wrangler secrets for that `--env`.                                                                                                                                                 |
| Admin console email is a magic link, not a 6-digit code | Production/staging Workers send a six-digit code with Resend (`RESEND_API_KEY`) after GoTrue `generate_link`. Without that secret they fall back to GoTrue `/otp`, which emails a magic link. Site URL should be `https://audio-reader-admin.pages.dev`. |
| Wrangler deploy used local CORS                         | Always `pnpm deploy:production` or `wrangler deploy --env production`                                                                                                                                                                                    |
| iPad device cannot reach API                            | Not `localhost`; use Mac LAN IP; ATS allows local HTTP only                                                                                                                                                                                              |
| `docker info` fails                                     | Start Docker Desktop; `pnpm dev:docker` prints a clear error                                                                                                                                                                                             |
| Postgres port busy                                      | Host maps **54329**, not 5432, to avoid Homebrew Postgres                                                                                                                                                                                                |
| `readyz` is `503` in production                         | Database or Qwen probe failed. Optional `storage` `unavailable` is expected until GCS is configured in the admin portal.                                                                                                                                 |
| Version mismatch after install                          | Repackage with `./scripts/package_app.sh` and `./scripts/package_ipad_simulator.sh`; `CFBundleShortVersionString` must match `MARKETING_VERSION`                                                                                                         |

---

## 7. Related files

| Path                                             | Role                                                                                                  |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `README.md`                                      | Product usage for readers                                                                             |
| `server/README.md`                               | Workspace commands and Worker behavior                                                                |
| `server/docker-compose.yml`                      | Local API + Postgres                                                                                  |
| `server/Dockerfile`                              | Wrangler local image                                                                                  |
| `contracts/openapi-v1.yaml`                      | Public product contract                                                                               |
| `docs/architecture/ADR-002-*.md`                 | Why Workers + Supabase                                                                                |
| `Sources/AudioReaderNetworking/AuthModels.swift` | `ProductAPI` base URL: env `AUDIOREADER_API_BASE_URL`, then plist `ProductAPIBaseURL`, then localhost |
| `server/scripts/preflight-deploy.sh`             | Named-env checks + Wrangler login                                                                     |
| `server/scripts/deploy-worker.sh`                | `wrangler deploy --env staging\|production`                                                           |
