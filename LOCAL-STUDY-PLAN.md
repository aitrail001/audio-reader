# Local study layer (fully on-device)

Branch: `feature/local-study-layer`  
Worktree: `../audio-reader-local-study`  
`main` is not modified.

## Research (what this product already is)

AudioReader is an **immersion reader** (LingQ / Readlang family), not a course app:

- Listen to the audiobook with word-level timestamps
- Look up a word, save it with the original sentence
- Review with SM-2-like SRS
- Optional cloud LLM for in-sentence meaning, translation notes, summary, chat

Typical language-learning apps split into: gamified courses (Duolingo), structured lessons (Babbel), SRS (Anki), immersion readers (LingQ/Readlang), speaking (italki/Pimsleur). Users of this family cry for:

1. Known vs learning vs unknown **in the text**
2. Chapter **coverage** (“how much of this do I know?”)
3. Production practice: **cloze** and reverse cards, not only recognition
4. Frictionless mark-known **without** auto-known on scroll
5. Offline / on-device intelligence
6. No XP, streaks, or rainbow dashboards

## Multi-agent verdict

| Ship now | Why | Engine |
|---|---|---|
| Lemma map + mark known | LingQ’s actual killer feature | Local |
| Study overlay on the **current sentence** | Gold stays playback; terracotta underlines study | Local |
| Chapter coverage + chapter-word list | Quiet, book-primary | Local |
| Cloze + reverse review faces | Highest-value SRS gap; no LLM | Local |
| Apple Intelligence provider | Existing LLM jobs without a remote server | On-device 3B |

| Later | Why not now |
|---|---|
| Remote libraries / social / XP | Needs servers; violates PRODUCT.md |

Shipped after 1.0.45: full-chapter overlay, snapshot Chapter words sheet, on-device shadowing score, local chapter quiz, quiet study-day log. Still no XP or remote libraries.

## Contract

- Never mark a word known because it played, scrolled, or was paged past.
- Vocabulary occurrence cards stay separate from the lemma map. In-vocab ⇒ **learning**, even if also marked known.
- Apple Intelligence is an official on-device API (both macOS and iPadOS). It is **not** unofficial OAuth. No API key, no endpoint, no vault.
- If Apple Intelligence is off, lookup + overlay + cloze still work.
- ChatGPT-plan stays macOS-only. Apple Intelligence is on both platforms.
- iPad: no extra toolbar owner. Overlay and chapter words live in the existing Reading menu.

## Implementation slices

1. Pure study algorithms + tests
2. Persistence + AppState (lexicon, overlay, review face)
3. Reader / inspector / review UI (shared)
4. Apple Foundation Models provider + tests (no live model in CI)
5. Version 1.0.42 → 1.0.43, rebuild both targets
