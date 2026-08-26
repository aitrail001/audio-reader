# AudioReader server workspace

Pinned Node/pnpm workspace for the Cloudflare API worker, job worker, admin console, and shared TypeScript packages.

This tree is a compile-and-test scaffold. Health routes, OpenAPI codegen, Qwen calls, and auth logic are out of scope here.

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
```

`pnpm format` rewrites files with Prettier.

## Layout

```text
server/
  apps/
    api-worker/     Cloudflare Worker API/BFF stub
    job-worker/     Cloudflare Worker queue consumer stub
    admin-web/      React + TypeScript + Vite stub
  packages/
    contract/       Generated API types (later)
    domain/         Shared domain types and rules
    database/       Persistence adapters
    auth/           Session/JWT validation
    qwen/           Managed Qwen client
    observability/  Logging and tracing
```
