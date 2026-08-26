import SwiftUI

private struct BookCategoryReviewOption: Identifiable {
    let bookID: String
    let category: VocabCategory

    var id: String { "\(bookID)::\(category.rawValue)" }
}

struct VocabularyReviewSetupView: View {
    @Bindable var state: AppState
    let onStart: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    private var entries: [VocabEntry] {
        state.vocab
    }

    private var books: [(id: String, title: String)] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard seen.insert(entry.bookID).inserted else { return nil }
            return (entry.bookID, entry.bookTitle)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
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
                        title: "All learn-list items",
                        symbol: "star.fill",
                        scope: VocabReviewScope.learnList
                    )
                    ForEach(booksWithLearnListItems, id: \.id) { book in
                        learnListNavigation(
                            title: book.title,
                            symbol: "book.closed",
                            scope: VocabReviewScope.learnListBook(book.id)
                        )
                    }
                } header: {
                    Text("Learn list")
                } footer: {
                    Text("Open a list to browse or remove items. Reviews include only items that are due.")
                }

                ForEach(books, id: \.id) { book in
                    Section(book.title) {
                        scopeButton(
                            title: "All items",
                            symbol: "rectangle.stack",
                            scope: VocabReviewScope.book(book.id)
                        )
                        ForEach(categoryOptions(in: book.id)) { option in
                            scopeButton(
                                title: option.category.title,
                                symbol: option.category.symbol,
                                scope: VocabReviewScope.bookCategory(option.bookID, option.category)
                            )
                        }
                    }
                }
            }
            .navigationTitle("Choose review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var booksWithLearnListItems: [(id: String, title: String)] {
        books.filter { book in
            entries.contains { $0.bookID == book.id && $0.isInLearnList }
        }
    }

    private func categoryOptions(in bookID: String) -> [BookCategoryReviewOption] {
        VocabCategory.allCases.compactMap { category in
            guard entries.contains(where: { $0.bookID == bookID && $0.category == category }) else {
                return nil
            }
            return BookCategoryReviewOption(bookID: bookID, category: category)
        }
    }

    private func scopeButton(
        title: String,
        symbol: String,
        scope: VocabReviewScope
    ) -> some View {
        let dueEntries = VocabReviewScheduler.dueEntries(in: entries, scope: scope, at: Date())
        return Button {
            guard !dueEntries.isEmpty else { return }
            dismiss()
            onStart(dueEntries.map(\.id))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(Palette.gold)
                Text(title)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(dueEntries.isEmpty ? "None due" : "\(dueEntries.count) due")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dueEntries.isEmpty)
        .accessibilityLabel(
            dueEntries.isEmpty ? "\(title), none due" : "\(title), \(dueEntries.count) due"
        )
        .accessibilityHint(
            dueEntries.isEmpty
                ? "There are no items due in this review scope."
                : "Starts this due-first review session."
        )
    }

    private func learnListNavigation(
        title: String,
        symbol: String,
        scope: VocabReviewScope
    ) -> some View {
        let scopedEntries = VocabReviewScheduler.scopedEntries(in: entries, scope: scope)
        let dueEntries = VocabReviewScheduler.dueEntries(in: entries, scope: scope, at: Date())
        let itemCount = "\(scopedEntries.count) \(scopedEntries.count == 1 ? "item" : "items")"
        let status = if scopedEntries.isEmpty {
            "Empty"
        } else if dueEntries.isEmpty {
            "\(itemCount) · None due"
        } else {
            "\(itemCount) · \(dueEntries.count) due"
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
        .disabled(scopedEntries.isEmpty)
        .accessibilityLabel("\(title), \(status)")
        .accessibilityHint("Opens this learn list for browsing, removal, and due reviews.")
    }
}
