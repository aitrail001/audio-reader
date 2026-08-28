import Foundation
import Testing
@testable import AudioReader

@Suite("macOS and iPadOS feature parity")
struct PlatformParityContractTests {
    @Test("Both app targets compile the same synchronized source tree")
    func bothTargetsShareProductionSources() throws {
        let project = try source("AudioReader.xcodeproj/project.pbxproj")

        #expect(project.components(separatedBy: "fileSystemSynchronizedGroups = (").count - 1 == 2)
        #expect(project.contains("name = \"AudioReader-macOS\";"))
        #expect(project.contains("name = \"AudioReader-iOS\";"))
        #expect(project.components(separatedBy: "100000000000000000000020 /* Sources/AudioReader */,").count - 1 == 3)
        #expect(project.components(separatedBy: "100000000000000000000025 /* Sources/AudioReaderDomain */,").count - 1 == 3)
        #expect(project.components(separatedBy: "100000000000000000000026 /* Sources/AudioReaderLocalStore */,").count - 1 == 3)
        #expect(project.components(separatedBy: "100000000000000000000027 /* Sources/AudioReaderNetworking */,").count - 1 == 3)

        let models = try source("Sources/AudioReader/Models.swift")
        #expect(models.contains("#if canImport(AudioReaderDomain)"))
        #expect(models.contains("@_exported import AudioReaderDomain"))
        #expect(models.contains("#if canImport(AudioReaderLocalStore)"))
        #expect(models.contains("@_exported import AudioReaderLocalStore"))
        #expect(models.contains("#if canImport(AudioReaderNetworking)"))
        #expect(models.contains("@_exported import AudioReaderNetworking"))
        #expect(!project.contains("/* AudioReaderDomain in Frameworks */"))
        #expect(!project.contains("/* AudioReaderLocalStore in Frameworks */"))
        #expect(!project.contains("/* AudioReaderNetworking in Frameworks */"))
    }

    @Test("Vocabulary review cards use one shared workflow on macOS and iPadOS")
    func vocabularyReviewIsShared() throws {
        let vocabularyView = try source("Sources/AudioReader/VocabularyView.swift")
        let reviewSetupView = try source("Sources/AudioReader/VocabularyReviewSetupView.swift")
        let reviewView = try source("Sources/AudioReader/VocabularyReviewView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")
        let macRoot = try source("Sources/AudioReader/RootView.swift")
        let iPadRoot = try source("Sources/AudioReader/IPadRootView.swift")

        #expect(macRoot.contains("VocabularyView(state: state)"))
        #expect(iPadRoot.contains("VocabularyView(state: state)"))
        #expect(vocabularyView.contains(".sheet(item: $reviewRequest)"))
        #expect(vocabularyView.contains("VocabularyReviewSetupView("))
        #expect(vocabularyView.contains("VocabularyReviewView(state: state, entryIDs: request.entryIDs)"))
        #expect(vocabularyView.contains("state.setVocabularyLearnList("))
        #expect(reviewSetupView.contains("VocabReviewScope.book("))
        #expect(reviewSetupView.contains("VocabReviewScope.bookCategory("))
        #expect(reviewSetupView.contains("VocabReviewScope.learnList"))
        #expect(reviewSetupView.contains("VocabReviewScope.learnListBook("))
        #expect(reviewSetupView.contains(".accessibilityLabel("))
        #expect(reviewSetupView.contains(#"\(bookID)::\(category.rawValue)"#))
        #expect(reviewView.contains("Button(\"Show answer\")"))
        #expect(reviewSetupView.contains("Card face"))
        #expect(reviewSetupView.contains("VocabReviewPrompt.allCases"))
        #expect(reviewView.contains("VocabCloze.blankedSentence"))
        #expect(reviewView.contains("VocabReversePrompt.promptText"))
        #expect(reviewView.contains("ForEach(VocabReviewQuality.allCases)"))
        #expect(reviewView.contains("dynamicTypeSize.isAccessibilitySize"))
        #expect(reviewView.contains("reviewCardMinimumHeight"))
        #expect(reviewView.contains("if isRevealed {\n                        back(of: entry)"))
        #expect(reviewView.contains("Next round"))
        #expect(vocabularyView.contains("Label(\"Choose review\""))
        #expect(vocabularyView.contains(".navigationTitle(\"Vocabulary\")"))
        #expect(vocabularyView.contains(".navigationBarTitleDisplayMode(.inline)"))
        #expect(vocabularyView.contains("in learn list"))
        #expect(reviewView.contains("entry.bookTitle"))
        #expect(reviewView.contains("entry.chapterTitle"))
        #expect(vocabularyView.contains("VocabOriginalPlayButton(state: state, entry: entry"))
        #expect(reviewView.contains("VocabOriginalPlayButton(state: state, entry: entry"))
        #expect(appState.contains("func playVocabSentence("))
        #expect(appState.contains("playingVocabEntryID"))
        #expect(appState.contains("func reviewVocabulary("))
        #expect(appState.contains("func setVocabularyLearnList("))
        #expect(appState.contains("quality: VocabReviewQuality"))
        #expect(!reviewSetupView.contains("#if os("))
        #expect(!reviewView.contains("#if os("))
    }

