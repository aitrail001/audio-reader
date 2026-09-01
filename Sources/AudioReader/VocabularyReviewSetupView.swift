import SwiftUI

struct VocabularyReviewSetupView: View {
    @Bindable var state: AppState
    let onStart: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var projection = VocabularyReviewSetupProjection.empty
    @State private var isLoading = true
    @State private var refreshClock = Date()

    private var refreshRequest: VocabularyReviewSetupRequest {
        VocabularyReviewSetupRequest(
            revision: state.vocabularyLearningRevision,
            minute: Int(refreshClock.timeIntervalSince1970 / 60)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView("Preparing review choices…")
                        .frame(maxWidth: .infinity, minHeight: 88)
                        .accessibilityLabel("Preparing review choices")
                }
                Section {
                    Picker("Card face", selection: $state.vocabReviewPrompt) {
                        ForEach(VocabReviewPrompt.allCases) { prompt in
                            Text(prompt.title).tag(prompt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: state.settings.vocabReviewPrompt) { _, _ in
                        state.persistSettings()
                    }
                    .accessibilityLabel("Card face")
                } footer: {
                    Text("Recognition shows the word. Cloze hides it in the original sentence. Reverse asks you to recall the word from a translation or definition.")
                }

                Section {
                    learnListNavigation(
                        title: "All items in My list",
                        symbol: "star.fill",
                        scope: VocabReviewScope.learnList,
                        summary: projection.summary(for: .learnList)
                    )
                    ForEach(projection.learnListBooks) { book in
                        let scope = VocabReviewScope.learnListBook(book.id)
                        learnListNavigation(
                            title: book.title,
                            symbol: "book.closed",
                            scope: scope,
                            summary: projection.summary(for: scope)
                        )
                    }
                } header: {
                    Text("My list")
                } footer: {
                    Text("Open My list to add or remove items. Study sessions include due cards first, then up to \(VocabularyLearningPolicy.dailyNewCardLimit) new cards.")
                }

                ForEach(projection.books) { book in
                    Section(book.title) {
                        let bookScope = VocabReviewScope.book(book.id)
                        scopeButton(
                            title: "Study this book",
                            symbol: "rectangle.stack",
                            summary: projection.summary(for: bookScope)
                        )
                        ForEach(projection.categoryOptions(in: book.id)) { option in
                            let categoryScope = VocabReviewScope.bookCategory(option.bookID, option.category)
                            scopeButton(
                                title: option.category.title,
                                symbol: option.category.symbol,
                                summary: projection.summary(for: categoryScope)
                            )
                        }
                    }
                }
            }
            .disabled(isLoading)
            .navigationTitle("Review by list or book")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task(id: refreshRequest) {
            await refreshProjection(for: refreshRequest)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                refreshClock = Date()
            }
        }
    }

    /// Review scope construction scans and sorts the complete vocabulary, so it
    /// stays cancellable and outside the main actor as the picker refreshes.
    private func refreshProjection(for request: VocabularyReviewSetupRequest) async {
        isLoading = true
        let entries = state.vocab
        let worker = Task.detached(priority: .userInitiated) {
            try VocabularyReviewSetupProjection.makeCancellable(entries: entries, at: Date())
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, request == refreshRequest else { return }
            projection = result
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard request == refreshRequest else { return }
            projection = .empty
            isLoading = false
        }
    }

    private func scopeButton(
        title: String,
        symbol: String,
        summary: VocabularyReviewScopeSummary
    ) -> some View {
        return Button {
            guard !summary.sessionIDs.isEmpty else { return }
            dismiss()
            onStart(summary.sessionIDs)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(Palette.gold)
                Text(title)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(sessionStatus(summary))
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(summary.sessionIDs.isEmpty)
        .accessibilityLabel("\(title), \(sessionStatus(summary))")
        .accessibilityHint(
            summary.sessionIDs.isEmpty
                ? "There are no due or new cards in this study scope."
                : "Starts due cards first, followed by new cards."
        )
    }

    private func learnListNavigation(
        title: String,
        symbol: String,
        scope: VocabReviewScope,
        summary: VocabularyReviewScopeSummary
    ) -> some View {
        let itemCount = "\(summary.itemCount) \(summary.itemCount == 1 ? "item" : "items")"
        let status = if summary.itemCount == 0 {
            "Empty"
        } else if summary.sessionIDs.isEmpty {
            "\(itemCount) · Nothing ready"
        } else {
            "\(itemCount) · \(sessionStatus(summary))"
        }

        return NavigationLink {
            VocabularyLearnListView(
                state: state,
                scope: scope,
                title: title,
                onReviewDue: onStart
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(Palette.gold)
                Text(title)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            .contentShape(Rectangle())
        }
        .disabled(summary.itemCount == 0)
        .accessibilityLabel("\(title), \(status)")
        .accessibilityHint("Opens My list for browsing, removal, and focused study.")
    }

    private func sessionStatus(_ summary: VocabularyReviewScopeSummary) -> String {
        if summary.sessionIDs.isEmpty { return "Nothing ready" }
        if summary.sessionDueCount == 0 { return "\(summary.sessionNewCount) new" }
        if summary.sessionNewCount == 0 { return "\(summary.sessionDueCount) due" }
        return "\(summary.sessionDueCount) due + \(summary.sessionNewCount) new"
    }
}

private struct VocabularyReviewSetupRequest: Hashable, Sendable {
    let revision: UInt
    let minute: Int
}
