import SwiftUI

struct VocabularyLearnListView: View {
    @Bindable var state: AppState
    let scope: VocabReviewScope
    let title: String
    let onReviewDue: ([String]) -> Void

    var body: some View {
        let entries = VocabReviewScheduler.scopedEntries(in: state.vocab, scope: scope)
        let queue = VocabularyLearningAnalytics.queue(entries: entries, at: Date())
        let session = queue.sessionBreakdown
        let sessionIDs = queue.session.map(\.id)
        List {
            Section {
                if sessionIDs.isEmpty {
                    Label("Nothing is due for review. Browse or remove saved items below.", systemImage: "checkmark.circle")
                        .foregroundStyle(Palette.dim)
                } else {
                    Button {
                        onReviewDue(sessionIDs)
                    } label: {
                        Label(
                            sessionLabel(session),
                            systemImage: "rectangle.stack"
                        )
                    }
                    .foregroundStyle(Palette.gold)
                    .accessibilityHint("Starts due cards first, followed by up to \(VocabularyLearningPolicy.dailyNewCardLimit) new cards from My list.")
                }
            }

            Section("Items") {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "My list is empty",
                        systemImage: "star",
                        description: Text("Add items from Vocabulary to include them in focused study.")
                    )
                } else {
                    ForEach(entries) { entry in
                        learnListRow(entry)
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private func learnListRow(_ entry: VocabEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.word)
                        .font(.system(.body, design: .serif, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(entry.category.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.gold)
                }
                Text("\(entry.bookTitle) · \(entry.chapterTitle)")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(role: .destructive) {
                state.setVocabularyLearnList(entry.id, included: false)
            } label: {
                Label("Remove", systemImage: "star.slash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(entry.word) from My list")
        }
        .padding(.vertical, 4)
    }

    private func sessionLabel(_ session: VocabularyStudySessionBreakdown) -> String {
        if session.dueCount == 0 { return "Study \(session.newCount) new" }
        if session.newCount == 0 { return "Review \(session.dueCount) due" }
        return "Study \(session.dueCount) due + \(session.newCount) new"
    }
}
