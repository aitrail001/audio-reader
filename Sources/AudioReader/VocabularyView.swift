import SwiftUI

struct VocabularyView: View {
    @Bindable var state: AppState
    @State private var query = ""
    @State private var bookFilter: String = "all"
    @State private var category: VocabCategory? = nil

    private var booksInVocab: [(id: String, title: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for entry in state.vocab {
            if seen.insert(entry.bookID).inserted {
                out.append((entry.bookID, entry.bookTitle))
            }
        }
        return out.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private var filtered: [VocabEntry] {
        var items = state.vocab
        if bookFilter != "all" {
            items = items.filter { $0.bookID == bookFilter }
        }
        if let category {
            items = items.filter { $0.category == category }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            items = items.filter {
                $0.word.localizedCaseInsensitiveContains(q)
                || $0.context.localizedCaseInsensitiveContains(q)
                || $0.bookTitle.localizedCaseInsensitiveContains(q)
                || ($0.translation?.localizedCaseInsensitiveContains(q) ?? false)
                || ($0.definition?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        return items
    }

    private func count(for cat: VocabCategory?) -> Int {
        let base = bookFilter == "all" ? state.vocab : state.vocab.filter { $0.bookID == bookFilter }
        if let cat { return base.filter { $0.category == cat }.count }
        return base.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            if filtered.isEmpty {
                empty
            } else {
                List {
                    ForEach(filtered) { entry in
                        VocabCard(entry: entry) {
                            state.jumpToVocab(entry)
                        } onDelete: {
                            state.removeVocab(entry)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.bg)
    }

    private var header: some View {
        HStack {
            Text("Vocabulary")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(Palette.ink)
            Spacer()
            Text("\(filtered.count) of \(state.vocab.count)")
                .foregroundStyle(Palette.dim)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.mute)
                TextField("Search words, phrases, sentences, books", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Palette.panel2)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Picker("Book", selection: $bookFilter) {
                Text("All books").tag("all")
                ForEach(booksInVocab, id: \.id) { book in
                    Text(book.title).tag(book.id)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 8) {
                categoryChip(nil, title: "All", symbol: "square.grid.2x2", count: count(for: nil))
                ForEach(VocabCategory.allCases) { cat in
                    categoryChip(cat, title: cat.title, symbol: cat.symbol, count: count(for: cat))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func categoryChip(_ cat: VocabCategory?, title: String, symbol: String, count: Int) -> some View {
        let on = category == cat
        return Button {
            category = cat
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text("\(title) \(count)")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(on ? Palette.goldSoft : Palette.panel2)
            .foregroundStyle(on ? Palette.gold : Palette.dim)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "bookmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.gold)
            Text("Click a word while listening, then add it here. Accept a Grok translation to keep sentences and phrases, grouped by book.")
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VocabCard: View {
    let entry: VocabEntry
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var dictHeight: CGFloat = 140
    @State private var showDictHTML = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.word)
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                Text(entry.category.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.gold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.goldSoft)
                    .clipShape(Capsule())
                Spacer()
                Button(action: onOpen) {
                    Label("Open in text", systemImage: "text.alignleft")
                }
                .controlSize(.small)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
            }

            Text("\(entry.bookTitle) · \(entry.chapterTitle) · \(formatClock(entry.timestamp))")
                .font(.system(size: 11))
                .foregroundStyle(Palette.mute)

            labeled("Original text") {
                Text(entry.ebookText ?? entry.context)
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if dictionaryHTML != nil || readableDefinition != nil {
                labeled(entry.dictionaryName.map { "Apple Dictionary · \($0)" } ?? "Apple Dictionary") {
                    if let summary = readableDefinition {
                        Text(summary)
                            .font(.system(size: 14, design: .serif))
                            .foregroundStyle(Palette.ink.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let html = dictionaryHTML {
                        Button(showDictHTML ? "Hide full entry" : "Show full dictionary entry") {
                            showDictHTML.toggle()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.gold)
                        .buttonStyle(.plain)
                        if showDictHTML {
                            DictionaryHTMLView(html: html, dark: colorScheme == .dark, height: $dictHeight)
                                .frame(height: min(max(dictHeight, 160), 420))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            if let translation = entry.translation, !translation.isEmpty {
                labeled("Grok") {
                    GlossBody(text: translation)
                }
            }
        }
        .padding(14)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var readableDefinition: String? {
        if let def = entry.definition, !def.isEmpty, !DictionaryLookup.looksLikeMarkup(def) {
            return def
        }
        if let html = entry.dictionaryHTML, !html.isEmpty {
            let plain = DictionaryLookup.plainPreview(from: html)
            return plain.isEmpty ? nil : plain
        }
        if let def = entry.definition, DictionaryLookup.looksLikeMarkup(def) {
            let plain = DictionaryLookup.plainPreview(from: def)
            return plain.isEmpty ? nil : plain
        }
        return nil
    }

    private var dictionaryHTML: String? {
        if let html = entry.dictionaryHTML, !html.isEmpty {
            return DictionaryLookup.displayHTML(html)
        }
        if let def = entry.definition, DictionaryLookup.looksLikeMarkup(def) {
            return DictionaryLookup.displayHTML(def)
        }
        return nil
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.mute)
                .tracking(0.5)
            content()
        }
    }
}
