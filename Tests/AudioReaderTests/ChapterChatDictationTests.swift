import Testing
@testable import AudioReader

@Suite("Chapter chat dictation")
struct ChapterChatDictationTests {
    @Test("Dictation appends to an existing editable question")
    func appendsToExistingDraft() {
        let draft = ChapterChatDictationDraft(prefix: "Why does the narrator")

        #expect(draft.text(for: "change their mind?") == "Why does the narrator change their mind?")
    }

    @Test("A newer partial result replaces the previous partial result")
    func replacesPartialResult() {
        var transcript = ChapterChatDictationTranscript(prefix: "Compare")

        #expect(transcript.receive("this scene", isFinal: false) == "Compare this scene")
        #expect(
            transcript.receive("this scene with the previous chapter", isFinal: false)
                == "Compare this scene with the previous chapter"
        )
    }

    @Test("Final results replace volatile text and subsequent speech is appended")
    func combinesFinalAndVolatileResults() {
        var transcript = ChapterChatDictationTranscript(prefix: "Explain")

        #expect(transcript.receive("the first idea", isFinal: false) == "Explain the first idea")
        #expect(transcript.receive("the first idea.", isFinal: true) == "Explain the first idea.")
        #expect(transcript.receive("Then compare", isFinal: false) == "Explain the first idea. Then compare")
        #expect(
            transcript.receive("Then compare both chapters.", isFinal: true)
                == "Explain the first idea. Then compare both chapters."
        )
    }

    @Test("Empty drafts contain only the recognized speech")
    func startsAnEmptyDraft() {
        let draft = ChapterChatDictationDraft(prefix: "")

        #expect(draft.text(for: "Explain this metaphor") == "Explain this metaphor")
    }

    @Test("Voice levels map silence and full-scale audio into the waveform range")
    func normalizesVoiceLevels() {
        #expect(ChapterChatVoiceLevel.normalized(amplitude: 0) == 0)
        #expect(ChapterChatVoiceLevel.normalized(amplitude: 0.001) == 0)
        #expect(ChapterChatVoiceLevel.normalized(amplitude: 1) == 1)
        #expect(abs(ChapterChatVoiceLevel.normalized(amplitude: 0.056_234) - 0.5) < 0.01)
    }

    @Test("Waveform history stays bounded and clamps incoming levels")
    func keepsBoundedWaveformHistory() {
        var history = ChapterChatVoiceLevelHistory(sampleCount: 3)

        #expect(history.samples == [0, 0, 0])
        history.append(0.25)
        history.append(2)
        history.append(-1)
        history.append(0.75)

        #expect(history.samples == [1, 0, 0.75])
    }
}
