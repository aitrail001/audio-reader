# AudioReader

AudioReader is a macOS and iPadOS study app for language learners. It combines audiobook playback, EPUB reading, multilingual on-device transcription, word-level highlighting, optional EPUB alignment, dictionary lookup, vocabulary capture, a local known/learning map with cloze and reverse review, and contextual assistance from Apple Intelligence, Grok, QwenCloud, or OpenAI.

## What this is for

AudioReader is designed for focused listening and reading rather than passive audiobook playback. It helps you:

- follow the words being spoken and seek by sentence;
- compare the narration with the published text in a companion EPUB;
- look up unfamiliar words and save them with their original sentence, book, chapter, and timestamp;
- mark words known, see coverage for the current chapter, underline unknown or learning words across the chapter, shadow a sentence, and take a local chapter quiz;
- review vocabulary as recognition, cloze, or reverse cards, still using the original narration;
- replay or loop a sentence and return to saved vocabulary in context;
- translate words, sentences, or chapters and ask questions about the current chapter through an optional LLM provider, including on-device Apple Intelligence.

When a book has audio, the transcript is the timing source. Audio narration often contains publisher introductions, omitted footnotes, or wording that differs from the ebook, so AudioReader first transcribes what was actually spoken with Apple SpeechAnalyzer. When an EPUB is present, it then matches sufficiently similar sentences and lets you switch between **Spoken**, **Ebook**, and **Both**. EPUB-only books skip transcription and use the published sentences for reading, lookup, translation, and review until you add audio.

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
- SpeechAnalyzer assets for the selected audiobook language; AudioReader requests their installation on the first transcription
- Optional: Apple Intelligence on this device, or a Grok, QwenCloud, OpenAI API, or ChatGPT plan account and network connection for translation, summaries, and chapter chat

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

On macOS, use **Import** to select audio files, EPUB files, a book folder, or an accessible downloaded title from Apple Books. You can also choose a library folder containing one subfolder per book.

On iPad, use **Import Files** or **Import Folder** to choose audio and/or EPUB resources from Files or iCloud Drive. The **Apple Books & Device** source lists audiobooks exposed through the device media library; EPUBs on iPad are imported through Files.

You can import audio and EPUB together, audio only, or EPUB only. Re-importing the same audio or EPUB does not create a duplicate; it can attach the missing counterpart. From a book you can still **Add EPUB** or **Add Audio** later.

For the best result, keep each book in its own folder:

```text
Book Title/
├── 01 Introduction.mp3
├── 02 First Chapter.mp3
├── book.epub
└── cover.jpg
```

AudioReader copies explicitly imported resources into its own imported-books library. Re-importing the same audio or EPUB does not create a duplicate; it can add a missing EPUB, audio file, or cover to the existing book.

### Transcribe and read

1. In **Settings → Languages**, choose the audiobook's spoken language independently from **Translate into**.
2. Select a book and chapter. For audiobooks, select **Transcribe**. The first run may download the selected language's speech assets. EPUB-only books open the published text immediately.
   If the book has no companion ebook, the reader displays **EPUB ebook missing** at the top. Select **Add EPUB** and choose the matching `.epub` file.
   If the book has no audio, the reader displays **Audiobook missing**. Select **Add Audio** when you want narration.
3. Wait for transcription and optional EPUB validation/alignment to finish. AudioReader checks extraction quality, book metadata, sampled content, match coverage and scores, reading order, and unmatched passages before EPUB wording can replace speech.
4. Play the chapter and use the highlighted transcript to follow, seek, replay, or loop sentences.
5. Choose **Spoken**, **Ebook**, or **Both** when the EPUB and individual sentence matches are trusted. Unreadable, likely-wrong, different-edition, and uncertain EPUBs show the same warning and recovery actions on macOS and iPadOS. **Recheck EPUB** validates an existing transcript again without retranscribing audio; **Replace EPUB** installs another file; and **Use This EPUB Anyway** remains an explicit option after assessment and still permits only strong individual matches.
6. Select a word for dictionary lookup or save it to **Vocabulary**. Use **Open in text** later to return to its source passage.
7. Turn on **Study overlay** in the reader header or **Reading** menu to underline unknown and learning content words throughout the chapter, not only the current sentence. **Chapter words** is a chapter-level list (macOS also has a header button, not only a menu item). **Shadow this sentence** scores on-device speech against the current sentence. **Chapter quiz** is a local cloze and “what comes next” check; it does not add XP, streaks-as-flames, or remote content libraries. Study days are a quiet local calendar count.

