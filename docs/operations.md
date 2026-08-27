# AudioReader operations

This guide covers building and installing the native apps, deploying the remote
API, day-to-day operation, and running a local Docker copy of the remote server
so macOS and iPad can exercise the same account flow.

The native apps stay **local-first**. Signing in is optional. Books, transcripts,
and vocabulary stay on the device even when the account API is down. This
version registers devices and issues sessions; it does not yet upload books or
sync learning data to Postgres.

## What this stack implements today

| Surface | Status |
|---|---|
| macOS app | Full local reading, transcription, study, optional LLM providers |
| iPadOS app | Same product contract as macOS (ChatGPT-plan Codex login remains macOS-only) |
| Product API (Cloudflare Worker) | Health, CORS, problem+json, email OTP, Google/Microsoft PKCE (local completes via `GET /v1/auth/oauth/local-complete` 302 onto `audioreader://auth/callback`), JWT refresh/logout, bootstrap, `GET /v1/me`, device list/revoke |
| Postgres schema + RLS | Versioned migrations in `server/supabase/migrations/` |
| Local Docker API | Worker on `http://127.0.0.1:8787` with in-memory adapters + Postgres schema sandbox |
| Hosted Qwen, R2 media, sync push/pull, Resend email, admin console | Not wired yet. Staging/production health reports those dependencies `unavailable` until later PRs attach real clients |

Local and test Workers mint sessions in-process. Staging and production **never**
mint stub OTPs; they only validate JWTs when `SUPABASE_JWT_SECRET` and
`SUPABASE_URL` are both set.

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

The live account client talks to `http://localhost:8787` unless you override
`AUDIOREADER_API_BASE_URL`. Start the Docker API first if you want Settings →
Account to hit a server (section 5).

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
safe to re-run. Migrations also create `anon` / `authenticated` / `service_role`
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

```bash
cd server
cp .env.example .env          # names only; fill values locally, never commit
cd apps/api-worker

# Required in staging/production or the Worker fails closed (no JWT validation,
# no local issuance).
wrangler secret put SUPABASE_JWT_SECRET --env production
wrangler secret put SUPABASE_URL --env production

# Recommended before real passwordless issuance:
wrangler secret put TURNSTILE_SECRET_KEY --env production
wrangler secret put PASSWORDLESS_HMAC_SECRET --env production
```

Set non-secret vars in `apps/api-worker/wrangler.toml` under
`[env.production.vars]`:

- `ENVIRONMENT = "production"` (must not inherit `local`)
- `CORS_ALLOWED_ORIGINS` — comma-separated admin/web origins; empty for native-only
- `ADMIN_ORIGIN` when the admin app is hosted
- `APP_VERSION`
- `LOCAL_DEV_OTP = ""` — already set so production cannot mint the local code

Deploy **named environments only**:

```bash
cd server/apps/api-worker
pnpm exec wrangler deploy --env production
pnpm exec wrangler deploy --env staging   # optional
```

Do not `wrangler deploy` without `--env`. Top-level `[vars]` is for
`wrangler dev` (`ENVIRONMENT=local`, localhost CORS, `LOCAL_DEV_OTP=123456`).

The job worker is a stub (`apps/job-worker`). Deploy it the same way when you
attach a queue.

### 2.4 Smoke the hosted API

```bash
curl -i https://<worker-host>/healthz
curl -i https://<worker-host>/readyz
curl -i https://<worker-host>/v1/health
curl -s https://<worker-host>/v1/auth/config
```

Expect:

- `/healthz` → `200` even if adapters are down (liveness)
- `/readyz` → `503 application/problem+json` until real database/R2/Qwen probes
  are attached in staging/production
- `/v1/health` → `200` with `status: degraded` and `unavailable` dependencies
  in this phase
- `POST /v1/auth/email-otp/request` → `503` in production until a real issuer
  (Supabase Auth + Resend) is wired; that is intentional

Point native apps at the Worker with:

```bash
AUDIOREADER_API_BASE_URL=https://<worker-host>
```

---

## 3. How to operate

### 3.1 Local-first reading (no account)

