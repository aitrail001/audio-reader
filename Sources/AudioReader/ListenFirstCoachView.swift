import SwiftUI

/// A compact retrieval strip shown only after Listen First completes a sentence.
struct ListenFirstCoachView: View {
    @Bindable var state: AppState
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("What did you hear?", systemImage: "ear.and.waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("Sentence complete")
                    .font(.caption)
                    .foregroundStyle(Palette.gold)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.goldSoft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.listenFirstCoach")
    }

    @ViewBuilder
    private var actions: some View {
        coachButton("Replay", systemImage: "repeat.1") {
            state.replaySentence()
        }
        coachButton("Explain", systemImage: "character.book.closed") {
            state.translateSentence(segment)
        }
        coachButton("Shadow", systemImage: "waveform.and.mic") {
            state.presentShadowing(for: segment)
        }
        coachButton(
            state.isHeardQuizWorking ? "Preparing…" : "Quick Quiz",
            systemImage: "questionmark.bubble"
        ) {
            state.requestHeardQuiz()
        }
        .disabled(state.isHeardQuizWorking)
        coachButton("Continue", systemImage: "forward.end.circle") {
            state.continueDeepReading()
        }
        .disabled(!state.canContinueDeepReading)
    }

    private func coachButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// Read & Pause exposes only the controls needed to repeat or advance the fully visible text.
struct ReadAndPauseCoachView: View {
    @Bindable var state: AppState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 8)
                actions
            }
            VStack(alignment: .leading, spacing: 6) {
                title
                HStack(spacing: 8) { actions }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.goldSoft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.readAndPauseCoach")
    }

    private var title: some View {
        Label("Sentence paused", systemImage: "pause.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.ink)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Replay sentence") { state.replaySentence() }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("reader.readAndPauseReplay")
        Button("Continue to next sentence") { state.continueDeepReading() }
            .buttonStyle(.borderedProminent)
            .tint(Palette.terracotta)
            .frame(minHeight: 44)
            .disabled(!state.canContinueDeepReading)
            .accessibilityIdentifier("reader.readAndPauseContinue")
    }
}
