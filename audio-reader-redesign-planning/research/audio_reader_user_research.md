# AudioReader Language-Learning Product Research

**Research date:** 2026-08-26  
**Scope:** Immersion readers, subtitle tools, sentence-mining systems, spaced-repetition products, audiobook/ebook workflows, public support forums, Reddit discussions, app-store feedback, and relevant learning research.

## 1. Research method and limits

This review used official product pages and documentation where possible, then compared them with public requests, issue reports, support forums, Reddit discussions, app-store reviews, and research literature. Quora search results were attempted, but Quora blocks automated access through `robots.txt`; no Quora claims are presented as evidence.

User feedback is directional rather than statistically representative. Forum participants are often power users and overrepresent problems. The value of the feedback is in repeated workflow failures and feature requests across products, not in estimating market percentages.

## 2. Product categories

Language-learning products usually optimize one part of the journey:

| Category | Representative products | Strong at | Common gap |
|---|---|---|---|
| Gamified courses | Duolingo and similar course apps | Habit formation, beginner structure | Authentic long-form content, user-owned books, deep context, advanced study |
| Immersion readers | LingQ, Readlang, Lute-style readers | Click-to-translate, known-word tracking, authentic text | Reliable audio alignment, native cross-device reading, offline consistency, transparent data portability |
| Subtitle/video tools | Language Reactor, Migaku, asbplayer workflows | Dual subtitles, looping, sentence mining, media context | Full audiobook/EPUB workflows, mobile parity, durable book progress |
| SRS systems | Anki, AnkiDroid, FSRS-based tools | Flexible memory scheduling | Frictionless capture, original audio/text context, pleasant reading experience |
| Audiobook/ebook apps | Apple Books, Audible, Kindle | Playback, library, cross-device position | Learner-aware transcript, vocabulary state, retrieval practice, contextual explanation |
| Speaking/pronunciation tools | shadowing and coaching apps | Production practice and feedback | Connection to the exact book sentence the learner is studying |

AudioReader’s opportunity is not to beat each specialist at its own isolated feature. It is to preserve context across the entire loop: **listen → follow text → inspect → understand → save → review → return to the exact sentence**.

## 3. What leading products already prove users value

### 3.1 Readlang

Readlang’s official feature set centres on fast inline translation, context-aware word/phrase explanation, a clean reader, automatic capture of translated words, and spaced flashcards. It also offers web reading and video with transcripts.

Product lesson: translation must be immediate and vocabulary capture must not interrupt reading.

### 3.2 LingQ

LingQ’s import flow supports personal content and turns imported captions/transcripts into interactive lessons where learners create saved terms and mark words learned or known.

Product lesson: authentic user-selected content and visible known-word state are core retention drivers for immersion readers.

### 3.3 Language Reactor

Language Reactor supports saved phrases, words with context, and words without context. Its Anki export explicitly treats words saved with an example as more desirable. It is strong at dual subtitles, playback control, lookup, and sentence-oriented video study.

Product lesson: a vocabulary item without its encounter context is a degraded object.

### 3.4 Migaku

Migaku combines browser/media immersion, known-word tracking, comprehension estimates, one-click card creation, built-in review, and mobile apps. Its changelog shows continuous work on cross-device saving, synchronization, mobile media support, and card creation.

Product lesson: users expect capture, review, known-state changes, and media progress to survive across devices. When they do not, the product’s central promise fails.

### 3.5 Anki and sentence-mining workflows

Anki’s strength is scheduling and flexibility. Public discussions repeatedly prefer cards with phrases, sentences, and audio over isolated words. Users also want the ability to select only useful items and suspend low-value cards rather than feel forced to study everything.

Product lesson: review must preserve useful context while giving users control over burden.

## 4. Repeated pain points and unmet requests

### 4.1 “Let me use my actual books and audio together”

Language Reactor users have requested direct EPUB import and specifically described the desire to combine listening and reading. Current workarounds include converting an EPUB to another form or uploading content elsewhere. This is a clear gap between subtitle tools and real book study.

