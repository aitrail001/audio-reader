# AudioReader Repository Audit

**Repository:** `aitrail001/audio-reader`  
**Audited branch:** `main`  
**Audited commit:** `e22685ae2c3b6c14eb53de8ebd2d4d3e017d6c3b`  
**Audit date:** 2026-08-26  
**Method:** Source inspection through the connected GitHub repository API. The execution environment could not resolve `github.com`, so this audit does **not** claim a local build or test run.

## 1. Current product in one sentence

AudioReader is a native macOS and iPadOS immersion reader that combines audiobook playback, Apple on-device transcription, word-timed text, optional EPUB alignment, contextual dictionary and LLM assistance, vocabulary capture, local study tools, and review in the original book context.

The current application is already unusually strong at the difficult part of the product: preserving the relationship among audio time, spoken text, ebook wording, word selection, vocabulary, and study. The redesign should keep that native local-first core and add an account, synchronization, server-managed AI, shared exact-result caching, and administration around it. Replacing the reader with a web-first shell would throw away the product’s strongest work.

## 2. Repository shape

The repository is a Swift 6.2 package and Xcode project targeting macOS 26 and iPadOS 26. The main executable target is under `Sources/AudioReader`; shared tests are under `Tests/AudioReaderTests`. The Xcode project exposes separate macOS and iOS schemes.

Key top-level files:

| Path | Purpose |
|---|---|
| `Package.swift` | Swift 6.2 package, macOS/iOS 26 deployment targets, ZIPFoundation dependency, Apple frameworks and SQLite linkage. |
| `AudioReader.xcodeproj` | Native macOS and iPadOS application targets and schemes. |
| `README.md` | Detailed product behavior, supported imports, on-device transcription, EPUB validation, study tools, providers, security, and known limitations. |
| `PRODUCT.md` | Product positioning: calm, book-focused, native, progressive disclosure, accessibility, and no decorative AI-dashboard treatment. |
| `AGENTS.md` | Hard engineering rules for macOS/iPadOS parity, provider security, testing, packaging, and version synchronization. |
| `Sources/AudioReader/` | Application state, views, import, playback, transcription, alignment, persistence, study logic, AI clients, settings, and platform adapters. |
| `Tests/AudioReaderTests/` | Regression tests for import parity, alignment, providers, credentials, background jobs, study, review, layout, and platform contracts. |

## 3. Main user-facing capabilities already present

### 3.1 Library and import

The application imports audiobook files, folders, M4B chapters, EPUB companions, cover images, accessible Apple Books items on macOS, and device media-library audiobooks on iPadOS. Re-import can enrich an existing book with a missing EPUB or cover rather than duplicating the book.

Relevant code:

- `AudiobookImportService.swift`
- `LibraryScanner.swift`
- `M4BChapterExtractor.swift`
- `MacAudiobookImporter.swift`
- `MacAppleBooksLibrary.swift`
- `IPadImports.swift`
- `IPadRootView.swift`

### 3.2 Playback and precise reading context

The player maintains chapter playback, current sentence and word, sentence seeking, sentence replay, sentence loop, A–B loop support, playback speed, skip intervals, and deep-reading pause/continue behavior. The transcript—not EPUB text—is the timing source.

Relevant code:

- `PlayerEngine.swift`
- `PlayerView.swift`
- `StudyPractice.swift` (`PlaybackCursor`)
- `VocabSentencePlayback.swift`
- `ReaderSplitLayout.swift`

### 3.3 On-device transcription

`Transcriber.swift` uses Apple `SpeechAnalyzer` and `SpeechTranscriber`, installs language assets when required, emits word timing and confidence, checkpoints partial work, and handles M4B chapter slicing through temporary audio files. Audio is not sent to the configured LLM provider.

This is a core architectural asset. The server redesign should treat transcription as a device capability and synchronization source, not immediately replace it with expensive server transcription.

### 3.4 EPUB parsing, validation, and alignment

The app extracts EPUB content and aligns it against what was actually spoken. It uses document-level assessment and per-sentence trust gates so a coincidental sentence match cannot make an entire ebook trusted. Users can recheck, replace, or explicitly override an uncertain ebook while still requiring strong individual sentence matches.

Relevant code:

- `EPUBParser.swift`
- `Aligner.swift`
- alignment fields in `Models.swift`
- recheck/replacement logic in `AppState.swift`
- extensive `EPUBAlignmentTests.swift`

### 3.5 Dictionary, translation, and contextual assistance

The application supports dictionary lookup and server/on-device language assistance for:

