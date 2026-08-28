# AudioReader server workspace

Pinned Node/pnpm workspace for the Cloudflare API worker, job worker, admin console, and shared TypeScript packages.

TypeScript types are generated from `contracts/openapi-v1.yaml` into `@audio-reader/contract`. The API worker implements health/readiness, request correlation, CORS, body validation, `application/problem+json` errors, the product authentication API (email OTP, Google/Microsoft OAuth PKCE, JWT sessions, refresh/logout, bootstrap, profile/settings, and devices), sync push/pull, library/progress/vocabulary/reviews/transcripts, GCS upload tickets, privacy export/deletion, admin users/jobs/policies/cache/runtime-config, and managed Qwen translations/summaries/chat with HMAC-SHA256 shared exact-content cache, single-flight generation, private chat messages, and daily quotas. Versioned Postgres migrations, row-level security, and transaction functions for idempotency, cache claims, sync versions, and immutable audit events live in `supabase/migrations/`. Staging/production persist identity, library, and the sync changelog through Supabase PostgREST when `SUPABASE_SERVICE_ROLE_KEY` is set. Managed Qwen uses server-held Model Studio credentials from Worker env or the admin runtime-config overlay.

## Requirements

- Node.js 22.18 or later (see `.nvmrc`)
- pnpm 11.22 or later via [Corepack](https://nodejs.org/api/corepack.html)

## Setup from a clean checkout

```bash
corepack enable
corepack prepare pnpm@11.22.0 --activate
cd server
pnpm install
cp .env.example .env
```

`.env.example` lists variable **names only**. Put real values in `.env` or Wrangler `.dev.vars` on your machine. Do not commit secrets, API keys, tokens, or passwords.

## Commands

Run from `server/`:

```bash
pnpm test
pnpm test:all
pnpm lint
pnpm typecheck
pnpm format:check
pnpm contract:generate
pnpm contract:check
pnpm dev:db
pnpm dev:api
```

`pnpm format` rewrites files with Prettier.

`pnpm contract:generate` writes TypeScript request/response types from the repo-root OpenAPI document into `packages/contract/src/generated/openapi.ts`. Commit that file. `pnpm contract:check` regenerates in memory and fails if the working copy differs.

`pnpm test:all` is the one command for contract, unit, and integration suites: Python OpenAPI contract tests, generated-type drift check, then Vitest (package unit tests plus API worker HTTP tests against fake adapters).

## Health and readiness

OpenAPI documents product health as `GET /v1/health` (`operationId: getHealth`) with the `Health` schema. Ops probes are aliases, not separate OpenAPI paths:

| Path             | Role                 | Response                                                                                                                                                                     |
| ---------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /v1/health` | Product health       | `200` `application/json` `Health`. `status` is `ok` or `degraded`; `dependencies` lists database, storage, and Qwen.                                                         |
| `GET /healthz`   | Process liveness     | `200` `Health` without dependency checks. Stays `ok` even if adapters are down.                                                                                              |
| `GET /readyz`    | Dependency readiness | `200` `Health` when database and Qwen are `ok`; optional object storage may be `unavailable` (ADR-003). `503` `application/problem+json` when a required dependency is down. |

Local and test environments use in-memory fake database, object store, and Qwen adapters so readiness succeeds without Docker. Staging/production attach Qwen from `QWEN_API_KEY` or the admin runtime-config overlay and Postgres from `SUPABASE_SERVICE_ROLE_KEY`. Storage is `ok` when GCS is configured in the admin portal or Worker env. Missing or unknown `ENVIRONMENT` values fail closed as `production` (unavailable probes, no localhost CORS). `wrangler.toml` sets `ENVIRONMENT = "local"` only in top-level `[vars]` for `wrangler dev`. Deploy with `wrangler deploy --env production` (or `--env staging`); those named environments override `ENVIRONMENT` and do not inherit the local CORS allowlist.

Error responses use RFC 7807 `application/problem+json` with the OpenAPI `Problem` schema (`type`, `title`, `status`, `code`, `traceId`, optional `detail` / `retryAfterSeconds` / `fieldErrors`). Shared OpenAPI error responses declare the same media type. Every response includes `X-Request-Id`, which is also `Problem.traceId`.

CORS origins come from `CORS_ALLOWED_ORIGINS` and `ADMIN_ORIGIN`. The `local` environment also allows localhost admin (`5173`) and worker (`8787`) origins. JSON writes require `Content-Type: application/json` and are capped at `MAX_BODY_BYTES` (default 1 MiB). Health paths accept `GET` and `HEAD`; other methods return `405` with `Allow: GET, HEAD` before body-content rules.

Route-level idempotency is an interface (`withIdempotency` + `IdempotencyStore`) used by `POST /v1/auth/bootstrap`. The Worker validates Supabase JWTs (issuer, audience, expiry, subject) and maps the subject to a product profile. With `SUPABASE_SERVICE_ROLE_KEY` (or the newer dashboard name `SUPABASE_SECRET_KEY`) that profile, its devices, and settings are stored in Postgres; otherwise they stay isolate-local. Hosted Workers need `wrangler secret put SUPABASE_SERVICE_ROLE_KEY --env staging|production`. Email OTP returns the same public `202` for existing and unknown addresses. Request and verify are rate limited per IP, HMAC email hash, and device using isolate-local in-memory buckets (Durable Objects, KV, or the Cloudflare Rate Limiting API should back this before production issuance). A 60s per-email-hash resend cooldown applies after each allowed request and is cleared on successful verify so a new login is not treated as a resend. Brute-force lockout returns `429`. After the challenge threshold, a Turnstile token is required when `TURNSTILE_SECRET_KEY` is set (`wrangler secret put TURNSTILE_SECRET_KEY`); staging/production without that secret stay lockout-only, and siteverify errors fail closed. Identifier hashes use `PASSWORDLESS_HMAC_SECRET` or `CACHE_HMAC_SECRET`. Security events and the in-memory admin blocked-attempt list store HMAC hashes, never raw email. Identities are not auto-merged by email; linking is explicit and cannot steal a provider subject already bound to another account. `createFakePrincipal` remains available for tests that do not exercise JWT validation. Staging and production require both `SUPABASE_JWT_SECRET` and `SUPABASE_URL` and never fall back to the local-dev issuer. Stub OTP/OAuth issuance is local/test only. Hosted issuance uses GoTrue when `SUPABASE_ANON_KEY` is also set (`createHostedAuthService`); production without that key validates JWTs but returns `503` for OTP/OAuth. `GET /v1/auth/oauth/local-complete` is local/test only.

## Local development

```bash
pnpm dev:db       # supabase --workdir server start (requires the Supabase CLI)
pnpm dev:api      # wrangler dev for @audio-reader/api-worker with fake adapters
pnpm dev:docker   # Postgres 18 + API worker in Docker, then HTTP e2e checks
pnpm test:e2e-local
```

`pnpm dev:docker` publishes the API at `http://127.0.0.1:8787` (local OTP `123456`)
and Postgres at `127.0.0.1:54329`. Native apps default to that API URL. Full
build, deploy, operate, and end-to-end steps: [../docs/operations.md](../docs/operations.md).

Production deploys must use `--env production` so they do not inherit local `ENVIRONMENT`, localhost CORS, or `LOCAL_DEV_OTP` from top-level `[vars]`. From `server/`: `pnpm preflight:deploy production` then `pnpm deploy:production` (or `pnpm deploy:staging`).

`supabase/config.toml` is CLI config only: ports, schemas, and local auth settings. No JWT secrets, service-role keys, or provider client secrets.

## Layout

```text
server/
  apps/
    api-worker/     Cloudflare Worker API/BFF
    job-worker/     Queue consumer + minute cron for queued jobs
    admin-web/      Operator console (hosted at https://audio-reader-admin.pages.dev)
  packages/
    contract/       Generated API types from OpenAPI v1
    domain/         Shared domain types and rules
    database/       Persistence adapters and schema contract constants
    auth/           JWT validation, in-memory OTP/OAuth, hosted GoTrue adapter, profile mapping
    qwen/           Managed Qwen client (fake ping for local/test)
    observability/  Logging and tracing
  scripts/          Local db, API worker runner, full test suites, named-env deploy
  supabase/         Supabase CLI config and versioned Postgres migrations
```
