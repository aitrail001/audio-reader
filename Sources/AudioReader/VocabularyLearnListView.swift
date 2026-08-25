import SwiftUI

struct VocabularyLearnListView: View {
    @Bindable var state: AppState
    let scope: VocabReviewScope
    let title: String
    let onReviewDue: ([String]) -> Void

    private var entries: [VocabEntry] {
        VocabReviewScheduler.scopedEntries(in: state.vocab, scope: scope)
    }

    private var dueEntries: [VocabEntry] {
        VocabReviewScheduler.dueEntries(in: state.vocab, scope: scope, at: Date())
    }

    var body: some View {
        List {
            Section {
                if dueEntries.isEmpty {
                    Label("Nothing is due for review. Browse or remove items below.", systemImage: "checkmark.circle")
                        .foregroundStyle(Palette.dim)
                } else {
                    Button {
                        onReviewDue(dueEntries.map(\.id))
                    } label: {
                        Label(
                            "Review \(dueEntries.count) due",
                            systemImage: "rectangle.stack"
                        )
                    }
                    .foregroundStyle(Palette.gold)
                    .accessibilityHint("Starts a review containing only the due items in this list.")
                }
            }

            Section("Items") {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Learn list is empty",
                        systemImage: "star",
                        description: Text("Add items from Vocabulary to include them here.")
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
            .accessibilityLabel("Remove \(entry.word) from learn list")
        }
        .padding(.vertical, 4)
    }
}