**AudioReader response:** Treat audiobook + EPUB as a first-class paired edition, with transcript timing, edition validation, and a repairable alignment workflow.

### 4.2 “Resume at the exact place, not roughly the same page”

Language Reactor forum feedback notes that returning to the same page is not enough when the precise subtitle line or lower reading position resets. Audiobook learners care about exact sentence/audio continuity, not only chapter completion.

**AudioReader response:** Synchronize chapter ID, media time, focused segment ID, focused word ID, text mode, playback rate, and loop/deep-reading state separately. Resume safely without overwriting a newer local session.

### 4.3 “Give me native mobile access, not a desktop workflow squeezed into a browser”

Language Reactor users continue to ask for iOS/Android support; official forum responses in 2026 state that there is no native app. Earlier requests describe desktop mode on mobile as too awkward for enjoyable reading.

**AudioReader response:** Keep the existing native SwiftUI clients and make account/sync behavior equivalent on macOS and iPadOS. Do not make the browser the primary reader.

### 4.4 “Audio and text must stay synchronized”

A 2026 LingQ import discussion describes user-provided audio and transcripts drifting progressively out of sync in sentence mode and calls the workflow effectively broken. This is not a cosmetic defect: sentence replay, word timing, lookup, and cards all depend on alignment.

**AudioReader response:** Preserve the current transcript-as-timing-source rule, version every alignment, expose confidence, and allow recheck/replacement without retranscribing when possible.

### 4.5 “Offline work must sync correctly later”

LingQ’s support forum describes offline activity syncing after reconnection, but also notes that activity may be attributed to the reconnection date. Migaku’s changelog includes fixes where known/unknown changes and cards failed to save or sync.

**AudioReader response:** Use an append-only local outbox with original event timestamps, stable mutation IDs, explicit conflict rules, and idempotent server application. Never infer successful sync from a local UI update.

### 4.6 “Do not lose my cards or known-word changes”

Migaku issue reports and changelogs show how damaging silent card-generation or save failures are. A generated card that never appears, or a known-state change that does not persist, destroys trust.

**AudioReader response:** Every save action writes locally first, receives a durable mutation ID, exposes pending/synced/error state, and can be retried. The server returns entity versions and mutation receipts.

### 4.7 “I want better review choices than pass/fail”

An Australian App Store review for Migaku praises the integrated course/SRS convenience but asks for richer SRS choices than a tick and an X. Other public discussions emphasize suspending irrelevant cards to keep review sustainable.

**AudioReader response:** Offer Again/Hard/Good/Easy or equivalent FSRS grades, suspend, bury, reset, and “not useful.” Keep the original sentence/audio available, but allow progressively reduced cues to trigger retrieval.

### 4.8 “Preserve context, but make me retrieve”

Research shows that contextual information helps comprehension, while successful retrieval with feedback improves later retention. Spacing also benefits second-language learning. This argues against two extremes: isolated word lists and cards that reveal the whole answer immediately.

**AudioReader response:** Store rich encounter context, then vary the review face: recognition, cloze, reverse production, listening-only, and sentence continuation. Reveal context progressively after an attempt.

### 4.9 “Make explanations useful for this sentence, not generic dictionary noise”

Readlang and modern immersion tools emphasize context-aware explanations. Language Reactor distinguishes words saved with context from words saved without it. Learners want idioms, phrasal verbs, collocations, grammar, and book-specific concepts explained where they occur.

**AudioReader response:** Keep provider output structured and task-specific: translation, meaning in this sentence, phrase/idiom notes, challenging combinations, grammar/cultural note, and confidence. Let users correct or reject an answer.

### 4.10 “Let me read without an AI dashboard taking over”

Many advanced learners want tools to disappear until needed. AudioReader’s current `PRODUCT.md` already rejects decorative AI-dashboard styling and prioritizes the book and passage.

**AudioReader response:** AI is a contextual action and background service, not the product’s visual identity. The reading surface remains primary.

### 4.11 “Give me production practice tied to the material”

