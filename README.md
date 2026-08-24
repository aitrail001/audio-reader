# AudioReader

AudioReader is a macOS and iPadOS audiobook study app for people learning English. It combines audiobook playback, on-device English transcription, word-level highlighting, optional EPUB alignment, dictionary lookup, vocabulary capture, and contextual assistance from Grok, QwenCloud, or OpenAI.

## What this is for

AudioReader is designed for focused listening and reading rather than passive audiobook playback. It helps you:

- follow the words being spoken and seek by sentence;
- compare the narration with the published text in a companion EPUB;
- look up unfamiliar words and save them with their original sentence, book, chapter, and timestamp;
- replay or loop a sentence and return to saved vocabulary in context;
- translate words, sentences, or chapters and ask questions about the current chapter through an optional LLM provider.

The transcript is the timing source. Audio narration often contains publisher introductions, omitted footnotes, or wording that differs from the ebook, so AudioReader first transcribes what was actually spoken with Apple SpeechAnalyzer. When an EPUB is present, it then matches sufficiently similar sentences and lets you switch between **Spoken**, **Ebook**, and **Both**.

Supported local resources:

| Resource | Supported formats |
|---|---|
| Audio | MP3, M4A, M4B, AAC, WAV, CAF |
| Companion ebook | EPUB |
| Cover image | JPG, JPEG, PNG, WebP |

M4B chapter metadata is detected and exposed as separate playable and transcribable chapters. When a folder contains multiple chapter MP3 files, those files become the chapter list.

## How to use

### Requirements

- macOS 26 or later, or iPadOS 26 or later
- Xcode with the corresponding platform SDK to build the app
- English SpeechAnalyzer assets; AudioReader requests their installation on the first transcription
- Optional: a Grok, QwenCloud, OpenAI API, or ChatGPT plan account and network connection for translation, summaries, and chapter chat

### Build and run on macOS

Open `AudioReader.xcodeproj`, select the **AudioReader-macOS** scheme, and run it. You can also build the standalone app from Terminal:

```bash
cd /Users/johnsonzhang/Documents/AI/Dataiku/src/audio-reader
./scripts/package_app.sh
open AudioReader.app
```

### Build and run on iPad

Open `AudioReader.xcodeproj`, select the **AudioReader-iOS** scheme, choose a physical iPad or iPad Simulator, and run it. For a physical device, select your developer team under **AudioReader-iOS → Signing & Capabilities**.

To package and install the Simulator build from Terminal:

```bash
cd /Users/johnsonzhang/Documents/AI/Dataiku/src/audio-reader
./scripts/package_ipad_simulator.sh
xcrun simctl install booted AudioReader-iPad.app
xcrun simctl launch booted com.johnsonzhang.AudioReader
```

### Import a book

On macOS, use **Import** to select audiobook files, an audiobook folder, or an accessible downloaded title from Apple Books. You can also choose a library folder containing one subfolder per book.

On iPad, use **Import Files** or **Import Folder** to choose resources from Files or iCloud Drive. The **Apple Books & Device** source lists audiobooks exposed through the device media library.

For the best result, keep each book in its own folder:

```text
Book Title/
├── 01 Introduction.mp3
├── 02 First Chapter.mp3
├── book.epub
└── cover.jpg
```

AudioReader copies explicitly imported resources into its own imported-books library. Re-importing the same audio does not create a duplicate; it can add a missing EPUB or cover to the existing book.

### Transcribe and read

1. Select a book and chapter.
2. Select **Transcribe**. The first run may download the English speech assets.
3. Wait for transcription and optional EPUB validation/alignment to finish. AudioReader checks extraction quality, book metadata, sampled content, match coverage and scores, reading order, and unmatched passages before EPUB wording can replace speech.
4. Play the chapter and use the highlighted transcript to follow, seek, replay, or loop sentences.
5. Choose **Spoken**, **Ebook**, or **Both** when the EPUB and individual sentence matches are trusted. Unreadable, likely-wrong, different-edition, and uncertain EPUBs show the same warning and **Replace EPUB** recovery on macOS and iPadOS. **Use This EPUB Anyway** remains an explicit option after assessment and still permits only strong individual matches.
6. Select a word for dictionary lookup or save it to **Vocabulary**. Use **Open in text** later to return to its source passage.

Enable **Deep Reading** from the playback controls when you want time to inspect or research each sentence. AudioReader plays the current sentence and pauses while keeping it highlighted. Select **Continue** to advance to and play the next sentence. On iPad, both controls are available in the reader playback bar, and **Command–Return** also continues when using a hardware keyboard. Deep Reading and sentence looping are mutually exclusive.

Transcripts, vocabulary, settings, accepted translations, and chapter-translation checkpoints are stored locally under the platform's AudioReader application-support container. Imported iPad books are stored in the app's Documents directory.

### Configure optional AI assistance

Open **Settings → LLM provider** and choose Grok, QwenCloud, or OpenAI / ChatGPT.

