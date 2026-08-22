# AudioReader

A macOS audiobook reader for English study: spoken words highlight like lyrics while the audio plays, the page auto-scrolls, and you can save words back to the original sentence.

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
- Transcripts, vocabulary, and Grok translations stored in SQLite (`~/Library/Application Support/AudioReader/library.sqlite`)
- Vocabulary grouped by book and category (words, phrases, sentences). Each card keeps the Apple Dictionary entry, the original sentence, and any accepted Grok translation. **Open in text** selects the sentence or highlights the word.

## Requirements

- macOS 26+
- English speech assets (the app downloads them on first transcribe)

## Build & run

```bash
cd /Users/johnsonzhang/Documents/AI/Dataiku/src/audio-reader
chmod +x scripts/package_app.sh
./scripts/package_app.sh
open AudioReader.app
```

First chapter you play: click **Transcribe**. A 30-minute chapter typically takes a few minutes on Apple Silicon. After that, highlighting is instant.

## Keyboard

| Key | Action |
|---|---|
| Space | Play / pause |
| ← / → | Skip 5 seconds |
| ⌥← / ⌥→ | Previous / next sentence |
| ⌘R | Replay sentence |
| ⌘L | Loop sentence |
| ⌘T | Transcribe chapter |