Research reviews suggest shadowing can help listening, comprehensibility, fluency, and aspects of pronunciation, while noting limitations in the evidence. Learners value using real sentences rather than generic drills.

**AudioReader response:** Keep on-device shadowing tied to the current sentence, show missed/extra tokens and timing, and avoid claiming accent diagnosis that the evidence or model cannot support.

### 4.12 “Help me choose material I can actually understand”

Migaku promotes comprehension scores based on known vocabulary. Immersion learners often struggle to find content at the right difficulty.

**AudioReader response:** Compute chapter coverage, unique unknown content words, speech rate, transcript confidence, and estimated difficulty. Recommend the next chapter/book from the user’s own library rather than creating a public course catalog in the first release.

### 4.13 “Do not make me pay an LLM twice for the same sentence”

The user explicitly requested cross-user caching for identical books. This is also operationally necessary: sentence translation is highly repetitive across shared editions.

**AudioReader response:** Add exact, privacy-safe, versioned, server-side cache reuse and single-flight request coalescing. Do not start with fuzzy semantic sharing; exact reuse is easier to test, invalidate, and defend.

### 4.14 “I should own and export my learning history”

Power users commonly combine readers with Anki or other tools. Platform lock-in and fragile integrations are recurring complaints.

**AudioReader response:** Provide export of vocabulary, review history, notes, transcripts owned by the user, and book metadata. Add Anki-compatible TSV/APKG export after the synchronized domain model stabilizes.

## 5. Rarely combined features worth differentiating on

The following combination remains uncommon even though each piece exists somewhere:

1. User-owned audiobook and EPUB pairing.
2. On-device word-timed transcription.
3. Probabilistic alignment that fails closed.
4. Exact sentence replay and deep-reading pause/continue.
5. Contextual word/sentence explanation with structured notes.
6. Vocabulary occurrence linked to source audio time.
7. Known/learning/unknown overlay throughout a chapter.
8. Recognition, cloze, reverse, listening, and continuation review.
9. On-device shadowing against the same sentence.
10. Offline-first cross-device synchronization.
11. Server-managed AI with no user provider setup.
12. Cross-user exact-result caching for identical editions.
13. Admin control over prompts, models, quotas, invalidation, and cost.
14. Data export and transparent sync status.

That integrated loop is the product thesis.

## 6. Recommended feature priority

### P0 — required for the cross-device multi-user release

- Google, Microsoft, and email-code sign-in.
- Account and device management.
- Synchronized reading settings and exact progress.
- Synchronized book metadata, assets, transcripts, vocabulary, known state, cards, and review events.
- Offline outbox/delta synchronization with deterministic conflicts.
- Server-managed Qwen translation/explanation/summary/chat.
- Exact shared translation cache with single-flight generation.
- Local-first transcription and transcript reuse across a user’s devices.
- User export/deletion.
- Admin users, quotas, jobs, provider policy, cache operations, storage, feature flags, and audit log.

### P1 — high-value follow-up

- Anki export/import mapping.
- Transcript and translation correction workflows.
- Book difficulty recommendations from personal library.
- Listening-only and dictation review faces.
- Download management and selective offline books.
- Cross-user shared transcript reuse with explicit rights/privacy policy.
- Family/classroom accounts only after individual tenancy is solid.

### P2 — defer until evidence supports it

- Public social feed.
- XP economy, leagues, streak pressure, badges, and competitive gamification.
- Public copyrighted book catalog.
- Marketplace or creator payouts.
- Real-time collaborative annotation.
- Automatic accent grading presented as authoritative.
- Fuzzy cross-book AI cache reuse.

## 7. Learning-design principles

1. **Authentic content first.** The user chooses material worth finishing.
2. **Comprehension at the moment of need.** Lookup and explanation should be fast and contextual.
3. **Retrieval after comprehension.** Review should progressively hide support and require an attempt.
4. **Spacing without punishment.** The scheduler adapts; missed days do not trigger shame mechanics.
5. **Explicit learner control.** Known, learning, ignored, suspended, and corrected states are user actions.
6. **Return to source.** Every vocabulary and review object can reopen its original sentence and audio.
7. **Local work remains useful offline.** Network failure must not turn the reader into a blank shell.
8. **AI outputs are drafts with provenance.** Store model, prompt version, schema version, and user decision.
9. **Privacy is a product feature.** Audio transcription stays local by default; shared caches use keyed exact fingerprints.
10. **Quality beats feature count.** Audio/text sync, data durability, and resume behavior are more important than a large dashboard.

