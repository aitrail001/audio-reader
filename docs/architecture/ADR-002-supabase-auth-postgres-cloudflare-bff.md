# ADR-002: Supabase Auth/Postgres + Cloudflare BFF

- Status: Accepted
- Date: 2026-08-26

## Context

The product needs supported Google/Microsoft/email-OTP sign-in, relational
learning data, object storage for optional media, queued Qwen work, and a
stable API that native and admin clients can generate against.

Two alternatives were rejected:

- **Client-direct Supabase.** Fast to prototype, but couples every client to
  vendor schemas and SDKs, leaks sync/conflict policy into the apps, and makes
  service-role, cache, and Qwen coordination harder to keep server-side.
- **Cloudflare-only with D1.** One operational platform, but account identity
  becomes a separate project and D1 is a weaker fit for PostgreSQL-style RLS,
  transactional cache claims, and relational learning data.

## Decision

Use **Supabase Auth and PostgreSQL** as the system of record, and **Cloudflare
Workers** as the public OpenAPI BFF.

The Worker is the only public product boundary. It validates JWTs, enforces
authorization and quotas, signs R2 transfers, coordinates jobs, and is the only
component allowed to invoke Qwen. Native clients and the admin console talk to
the product contract, not to Supabase, R2, or Model Studio directly.

Supporting pieces: Cloudflare Queues for async jobs, R2 for private objects,
Pages for the admin app, Resend for email OTP.

## Consequences

- Provider secrets stay server-side.
- Clients can be regenerated from OpenAPI without inheriting vendor SDKs.
- Auth, Postgres, R2, or Qwen can be replaced later without changing the
  product API.
- Workers must stay thin: heavy Qwen work is queued, not done in the 10 ms
  CPU budget of a free-tier isolate.
