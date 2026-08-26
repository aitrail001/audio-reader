# Phase 0.1 — Cross-device baseline

Recorded 2026-08-26 from the existing execution worktree. This document is
investigation evidence only. **No production behavior was changed.** Application
versions were not bumped. Swift sources, tests, plists, and the Xcode project
were not edited.

Evidence levels in this file:

| Level | What it proves | Obtained? |
| --- | --- | --- |
| Source | Git HEAD, working tree, version strings in tracked files | Yes |
| Tests | Full `swift test` process finished | Yes |
| Build | `AudioReader-macOS` and `AudioReader-iOS` `xcodebuild` finished | Yes |
| Artifact | Inspected existing tracked / DerivedData bundles without repackaging | Partial (read-only inspection) |
| Runtime | Launching and exercising the app | **No** — neither app was launched |

## 1. Checkout

| Field | Value |
| --- | --- |
| Worktree | `/Users/johnsonzhang/Documents/AI/Dataiku/src/audio-reader/.worktree/audio-reader-cross-device` |
| Branch | `execute-plan/bc39d3c9-pr-1-record-cross-device-baseline` |
| Tracking | up to date with `origin/main` at record time |
| Host | macOS 26.6.1 (25G76), Darwin 25.6.0, arm64 |
| Xcode | 26.6 (17F113) |
| Swift | Apple Swift 6.3.3 (swift-driver 1.148.6, swiftlang-6.3.3.1.3 clang-2100.1.1.101) |

This PR did not create a new worktree or feature branch. The worktree and
assigned branch already existed.

### HEAD

```text
$ git rev-parse HEAD
22c4c1f5145e0eec911343d5a8eb6ef9894c9d45
```

`22c4c1f` is `origin/main` at checkout, commit message `add planning`
(2026-08-26 19:23:44 +1000). It adds the planning bundle under
`audio-reader-redesign-planning/` (design doc, OpenAPI contract, research,
validation JSON). No product source is in that commit.

The design document originally named baseline `main` at
`e22685ae2c3b6c14eb53de8ebd2d4d3e017d6c3b`. Current HEAD is one commit ahead of
that SHA:

```text
$ git log --oneline e22685ae2c3b6c14eb53de8ebd2d4d3e017d6c3b..HEAD
22c4c1f  add planning
```

### Git status at record time (before this document)

```text
$ git status --short
```

Empty output. Working tree was clean: no staged, unstaged, or untracked files.

`git status` also reported:

```text
On branch execute-plan/bc39d3c9-pr-1-record-cross-device-baseline
Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean
```

After `swift test` and both `xcodebuild` runs, `git status --short` was still
empty. SPM `.build/` is gitignored. Xcode `DerivedData` is outside the worktree.
The only file added by this PR is this document.

## 2. Application versions (source)

Literal versions in root plists:

| File | `CFBundleShortVersionString` | `CFBundleVersion` |
| --- | --- | --- |
| `Info.plist` | `1.0.54` | `55` |
| `Info-iPad.plist` | `1.0.54` | `55` |

Xcode target Info plists substitute build settings:

| File | `CFBundleShortVersionString` | `CFBundleVersion` |
| --- | --- | --- |
| `Xcode/Info-macOS.plist` | `$(MARKETING_VERSION)` | `$(CURRENT_PROJECT_VERSION)` |
| `Xcode/Info-iOS.plist` | `$(MARKETING_VERSION)` | `$(CURRENT_PROJECT_VERSION)` |

`AudioReader.xcodeproj/project.pbxproj` target settings (four occurrences each):

| Target configuration | `MARKETING_VERSION` | `CURRENT_PROJECT_VERSION` |
| --- | --- | --- |
| AudioReader-macOS Debug | `1.0.54` | `55` |
| AudioReader-macOS Release | `1.0.54` | `55` |
| AudioReader-iOS Debug | `1.0.54` | `55` |
| AudioReader-iOS Release | `1.0.54` | `55` |

`Tests/AudioReaderTests/ImportParityTests.swift` asserts the same values
(`1.0.54` / `55`, four `MARKETING_VERSION` and four `CURRENT_PROJECT_VERSION`
assignments). Those assertions passed as part of the suite below.

## 3. `swift test`

Command:

```bash
swift test
```

| Field | Value |
| --- | --- |
| Started (UTC) | 2026-08-26T09:31:40Z |
| Finished (UTC) | 2026-08-26T09:32:37Z |
| Exit code | `0` |
| SPM build | `Build complete! (44.23s)` |
| Result | **pass** — full suite finished; not a focused subset |

