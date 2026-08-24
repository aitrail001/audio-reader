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
        settings.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue
        settings.openAIModel = OpenAIModel.gpt56Sol.rawValue
        settings.openAIEffort = OpenAIEffort.high.rawValue

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded.deepReadingMode)
        #expect(decoded.llmProvider == LLMProvider.openAI.rawValue)
        #expect(decoded.openAIAuthentication == OpenAIAuthentication.apiKey.rawValue)
        #expect(decoded.openAIModel == OpenAIModel.gpt56Sol.rawValue)
        #expect(decoded.openAIEffort == OpenAIEffort.high.rawValue)
    }

    @Test("Provider availability is shared while ChatGPT-plan auth is explicitly macOS-only")
    func providerPlatformDifferenceIsExplicit() throws {
        #expect(LLMProvider.allCases == [.grok, .qwenCloud, .openAI])

        let appState = try source("Sources/AudioReader/AppState.swift")
        let settingsView = try source("Sources/AudioReader/SettingsView.swift")
        let codexClient = try source("Sources/AudioReader/CodexCLIClient.swift")

        #expect(appState.contains("settings.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue"))
        #expect(settingsView.contains("ForEach(OpenAIAuthentication.allCases)"))
        #expect(settingsView.contains("Text(\"API key\")"))
        #expect(settingsView.contains("draft.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue"))
        #expect(codexClient.contains("return \"ChatGPT-plan access through Codex is available on macOS only.\""))
        #expect(codexClient.contains("throw LLMError.codexUnavailable"))
    }

    @Test("Shared settings and transcription copy does not present iPad as a Mac")
    func sharedCopyIsPlatformNeutral() throws {
        let settingsView = try source("Sources/AudioReader/SettingsView.swift")
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let transcriber = try source("Sources/AudioReader/Transcriber.swift")
        let settingsBody = try section(
            in: settingsView,
            from: "    var body: some View",
            to: "    private var settingsWidth"
        )
        let dictionarySection = try section(
            in: settingsView,
            from: "    private var dictionarySection",
            to: "    private var languageSection"
        )

        #expect(settingsBody.contains("dictionarySection\n                    languageSection"))
        #expect(!settingsBody.contains("#if os(macOS)\n                    dictionarySection"))
        #expect(dictionarySection.contains("#if os(iOS)"))
        #expect(dictionarySection.contains("Word definitions use the dictionaries installed in iPadOS."))
        #expect(playerView.contains("transcribes the audio on this device"))
        #expect(!playerView.contains("transcribes the audio on your Mac"))
        #expect(transcriber.contains("not available on this device"))
        #expect(!transcriber.contains("not available on this Mac"))
    }

    @Test("Both platforms share EPUB status and the same recovery actions")
    func sharesEbookAlignmentRecovery() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let notice = try section(
            in: playerView,
            from: "    private func ebookAlignmentNotice",
            to: "    private func replaceEbook()"
        )
        let replacement = try section(
            in: playerView,
            from: "    private func replaceEbook()",
            to: "    private var header"
        )

        #expect(notice.contains("EPUB alignment status:"))
        #expect(notice.contains("Button(\"Replace EPUB\")"))
        #expect(notice.contains("Button(\"Use This EPUB Anyway\")"))
        #expect(notice.contains("if state.canUseCurrentEbookAnyway"))
        #expect(!notice.contains("#if os("))
        #expect(replacement.contains("#if os(macOS)"))
        #expect(replacement.contains("showReplaceEbookImporter = true"))
        #expect(playerView.contains(".fileImporter(isPresented: $showReplaceEbookImporter"))
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
