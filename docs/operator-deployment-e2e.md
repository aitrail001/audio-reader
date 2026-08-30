# Operator deployment and end-to-end runbook

Use this runbook after source tests, both native target builds, and both tracked
packages pass. Production remains read-only except for ordinary login/session
registration and the explicitly selected Managed Qwen probe.

## Evidence tuple

Record these values for staging and production separately:

- Git commit SHA and clean/dirty state;
- API environment, Wrangler deployment ID, `APP_VERSION`, deployment time, and
  `/healthz` / `/readyz` result;
- Operator Pages project, branch/alias, deployment ID, console version, and
  deployment time;
- packaged macOS and iPadOS version/build, resource inspection, and signature;
- the Qwen probe request ID and its matching Product Event, Activity, Trace,
  and Audit evidence.

Never substitute a source build, a successful console render, or a saved policy
for this tuple.

## Automated gate

From `server/`:

```bash
pnpm install --frozen-lockfile
pnpm test:all
pnpm lint
pnpm typecheck
pnpm contract:generate
pnpm contract:check
pnpm --filter @audio-reader/admin-web build
```

Also run the complete Swift suite, macOS/iPadOS target builds, Debug UI tests,
and package/signature checks documented in `docs/operations.md`.

## Staging first

1. Apply all committed migrations before deploying either Worker. AudioReader's
   current Supabase project has one `main` production database and no staging
   branch, so apply additive migrations to `main` once, then validate the
   staging Workers against that schema. If a separate staging branch is added,
   restore the usual staging-first database order. Verify
   `20260830111500_byte_bounded_sync_pull.sql` and
   `20260830143000_user_progress_summaries.sql` and
   `20260830153000_progress_privacy_enforcement.sql` are recorded in
   `public.schema_migrations`, and verify `service_role` can execute
   `pull_sync_page`, `admin_user_progress_summary`,
   `set_user_analytics_preference`, `purge_expired_user_progress_summaries`, and
   `request_account_deletion`, `claim_assistant_jobs`, and `delete_account_data`. Stop if any readback
   is missing.

   ```sql
   select filename
   from public.schema_migrations
   where filename in (
     '20260830111500_byte_bounded_sync_pull.sql',
     '20260830143000_user_progress_summaries.sql',
     '20260830153000_progress_privacy_enforcement.sql'
   )
   order by filename;

   select
     has_function_privilege('service_role', 'public.pull_sync_page(uuid,bigint,integer,bigint)', 'execute') as pull_sync_page,
     has_function_privilege('service_role', 'public.admin_user_progress_summary(uuid)', 'execute') as progress_summary,
     has_function_privilege('service_role', 'public.set_user_analytics_preference(uuid,boolean)', 'execute') as analytics_preference,
     has_function_privilege('service_role', 'public.purge_expired_user_progress_summaries()', 'execute') as retention_purge,
     has_function_privilege('service_role', 'public.request_account_deletion(uuid,text,text)', 'execute') as deletion_request,
     has_function_privilege('service_role', 'public.claim_assistant_jobs(integer)', 'execute') as job_claim,
     has_function_privilege('service_role', 'public.delete_account_data(uuid)', 'execute') as account_deletion;

   select column_name, data_type
   from information_schema.columns
   where table_schema = 'public'
     and table_name = 'assistant_jobs'
     and column_name in ('payload', 'lease_expires_at')
   order by column_name;

   select
     has_table_privilege('service_role', 'public.object_write_leases', 'select') as lease_select,
     has_table_privilege('service_role', 'public.object_write_leases', 'insert') as lease_insert,
     has_table_privilege('service_role', 'public.object_write_leases', 'delete') as lease_delete;
   ```

2. Run `pnpm preflight:deploy staging`. Before deploying the Job Worker, confirm its staging secret
   names include `SUPABASE_URL` and either `SUPABASE_SERVICE_ROLE_KEY` or `SUPABASE_SECRET_KEY`.
   Supabase Storage requires the same explicit `SUPABASE_STORAGE_BUCKET` on both Workers; database
   credentials alone never select a storage provider.
   Deploy the API Worker and Job Worker to staging. The Job Worker health response must be HTTP 200
   with `dependencies.database = "ok"` and `dependencies.storage = "ok"`; this is a live dependency
   probe, not a secret-presence check. HTTP 503 blocks rollout, including an Operator-settings read
   error even when another storage binding exists. If GCS is configured in Operator, the
   Job Worker must also have the matching `OPERATOR_CONFIG_KEY` (preferred),
   `CACHE_HMAC_SECRET`, or `PASSWORDLESS_HMAC_SECRET` so it can
   decrypt the same service account; otherwise configure the same GCS credentials directly. Observe
   at least one scheduled `user_progress_retention_purged` structured log,
   then verify `select count(*) from public.user_progress_summaries where expires_at <= now()` is zero.
