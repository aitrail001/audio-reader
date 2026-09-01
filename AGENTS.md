# AudioReader repository instructions

## macOS and iPadOS parity

- Treat macOS and iPadOS as two presentations of one product. Evaluate every feature, behavior change, bug fix, persisted setting, command, accessibility label, and user control for both targets, and implement it on both unless an explicit OS or product constraint makes it platform-specific.
- Prefer shared model, service, state, and persistence code. Keep `#if os(...)` branches small and confined to platform adapters or UI affordances; do not duplicate core behavior merely because the views differ.
- Platform-specific implementations may use different affordances, such as a macOS keyboard shortcut and an iPad button or gesture, but must provide equivalent behavior and state transitions. Document intentional differences and cover the shared contract with tests.
- When changing a shared feature, scan both platform entry points and views for drift. Do not assume that compiling shared source proves that the feature is reachable or usable on both platforms.
- In the iPad `NavigationSplitView`, put stateful toolbar actions on the currently visible content or detail column and preserve exactly one owner. Extend the toolbar-placement policy test when adding or moving such actions.

## Provider platform contracts

- Preserve deliberate authentication differences. OpenAI API-key authentication must remain available on both macOS and iPadOS. ChatGPT-plan authentication through an existing Codex `Sign in with ChatGPT` session is macOS-only; keep that path isolated with `#if os(macOS)` and do not treat its absence on iPadOS as a parity defect.
- Do not expose, copy, or add direct handling of cached Codex OAuth tokens. iPadOS must use the supported API-key path.
- Keep provider-managed logins separate from API-key authentication. Grok Build and ChatGPT-plan tabs must warn that the unofficial integration may violate the provider's terms; API keys and editable endpoints belong only to API mode.
- Give every API provider a valid default endpoint and persist user overrides through shared settings. Route requests through the selected provider's persisted endpoint rather than a view-only or hard-coded call-site value.
- Store provider API keys only in the AES-GCM encrypted local credential vault, never as per-provider Apple Keychain items or in settings JSON, logs, app-bundle resources, or plaintext files. Keep the vault's random wrapping key as a 256-bit file next to the vault (`credential-vault.key`, POSIX 0600 on macOS / complete-until-first-unlock protection on iPadOS) and cache it for the running app session. Do not use Apple Keychain for API keys, wrapping keys, or account sessions. Do not replace a missing wrapping key when an existing vault cannot be unlocked. Do not reload an existing API key into a settings field; accept replacement input, expose explicit removal, and securely migrate legacy Keychain items and plaintext key files before using them.

## Cross-platform verification

- For behavior changes, add or update regression tests first. Include parity-focused tests for shared semantics and focused platform tests where the implementations differ.
- Build both the `AudioReader-macOS` and `AudioReader-iOS` targets for every shared code or behavior change. If a change is intentionally platform-only, build that target and run shared regression tests; state why the other target is unaffected.
- Repackage each affected tracked app with the repository scripts. For each fresh artifact, verify its plist version, relevant resources or binary strings, and code signature where applicable. A successful source build does not prove that a tracked app bundle is current.
- Report source, build, artifact, and runtime evidence separately: tests/diff establish source behavior; target builds establish compilation; bundle inspection establishes packaged contents; launching and exercising the feature establishes runtime behavior. Never imply a stronger level of evidence than was actually obtained.
- Exercise shared changes on macOS and an iPad Simulator or physical iPad when practical. If Simulator limitations prevent validation of a device-only API, report that runtime gap explicitly instead of treating a rendered UI as proof.
- Let the complete Swift suite finish. If the aggregate run exposes a timing-sensitive failure, rerun the exact test or suite independently and report both outcomes; do not describe focused or isolated success as a full-suite pass.

## Comments

- Comment the key functions you add or change: public APIs, persistence and auth boundaries, protocol parsers, background jobs, and any path whose invariants are not obvious from names and types.
- State *why* and the non-obvious constraint (who owns the token, which store is source of truth, what the caller must not do). Do not narrate the implementation, restate the signature, or leave TODOs that substitute for finishing the work.
- Keep comments short, factual, and next to the code they describe. Update or delete them when the behavior changes.

## Logging, audit, and trace

- Instrument the paths you change so an operator can reconstruct what happened without a debugger: start and finish of a request or job, auth success or failure, policy or config writes, cache/sync decisions, and upstream provider errors.
- Prefer structured logs with a stable `message`, `requestId` / trace id, component, and outcome. Include the resource and actor when they exist (user, device, policy, job). Match the surrounding logging style (`console.warn` JSON on Workers, OSLog or existing helpers on Apple).
- Log enough to troubleshoot, audit, and trace a single user action across native app, Worker, and admin console. Do not log secrets, tokens, wrapping keys, raw provider key material, OTP codes, or full request bodies that may contain book text or credentials. Redact rather than omit the event.

## Versioning

- Use semantic versions in `x.y.z` form. Bump **only the components that changed**, and bump each of those exactly once before completion.
- Choose the digit from the change, not from the size of the diff: new user-visible capability or API surface → minor (`y`, reset `z` to 0); bug fix, hotfix, or hardening of existing behavior → patch (`z`). Do not bump major unless the change is an intentional breaking contract.
- Native apps: keep `CFBundleShortVersionString` in the root `Info.plist` synchronized with `MARKETING_VERSION` for macOS and iPadOS Debug and Release. Increment `CFBundleVersion` and every `CURRENT_PROJECT_VERSION` when that marketing version changes. Shared native behavior bumps both app targets unless demonstrated otherwise. Run the version synchronization test and rebuild every affected app target before reporting completion.
- Hosted API: bump `APP_VERSION` in `server/apps/api-worker/wrangler.toml` (and the job worker when that worker changed) for every Worker, route, schema, or auth behavior change.
- Operator console: bump `server/apps/admin-web/package.json` `version` for every admin-web behavior or UI change.
- Documentation-only or investigation-only work does not require a version bump. If a change spans native and server, bump each affected component; leave untouched components alone.
