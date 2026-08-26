import SwiftUI

struct ChapterQuizView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var session: ChapterQuizSession? { state.chapterQuizSession }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    quizList(session)
                } else {
                    ContentUnavailableView(
                        "No quiz",
                        systemImage: "questionmark.circle",
                        description: Text("Transcribe this chapter, then try Chapter quiz again.")
                    )
                }
            }
            .frame(minWidth: 420, minHeight: 480)
            .navigationTitle("Chapter quiz")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func quizList(_ session: ChapterQuizSession) -> some View {
        List {
            Section {
                Text("Local comprehension check for this chapter. No XP, no remote library.")
                    .foregroundStyle(Palette.dim)
                Text(state.studyActivityLog.caption)
                    .font(.caption)
                    .foregroundStyle(Palette.mute)
            }

            ForEach(Array(session.quiz.questions.enumerated()), id: \.element.id) { index, question in
                Section("Question \(index + 1)") {
                    Text(question.prompt)
                        .font(.system(.body, design: .serif))
                    ForEach(question.labeledChoices) { choice in
                        Button {
                            select(choice.index, at: index)
                        } label: {
                            HStack {
                                Image(systemName: session.selections[index] == choice.index
                                      ? "largecircle.fill.circle"
                                      : "circle")
                                Text(choice.text)
                                    .foregroundStyle(Palette.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                if session.isRevealed {
                                    if choice.index == question.answerIndex {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.green)
                                    } else if session.selections[index] == choice.index {
                                        Image(systemName: "xmark")
                                            .foregroundStyle(Palette.terracotta)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(session.isRevealed)
                        .accessibilityLabel(choice.text)
                    }
                }
            }

            Section {
                if session.isRevealed {
                    Text(session.result().caption)
                        .font(.headline)
                } else {
                    Button("Score quiz") {
                        score()
                    }
                    .disabled(!session.canScore)
                }
            }
        }
    }

    private func select(_ choiceIndex: Int, at questionIndex: Int) {
        guard var session = state.chapterQuizSession else { return }
        session.select(choiceIndex, at: questionIndex)
        state.chapterQuizSession = session
    }

    private func score() {
        guard var session = state.chapterQuizSession else { return }
        session.isRevealed = true
        state.chapterQuizSession = session
        state.recordStudyActivity()
    }
}
