# AudioReader server workspace

Pinned Node/pnpm workspace for the Cloudflare API worker, job worker, admin console, and shared TypeScript packages.

TypeScript types are generated from `contracts/openapi-v1.yaml` into `@audio-reader/contract`. The API worker implements health/readiness, request correlation, CORS, body validation, `application/problem+json` errors, and the product authentication API (email OTP, Google/Microsoft OAuth PKCE, JWT sessions, refresh/logout, bootstrap, and `GET /v1/me`). Qwen inference and Postgres schema are out of scope here.

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

| Path             | Role                 | Response                                                                                                        |
| ---------------- | -------------------- | --------------------------------------------------------------------------------------------------------------- |
| `GET /v1/health` | Product health       | `200` `application/json` `Health`. `status` is `ok` or `degraded`; `dependencies` lists database, R2, and Qwen. |
| `GET /healthz`   | Process liveness     | `200` `Health` without dependency checks. Stays `ok` even if adapters are down.                                 |
| `GET /readyz`    | Dependency readiness | `200` `Health` when every dependency is `ok`; `503` `application/problem+json` otherwise.                       |

Local and test environments use in-memory fake database, R2, and Qwen adapters so readiness succeeds without Docker. Staging/production wiring reports those dependencies as `unavailable` until later PRs attach real clients. Missing or unknown `ENVIRONMENT` values fail closed as `production` (unavailable probes, no localhost CORS). `wrangler.toml` sets `ENVIRONMENT = "local"` only in top-level `[vars]` for `wrangler dev`. Deploy with `wrangler deploy --env production` (or `--env staging`); those named environments override `ENVIRONMENT` and do not inherit the local CORS allowlist.

Error responses use RFC 7807 `application/problem+json` with the OpenAPI `Problem` schema (`type`, `title`, `status`, `code`, `traceId`, optional `detail` / `retryAfterSeconds` / `fieldErrors`). Shared OpenAPI error responses declare the same media type. Every response includes `X-Request-Id`, which is also `Problem.traceId`.

CORS origins come from `CORS_ALLOWED_ORIGINS` and `ADMIN_ORIGIN`. The `local` environment also allows localhost admin (`5173`) and worker (`8787`) origins. JSON writes require `Content-Type: application/json` and are capped at `MAX_BODY_BYTES` (default 1 MiB). Health paths accept `GET` and `HEAD`; other methods return `405` with `Allow: GET, HEAD` before body-content rules.

Route-level idempotency is an interface (`withIdempotency` + `IdempotencyStore`) used by `POST /v1/auth/bootstrap`. The Worker validates Supabase JWTs (issuer, audience, expiry, subject) and maps the subject to an in-memory product profile. Email OTP returns the same public `202` for existing and unknown addresses. Identities are not auto-merged by email; linking is explicit. `createFakePrincipal` remains available for tests that do not exercise JWT validation. Production without `SUPABASE_JWT_SECRET` fails closed (unauthenticated). Local and test environments use a non-production HS256 config so OTP/OAuth can issue verifiable tokens.

## Local development

```bash
pnpm dev:db    # supabase --workdir server start (requires the Supabase CLI)
pnpm dev:api   # wrangler dev for @audio-reader/api-worker with fake adapters
```

Production deploys must use `--env production` so they do not inherit local `ENVIRONMENT` or localhost CORS from top-level `[vars]`.

`supabase/config.toml` is CLI config only: ports, schemas, and local auth settings. No JWT secrets, service-role keys, or provider client secrets.

## Layout

```text
server/
  apps/
    api-worker/     Cloudflare Worker API/BFF
    job-worker/     Cloudflare Worker queue consumer stub
    admin-web/      React + TypeScript + Vite stub
  packages/
    contract/       Generated API types from OpenAPI v1
    domain/         Shared domain types and rules
    database/       Persistence adapters (fake ping for local/test)
    auth/           JWT validation, email OTP, OAuth PKCE, profile mapping
    qwen/           Managed Qwen client (fake ping for local/test)
    observability/  Logging and tracing
  scripts/          Local db, API worker runner, full test suites
  supabase/         Supabase CLI config
```
