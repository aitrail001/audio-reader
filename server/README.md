# AudioReader server workspace

Pinned Node/pnpm workspace for the Cloudflare API worker, job worker, admin console, and shared TypeScript packages.

This tree is a compile-and-test scaffold. Health routes, Qwen calls, and auth logic are out of scope here. TypeScript types are generated from `contracts/openapi-v1.yaml` into `@audio-reader/contract`.

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
pnpm lint
pnpm typecheck
pnpm format:check
pnpm contract:generate
pnpm contract:check
```

`pnpm format` rewrites files with Prettier.

`pnpm contract:generate` writes TypeScript request/response types from the repo-root OpenAPI document into `packages/contract/src/generated/openapi.ts`. Commit that file. `pnpm contract:check` regenerates in memory and fails if the working copy differs.

## Layout

```text
server/
  apps/
    api-worker/     Cloudflare Worker API/BFF stub
    job-worker/     Cloudflare Worker queue consumer stub
    admin-web/      React + TypeScript + Vite stub
  packages/
    contract/       Generated API types from OpenAPI v1
    domain/         Shared domain types and rules
    database/       Persistence adapters
    auth/           Session/JWT validation
    qwen/           Managed Qwen client
    observability/  Logging and tracing
```
