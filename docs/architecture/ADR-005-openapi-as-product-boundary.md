# ADR-005: OpenAPI as product boundary

- Status: Accepted
- Date: 2026-08-26

## Context

Native Swift clients, a TypeScript admin console, and a Cloudflare BFF must
agree on authentication, errors, sync, jobs, and admin authorization. Talking
directly to Supabase, R2, or Qwen schemas would freeze vendor details into
every client and make independent test-first implementation impossible.

## Decision

The versioned OpenAPI document at `contracts/openapi-v1.yaml` is the product
API contract. Native clients and admin talk to that contract, not to vendor
schemas.

Contract rules:

- `/v1` major-version prefix; breaking changes require `/v2`
- UUID resource IDs and RFC 3339 timestamps
- `Idempotency-Key` on retryable writes and job submissions
- cursor pagination for change feeds
- consistent `ProblemDetails` errors
- explicit `operationId` for generated clients
- bearer session auth; admin operations also require `AdminBearer`
- long work returns `202 Accepted` and a job resource
- signed media URLs are short-lived and scoped
- additive schema evolution inside v1

Swift and TypeScript clients are generated from this document. CI fails when
generated code differs from the checked contract. Contract lint in this phase
parses the YAML, requires OpenAPI 3.1, resolves local refs, rejects duplicate
`operationId`s, and asserts write problem responses and admin security.

## Consequences

- Backend and clients can be implemented and tested independently.
- Infrastructure vendors can change behind the BFF without a client rewrite.
- Additive fields are allowed in v1; removals and incompatible type changes
  are a v2 event.