- Grok accepts an `XAI_API_KEY`; on macOS it can also use an existing Grok Build login.
- QwenCloud accepts a `DASHSCOPE_API_KEY`, an editable endpoint, and a supported text model.
- OpenAI accepts an `OPENAI_API_KEY` on macOS and iPadOS. On macOS, **ChatGPT plan** can instead reuse an existing Codex **Sign in with ChatGPT** session: install the Codex CLI, run `codex login`, and select that authentication mode in AudioReader. AudioReader prefers the native executable included with Codex installations, so an npm-installed Codex does not require `node` to be present in the Finder app's `PATH`; if only the JavaScript launcher is available, AudioReader adds its sibling Node directory for that process. AudioReader asks Codex to run an ephemeral, read-only, tool-disabled request and never reads or displays its cached OAuth tokens.

After configuration, AudioReader can translate a selected word or sentence, translate or summarise a transcribed chapter, and provide chapter-aware chat. Single-sentence and chapter-batch translation use the same structured learning contract: a natural translation plus categorized notes for phrasal verbs, phrases, idioms, challenging words or combinations, and book-specific concepts. The selected translation language is treated as the reader's mother language, so explanations focus on difficulties relevant to that language and use the book plus nearby previous and next sentences as context.

Core reading-assistant prompts and translation results are provider-neutral. Provider-specific code is limited to authentication, request transport, reasoning controls, and structured-output capabilities, making additional providers and models easier to add consistently. These requests send the selected text and configured reading context to the chosen provider; audio transcription itself remains on-device.

### macOS keyboard shortcuts

| Shortcut | Action |
|---|---|
| Space | Play or pause |
| Left / Right arrow | Skip backward or forward |
| Option–Left / Option–Right | Previous or next sentence |
| Command–R | Replay the current sentence |
| Command–L | Toggle sentence loop |
| Command–D | Toggle Deep Reading |
| Command–Return | Continue with the next sentence |
| Command–T | Transcribe the selected chapter |

## Limitations

- **Protected audiobooks cannot be imported or transcribed.** AudioReader can list some downloaded Apple Books titles, but DRM-protected items remain disabled and must be played in Apple Books. It does not remove or bypass DRM.
- **Cloud-only Apple Books titles are unavailable.** Download a title first. Even when downloaded, the operating system must expose an unprotected, accessible asset URL before AudioReader can import it.
- **Apple Books discovery differs by platform.** macOS discovery reads locally downloaded audiobook files; iPad discovery uses the device media library. Validate iPad media access on a physical device because the Simulator has no real Apple Books library.
- **Podcast and publisher-app import is not implemented.** AudioReader currently does not import Apple Podcasts feeds, HBR resources, Economist resources, private RSS feeds, or audio stored inside other apps.
- **Transcription is English-only.** The transcriber requests the `en-US` SpeechAnalyzer locale. Accuracy varies with accents, names, background noise, recording quality, and narration speed.
- **EPUB alignment remains probabilistic.** Document-level validation prevents one incidental sentence from trusting a book and keeps untrusted EPUB wording out of LLM and vocabulary workflows, but speech recognition and edition differences can still leave valid passages unmatched. Reordered or weak matches remain spoken text unless the reader explicitly accepts individually verified matches. MOBI and PDF text extraction are not supported.
- **LLM features are optional external services.** They need valid credentials and network access, may incur provider charges, and can fail because of model availability, account limits, endpoint changes, or unsupported reasoning settings. Text sent to them is governed by the selected provider's privacy and usage terms.
- **Saved API keys are local files, not Keychain entries.** AudioReader restricts their file permissions, but users who require hardware-backed credential storage should supply keys through the environment or avoid saving them in the app.
- **ChatGPT-plan access requires an installed, signed-in Codex on macOS.** AudioReader does not bundle Codex or its OAuth credentials. The standalone Codex installer avoids a Node.js dependency, while AudioReader also supports npm installations by selecting their bundled native binary when available. ChatGPT-plan access is distinct from OpenAI API billing and is unavailable on iPadOS; use an OpenAI API key there. Model access and usage limits depend on the signed-in ChatGPT plan.
- **Publisher permissions still apply.** Possessing an accessible audio file or RSS URL does not necessarily grant permission to transcribe, translate, summarise, or otherwise process it. Use AudioReader only with content you are authorized to process.
- **Data is local to each installation.** There is no built-in cross-device library, transcript, vocabulary, or playback-position synchronization.
- **Chapter summaries and chat history are session-only.** They are kept while the app is running but are not restored after relaunch. Accepted vocabulary translations and chapter-translation checkpoints are persisted.
- **Background execution is platform-controlled.** Long transcription or chapter-AI work can be interrupted if the operating system suspends or terminates the app; retained progress is best effort.
- **This is a development build.** It requires current Apple platform tooling and has not been presented as an App Store release.