- word meaning in the current sentence;
- sentence translation with previous/next context;
- chapter translation in resumable blocks;
- chapter summaries;
- chapter-aware chat;
- structured language and context notes;
- voice dictation for chapter chat.

Relevant code:

- `DictionaryLookup.swift`
- `DictionaryHTMLView.swift`
- `GlossPresentation.swift`
- `ReadingAssistantPrompt.swift`
- `GrokClient.swift`
- `FoundationModelsClient.swift`
- `CodexCLIClient.swift`
- `ChapterChatDictation.swift`

### 3.6 Vocabulary and study

The current local study layer includes:

- vocabulary occurrences saved with source book, chapter, sentence, word ID, and timestamp;
- word, phrase, and sentence categories;
- known/learning/unknown lemma state;
- chapter coverage and chapter word lists;
- full-chapter study overlay;
- recognition, cloze, and reverse review faces;
- spaced review state;
- local chapter cloze/sequencing quizzes;
- on-device shadowing score;
- quiet study-day tracking without XP or game mechanics.

Relevant code:

- `StudyLexicon.swift`
- `StudyPractice.swift`
- `VocabularyReview.swift`
- `VocabularyReviewView.swift`
- `VocabularyView.swift`
- `ChapterQuizView.swift`
- `ChapterStudyListView.swift`
- `ShadowingPracticeView.swift`

### 3.7 Background work

The app has a local background-job presentation and queue for transcription and LLM tasks. It can navigate back to the source book/chapter and exposes queued/running states.

Relevant code:

- `BackgroundJobQueue.swift`
- background job models in `Models.swift`
- orchestration in `AppState.swift`
- UI in `RootView.swift` and `IPadRootView.swift`

## 4. Current persistence model

### 4.1 Local files

`Persistence.swift` stores application data under the platform application-support container, including:

- transcripts;
- vocabulary;
- known lemmas;
- study activity;
- settings;
- glosses;
- translation checkpoints;
- chapter summaries;
- imported books.

It keeps JSON compatibility while routing transcripts, vocabulary, and glosses through SQLite where available.

### 4.2 SQLite

`Store.swift` defines a local `LibraryStore` with tables for transcripts, vocabulary, and glosses. It imports legacy JSON once and keeps JSON mirrors for compatibility.

This gives the redesign a practical migration path: add a sync/outbox database beside the current local store, then gradually move entity persistence behind repositories. Do not attempt a one-shot replacement of every local file and SQLite call.

### 4.3 Current identity model

There is no user, account, tenant, or device identity. Book and chapter IDs are derived locally. Absolute local paths remain part of several models. Data is scoped to an installation rather than an authenticated person.

That is the central change required by the redesign.

## 5. Existing AI-provider design

The current client exposes Apple Intelligence, Grok, QwenCloud, and OpenAI/ChatGPT choices. API endpoints and model settings are persisted locally. API keys are kept in an AES-GCM encrypted local vault whose wrapping key is in device-only Keychain storage. Provider-specific OAuth reuse exists on macOS for Grok Build and a Codex ChatGPT session.

This design is appropriate for a power-user local app, but it conflicts with the multi-user product requirement that ordinary users should not configure providers, endpoints, models, or keys.

### Required migration

- Keep provider-neutral prompt and output contracts.
- Move remote provider selection, API keys, endpoints, model aliases, effort, budgets, and retry policy to server-side admin configuration.
- Remove provider configuration from normal user settings in remote-account mode.
- Keep Apple Intelligence as an optional device-local provider only for explicitly local tasks.
- Preserve local credentials only for a transitional “local-only mode,” if that mode remains supported.

## 6. Existing architectural strengths to preserve

1. **The transcript is the timing authority.** This avoids assuming ebook and narration text are identical.
2. **EPUB trust fails closed.** The current two-level trust model is safer than blindly replacing speech text.
3. **Vocabulary is an occurrence, not just a word.** Book, chapter, context, and timestamp remain attached.
4. **Known state is explicit.** The product explicitly rejects marking words known merely because they were played or scrolled past.
5. **Study logic is mostly local and deterministic.** It can remain available offline.
6. **Provider prompts are already separated from transports.** This lowers the cost of moving Qwen calls to the server.
7. **macOS and iPadOS parity is documented as a contract.** The redesign should extend this to account and sync behavior.
8. **There is meaningful regression coverage.** The redesign can add cloud and sync tests without abandoning existing native tests.

## 7. Architectural pressure points

### 7.1 `AppState.swift` is a monolith

At roughly 114 KB, `AppState.swift` owns library scanning, selection, playback state, transcription, EPUB operations, vocabulary, study, credentials, models, translations, summaries, chat, background jobs, and persistence coordination.

