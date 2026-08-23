# AudioReader

A macOS and iPadOS audiobook reader for English study: spoken words highlight like lyrics while the audio plays, the page auto-scrolls, and you can save words back to the original sentence.

## Why speech-to-text, not ebook-only

The books in `~/Documents/books` pair chapter MP3s / M4B files with EPUB/MOBI/PDF. Those texts are **not** a 1:1 match with the narration.

A 45-second clip of *The Ride of a Lifetime* (ch. 1) was transcribed on-device with Apple **SpeechAnalyzer** (macOS 26) and compared to the EPUB:

| Source | What you get |
|---|---|
| Audiobook | `This is Audible. Penguin Random House Audio presents…` then the prologue |
| EPUB | Starts at `In June 2016 I made my fortieth trip…` — no publisher intro |
| Wording | Spoken/STT `40th / 18 years / 11th / 6 months` vs ebook `fortieth / eighteen / eleventh / six` |
| Names | STT can misspell (`Eiger` vs `Iger`) |

Forced-alignment of the ebook onto the audio fails as soon as the narrator adds an intro, skips a footnote, or says a number differently. Karaoke highlighting needs timestamps of **what was actually said**.

**Approach used**

1. **Speech-to-text with word timestamps** (Apple SpeechAnalyzer, on-device) is the source of truth for highlighting and seeking.
2. **Ebook alignment** (EPUB sentence matching) is optional enrichment: when a spoken sentence is close enough to a printed sentence, the original wording is attached so you can study the published text.
3. Toggle **Spoken / Ebook / Both** in the player.

This is the same idea as karaoke apps (timestamps from audio) plus a language-learning glossary.

## Features

- Scans a books folder (default `/Users/johnsonzhang/Documents/books`)
- Chaptered MP3s preferred over a single `.m4b`
- Word-level highlight, sentence highlight, auto-scroll
- Play / pause, ±5s, previous/next sentence, replay sentence, sentence loop, 0.7–1.6× speed
- Click a word to look it up in the macOS dictionary
- Save a word with its sentence, book, chapter, and timestamp; jump back later
- Transcripts, vocabulary, and LLM translations stored in SQLite (`~/Library/Application Support/AudioReader/library.sqlite`)
- Select Grok or QwenCloud for word and sentence translations. QwenCloud defaults to `qwen3.7-flash`, discovers models authorized for the configured workspace, falls back to a built-in catalog, and supports thinking and reasoning-effort controls.
- Sentence translation prompts include the book, author, chapter, and a configurable number of preceding and following sentences.
- **Chapter AI** can translate or summarise the complete transcribed chapter and provides a side-panel chat grounded in the book metadata and nearby reading context.
- Vocabulary grouped by book and category (words, phrases, sentences). Each card keeps the Apple Dictionary entry, the original sentence, and any accepted LLM translation. **Open in text** selects the sentence or highlights the word.
- Both apps import individual MP3/M4A/M4B files and audiobook folders, retain companion EPUBs and covers, and use the same EPUB alignment implementation.
- M4B files are inspected for embedded chapter tracks. Chapter titles and time ranges become separate playable and transcribable chapters instead of one full-book chapter.

## Platform parity

| Capability | macOS | iPadOS |
|---|---|---|
| Playback, transcription, highlighting, vocabulary, LLM translation, Chapter AI, and chat | Yes | Yes |
| Import audio/EPUB/cover files | Finder import | Files/iCloud Drive import |
| Import one book folder or a folder containing multiple books | Yes | Yes |
| EPUB extraction and printed-text alignment | Yes | Yes |
| Apple Books/device audiobook discovery | Discovers downloaded MP3/M4A/M4B files in Apple Books’ local audiobook store, with refresh, import, and Open in Books | Direct device-library discovery through `MPMediaQuery` |
| Protected Apple Books titles | Downloaded protected files are shown but disabled; cloud-only titles are not visible until downloaded | Shown but disabled; they cannot be copied or transcribed |
| Dictionary lookup | Installed macOS dictionaries | iPadOS system dictionary sheet |

Platform-specific code should only represent an Apple API or interaction difference; reading and study features remain shared.

## Requirements

- macOS 26+
- iPadOS 26+ for the iPad build
- English speech assets (the app downloads them on first transcribe)

## Build & run

### Xcode and physical iPad

Open `AudioReader.xcodeproj` and choose one of the shared schemes:

- `AudioReader-iOS` for a physical iPad or iPad Simulator.
- `AudioReader-macOS` for the native Mac app.

Both targets use `com.johnsonzhang.AudioReader`. Automatic signing is enabled for the iOS target. Before the first physical-device build, open **AudioReader-iOS → Signing & Capabilities**, select your Apple developer team, connect the iPad, and choose it as the run destination. Xcode will create or download the required development profile.

The existing standalone package builds remain available:

```bash
cd /Users/johnsonzhang/Documents/AI/Dataiku/src/audio-reader
chmod +x scripts/package_app.sh
./scripts/package_app.sh
open AudioReader.app
```

First chapter you play: click **Transcribe**. A 30-minute chapter typically takes a few minutes on Apple Silicon. After that, highlighting is instant.

### iPad Simulator

```bash
cd /Users/johnsonzhang/Documents/AI/Dataiku/src/audio-reader
./scripts/package_ipad_simulator.sh
xcrun simctl install booted AudioReader-iPad.app
xcrun simctl launch booted com.johnsonzhang.AudioReader
```

The Simulator can validate the app and Files/folder import UI, but it has no real Apple Books media library. Validate Apple Books discovery, media permission, and asset accessibility on a physical iPad.

## Keyboard

| Key | Action |
|---|---|
| Space | Play / pause |
| ← / → | Skip 5 seconds |
| ⌥← / ⌥→ | Previous / next sentence |
| ⌘R | Replay sentence |
| ⌘L | Loop sentence |
| ⌘T | Transcribe chapter |
