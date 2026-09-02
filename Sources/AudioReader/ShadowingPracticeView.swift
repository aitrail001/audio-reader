import SwiftUI
#if os(iOS)
import AVFoundation
#endif

struct ShadowingPracticeView: View {
    @Bindable var state: AppState
    let segment: TranscriptSegment
    @Environment(\.dismiss) private var dismiss
    @State private var dictation = ChapterChatDictation()
    @State private var voice = VoiceCaptureStatus()
    @State private var spoken = ""
    @State private var result: ShadowingResult?

    private var expected: String {
        StudyTokenIndex.sentenceText(in: segment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Shadow this sentence")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Button("Close") { dismiss() }
            }

            Text(expected)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Replay sentence") {
                    state.seekToSentence(segment, time: segment.start, autoplay: true)
                }
                .buttonStyle(.bordered)
                .disabled(voice.isListening || voice.isRequestingPermission)

                ZStack {
                    Text(voice.isListening ? "Stop" : "Speak the sentence")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.terracotta, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                    PlatformTap(
                        isEnabled: !(voice.isRequestingPermission || voice.isFinalizing),
                        accessibilityLabelText: voice.isListening ? "Stop" : "Speak the sentence",
                        action: toggleListening
                    )
                }
                .frame(minWidth: 44, minHeight: 44)
            }

            if voice.isListening {
                Label("Listening on device…", systemImage: "mic.fill")
                    .foregroundStyle(Palette.gold)
                    .accessibilityLabel("Voice input is listening")
                ChapterChatVoiceWaveform(levels: voice.audioLevels)
            }

            if let preparation = voice.preparationMessage {
                Text(preparation)
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }

            if !spoken.isEmpty {
                Text(spoken)
                    .font(.body)
                    .foregroundStyle(Palette.dim)
                    .textSelection(.enabled)
            }

            if let result {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.caption)
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    if !result.missed.isEmpty {
                        Text("Missed: \(result.missed.joined(separator: ", "))")
                            .foregroundStyle(Palette.terracotta)
                    }
                    if !result.extra.isEmpty {
                        Text("Extra: \(result.extra.joined(separator: ", "))")
                            .foregroundStyle(Palette.dim)
                    }
                }
            }

            if let error = voice.unavailableMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
        .onChange(of: voice.isFinalizing) { wasFinalizing, isFinalizing in
            if wasFinalizing, !isFinalizing, !spoken.isEmpty {
                finishScoring()
            }
        }
        .onDisappear {
            dictation.cancel()
            restorePlaybackSession()
        }
    }

    private func toggleListening() {
        if voice.isListening {
            dictation.stop()
            return
        }
        state.player.pause()
        spoken = ""
        result = nil
        dictation.start(
            existingText: "",
            locale: VoiceCaptureLocale.speechLocale(
                for: .sentenceShadowing,
                audiobook: state.currentAudiobookLanguage
            ),
            onStatus: { voice = $0 },
            onWillRecord: { state.player.pause() },
            onTextUpdate: { spoken = $0 }
        )
    }

    private func finishScoring() {
        result = ShadowingScorer.score(expected: expected, spoken: spoken)
        state.recordStudyActivity()
        restorePlaybackSession()
    }

    private func restorePlaybackSession() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
#endif
    }
}