## 8. Evidence-to-feature map

| Evidence | Product implication |
|---|---|
| Readlang saves translated terms and reviews them with spacing | Capture must flow directly into review. |
| Language Reactor prefers words saved with examples | Context is part of the vocabulary entity. |
| EPUB and listening/reading requests recur in Language Reactor forums | Audiobook + EPUB is a meaningful unmet workflow. |
| Mobile requests continue where browser-only tools dominate | Native clients are strategic, not legacy. |
| LingQ import users report progressive sentence desynchronization | Alignment needs versioning, confidence, repair, and tests. |
| Migaku save/sync fixes and GitHub issues | Sync must be observable, idempotent, and testable. |
| App review asks for richer SRS grading | Use a multi-grade scheduler and learner controls. |
| Spacing meta-analysis | Review events and deterministic scheduling belong in the core model. |
| Retrieval/context research | Store rich context but do not reveal all of it before an attempt. |
| Shadowing reviews | Keep sentence-linked shadowing, with modest claims and useful feedback. |
| Online extensive-reading review notes poor connection/fatigue | Offline-first and a calm native reader reduce known barriers. |

## 9. Sources

### Product and support sources

- Readlang features: https://readlang.com/features
- Readlang overview: https://readlang.com/
- LingQ importing guide: https://lingq-support.groovehq.com/help/importing-guide
- LingQ 2026 import/alignment discussion: https://forum.lingq.com/t/new-import-workflow-what-the/2574619
- LingQ offline sync discussion: https://forum.lingq.com/t/offline-lingq/37895
- Language Reactor export/context help: https://www.languagereactor.com/help/export
- Language Reactor mobile-app discussion: https://forum.languagelearningwithnetflix.com/t/phone-app/38590
- Language Reactor EPUB request: https://forum.languagelearningwithnetflix.com/t/feature-request-support-epub-book-import/29732
- Language Reactor listening + EPUB request: https://forum.languagelearningwithnetflix.com/t/pls-support-epub-import/36876
- Language Reactor exact resume request: https://forum.languagelearningwithnetflix.com/t/page-by-page-reading-and-auto-resume-for-books/32568
- Language Reactor mobile reading request: https://forum.languagelearningwithnetflix.com/t/reading-text-mode-for-mobile/13912
- Migaku feature overview: https://migaku.com/faq/features
- Migaku changelog: https://migaku.com/blog/changelog
- Migaku iOS App Store page: https://apps.apple.com/au/app/migaku-really-learn-languages/id1664096855
- Migaku Anki sync issue: https://github.com/migaku-official/Migaku-Anki-Addon/issues/94
- Reddit discussion about useful sentence/audio cards and suspending low-value cards: https://www.reddit.com/r/LearnJapanese/comments/rnpys1/how_to_learn_vocabulary_not_flashcards/

### Learning research

- Kim & Webb, spaced practice meta-analysis: https://doi.org/10.1111/lang.12479
- van den Broek et al., context and retrieval: https://doi.org/10.1111/lang.12285
- Binhomran & Altalhab, reading and vocabulary systematic review: https://doi.org/10.36892/ijlls.v5i3.1395
- Serrano, reading versus reading-while-listening: https://doi.org/10.3390/educsci13050493
- Whitworth & Rose, shadowing/pronunciation systematic review: https://doi.org/10.1080/29984475.2025.2546827
- El Moussaoui, shadowing and bottom-up listening review: https://doi.org/10.36892/ijlls.v7i4.2260
- Umamah et al., online extensive-reading review: https://www.journal.qiteplanguage.org/index.php/sjle/article/view/100
