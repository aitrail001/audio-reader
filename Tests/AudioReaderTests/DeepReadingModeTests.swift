import Foundation
import Testing
@testable import AudioReader

@MainActor
@Suite("Deep Reading mode")
struct DeepReadingModeTests {
    @Test("Deep Reading defaults off and migrates existing settings")
    func migratesExistingSettings() throws {
        #expect(AppSettings.default.deepReadingMode == false)

        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "deepReadingMode")

        let migrated = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(migrated.deepReadingMode == false)
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
}