The cloud redesign must not add authentication, network state, synchronization, uploads, and account administration directly into this class. Introduce focused services and stores:

- `SessionStore`
- `SyncCoordinator`
- `RemoteLibraryRepository`
- `RemoteStudyRepository`
- `AssetTransferService`
- `AIJobService`
- `DeviceCapabilityService`

`AppState` should coordinate screen-level state and call these interfaces.

### 7.2 `PlayerView.swift` is also very large

At roughly 113 KB, the reader view carries many controls and modes. Cross-device sync UI should be small and extracted: account state, sync status, conflict banner, and download state should not make this file larger.

### 7.3 Local paths are embedded in domain models

`Book.folderPath`, `Book.coverPath`, `Book.ebookPath`, and `Chapter.audioPath` are installation-specific. The remote model needs stable IDs and asset references while the local adapter maps those IDs to sandbox URLs.

### 7.4 Existing IDs are not guaranteed cross-device stable

Book, chapter, segment, and word identifiers must survive import on another device. The server design therefore needs:

- server UUIDs;
- client-generated UUIDs for offline creation;
- exact asset hashes;
- edition fingerprints;
- stable chapter anchors;
- transcript-version IDs;
- deterministic segment anchors where possible.

### 7.5 Settings mix user preferences with infrastructure configuration

`AppSettings` currently combines reading preferences, library paths, target languages, LLM provider configuration, model IDs, endpoints, reasoning settings, dictionary choice, and layout values. Split this into:

- synchronized user preferences;
- device-only preferences;
- installation paths/capabilities;
- server-only AI policies;
- admin-only operational configuration.

### 7.6 Local background jobs are not durable across devices

A remote Qwen request must become an idempotent server job with persisted status, retry count, usage, result, and cache relationship. The client queue remains useful for local transcription and upload operations.

## 8. Test assets and engineering rules already present

The repository includes focused tests for:

- background job scheduling;
- chapter acceptance batching;
- chapter chat dictation;
- deep reading;
- EPUB alignment;
- Foundation Models;
- provider fallback and credentials;
- iPad toolbar ownership;
- import parity;
- OpenAI provider behavior;
- platform parity contracts;
- model catalogs;
- reader chrome layout;
- reading-assistant prompts;
- study lexicon and practice;
- transcription languages;
- vocabulary review.

`AGENTS.md` requires regression tests first, both platform builds for shared changes, artifact inspection, honest separation of source/build/runtime evidence, and version synchronization. The implementation plan extends these rules rather than replacing them.

## 9. Recommended repository additions

Keep the existing Swift source in place during migration. Add the following boundaries:

```text
Backend/
├── api/                         # Cloudflare Worker, Hono, OpenAPI handlers
├── admin/                       # React admin console
├── db/                          # SQL migrations, RLS policies, seed data
└── tests/                       # API, RLS, integration and scenario tests

Contracts/
├── openapi/audio-reader-v1.yaml
└── schemas/                     # Versioned JSON schemas for Qwen outputs

Packages/
├── AudioReaderAPI/              # Generated/hand-wrapped Swift API client
├── AudioReaderAuth/             # Session, OAuth and email-code flows
└── AudioReaderSync/             # Outbox, cursors, conflicts and transfer state

Sources/AudioReader/
├── Auth/                        # Native account UI and session integration
├── Remote/                      # Domain repositories and API adapters
└── Sync/                        # App-facing sync bridge

infra/
├── cloudflare/
├── supabase/
└── environments/

docs/
├── architecture/
├── operations/
├── runbooks/
└── adr/
```

## 10. Migration strategy from the current app

1. Add interfaces around current local persistence without changing behavior.
2. Add a local sync database with outbox, server cursor, entity versions, and tombstones.
3. Add account/session state while preserving local-only launch.
4. Upload/sync metadata, progress, vocabulary, review events, and settings first.
5. Add optional asset sync after metadata sync is stable.
6. Upload local transcripts and translation results as versioned account data.
7. Move Qwen calls behind the server gateway and hide provider configuration from users.
8. Introduce shared exact-result caching only after edition and request fingerprinting tests pass.
9. Migrate existing local data through an explicit, reversible onboarding flow.
10. Remove legacy remote-provider settings only after the server path has production evidence.

## 11. Audit conclusion

The correct redesign is not “turn the Swift app into a web app.” It is “retain a capable offline native reader and surround it with an account-scoped control plane.” The current transcript, alignment, vocabulary-context, and local-study work should become the client-side engine. The backend should own identity, durable synchronization, shared assets, Qwen policy, exact-result caching, quotas, jobs, auditability, and administration.
