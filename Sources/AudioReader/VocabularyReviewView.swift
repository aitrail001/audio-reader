import SwiftUI

struct VocabularyReviewView: View {
    @Bindable var state: AppState
    let entryIDs: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var currentIndex = 0
    @State private var isRevealed = false
    @State private var reviewedCount = 0
    @State private var dictHeight: CGFloat = 160
    @State private var showDictionaryEntry = false

    private var entry: VocabEntry? {
        guard entryIDs.indices.contains(currentIndex) else { return nil }
        let id = entryIDs[currentIndex]
        return state.vocab.first { $0.id == id }
    }

    private var reviewCardMinimumHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 220 : 390
    }

    private var assistantBodySize: CGFloat {
        AssistantTypography.bodySize(forReaderScale: state.settings.readerFontScale)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let entry {
                    review(entry)
                } else {
                    completion
                }
            }
            .navigationTitle("Vocabulary review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .background(Palette.bg)
        .onChange(of: currentIndex) { _, _ in
            state.stopVocabSentencePlayback()
        }
        .onDisappear {
            state.stopVocabSentencePlayback()
        }
    }

    private func review(_ entry: VocabEntry) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Text("Card \(currentIndex + 1) of \(entryIDs.count)")
                    Spacer()
                    Text("\(prompt(for: entry).title) · \(entry.category.title)")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.dim)

                VocabOriginalPlayButton(state: state, entry: entry)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if isRevealed {
                        back(of: entry)
                            .transition(.opacity)
                    } else {
                        front(of: entry)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? .linear(duration: 0.12) : .easeInOut(duration: 0.32), value: isRevealed)

                if isRevealed {
                    qualityButtons(for: entry)
                        .transition(.opacity)
                } else {
                    Button("Show answer") {
                        isRevealed = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.gold)
                    .foregroundStyle(Palette.inkOnGold)
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityHint("Flips the card to show the translation and dictionary entry.")
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private func front(of entry: VocabEntry) -> some View {
        Button {
            isRevealed = true
        } label: {
            VStack(alignment: .leading, spacing: 22) {
                switch prompt(for: entry) {
                case .recognition:
                    Text(entry.word)
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                    highlightedSentence(entry)
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .cloze:
                    Text(VocabCloze.blankedSentence(for: entry))
                        .font(.system(.title, design: .serif, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .reverse:
                    Text(VocabReversePrompt.promptText(for: entry) ?? entry.word)
                        .font(.system(.title, design: .serif, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Divider()

                Label(entry.bookTitle, systemImage: "book.closed")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.dim)
                Text("\(entry.chapterTitle) · \(formatClock(entry.timestamp))")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)

                HStack {
                    Spacer()
                    Label("Flip card", systemImage: "rectangle.portrait.rotate")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.dim)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: reviewCardMinimumHeight, alignment: .topLeading)
            .background(Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.word). \(entry.context). From \(entry.bookTitle), \(entry.chapterTitle).")
        .accessibilityHint("Double tap to show the answer.")
    }

    private func back(of entry: VocabEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(entry.word)
                .font(.system(.title, design: .serif, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)

            if let translation = entry.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !translation.isEmpty {
                answerSection("Translation") {
                    GlossBody(text: translation, size: assistantBodySize)
                }
            }

            if dictionaryHTML(for: entry) != nil || !dictionarySummary(for: entry).isEmpty {
                answerSection(entry.dictionaryName.map { "Apple Dictionary · \($0)" } ?? "Apple Dictionary") {
                    if !dictionarySummary(for: entry).isEmpty {
                        DictionarySummaryView(lines: dictionarySummary(for: entry))
                    }
                    if let html = dictionaryHTML(for: entry) {
                        Button(showDictionaryEntry ? "Hide full entry" : "Show full dictionary entry") {
                            showDictionaryEntry.toggle()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.dim)
                        .underline()
                        if showDictionaryEntry {
                            DictionaryHTMLView(html: html, dark: colorScheme == .dark, height: $dictHeight)
                                .frame(height: min(max(dictHeight, 160), 360))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            if entry.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               dictionarySummary(for: entry).isEmpty {
                ContentUnavailableView(
                    "No saved answer",
                    systemImage: "text.book.closed",
                    description: Text("This card has no saved translation or dictionary definition yet.")
                )
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: reviewCardMinimumHeight, alignment: .topLeading)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func qualityButtons(for entry: VocabEntry) -> some View {
        VStack(spacing: 10) {
            Text("How well did you remember it?")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.dim)

            if dynamicTypeSize.isAccessibilitySize {
                qualityButtonsVertical(for: entry)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(VocabReviewQuality.allCases) { quality in
                            qualityButton(quality, for: entry)
                        }
                    }
                    qualityButtonsVertical(for: entry)
                }
            }
        }
    }

    private func qualityButtonsVertical(for entry: VocabEntry) -> some View {
        VStack(spacing: 10) {
            ForEach(VocabReviewQuality.allCases) { quality in
                qualityButton(quality, for: entry)
            }
        }
    }

    private func qualityButton(_ quality: VocabReviewQuality, for entry: VocabEntry) -> some View {
        Button {
            grade(entry, quality: quality)
        } label: {
            VStack(spacing: 2) {
                Label(quality.title, systemImage: quality.symbol)
                Text(quality.intervalLabel(for: entry))
                    .font(.caption2)
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(quality.tint)
        .accessibilityHint("Schedules the next review in \(quality.intervalLabel(for: entry)).")
    }

    private var completion: some View {
        ContentUnavailableView {
            Label("Review complete", systemImage: "checkmark.seal")
        } description: {
            Text(completionDescription)
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Palette.gold)
                .foregroundStyle(Palette.inkOnGold)
        }
    }

    private var completionDescription: String {
        let count = "You reviewed \(reviewedCount) \(reviewedCount == 1 ? "card" : "cards")."
        let sessionIDs = Set(entryIDs)
        let sessionEntries = state.vocab.filter { sessionIDs.contains($0.id) }
        guard let next = VocabReviewScheduler.nextReviewDate(in: sessionEntries, after: Date()) else {
            return count
        }
        return "\(count) Next round: \(next.formatted(date: .abbreviated, time: .shortened))."
    }

    private func grade(_ entry: VocabEntry, quality: VocabReviewQuality) {
        state.reviewVocabulary(entry.id, quality: quality)
        reviewedCount += 1
        currentIndex += 1
        isRevealed = false
        showDictionaryEntry = false
        dictHeight = 160
    }

    private func prompt(for entry: VocabEntry) -> VocabReviewPrompt {
        VocabReversePrompt.effectivePrompt(for: entry, requested: state.vocabReviewPrompt)
    }

    private func highlightedSentence(_ entry: VocabEntry) -> Text {
        guard let range = entry.context.range(of: entry.word, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(entry.context)
        }
        let prefix = Text(entry.context[..<range.lowerBound])
        let match = Text(entry.context[range]).bold().foregroundStyle(Palette.gold)
        let suffix = Text(entry.context[range.upperBound...])
        return Text("\(prefix)\(match)\(suffix)")
    }

    private func answerSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.dim)
                .tracking(0.5)
            content()
        }
    }

    private func dictionarySummary(for entry: VocabEntry) -> [String] {
        DictionaryLookup.concisePreview(
            definition: entry.definition,
            html: entry.dictionaryHTML,
            limit: 3
        )
    }

    private func dictionaryHTML(for entry: VocabEntry) -> String? {
        let source = entry.dictionaryHTML
            ?? (entry.definition.flatMap { DictionaryLookup.looksLikeMarkup($0) ? $0 : nil })
        guard let source, !source.isEmpty else { return nil }
        return DictionaryLookup.displayHTML(source)
    }
}

private extension VocabReviewQuality {
    var symbol: String {
        switch self {
        case .forgot: "arrow.counterclockwise"
        case .vague: "questionmark"
        case .remember: "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .forgot: .red
        case .vague: .orange
        case .remember: .green
        }
    }

    func intervalLabel(for entry: VocabEntry) -> String {
        let days = VocabReviewScheduler.nextIntervalDays(for: self, entry: entry)
        if days == 1 { return "1 day" }
        if days.rounded() == days { return "\(Int(days)) days" }
        return "\(days.formatted(.number.precision(.fractionLength(1)))) days"
    }
}