    @Test("Learn-list action shares the vocabulary header with Open in text")
    func vocabularyLearnListActionSharesHeader() throws {
        let vocabularyView = try source("Sources/AudioReader/VocabularyView.swift")
        let cardHeader = try section(
            in: vocabularyView,
            from: "            HStack(alignment: .firstTextBaseline)",
            to: "            Text(\"\\(entry.bookTitle)"
        )

        #expect(cardHeader.contains("Label(\"Open in text\", systemImage: \"text.alignleft\")"))
        #expect(cardHeader.contains("Button(action: onToggleLearnList)"))
        #expect(cardHeader.contains("entry.isInLearnList ? \"In learn list\" : \"Add to learn list\""))
        #expect(vocabularyView.components(separatedBy: "Button(action: onToggleLearnList)").count - 1 == 1)
        #expect(!cardHeader.contains("#if os("))
    }

    @Test("Learn lists remain manageable when no cards are due on both platforms")
    func learnListManagementIsIndependentFromReviewDueState() throws {
        let setupView = try source("Sources/AudioReader/VocabularyReviewSetupView.swift")
        let learnListView = try source("Sources/AudioReader/VocabularyLearnListView.swift")
        let learnListNavigation = try section(
            in: setupView,
            from: "    private func learnListNavigation(",
            to: "\n}"
        )

        #expect(setupView.contains("VocabularyLearnListView("))
        #expect(learnListNavigation.contains("VocabReviewScheduler.scopedEntries"))
        #expect(learnListNavigation.contains(".disabled(scopedEntries.isEmpty)"))
        #expect(!learnListNavigation.contains(".disabled(dueEntries.isEmpty)"))
        #expect(learnListView.contains("Nothing is due for review. Browse or remove items below."))
        #expect(learnListView.contains("state.setVocabularyLearnList(entry.id, included: false)"))
        #expect(learnListView.contains("onReviewDue(dueEntries.map(\\.id))"))
        #expect(!learnListView.contains("#if os("))
    }

    @Test("Deep Reading playback logic remains shared and platform-neutral")
    func deepReadingLogicIsShared() throws {
        let appState = try source("Sources/AudioReader/AppState.swift")
        let sharedLogic = try section(
            in: appState,
            from: "    func setDeepReadingMode(_ enabled: Bool)",
            to: "    func isInVocabulary(word: TranscriptWord)"
        )

        #expect(!sharedLogic.contains("#if os("))
        #expect(sharedLogic.contains("func setSentenceLoop(_ enabled: Bool)"))
        #expect(sharedLogic.contains("func continueDeepReading()"))
        #expect(sharedLogic.contains("func tickPlaybackModes()"))
        #expect(sharedLogic.contains("func resetDeepReadingAfterSeek()"))
    }

    @Test("Both platforms expose Deep Reading and a continue action")
    func bothPlatformsExposeDeepReadingControls() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let app = try source("Sources/AudioReader/AudioReaderApp.swift")

        #expect(playerView.components(separatedBy: "Toggle(isOn: deepReadingBinding)").count - 1 == 2)
        #expect(playerView.components(separatedBy: "Button { state.continueDeepReading() }").count - 1 == 2)
        #expect(playerView.contains(".accessibilityLabel(\"Deep Reading\")"))
        #expect(playerView.contains(".accessibilityLabel(\"Continue with next sentence\")"))
        #expect(playerView.contains(".keyboardShortcut(.return, modifiers: [.command])"))

