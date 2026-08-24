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

## Cross-platform verification

- For behavior changes, add or update regression tests first. Include parity-focused tests for shared semantics and focused platform tests where the implementations differ.
- Build both the `AudioReader-macOS` and `AudioReader-iOS` targets for every shared code or behavior change. If a change is intentionally platform-only, build that target and run shared regression tests; state why the other target is unaffected.
- Repackage each affected tracked app with the repository scripts. For each fresh artifact, verify its plist version, relevant resources or binary strings, and code signature where applicable. A successful source build does not prove that a tracked app bundle is current.
- Report source, build, artifact, and runtime evidence separately: tests/diff establish source behavior; target builds establish compilation; bundle inspection establishes packaged contents; launching and exercising the feature establishes runtime behavior. Never imply a stronger level of evidence than was actually obtained.
- Exercise shared changes on macOS and an iPad Simulator or physical iPad when practical. If Simulator limitations prevent validation of a device-only API, report that runtime gap explicitly instead of treating a rendered UI as proof.
- Let the complete Swift suite finish. If the aggregate run exposes a timing-sensitive failure, rerun the exact test or suite independently and report both outcomes; do not describe focused or isolated success as a full-suite pass.

## Versioning

- Use semantic application versions in `x.y.z` form.
- For every code or behavior fix/change, increment the patch component (`z`) exactly once before completion. Documentation-only or investigation-only work does not require a version bump.
- Keep `CFBundleShortVersionString` in the root `Info.plist` synchronized with `MARKETING_VERSION` for macOS and iPadOS Debug and Release configurations.
- Increment `CFBundleVersion` and every `CURRENT_PROJECT_VERSION` when the patch version changes.
- Run the version synchronization test and rebuild every affected app target before reporting completion. Shared code or behavior changes affect both app targets unless demonstrated otherwise.