This is the default. Import a book, transcribe, study, and use optional LLM
providers. Data lives in the platform application-support container (iPad
imports also in Documents). Signing out never deletes local books.

### 3.2 Optional product account

In **Settings → Account**:

1. **Sign in with Google / Microsoft** — production uses `ASWebAuthenticationSession`
   with callback `audioreader://auth/callback`. Local `ENVIRONMENT=local|test`
   authorizes against `GET /v1/auth/oauth/local-complete`; the app follows that
   302 in-process (no Safari sheet) onto `audioreader://auth/callback`. Hosted
   OAuth needs provider clients on Supabase Auth, not in the app.
2. **Email code** — request a 6-digit OTP, then verify. The API returns the
   same `202` whether or not the address already has an account.
3. After tokens arrive, the app **bootstraps** this device (`POST /v1/auth/bootstrap`
   with `X-Device-Id` and `Idempotency-Key`).
4. **Sync learning data across devices** is an opt-in flag only in this
   version. It does not upload books or vocabulary yet.
5. **Revoke** another device from the list. That device returns to local mode
   on next refresh; its on-disk library is not deleted.

Session tokens live in the Keychain-backed `AuthSessionStore`, not in settings
JSON. LLM API keys stay in the separate AES-GCM credential vault.

### 3.3 Health and incidents

| Path | Use |
|---|---|
| `GET /healthz` | Process up |
| `GET /readyz` | Gate traffic; `503` + `Problem` when a dependency is not `ok` |
| `GET /v1/health` | Product payload with `database`, `r2`, `qwen` |

Every response includes `X-Request-Id` (also `Problem.traceId`). Correlate
Worker logs with that header.

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
  `CFBundleVersion`. Shared native behavior bumps the patch once.
- Server packages stay `0.0.0` private workspace versions. Worker
  `APP_VERSION` is independent (`1.0.0-draft.1` until the public API ships).

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

| Service | Port on the host | Role |
|---|---|---|
| `api` | `8787` | Wrangler local Worker, `ENVIRONMENT=local` |
| `postgres` | `54329` | Postgres 18, trust auth, user `postgres` |
| `migrate` | — | One-shot SQL apply, then exits |

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
(`ProductAPI.defaultBaseURL`). Override only when the Worker is elsewhere.

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

| Symptom | Check |
|---|---|
| App account calls fail immediately | `curl http://127.0.0.1:8787/healthz`; start `pnpm dev:docker` |
| OTP `401` | Local code is `123456` only when `ENVIRONMENT=local` and `LOCAL_DEV_OTP` is set. Production never accepts it |
| OTP `429` | Isolate rate limits; wait or recreate the `api` container |
| Google/Microsoft sign-in hangs | The API must be local (`ENVIRONMENT=local`) so authorize returns `/v1/auth/oauth/local-complete`, not `auth.example.invalid`. Restart `pnpm dev:api` or `pnpm dev:docker`. Hosted OAuth needs real IdP clients. |
| iPad device cannot reach API | Not `localhost`; use Mac LAN IP; ATS allows local HTTP only |
| `docker info` fails | Start Docker Desktop; `pnpm dev:docker` prints a clear error |
| Postgres port busy | Host maps **54329**, not 5432, to avoid Homebrew Postgres |
| `readyz` is `503` in production | Expected until real database/R2/Qwen clients are attached |
| Wrangler deploy used local CORS | Always `wrangler deploy --env production` |
| Version mismatch after install | Repackage with `./scripts/package_app.sh` and `./scripts/package_ipad_simulator.sh`; `CFBundleShortVersionString` must match `MARKETING_VERSION` |

---

## 7. Related files

| Path | Role |
|---|---|
| `README.md` | Product usage for readers |
| `server/README.md` | Workspace commands and Worker behavior |
| `server/docker-compose.yml` | Local API + Postgres |
| `server/Dockerfile` | Wrangler local image |
| `contracts/openapi-v1.yaml` | Public product contract |
| `docs/architecture/ADR-002-*.md` | Why Workers + Supabase |
| `Sources/AudioReaderNetworking/AuthModels.swift` | `ProductAPI.defaultBaseURL` and `AUDIOREADER_API_BASE_URL` |