        #expect(app.contains("Toggle(\"Deep Reading\""))
        #expect(app.contains(".keyboardShortcut(\"d\", modifiers: [.command])"))
        #expect(app.contains("Button(\"Continue with next sentence\") { state.continueDeepReading() }"))
        #expect(app.contains(".keyboardShortcut(.return, modifiers: [.command])"))
    }

    @MainActor
    @Test("Deep Reading and sentence loop stay mutually exclusive")
    func readingModesStayMutuallyExclusive() {
        let state = AppState()

        state.setSentenceLoop(true)
        state.setDeepReadingMode(true)
        #expect(state.settings.deepReadingMode)
        #expect(!state.loopSentence)

        state.setSentenceLoop(true)
        #expect(!state.settings.deepReadingMode)
        #expect(state.loopSentence)
    }

    @MainActor
    @Test("Seeking clears a Deep Reading pause and arms the new sentence on playback")
    func seekingResetsDeepReadingState() {
        let state = deepReadingState()
        state.settings.deepReadingMode = true
        state.player.currentTime = 0.5
        state.player.isPlaying = true
        state.tickPlaybackModes()
        state.player.currentTime = 2.01
        state.tickPlaybackModes()
        #expect(state.deepReadingPausedSentenceID == "first")

        state.seekPlayback(to: 2.5)
        #expect(state.deepReadingPausedSentenceID == nil)
        #expect(state.deepReadingActiveSentenceID == nil)

        state.player.isPlaying = true
        state.tickPlaybackModes()
        #expect(state.deepReadingActiveSentenceID == "second")
    }

    @Test("Deep Reading and provider settings round trip through the shared schema")
    func sharedSettingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.deepReadingMode = true
        settings.llmProvider = LLMProvider.openAI.rawValue
        settings.grokAuthentication = GrokAuthentication.apiKey.rawValue
        settings.grokEndpoint = "https://grok.example/v1"
        settings.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue
        settings.openAIEndpoint = "https://openai.example/v1"
        settings.openAIModel = OpenAIModel.gpt56Sol.rawValue
        settings.openAIEffort = OpenAIEffort.high.rawValue

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded.deepReadingMode)
        #expect(decoded.llmProvider == LLMProvider.openAI.rawValue)
        #expect(decoded.grokAuthentication == GrokAuthentication.apiKey.rawValue)
        #expect(decoded.grokEndpoint == "https://grok.example/v1")
        #expect(decoded.openAIAuthentication == OpenAIAuthentication.apiKey.rawValue)
        #expect(decoded.openAIEndpoint == "https://openai.example/v1")
        #expect(decoded.openAIModel == OpenAIModel.gpt56Sol.rawValue)
        #expect(decoded.openAIEffort == OpenAIEffort.high.rawValue)
    }

    @Test("Provider availability is shared while ChatGPT-plan auth is explicitly macOS-only")
    func providerPlatformDifferenceIsExplicit() throws {
        #expect(LLMProvider.allCases == [.managedQwen, .grok, .qwenCloud, .openAI, .appleFoundation])

        let appState = try source("Sources/AudioReader/AppState.swift")
        let settingsView = try source("Sources/AudioReader/SettingsView.swift")
        let codexClient = try source("Sources/AudioReader/CodexCLIClient.swift")

        #expect(appState.contains("settings.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue"))
        #expect(settingsView.contains("ForEach(OpenAIAuthentication.allCases)"))
        #expect(settingsView.contains("ForEach(GrokAuthentication.allCases)"))
        #expect(settingsView.contains("Text(\"API key\")"))
        #expect(settingsView.contains("draft.grokAuthentication = GrokAuthentication.apiKey.rawValue"))
        #expect(settingsView.contains("draft.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue"))
        #expect(settingsView.contains("Using a Grok Build sign-in through AudioReader may violate xAI's terms"))
        #expect(settingsView.contains("Using a ChatGPT-plan Codex session through AudioReader may violate OpenAI's terms"))
        #expect(settingsView.contains("value: $draft.grokEndpoint"))
        #expect(settingsView.contains("value: $draft.openAIEndpoint"))
        #expect(settingsView.contains("managedQwenSettings"))
        #expect(settingsView.contains("Uses the signed-in AudioReader account"))
        #expect(settingsView.contains("case .managedQwen:"))
        #expect(try source("Sources/AudioReader/GrokClient.swift").contains("Managed Qwen (account)"))
        #expect(codexClient.contains("return \"ChatGPT-plan access through Codex is available on macOS only.\""))
        #expect(codexClient.contains("throw LLMError.codexUnavailable"))
        #expect(settingsView.contains("appleFoundationSettings"))
        #expect(!settingsView.contains("Using an Apple Intelligence"))
        #expect(!appState.contains("#if os(macOS)\n        case .appleFoundation"))
        #expect(LLMConnectionChoice.appleFoundation.menuLabel.contains("Apple Intelligence"))
    }

    @Test("API credentials use an encrypted vault and never settings JSON or plaintext files")
    func providerCredentialsUseEncryptedVault() throws {
        let package = try source("Package.swift")
        let credentials = try source("Sources/AudioReader/SecureCredentialStore.swift")
        let client = try source("Sources/AudioReader/GrokClient.swift")
        let settings = try source("Sources/AudioReader/SettingsView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")
        let appStateBootSection = try section(
            in: appState,
            from: "    func boot() async",
            to: "    func migrateLegacyProviderCredentials()"
        )

        #expect(package.contains(".linkedFramework(\"Security\")"))
        #expect(credentials.contains("AES.GCM.seal"))
        #expect(credentials.contains("AES.GCM.open"))
        #expect(credentials.contains("llm-credentials.vault"))
        #expect(credentials.contains("credential-vault.key"))
        #expect(credentials.contains("FileCredentialVaultKeyProvider"))
        #expect(!credentials.contains("deleteLegacyKeychainKey"))
        #expect(!credentials.contains("readLegacyKeychainKey"))
        #expect(!credentials.contains("credential-vault-wrapping-key"))
        #expect(credentials.contains("private var cachedError: CredentialVaultKeyError?"))
        #expect(credentials.contains("if let cachedError { throw cachedError }"))
        #expect(!credentials.contains("kSecUseAuthenticationUIFail"))
        #expect(credentials.contains("LegacyVaultCredentialMigration"))
        #expect(credentials.contains("interactionNotAllowed = true"))
        #expect(credentials.contains(".posixPermissions"))
        #expect(credentials.contains(".protectionKey"))
        #expect(!credentials.contains("KeychainCredentialVaultKeyProvider"))
        #expect(!appStateBootSection.contains("refreshGrokModels"))
        #expect(!appStateBootSection.contains("refreshQwenModels"))
        #expect(!appStateBootSection.contains("refreshOpenAIModels"))
        #expect(!client.contains("Data(trimmed.utf8).write(to: fileURL"))
        #expect(!settings.contains("State(initialValue: state.apiKeyDraft)"))
        #expect(!settings.contains("State(initialValue: state.qwenAPIKeyDraft)"))
        #expect(!settings.contains("State(initialValue: state.openAIAPIKeyDraft)"))
    }

    @Test("xAI and OpenAI API settings expose model discovery on both platforms")
    func apiProvidersExposeModelDiscovery() throws {
        let settings = try source("Sources/AudioReader/SettingsView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")

        #expect(settings.contains("Retrieve xAI Models"))
        #expect(settings.contains("Retrieve OpenAI Models"))
        #expect(settings.contains("isLoadingGrokModels"))
        #expect(settings.contains("isLoadingOpenAIModels"))
        #expect(appState.contains("retrieveGrokModels"))
        #expect(appState.contains("retrieveOpenAIModels"))
    }

    @Test("Settings is a first-class page on macOS and iPadOS")
    func settingsIsAFirstClassPage() throws {
        let settingsView = try source("Sources/AudioReader/SettingsView.swift")
        let macRoot = try source("Sources/AudioReader/RootView.swift")
        let iPadRoot = try source("Sources/AudioReader/IPadRootView.swift")
        let models = try source("Sources/AudioReader/Models.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")

        #expect(models.contains("case settings = \"Settings\""))
        #expect(settingsView.contains(".navigationTitle(\"Settings\")"))
        #expect(settingsView.contains(".formStyle(.grouped)"))
        #expect(settingsView.contains("scrollContentBackground(.hidden)"))
        #expect(settingsView.contains("listRowBackground(Palette.panel)"))
        #expect(settingsView.contains("Save Settings"))
        #expect(settingsView.contains(".accessibilityLabel(\"Save settings\")"))
        #expect(!settingsView.contains("state.showSettings = false"))
        #expect(!settingsView.contains(".frame(width: settingsWidth"))
        #expect(!macRoot.contains(".sheet(isPresented: $state.showSettings)"))
        #expect(!iPadRoot.contains(".sheet(isPresented: $state.showSettings)"))
        #expect(macRoot.contains("case .settings:"))
        #expect(iPadRoot.contains("case .settings:"))
        #expect(iPadRoot.contains("sourceRow(.settings)"))
        #expect(iPadRoot.contains("private var settingsSplit"))
        #expect(iPadRoot.contains("private var librarySplit"))
        #expect(iPadRoot.contains(".navigationSplitViewStyle(.automatic)"))
        #expect(settingsView.contains("navigationBarBackButtonHidden(true)"))
        #expect(appState.contains("func presentSettings()"))
        #expect(appState.contains("tab = .settings"))
        #expect(appState.contains("AUDIOREADER_OPEN_SETTINGS"))
        #expect(!appState.contains("showSettings = true"))
    }

    @Test("Shared settings and transcription copy does not present iPad as a Mac")
    func sharedCopyIsPlatformNeutral() throws {
        let settingsView = try source("Sources/AudioReader/SettingsView.swift")
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let transcriber = try source("Sources/AudioReader/Transcriber.swift")
        let settingsBody = try section(
            in: settingsView,
            from: "    var body: some View",
            to: "    private var accountSection"
        )
        let dictionarySection = try section(
            in: settingsView,
            from: "    private var dictionarySection",
            to: "    private var languageSection"
        )

        #expect(settingsBody.contains("dictionarySection\n            languageSection"))
        #expect(!settingsBody.contains("#if os(macOS)\n                    dictionarySection"))
        #expect(dictionarySection.contains("#if os(iOS)"))
        #expect(dictionarySection.contains("Word definitions use the dictionaries installed in iPadOS."))
        #expect(playerView.contains("transcribes the audio on this device"))
        #expect(!playerView.contains("transcribes the audio on your Mac"))
        #expect(transcriber.contains("not available on this device"))
        #expect(!transcriber.contains("not available on this Mac"))
    }

    @Test("Reader identity uses the native title without consuming reading height")
    func readerIdentityUsesNativeTitle() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let desktopHeader = try section(
            in: playerView,
            from: "    private var desktopHeader",
            to: "    private var sentenceLoopBinding"
        )

        #expect(playerView.contains(".navigationTitle(readerNavigationTitle)"))
        #expect(playerView.contains("private var readerNavigationTitle: String"))
        #expect(playerView.contains("ReaderWindowTitle.make("))
        #expect(!playerView.contains("chapterCoverageCaption"))
        #expect(!playerView.contains(".navigationSubtitle"))
        #expect(!desktopHeader.contains("state.selectedBook?.title"))
        #expect(!desktopHeader.contains("state.selectedChapter?.title"))
        #expect(desktopHeader.contains("ViewThatFits(in: .horizontal)"))
        #expect(desktopHeader.contains("desktopExpandedHeaderControls"))
        #expect(desktopHeader.contains("desktopCompactHeaderControls"))
    }

    @Test("Reader option and playback bars have compact single-row fallbacks")
    func readerChromeAdaptsToNarrowWindows() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let controls = try section(
            in: playerView,
            from: "    var body: some View",
            to: "    private var ebookMissingNotice"
        )
        let iPadPlayback = try section(
            in: playerView,
            from: "    private var iPadCompactPlaybackBar",
            to: "#endif\n}"
        )

        #expect(playerView.components(separatedBy: "ViewThatFits(in: .horizontal)").count - 1 >= 2)
        #expect(playerView.contains("private var sharedLLMMenu: some View"))
        #expect(playerView.contains("private var sharedReadingMenu: some View"))
        #expect(playerView.components(separatedBy: "sharedLLMMenu").count - 1 >= 3)
        #expect(playerView.components(separatedBy: "sharedReadingMenu").count - 1 >= 3)
        #expect(playerView.contains("private var iPadReaderToolbar"))
        #expect(controls.contains("desktopExpandedPlaybackControls"))
        #expect(controls.contains("desktopCompactPlaybackControls"))
        #expect(controls.contains("iPadCompactPlaybackBar"))
        #expect(!iPadPlayback.contains("VStack(spacing: 6)"))
        #expect(playerView.contains("chapterPositionLabel(in: chapters)"))
        #expect(playerView.contains(".help(state.selectedChapter?.title ?? \"Choose a chapter\")"))
    }

    @Test("All AI reading surfaces share compact structured typography on both platforms")
    func aiContentTypographyAndReaderScaleAreShared() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let settingsView = try source("Sources/AudioReader/SettingsView.swift")
        let theme = try source("Sources/AudioReader/Theme.swift")

        #expect(playerView.contains("ChapterSummaryView(summary: summary.summary)"))
        #expect(playerView.contains("GlossBody(text: translation, size: assistantBodySize)"))
        #expect(playerView.contains("GlossBody(text: message.text, size: assistantBodySize)"))
        #expect(playerView.contains("section.kind == .sentenceMeaning"))
        #expect(playerView.contains("ExampleRow(example: example"))
        #expect(theme.contains("enum AssistantTypography"))
        #expect(theme.contains("static let minimumBodySize: CGFloat = 11"))
        #expect(theme.contains("static let maximumBodySize: CGFloat = 15"))
        #expect(playerView.contains("@ScaledMetric(relativeTo: .body)"))
        #expect(settingsView.contains("in: 0.65...1.6"))
        #expect(playerView.contains("max(0.65,"))
        #expect(!playerView.contains("#if os(macOS)\nstruct GlossBody"))
    }

    @Test("AI prose and vocabulary dictionary summaries use the available width on both platforms")
    func assistantAndDictionaryContentAreResponsive() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let vocabularyView = try source("Sources/AudioReader/VocabularyView.swift")
        let reviewView = try source("Sources/AudioReader/VocabularyReviewView.swift")
        let dictionarySummaryView = try source("Sources/AudioReader/DictionarySummaryView.swift")

        #expect(playerView.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(!playerView.contains("AssistantTypography.maximumLineWidth"))
        #expect(vocabularyView.contains("DictionarySummaryView(lines: dictionarySummary)"))
        #expect(reviewView.contains("DictionarySummaryView(lines: dictionarySummary(for: entry))"))
        #expect(dictionarySummaryView.contains("ForEach(Array(lines.enumerated())"))
        #expect(dictionarySummaryView.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(!dictionarySummaryView.contains("#if os("))
    }

    @Test("Both platforms share the selected audiobook language end to end")
    func sharesAudiobookLanguage() throws {
        let settingsView = try source("Sources/AudioReader/SettingsView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")
        let transcriber = try source("Sources/AudioReader/Transcriber.swift")
        let macLibrary = try source("Sources/AudioReader/LibraryView.swift")
        let iPadLibrary = try source("Sources/AudioReader/IPadRootView.swift")
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let mismatchNotice = try section(
            in: playerView,
            from: "    private func transcriptionLanguageNotice",
            to: "    private func ebookAlignmentNotice"
        )

        #expect(settingsView.contains("ForEach(TranscriptionLanguage.allCases)"))
        #expect(settingsView.contains("selection: $draft.transcriptionLanguage"))
        #expect(settingsView.contains("Default audiobook language"))
        #expect(settingsView.contains("Reader level"))
        #expect(appState.contains("language: audiobookLanguage(for: book)"))
        #expect(appState.contains("settings.bookTranscriptionLanguages[book.id]"))
        #expect(transcriber.contains("language: TranscriptionLanguage"))
        #expect(!transcriber.contains("Locale(identifier: \"en-US\")"))
        #expect(macLibrary.contains("AudiobookLanguagePicker(state: state, book: book)"))
        #expect(iPadLibrary.contains("AudiobookLanguagePicker(state: state, book: book)"))
        #expect(playerView.contains("transcriptionLanguageNotice(mismatch)"))
        #expect(!mismatchNotice.contains("#if os("))
    }

    @Test("Both app targets package one provider-neutral prompt catalog")
    func sharesExternalPromptCatalog() throws {
        let package = try source("Package.swift")
        let project = try source("AudioReader.xcodeproj/project.pbxproj")
        let packaging = try source("scripts/package_app.sh")
        let promptSource = try source("Sources/AudioReader/ReadingAssistantPrompt.swift")

        #expect(package.contains(".process(\"Resources\")"))
        #expect(project.components(separatedBy: "Sources/AudioReader").count - 1 >= 3)
        #expect(packaging.contains("AudioReader_AudioReader.bundle"))
        #expect(promptSource.contains("PromptTemplateCatalog.shared"))
        #expect(!promptSource.contains("You are a literary translator"))
    }

    @Test("Retranslation confirmation and loading are shared across both platforms")
    func sharesRetranslationFeedback() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let sentenceTranslation = try section(
            in: playerView,
            from: "    private var translationBlock: some View",
            to: "\n}\n\nprivate struct WordToken"
        )
        let wordInspector = try section(
            in: playerView,
            from: "                        inspectorCard(title: \"In this sentence\")",
            to: "                    }\n                    .padding"
        )
        let activeIndex = try #require(wordInspector.range(of: "if state.isLLMJobActive")?.lowerBound)
        let glossIndex = try #require(wordInspector.range(of: "if let gloss")?.lowerBound)

        #expect(playerView.contains("Retranslate this sentence?"))
        #expect(playerView.contains("Retranslate this word or phrase?"))
        #expect(playerView.contains("Retranslate the whole chapter?"))
        #expect(sentenceTranslation.contains("if isTranslating {"))
        #expect(!sentenceTranslation.contains("if isTranslating && gloss == nil"))
        #expect(activeIndex < glossIndex)
        #expect(!playerView.contains("#if os(macOS)\n            .confirmationDialog"))
    }

    @Test("Top reader controls expose authentication-specific AI connections")
    func topReaderControlsExposeConnections() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")

        #expect(playerView.contains("Picker(\"Connection\", selection: llmConnectionBinding)"))
        #expect(playerView.contains("ForEach(LLMConnectionChoice.availableOnCurrentPlatform)"))
        #expect(playerView.contains("state.selectedLLMConnection.compactLabel"))
        #expect(appState.contains("var selectedLLMConnection: LLMConnectionChoice"))
        #expect(!playerView.contains("Picker(\"Provider\", selection: $state.settings.llmProvider)"))
    }

    @Test("Chapter summary drafts share review, persistence, and background-job behavior")
    func chapterSummaryReviewIsShared() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")
        let persistence = try source("Sources/AudioReader/Persistence.swift")

        #expect(playerView.contains("ChapterSummaryView(summary: summary.summary)"))
        #expect(playerView.contains("Button(\"Accept\") { state.acceptChapterSummary() }"))
        #expect(playerView.contains("Button(\"Reject\") { state.rejectChapterSummary() }"))
        #expect(playerView.contains("Button(\"Regenerate\")"))
        #expect(appState.contains("var chapterSummary: ChapterSummaryRecord?"))
        #expect(appState.contains("Persistence.loadChapterSummaries()"))
        #expect(appState.contains("Persistence.saveChapterSummaries(chapterSummaries)"))
        #expect(appState.contains("kind: .chapterSummary"))
        #expect(persistence.contains("chapter-summaries.json"))
        #expect(!playerView.contains("#if os(macOS)\n                    if let summary = state.chapterSummary"))
    }

    @Test("Word translation actions stay on one shared row")
    func wordTranslationActionsShareOneRow() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let pendingActions = try section(
            in: playerView,
            from: "                                    HStack(spacing: 10) {",
            to: "                                } else if gloss.status == .accepted"
        )

        #expect(pendingActions.contains("Button(\"Accept\")"))
        #expect(pendingActions.contains("Button(\"Reject\")"))
        #expect(pendingActions.contains("Button(\"Retranslate\")"))
        #expect(!pendingActions.contains("#if os("))
    }

    @Test("Chapter summaries use one structured presentation on both platforms")
    func sharesStructuredChapterSummaryPresentation() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")
        let prompt = try source("Sources/AudioReader/Resources/ReadingAssistantPrompts.json")
        let summaryPrompt = ReadingAssistantPrompt.chapterSummary(language: .ko)

        #expect(playerView.contains("ChapterSummaryView(summary: summary.summary)"))
        #expect(playerView.contains("private struct ChapterSummaryView: View"))
        #expect(appState.contains("var chapterSummary: ChapterSummaryRecord?"))
        #expect(appState.contains("ChapterSummaryPresentation.parse(summary)"))
        #expect(prompt.contains("\\\"keyConcepts\\\""))
        #expect(!summaryPrompt.localizedCaseInsensitiveContains("phrasal verbs"))
        #expect(!summaryPrompt.localizedCaseInsensitiveContains("idioms"))
    }

    @Test("Both platforms share EPUB status and the same recovery actions")
    func sharesEbookAlignmentRecovery() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let body = try section(
            in: playerView,
            from: "    var body: some View",
            to: "    private var ebookMissingNotice"
        )
        let missingNotice = try section(
            in: playerView,
            from: "    private var ebookMissingNotice",
            to: "    private func ebookAlignmentNotice"
        )
        let notice = try section(
            in: playerView,
            from: "    private func ebookAlignmentNotice",
            to: "    private func addOrReplaceEbook()"
        )
        let replacement = try section(
            in: playerView,
            from: "    private func addOrReplaceEbook()",
            to: "    private var header"
        )

        #expect(body.contains("if state.currentBookIsMissingEbook"))
        #expect(body.contains("ebookMissingNotice"))
        #expect(missingNotice.contains("Text(\"EPUB ebook missing\")"))
        #expect(missingNotice.contains("Add a companion EPUB to compare the published text with the audiobook and enable synchronized ebook reading."))
        #expect(missingNotice.contains("Button(\"Add EPUB\") { addOrReplaceEbook() }"))
        #expect(missingNotice.contains("accessibilityLabel(\"EPUB ebook missing. Add EPUB\")"))
        #expect(!missingNotice.contains("#if os("))
        #expect(notice.contains("EPUB alignment status:"))
        #expect(notice.contains("Button(\"Replace EPUB\") { addOrReplaceEbook() }"))
        #expect(notice.contains("Button(\"Recheck EPUB\")"))
        #expect(notice.contains("Button(\"Use This EPUB Anyway\")"))
        #expect(notice.contains("if state.canUseCurrentEbookAnyway"))
        #expect(!notice.contains("#if os("))
        #expect(replacement.contains("#if os(macOS)"))
        #expect(replacement.contains("showReplaceEbookImporter = true"))
        #expect(playerView.contains(".fileImporter(isPresented: $showReplaceEbookImporter"))
    }

    @Test("Chapter chat dictation is shared and remains on device")
    func sharesOnDeviceChapterChatDictation() throws {
        let dictation = try source("Sources/AudioReader/ChapterChatDictation.swift")
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let interaction = try source("Sources/AudioReader/MainThreadInteraction.swift")
        let macPlist = try source("Xcode/Info-macOS.plist")
        let iPadPlist = try source("Xcode/Info-iOS.plist")

        #expect(dictation.contains("SpeechAnalyzer"))
        #expect(dictation.contains("SpeechTranscriber"))
        #expect(dictation.contains("DictationTranscriber"))
        #expect(dictation.contains("AssetInventory.assetInstallationRequest"))
        #expect(dictation.contains("actor SpeechAssetSupport"))
        #expect(dictation.contains("Apple on-device speech recognition is not available"))
        #expect(dictation.contains("ChapterChatAudioTap.install("))
        #expect(dictation.contains("levelContinuation.yield(ChapterChatVoiceLevel.normalized(buffer))"))
        let session = try section(
            in: dictation,
            from: "@MainActor\nfinal class ChapterChatDictation",
            to: "private func completeFinalization"
        )
        #expect(!dictation.contains("@Observable\nfinal class ChapterChatDictation"))
        #expect(dictation.contains("@MainActor\nfinal class ChapterChatDictation"))
        #expect(dictation.contains("struct VoiceCaptureStatus"))
        #expect(!session.contains(".installTap("))
        #expect(!session.contains("downloadAndInstall()"))
        #expect(session.contains("SpeechAssetSupport.shared.installIfNeeded"))
        #expect(!dictation.contains("SFSpeechRecognizer"))
        #expect(!dictation.contains("requiresOnDeviceRecognition"))
        #expect(playerView.contains("PlatformTap("))
        #expect(playerView.contains("action: toggleDictation"))
        #expect(!playerView.contains("Button(action: toggleDictation)"))
        #expect(playerView.contains("MainActorAction { onSeek(word.start) }"))
        #expect(!interaction.contains("@unchecked Sendable"))
        #expect(!interaction.contains("nonisolated(unsafe)"))
        #expect(playerView.contains("\"Stop voice input\""))
        #expect(playerView.contains("\"Start voice input\""))
        #expect(playerView.contains("Text(\"Listening on device…\")"))
        #expect(playerView.contains("ChapterChatVoiceWaveform(levels: voice.audioLevels)"))
        #expect(playerView.contains("accessibilityLabel(\"Voice input is listening\")"))
        #expect(!playerView.contains("#if os(macOS)\n                            ChapterChatVoiceWaveform"))
        #expect(!playerView.contains("#if os(macOS)\n                            Button(action: toggleDictation)"))
        #expect(macPlist.contains("NSMicrophoneUsageDescription"))
        #expect(iPadPlist.contains("NSMicrophoneUsageDescription"))
        #expect(!macPlist.contains("SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE"))
        #expect(!iPadPlist.contains("SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func section(in source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    @MainActor
    private func deepReadingState() -> AppState {
        let segments = [
            TranscriptSegment(
                id: "first",
                start: 0,
                end: 2,
                words: [TranscriptWord(id: "first-word", text: "First.", start: 0, end: 2, confidence: nil)],
                ebookText: nil,
                alignmentScore: nil
            ),
            TranscriptSegment(
                id: "second",
                start: 2,
                end: 4,
                words: [TranscriptWord(id: "second-word", text: "Second.", start: 2, end: 4, confidence: nil)],
                ebookText: nil,
                alignmentScore: nil
            )
        ]
        let state = AppState()
        state.transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/deep-reading-parity.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: segments,
            source: "test",
            ebookAligned: false
        )
        return state
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