Enable **Deep Reading** from the playback controls when you want time to inspect or research each sentence. AudioReader plays the current sentence and pauses while keeping it highlighted. Select **Continue** to advance to and play the next sentence. On iPad, both controls are available in the reader playback bar, and **Command–Return** also continues when using a hardware keyboard. Deep Reading and sentence looping are mutually exclusive.

Transcripts, vocabulary, settings, accepted translations, and chapter-translation checkpoints are stored locally under the platform's AudioReader application-support container. Imported iPad books are stored in the app's Documents directory.

### Configure optional AI assistance

Open **Settings → LLM provider** and choose Apple Intelligence, Grok, QwenCloud, or OpenAI / ChatGPT.

- Apple Intelligence uses the on-device Foundation Models on a compatible Mac or iPad. It needs Apple Intelligence enabled, sends no API key, and does not use the credential vault. The 3B on-device model is best-effort for translation notes; study overlay, coverage, cloze, and mark-known keep working when it is unavailable.

- Grok API mode accepts an `XAI_API_KEY` and defaults to `https://api.x.ai/v1`. On macOS, the separate **Grok Build** authentication tab can use an existing `grok login` session. This is an unofficial integration and may violate xAI's terms; review the linked current terms before using it.
- QwenCloud accepts a `DASHSCOPE_API_KEY` and defaults to `https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`.
- OpenAI API mode accepts an `OPENAI_API_KEY` and defaults to `https://api.openai.com/v1` on macOS and iPadOS. On macOS, the separate **ChatGPT plan** tab can instead reuse an existing Codex **Sign in with ChatGPT** session: install the Codex CLI, run `codex login`, and select that authentication mode in AudioReader. This is an unofficial integration and may violate OpenAI's terms; review the linked current terms before using it. AudioReader prefers the native executable included with Codex installations, so an npm-installed Codex does not require `node` to be present in the Finder app's `PATH`; if only the JavaScript launcher is available, AudioReader adds its sibling Node directory for that process. AudioReader asks Codex to run an ephemeral, read-only, tool-disabled request and never reads or displays its cached OAuth tokens.

All three API endpoints have provider defaults and remain editable in their API settings. Saved API keys are held in an AES-GCM encrypted local vault; only the vault's random wrapping key is stored as a device-only Keychain item and cached for the running app session. AudioReader never writes API keys into its settings JSON or plaintext credential files. Older per-provider Keychain items and plaintext key files are deleted only after the encrypted value has been written and verified. Environment variables remain externally managed and are never copied into app storage.

After configuration, AudioReader can translate a selected word or sentence, translate or summarise a transcribed chapter, and provide chapter-aware chat. Single-sentence and chapter-batch translation use the same structured learning contract: a natural translation plus categorized notes for phrasal verbs, phrases, idioms, challenging words or combinations, and book-specific concepts. Both flows translate the untranslated sentences in the same consecutive chapter chunk; already-translated neighbors stay in the prompt as context. The selected translation language is treated as the reader's mother language, so explanations focus on difficulties relevant to that language.