XCTest compatibility runner (does not own this package's tests):

```text
Test Suite 'All tests' started at 2026-08-26 19:32:28.488.
Test Suite 'All tests' passed at 2026-08-26 19:32:28.489.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds
```

Swift Testing is the actual runner:

```text
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
…
✔ Test run with 272 tests in 28 suites passed after 9.398 seconds.
```

| Count | Value |
| --- | --- |
| Tests | 272 passed |
| Suites | 28 passed |
| Failures | 0 |
| Unexpected failures | 0 |
| Independent reruns | none required |

No `✘` failure markers and no recorded issues appeared in the log. Because the
full suite passed, no individual test was rerun. The XCTest line that reports
`Executed 0 tests` is **not** a suite failure and is **not** a claim that zero
Swift Testing cases ran.

Suites that passed:

- OpenAI provider
- Chapter comprehension quiz
- Full-chapter overlay and isolated playback chrome
- Provider credentials
- Playback cursor follows spoken tokens
- iPad background-jobs toolbar placement
- Local study days
- Chapter coverage and priming
- Provider-neutral reading assistant prompts
- Grok Responses fallback policy
- Reader split and iPad chrome layout
- Cloze and reverse review prompts
- On-device Apple Intelligence provider
- Study token and familiarity map
- Chapter chat dictation
- Shadowing score
- Provider model catalogs
- Multilingual transcription and synchronized reading
- Cross-platform import parity
- Chapter words presentation snapshot
- Known-lemma persistence
- Cached chapter study index
- macOS and iPadOS feature parity
- Vocabulary review scheduling
- EPUB document validation and trusted alignment
- Deep Reading mode
- Chapter acceptance batch
- BackgroundJobSchedulerTests

Resolved package during the run: ZIPFoundation `0.9.20`.

**Baseline tests did not fail.** There is no dirty test baseline to hide or to
reproduce on `main`.

## 4. `xcodebuild` — AudioReader-macOS

Command:

```bash
xcodebuild -project AudioReader.xcodeproj -scheme AudioReader-macOS \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

| Field | Value |
| --- | --- |
| Started (UTC) | 2026-08-26T09:32:47Z |
| Finished (UTC) | 2026-08-26T09:33:13Z |
| Exit code | `0` |
| Result | `** BUILD SUCCEEDED **` |
| Requested destination | `platform=macOS` |
| Selected destination | `{ platform:macOS, arch:arm64, id:00008142-000124C22222401C, name:My Mac }` |
| SDK | MacOSX26.5.sdk (`macosx26.5`) |
| Configuration | Debug (scheme default) |
| Signing | `CODE_SIGNING_ALLOWED=NO` |

xcodebuild warned that it used the first of two matching destinations (arm64 and
x86_64 on the same Mac). That is destination selection, not a compile failure.

Non-fatal notes from the log:

- `Ignoring --strip-bitcode because --sign was not passed`
- `Metadata extraction skipped. No AppIntents.framework dependency found.`
- `Disabling hardened runtime with ad-hoc codesigning.`

This is **build** evidence only. The Debug product was not launched.

## 5. `xcodebuild` — AudioReader-iOS

Command:

```bash
xcodebuild -project AudioReader.xcodeproj -scheme AudioReader-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

| Field | Value |
| --- | --- |
| Started (UTC) | 2026-08-26T09:33:24Z |
| Finished (UTC) | 2026-08-26T09:33:46Z |
| Exit code | `0` |
| Result | `** BUILD SUCCEEDED **` |
| Destination | `generic/platform=iOS Simulator` (as requested) |
| SDK | iPhoneSimulator26.5.sdk (`iphonesimulator26.5`) |
| Configuration | Debug (scheme default) |
| Architectures built | arm64 and x86_64 (universal simulator binary) |
| Signing | `CODE_SIGNING_ALLOWED=NO` |

Non-fatal notes from the log:

- `Ignoring --strip-bitcode because --sign was not passed`
- `Metadata extraction skipped. No AppIntents.framework dependency found.`
- `No AppShortcuts found - Skipping.`

This is **build** evidence only. The Simulator product was not installed or
launched. Device-only APIs were not exercised.

## 6. Package artifacts (inspection only)

Tracked and DerivedData bundles were read; **scripts were not run** and **apps
were not repackaged**.

### Tracked `AudioReader-iPad.app/`

Present and tracked. Plist:

| Key | Value |
| --- | --- |
| `CFBundleShortVersionString` | `1.0.54` |
| `CFBundleVersion` | `55` |
| `CFBundleIdentifier` | `com.johnsonzhang.AudioReader` |
| `CFBundleSupportedPlatforms` | `iPhoneSimulator` |
| `DTSDKName` | `iphonesimulator26.5` |
| `DTXcodeBuild` | `17F113` |
| `MinimumOSVersion` | `26.0` |

Code signature (existing artifact, not produced by this PR's `xcodebuild`):

```text
Identifier=com.johnsonzhang.AudioReader
Format=app bundle with Mach-O universal (x86_64 arm64)
Signature=adhoc
TeamIdentifier=not set
Sealed Resources version=2 rules=10 files=8
```

### Tracked `AudioReader.app/`

Not present in the worktree. `.gitignore` contains `AudioReader.app/`.
`git ls-files` has no macOS app bundle. Packaging script
`scripts/package_app.sh` exists but was not run.

### DerivedData products of this session (untracked, outside the repo)

These prove the baseline `xcodebuild` products, not the git-tracked packages.

| Product | Version | Build | Notes |
| --- | --- | --- | --- |
| `…/Build/Products/Debug/AudioReader.app` | `1.0.54` | `55` | macOS Debug, `DTSDKName=macosx26.5`, ad-hoc linker-signed arm64 |
| `…/Build/Products/Debug-iphonesimulator/AudioReader.app` | `1.0.54` | `55` | iOS Simulator Debug, `DTSDKName=iphonesimulator26.5`, universal x86_64+arm64 |

DerivedData path:
`/Users/johnsonzhang/Library/Developer/Xcode/DerivedData/AudioReader-cnqvgvrciujjnpcfzoicgzjpofis/`.

## 7. Production-behavior statement

- No Swift production code, tests, or version plists were modified.
- `CFBundleShortVersionString` / `MARKETING_VERSION` remain `1.0.54`.
- `CFBundleVersion` / `CURRENT_PROJECT_VERSION` remain `55`.
- No credentials, provider keys, or secrets were added.
- Local-first product behavior is unchanged because no product code changed.
- macOS and iPadOS remain two presentations of one product; this PR does not
  alter parity.
- The complete Swift suite finished successfully. Both Apple targets compiled
  with `CODE_SIGNING_ALLOWED=NO`.
- Runtime behavior was **not** observed.

This is a clean baseline: working tree was clean, tests passed, both scheme
builds succeeded.
