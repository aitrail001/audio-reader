import SwiftUI

struct ChapterStudyListView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var presentation: ChapterStudyPresentation {
        state.chapterStudyPresentation ?? .empty
    }

    private var coverage: ChapterCoverage { presentation.coverage }
    private var items: [ChapterStudyItem] { presentation.items }

    var body: some View {
        NavigationStack {
            Group {
                if !presentation.hasTranscript {
                    ContentUnavailableView(
                        "No transcript",
                        systemImage: "waveform",
                        description: Text("Transcribe this chapter to list its content words.")
                    )
                } else if items.isEmpty, coverage.contentCount == 0 {
                    ContentUnavailableView(
                        "No word tokens yet",
                        systemImage: "text.word.spacing",
                        description: Text("This chapter has no content words to list.")
                    )
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "All content words are marked known",
                        systemImage: "checkmark.circle",
                        description: Text("Unmark words in Lookup if you want them here again.")
                    )
                } else {
                    List {
                        Section {
                            Text(coverage.caption)
                                .foregroundStyle(Palette.dim)
                                .accessibilityLabel("\(coverage.percentKnown) percent known in this chapter")
                            Text(state.studyActivityLog.caption)
                                .foregroundStyle(Palette.mute)
                                .font(.caption)
                        }

                        Section("To study") {
                            ForEach(items) { item in
                                studyRow(item)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 420, minHeight: 480)
            .navigationTitle("Chapter words")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { state.refreshStudyIndex() }
        }
    }

    private func studyRow(_ item: ChapterStudyItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.surface)
                    .font(.system(.body, design: .serif, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(item.familiarity == .learning ? "Learning" : "Unknown")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.terracotta)
            }
            Spacer(minLength: 8)
            Button("Mark known") {
                state.markKnown(lemma: item.lemma, known: true)
                state.recordStudyActivity()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Mark \(item.surface) known")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            jump(to: item)
        }
        .accessibilityHint("Opens this word in the current chapter.")
    }

    private func jump(to item: ChapterStudyItem) {
        guard let segment = state.transcript?.segments.first(where: { $0.id == item.segmentID }) else { return }
        let tokens = StudyTokenIndex.tokens(in: segment)
        let word = tokens.first(where: { $0.id == item.wordID }) ?? tokens.first
        state.focusedSegmentID = segment.id
        if let word {
            state.inspect(word: word)
        }
        dismiss()
    }
}