3. Build the Operator with `VITE_API_BASE_URL` set to the staging Worker URL,
   then publish `server/apps/admin-web/dist` as a Cloudflare Pages preview for
   the staging branch. Add the exact returned preview alias to the staging
   Worker's `CORS_ALLOWED_ORIGINS` before requesting an OTP. Record the Pages
   deployment ID and URL and confirm the compiled Operator calls the staging
   Worker rather than its own Pages origin.
4. Verify `/healthz`, `/readyz`, `/v1/health`, and the version payload from the
   staging Worker.
5. Open the staging Operator preview. Verify every destination and a copied URL
   deep link, including filters and paginated Audit, Activity, and Privacy. For Audit and Product Events,
   follow the opaque `nextCursor` through multiple filtered pages and verify no row is duplicated or omitted.
6. Confirm that refreshing one failed panel preserves stale content and does
   not block another destination.
7. In Policies, select every applicable subtask and run **Validate & preview**.
   Confirm editable, enforced, effective, and output layers are visible and the
   sample book, author, chapter, languages, and level are present. Run the
   selected Managed Qwen staging probe, inspect its parsed/schema result, copy
   its request ID, and follow it through Product Events, Activity, Trace, and Audit. Confirm no prompt, token,
   secret, provider key, or full book text is disclosed.

Stop on the first failed gate. Do not promote a different unrecorded build.

## Production promotion

1. Re-run the automated gate against the exact commit being promoted.
2. Repeat the `schema_migrations` plus `service_role` execute-grant readback used
   in staging. With the current single-database topology, the migrations were
   already applied before the staging Worker deployment; do not execute them a
   second time. If production has its own database by rollout time, apply the
   same committed migrations there before this readback. Do not deploy a Worker
   that references an unverified RPC.
3. Run `pnpm preflight:deploy production`, then deploy the API Worker and Job
   Worker to production.
4. Publish the same verified Operator build to the Pages production branch and
   record its deployment ID.
5. Verify the production version tuple and health responses.
6. In the built-in browser signed in as **Audio Reader**, visit every destination
   and request-ID deep link, and run only the selected Qwen probe.
7. In the built-in browser and packaged app's existing personal session, validate packaged macOS Google login,
   account/bootstrap, visible sync status, and existing synchronized data. Do
   not edit study content.
8. Exercise parity on iPad Simulator and, when available, physical iPad. Record
   device-only gaps rather than treating a rendered Simulator view as proof.

## Required Operator checks

- Desk prioritizes degraded dependencies, failed jobs, quota pressure,
  configuration drift, and recent errors.
- People, AI, Delivery, and Observe groups are keyboard reachable at 44 px.
- Typed API failures preserve HTTP status, problem code, field errors, retry
  timing, and copyable trace ID.
- Contextual mutation reason starts blank, rejects fewer than five characters,
  shows before/after, and clears after success.
- Secret removal, Managed Qwen disable, destructive cache/privacy actions, and
  large quota reductions require explicit confirmation.
- Desktop, tablet, and 390 px layouts pass keyboard-only, 200% zoom, light/dark,
  reduced-motion, and WCAG AA checks.
- Metrics filters persist in the URL; trends, anomaly indicators, coarse
  geography, language, level, platform/version, opaque content, and feature
  distributions load without exposing direct identifiers or reading text.
- Activity exposes pseudonymous learner/device references only. Cohorts smaller
  than three learners are grouped, and precise location, raw IP, email, titles,
  authors, sentences, vocabulary, and arbitrary properties are absent.

## Rollback

Keep the immediately previous Worker deployment ID and Pages deployment ID in
the evidence record. If smoke validation fails, roll back the affected component
only, verify its health/version again, and leave the other component unchanged
unless contract incompatibility is demonstrated.
