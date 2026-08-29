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

1. Run `pnpm preflight:deploy staging`, then `pnpm deploy:staging`.
2. Publish the already-built `server/apps/admin-web/dist` as a Cloudflare Pages
   preview for the staging branch. Record the returned deployment ID and URL.
3. Verify `/healthz`, `/readyz`, `/v1/health`, and the version payload from the
   staging Worker.
4. Open the staging Operator preview. Verify every destination and a copied URL
   deep link, including filters and paginated Audit, Activity, and Privacy.
5. Confirm that refreshing one failed panel preserves stale content and does
   not block another destination.
6. Run the selected Managed Qwen probe, copy its request ID, and follow it
   through Product Events, Activity, Trace, and Audit. Confirm no prompt, token,
   secret, provider key, or full book text is disclosed.

Stop on the first failed gate. Do not promote a different unrecorded build.

## Production promotion

1. Re-run the automated gate against the exact commit being promoted.
2. Run `pnpm preflight:deploy production`, then `pnpm deploy:production`.
3. Publish the same verified Operator build to the Pages production branch and
   record its deployment ID.
4. Verify the production version tuple and health responses.
5. In Arc profile **Audio Reader**, sign in to Operator, visit every destination
   and request-ID deep link, and run only the selected Qwen probe.
6. In Arc profile **personal**, validate packaged macOS Google login,
   account/bootstrap, visible sync status, and existing synchronized data. Do
   not edit study content.
7. Exercise parity on iPad Simulator and, when available, physical iPad. Record
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

## Rollback

Keep the immediately previous Worker deployment ID and Pages deployment ID in
the evidence record. If smoke validation fails, roll back the affected component
only, verify its health/version again, and leave the other component unchanged
unless contract incompatibility is demonstrated.

