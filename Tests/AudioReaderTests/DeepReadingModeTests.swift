import Foundation
import Testing
@testable import AudioReader

@MainActor
@Suite("Deep Reading mode")
struct DeepReadingModeTests {
    @Test("Sentence-paced modes default off and migrate existing settings")
    func migratesExistingSettings() throws {
        #expect(AppSettings.default.deepReadingMode == false)
        #expect(AppSettings.default.readAndPauseMode == false)

        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "deepReadingMode")
        object.removeValue(forKey: "readAndPauseMode")

        let migrated = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(migrated.deepReadingMode == false)
        #expect(migrated.readAndPauseMode == false)
    }

    @Test("Read and Pause uses the same sentence boundary while keeping Listen First off")
    func readAndPauseUsesSentenceBoundary() {
        let state = makeState()
        state.setReadAndPauseMode(true)
        state.player.currentTime = 0.5
        state.player.isPlaying = true

        state.tickPlaybackModes()
        state.player.currentTime = 2.06
        state.tickPlaybackModes()

        #expect(state.player.isPlaying == false)
        #expect(state.deepReadingPausedSentenceID == "first")
        #expect(state.settings.readAndPauseMode)
        #expect(!state.settings.deepReadingMode)
    }

    @Test("Listen First and Read and Pause are mutually exclusive")
    func sentencePacedModesStayMutuallyExclusive() {
        let state = makeState()

        state.setDeepReadingMode(true)
        state.setReadAndPauseMode(true)
        #expect(!state.settings.deepReadingMode)
        #expect(state.settings.readAndPauseMode)

        state.setDeepReadingMode(true)
        #expect(state.settings.deepReadingMode)
        #expect(!state.settings.readAndPauseMode)
    }

    @Test("Read and Pause persists and normalizes impossible dual-mode settings")
    func readAndPausePersistence() throws {
        var settings = AppSettings.default
        settings.readAndPauseMode = true
        var restored = AppSettings.default
        restored.apply(StoredSettings(settings))
        #expect(restored.readAndPauseMode)
        #expect(!restored.deepReadingMode)

        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["deepReadingMode"] = true
        object["readAndPauseMode"] = true
        let normalized = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(normalized.deepReadingMode)
        #expect(!normalized.readAndPauseMode)
    }

    @Test("Play replays the final sentence after a paced pause")
    func playReplaysFinalPausedSentence() {
        let state = makeState()
        state.setReadAndPauseMode(true)
        state.player.currentTime = 2.5
        state.player.isPlaying = true
        state.tickPlaybackModes()
        state.player.currentTime = 4.06
        state.tickPlaybackModes()
        #expect(state.deepReadingPausedSentenceID == "second")
        #expect(!state.canContinueDeepReading)

        state.togglePlay()

        #expect(state.player.currentTime == 2.0)
        #expect(state.deepReadingActiveSentenceID == "second")
    }

    @Test("Playback pauses at the sentence that was armed")
    func pausesAtArmedSentenceBoundary() {
        let state = makeState()
        state.settings.deepReadingMode = true
        state.player.currentTime = 0.5
        state.player.isPlaying = true

        state.tickPlaybackModes()
        #expect(state.deepReadingActiveSentenceID == "first")

        state.player.currentTime = 2.06
        state.tickPlaybackModes()

        #expect(state.player.isPlaying == false)
        #expect(state.deepReadingPausedSentenceID == "first")
        #expect(state.currentSegment?.id == "first")
    }

    @Test("A paced pause reveals the audio sentence instead of an inspected sentence")
    func pacedPauseRevealsCurrentAudioSentence() {
        let state = makeState()
        state.settings.readAndPauseMode = true
        state.focusedSegmentID = "second"
        state.selectedWord = state.presentedTranscript?.segments[1].words.first
        state.scrollSegmentID = "second"
        let previousReveal = state.revealToken
        state.player.currentTime = 0.5
        state.player.isPlaying = true

        state.tickPlaybackModes()
        state.player.currentTime = 2.06
        state.tickPlaybackModes()

        #expect(state.deepReadingPausedSentenceID == "first")
        #expect(state.scrollSegmentID == "first")
        #expect(state.revealToken == previousReveal + 1)
        #expect(state.focusedSegmentID == "second")
        #expect(state.selectedWord?.id == "second-word")
        #expect(state.selectedWordContextSegment?.id == "second")
    }

    @Test("Original-text lookup keeps its own sentence and meaning while audio highlights another")
    func originalTextLookupKeepsExactSentenceContext() throws {
        let state = makeState()
        var second = try #require(state.transcript?.segments[1])
        second.ebookText = "Civilization grew beside the river."
        second.individualEbookMatchTrusted = true
        second.documentEbookUseAllowed = true
        state.transcript?.segments[1] = second
        state.reloadResolvedTranscriptForCurrentChapter()
        state.player.currentTime = 0.5
        state.focusedSegmentID = second.id
        let selectedWord = try #require(
            StudyTokenIndex.tokens(in: second, source: .original)
                .first { DictionaryLookup.headword($0.text) == "Civilization" }
        )
        state.inspect(word: selectedWord, in: second)
        state.glosses = [wordGloss(text: "Wrong meaning", context: "First.")]

        #expect(state.currentSegment?.id == "first")
        #expect(state.selectedWordContextSegment?.id == "second")
        #expect(state.selectedWordContextText == second.displayText)
        #expect(state.selectedWordGloss == nil)

        state.glosses.append(wordGloss(text: "Correct meaning", context: second.displayText))

        #expect(state.selectedWordGloss?.text == "Correct meaning")
    }

    @Test("Continue advances from the paused sentence and arms the next one")
    func continuesWithNextSentence() {
        let state = makeState()
        state.settings.deepReadingMode = true
        state.player.currentTime = 0.5
        state.player.isPlaying = true
        state.tickPlaybackModes()
        state.player.currentTime = 2.06
        state.tickPlaybackModes()

        state.continueDeepReading()

        #expect(state.player.currentTime == 2.0)
        #expect(state.deepReadingPausedSentenceID == nil)
        #expect(state.deepReadingActiveSentenceID == "second")
        #expect(state.canContinueDeepReading == false)
    }

    @Test("Player ticks drive Listen First even when the reader view is not mounted")
    func playerTicksAreOwnedByAppState() {
        let state = makeState()
        state.settings.deepReadingMode = true
        state.player.currentTime = 0.5
        state.player.isPlaying = true

        state.handlePlayerTick(0.5)
        state.player.currentTime = 2.06
        state.handlePlayerTick(2.06)

        #expect(state.player.isPlaying == false)
        #expect(state.deepReadingPausedSentenceID == "first")
    }

    private func makeState() -> AppState {
        let first = TranscriptSegment(
            id: "first",
            start: 0,
            end: 2,
            words: [TranscriptWord(id: "first-word", text: "First.", start: 0, end: 2, confidence: nil)],
            ebookText: nil,
            alignmentScore: nil
        )
        let second = TranscriptSegment(
            id: "second",
            start: 2,
            end: 4,
            words: [TranscriptWord(id: "second-word", text: "Second.", start: 2, end: 4, confidence: nil)],
            ebookText: nil,
            alignmentScore: nil
        )
        let state = AppState()
        let chapter = Chapter(
            id: "chapter",
            index: 0,
            title: "Chapter",
            audioPath: "/tmp/deep-reading.m4b",
            duration: 4
        )
        state.books = [Book(
            id: "book",
            title: "Book",
            author: nil,
            folderPath: "/tmp/deep-reading",
            coverPath: nil,
            ebookPath: nil,
            chapters: [chapter],
            source: .files
        )]
        state.selectedBookID = "book"
        state.selectedChapterID = "chapter"
        state.transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/deep-reading.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: [first, second],
            source: "test",
            ebookAligned: false
        )
        return state
    }

    private func wordGloss(text: String, context: String) -> GlossEntry {
        GlossEntry(
            id: UUID().uuidString,
            kind: .word,
            language: "zh-Hans",
            source: "civilization",
            context: context,
            text: text,
            status: .pending,
            model: "local-test",
            createdAt: Date()
        )
    }
}
