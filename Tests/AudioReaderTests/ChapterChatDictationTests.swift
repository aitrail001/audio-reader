import Foundation
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

    @Test("Voice capture uses the audiobook speech locale, not the system locale")
    func speechLocaleFollowsAudiobookLanguage() {
        #expect(VoiceCaptureLocale.speechLocale(for: .englishUS).identifier == "en-US")
        #expect(VoiceCaptureLocale.speechLocale(for: .french).identifier == "fr-FR")
        #expect(VoiceCaptureLocale.speechLocale(for: .simplifiedChinese).identifier == "zh-CN")
    }

    @Test("Chapter questions keep the already-installed system dictation locale")
    func chapterQuestionsDoNotSwitchToAudiobookLocale() {
        let question = VoiceCaptureLocale.speechLocale(for: .chapterQuestion, audiobook: .englishUS)
        let shadowing = VoiceCaptureLocale.speechLocale(for: .sentenceShadowing, audiobook: .englishUS)
        #expect(question == Locale.autoupdatingCurrent)
        #expect(shadowing.identifier == "en-US")
        #expect(question != shadowing)
    }

    @Test("An unusable microphone format is rejected before the engine starts")
    func rejectsInvalidInputFormat() {
        #expect(VoiceCaptureLocale.isUsable(sampleRate: 48_000, channelCount: 1))
        #expect(!VoiceCaptureLocale.isUsable(sampleRate: 0, channelCount: 1))
        #expect(!VoiceCaptureLocale.isUsable(sampleRate: 44_100, channelCount: 0))
    }

    @Test("The microphone input node exists before the audio graph is prepared")
    func initializesInputNodeBeforePreparingAudioGraph() throws {
        let dictation = try source()
        let methodStart = try #require(dictation.range(of: "private func beginRecognition"))
        let methodEnd = try #require(
            dictation.range(
                of: "private func startResultTask",
                range: methodStart.upperBound..<dictation.endIndex
            )
        )
        let method = String(dictation[methodStart.lowerBound..<methodEnd.lowerBound])
        let inputNode = try #require(method.range(of: "let inputNode = audioEngine.inputNode"))
        let prepare = try #require(method.range(of: "audioEngine.prepare()"))

        #expect(inputNode.lowerBound < prepare.lowerBound)
    }

    @Test("Voice capture status reports when the microphone can start")
    func voiceCaptureStatusCanStart() {
        var status = VoiceCaptureStatus()
        #expect(status.canStart)
        #expect(status.audioLevels.count == 24)

        status.isRequestingPermission = true
        #expect(!status.canStart)

        status.isRequestingPermission = false
        status.isListening = true
        #expect(!status.canStart)

        status.isListening = false
        status.isFinalizing = true
        #expect(!status.canStart)
    }

    @Test("Dictation publishes value snapshots from a MainActor-owned session")
    func dictationUIStateIsMainActorOwned() throws {
        let dictation = try source()
        #expect(dictation.contains("struct VoiceCaptureStatus"))
        #expect(dictation.contains("@MainActor\nfinal class ChapterChatDictation"))
        #expect(!dictation.contains("ChapterChatDictation: @unchecked Sendable"))
        #expect(!dictation.contains("@Observable\nfinal class ChapterChatDictation"))
        #expect(dictation.contains("onStatus: @escaping @MainActor (VoiceCaptureStatus) -> Void"))
        #expect(dictation.contains("actor SpeechAssetSupport"))
        let classStart = try #require(dictation.range(of: "@MainActor\nfinal class ChapterChatDictation"))
        let classEnd = try #require(dictation.range(of: "private func completeFinalization", range: classStart.upperBound..<dictation.endIndex))
        let body = String(dictation[classStart.lowerBound..<classEnd.lowerBound])
        #expect(body.contains("SpeechAssetSupport.shared.installIfNeeded"))
        #expect(!body.contains("downloadAndInstall()"))
        #expect(!body.contains("DispatchQueue.main.async"))
        #expect(!body.contains("UncheckedAction"))
    }

    @Test("Playback state is MainActor-owned without a process-wide executor override")
    func playbackStateIsMainActorOwned() throws {
        let engine = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AudioReader/PlayerEngine.swift"),
            encoding: .utf8
        )
        #expect(!engine.contains("MainActor.assumeIsolated"))
        #expect(engine.contains("@MainActor\n@Observable\nfinal class PlayerEngine"))
        #expect(!engine.contains("PlayerEngine: @unchecked Sendable"))
        #expect(engine.contains("Task { @MainActor"))
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AudioReader/AudioReaderApp.swift"),
            encoding: .utf8
        )
        #expect(!app.contains("IsolationRuntimeGuard.install()"))
    }

    private func source() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AudioReader/ChapterChatDictation.swift"),
            encoding: .utf8
        )
    }
}