The chapter-chat composer includes voice input on macOS and iPadOS. Select the microphone, speak, then stop and review or edit the recognized question before sending it. A live waveform beneath the composer shows the local microphone level while AudioReader is listening. Recognition uses Apple's on-device `SpeechAnalyzer` and does not require Siri or keyboard Dictation to be enabled. The first use may download an Apple-managed language asset; microphone audio remains on the device and AudioReader does not save the recording or fall back to network recognition.

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
| Command–Option–S | Toggle study overlay |
| Command–K | Mark the selected word known |
| Command–T | Transcribe the selected chapter |

## Limitations

- **Protected audiobooks cannot be imported or transcribed.** AudioReader can list some downloaded Apple Books titles, but DRM-protected items remain disabled and must be played in Apple Books. It does not remove or bypass DRM.
- **Cloud-only Apple Books titles are unavailable.** Download a title first. Even when downloaded, the operating system must expose an unprotected, accessible asset URL before AudioReader can import it.
- **Apple Books discovery differs by platform.** macOS discovery reads locally downloaded audiobook files; iPad discovery uses the device media library. Validate iPad media access on a physical device because the Simulator has no real Apple Books library.
- **Podcast and publisher-app import is not implemented.** AudioReader currently does not import Apple Podcasts feeds, HBR resources, Economist resources, private RSS feeds, or audio stored inside other apps.
- **Transcription language support depends on Apple and the device.** AudioReader offers English variants, Simplified and Traditional Chinese, Cantonese, Japanese, Korean, Spanish, French, German, Italian, Brazilian Portuguese, and Dutch. If Apple does not provide the selected on-device SpeechAnalyzer locale for the current OS/device, AudioReader reports it as unavailable. Accuracy varies with accents, names, background noise, recording quality, and narration speed.
- **EPUB alignment remains probabilistic.** Document-level validation prevents one incidental sentence from trusting a book and keeps untrusted EPUB wording out of LLM and vocabulary workflows, but speech recognition and edition differences can still leave valid passages unmatched. Reordered or weak matches remain spoken text unless the reader explicitly accepts individually verified matches. MOBI and PDF text extraction are not supported.
- **LLM features are optional.** Apple Intelligence runs on-device when available. Grok, QwenCloud, and OpenAI need valid credentials and network access, may incur provider charges, and can fail because of model availability, account limits, endpoint changes, or unsupported reasoning settings. Text sent to a remote provider is governed by that provider's privacy and usage terms.
- **Provider-managed login integrations are unofficial.** Reusing Grok Build or a ChatGPT-plan Codex session through AudioReader may not be permitted by the provider's current terms. Review the xAI or OpenAI terms linked in Settings before choosing either mode. Supported API-key modes remain available separately.
- **Saved API keys use an encrypted local vault.** Provider keys are AES-GCM encrypted and are not stored as Keychain items, in AudioReader settings, or in plaintext app files. One device-only Keychain item protects the vault's wrapping key. Environment-provided keys remain the responsibility of the environment configuration.
- **ChatGPT-plan access requires an installed, signed-in Codex on macOS.** AudioReader does not bundle Codex or its OAuth credentials. The standalone Codex installer avoids a Node.js dependency, while AudioReader also supports npm installations by selecting their bundled native binary when available. ChatGPT-plan access is distinct from OpenAI API billing and is unavailable on iPadOS; use an OpenAI API key there. Model access and usage limits depend on the signed-in ChatGPT plan.
- **Publisher permissions still apply.** Possessing an accessible audio file or RSS URL does not necessarily grant permission to transcribe, translate, summarise, or otherwise process it. Use AudioReader only with content you are authorized to process.
- **Data is local to each installation.** There is no built-in cross-device library, transcript, vocabulary, or playback-position synchronization.
- **Chapter summaries and chat history are session-only.** They are kept while the app is running but are not restored after relaunch. Accepted vocabulary translations and chapter-translation checkpoints are persisted.
- **Background execution is platform-controlled.** Long transcription or chapter-AI work can be interrupted if the operating system suspends or terminates the app; retained progress is best effort.
- **This is a development build.** It requires current Apple platform tooling and has not been presented as an App Store release.
