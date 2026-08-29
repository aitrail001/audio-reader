import SwiftUI
import UniformTypeIdentifiers

struct VocabularyView: View {
    @Bindable var state: AppState
    var onOpenInText: () -> Void = {}
    @State private var query = ""
    @State private var bookFilter: String = "all"
    @State private var category: VocabCategory? = nil
    @State private var pendingDelete: VocabEntry?
    @State private var reviewRequest: VocabularyReviewRequest?
    @State private var showReviewSetup = false
    @State private var selectedForExport: Set<String> = []
    @State private var isExporting = false
    @State private var ankiDocument: AnkiArchiveDocument?
    @State private var showAnkiExporter = false
    @State private var pendingAnkiReport: AnkiExportReport?
    @State private var ankiReport: AnkiExportReport?
    @State private var ankiExportError: String?

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

    private var learnListCount: Int {
        state.vocab.count(where: \.isInLearnList)
    }

    private var dueEntries: [VocabEntry] {
        VocabReviewScheduler.dueEntries(in: filtered, at: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
#if os(macOS)
            header
#endif
            filters
            if filtered.isEmpty {
                empty
            } else {
                List {
                    ForEach(filtered) { entry in
                        VocabCard(
                            state: state,
                            entry: entry,
                            assistantBodySize: AssistantTypography.bodySize(
                                forReaderScale: state.settings.readerFontScale
                            ),
                            onOpen: {
                                if state.jumpToVocab(entry) {
                                    onOpenInText()
                                }
                            },
                            onToggleLearnList: {
                                state.setVocabularyLearnList(entry.id, included: !entry.isInLearnList)
                            },
                            selectedForExport: selectedForExport.contains(entry.id),
                            onToggleExportSelection: {
                                if selectedForExport.contains(entry.id) {
                                    selectedForExport.remove(entry.id)
                                } else {
                                    selectedForExport.insert(entry.id)
                                }
                            },
                            onDelete: {
                                pendingDelete = entry
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteSwipeButton(entry)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            deleteSwipeButton(entry)
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
#if os(iOS)
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startDueReview()
                } label: {
                    Label("Review due — \(dueEntries.count)", systemImage: "rectangle.stack.fill")
                }
                .disabled(dueEntries.isEmpty)
                .accessibilityIdentifier("words.reviewDue")
                .accessibilityHint("Starts a due-first review using the current Words filters.")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Choose review") { showReviewSetup = true }
                    .disabled(state.vocab.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                ankiExportMenu
            }
        }
#endif
        .alert("Delete vocabulary item?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete {
                    state.removeVocab(entry)
                }
                pendingDelete = nil
            }
        } message: {
            Text("Remove “\(pendingDelete?.word ?? "this item")” from your vocabulary? This cannot be undone.")
        }
        .sheet(item: $reviewRequest) { request in
            VocabularyReviewView(state: state, entryIDs: request.entryIDs)
#if os(macOS)
                .frame(minWidth: 620, minHeight: 640)
#endif
        }
        .sheet(isPresented: $showReviewSetup) {
            VocabularyReviewSetupView(state: state) { entryIDs in
                showReviewSetup = false
                Task { @MainActor in
                    await Task.yield()
                    reviewRequest = VocabularyReviewRequest(entryIDs: entryIDs)
                }
            }
#if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
#endif
        }
        .fileExporter(
            isPresented: $showAnkiExporter,
            document: ankiDocument,
            contentType: .zip,
            defaultFilename: "AudioReader-Anki-Export.zip"
        ) { result in
            if case .success = result {
                ankiReport = pendingAnkiReport
            } else if case .failure(let error) = result {
                ankiExportError = error.localizedDescription
            }
            pendingAnkiReport = nil
            ankiDocument = nil
        }
        .alert("Anki export", isPresented: Binding(
            get: { ankiReport != nil || ankiExportError != nil },
            set: {
                if !$0 {
                    ankiReport = nil
                    ankiExportError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                ankiReport = nil
                ankiExportError = nil
            }
        } message: {
            if let report = ankiReport {
                Text("Prepared \(report.cardCount) cards with \(report.audioClipCount) audio clips. \(report.omissions.count) cards are text-only because audio was unavailable.")
            } else {
                Text(ankiExportError ?? "The export could not be prepared.")
            }
        }
    }

    private func deleteSwipeButton(_ entry: VocabEntry) -> some View {
        Button(role: .destructive) {
            pendingDelete = entry
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

#if os(macOS)
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vocabulary")
                    .font(.system(size: 22, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.ink)
                Text("\(filtered.count) of \(state.vocab.count)")
                    .foregroundStyle(Palette.dim)
                    .font(.system(size: 12))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    startDueReview()
                } label: {
                    Label("Review due — \(dueEntries.count)", systemImage: "rectangle.stack.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.terracotta)
                .frame(minHeight: 44)
                .disabled(dueEntries.isEmpty)
                .accessibilityIdentifier("words.reviewDue")
                .accessibilityHint("Starts a due-first review using the current Words filters.")
                Button("Choose review") { showReviewSetup = true }
                    .buttonStyle(.borderless)
                    .disabled(state.vocab.isEmpty)
                ankiExportMenu
                Text("\(learnListCount) in learn list")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
#endif

    private func startDueReview() {
        guard !dueEntries.isEmpty else { return }
        reviewRequest = VocabularyReviewRequest(entryIDs: dueEntries.map(\.id))
    }

    private var ankiExportMenu: some View {
        Menu {
            Button(selectedForExport.isEmpty ? "Current filtered view" : "Selected items (\(selectedForExport.count))") {
                startAnkiExport(scope: .selectionOrFiltered)
            }
            Button("Learning List") { startAnkiExport(scope: .learningList) }
            Button("All Vocabulary") { startAnkiExport(scope: .all) }
        } label: {
            Label(isExporting ? "Preparing export…" : "Export to Anki", systemImage: "square.and.arrow.up")
        }
        .disabled(state.vocab.isEmpty || isExporting)
        .accessibilityIdentifier("anki.export")
    }

    private func startAnkiExport(scope: AnkiExportScope) {
        let entries: [VocabEntry]
        switch scope {
        case .selectionOrFiltered:
            entries = selectedForExport.isEmpty
                ? filtered
                : state.vocab.filter { selectedForExport.contains($0.id) }
        case .learningList:
            entries = state.vocab.filter(\.isInLearnList)
        case .all:
            entries = state.vocab
        }
        guard !entries.isEmpty else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AudioReader-Anki-\(UUID().uuidString).zip")
                let report = try await AnkiExportService().export(
                    cards: entries.compactMap(ankiCard),
                    to: destination
                )
                let data = try Data(contentsOf: destination)
                try? FileManager.default.removeItem(at: destination)
                ankiDocument = AnkiArchiveDocument(data: data)
                pendingAnkiReport = report
                showAnkiExporter = true
            } catch is CancellationError {
                ankiExportError = "Export cancelled. No partial archive was kept."
            } catch {
                ankiExportError = error.localizedDescription
            }
        }
    }

    private func ankiCard(for entry: VocabEntry) -> AnkiExportCard? {
        guard let book = state.books.first(where: { $0.id == entry.bookID }),
              let chapter = book.chapters.first(where: { $0.id == entry.chapterID })
        else {
            return AnkiExportCard(
                stableID: entry.id,
                expression: entry.word,
                resolvedSentence: entry.context,
                gloss: entry.translation ?? entry.definition ?? "",
                book: entry.bookTitle,
                chapter: entry.chapterTitle,
                timestamp: entry.timestamp,
                tags: ["audioreader", entry.category.rawValue]
            )
        }
        let base = Persistence.loadTranscript(for: chapter)
        let resolved = base.map { Persistence.resolvedTranscript($0, chapterDuration: chapter.duration) }
        let segment = resolved?.segments.first { candidate in
            candidate.id == entry.segmentID
                || (entry.segmentID == nil && candidate.start <= entry.timestamp && entry.timestamp < candidate.end)
        }
        let audio = segment.map {
            AnkiAudioSource(
                mediaURL: URL(fileURLWithPath: chapter.audioPath),
                sentenceStart: $0.start,
                sentenceEnd: $0.end,
                chapterOffset: chapter.audioStart
            )
        }
        return AnkiExportCard(
            stableID: entry.id,
            expression: entry.word,
            resolvedSentence: segment?.displayText ?? entry.context,
            gloss: entry.translation ?? entry.definition ?? "",
            book: book.title,
            author: book.author ?? "",
            chapter: chapter.title,
            timestamp: segment?.start ?? entry.timestamp,
            tags: ["audioreader", entry.category.rawValue],
            audio: audio
        )
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
#if os(iOS)
            HStack {
                Text("\(filtered.count) of \(state.vocab.count)")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
                Spacer()
                Text("\(learnListCount) in learn list")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
#endif
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
#if os(iOS)
        .padding(.top, 8)
        .padding(.bottom, 6)
#else
        .padding(.bottom, 8)
#endif
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
        .accessibilityIdentifier("words.category.\(cat?.rawValue ?? "all")")
#if os(iOS)
        .frame(minHeight: 44)
#endif
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "bookmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.gold)
            Text("Click a word while listening, then add it here. Accept an LLM translation to keep sentences and phrases, grouped by book.")
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VocabularyReviewRequest: Identifiable {
    let id = UUID()
    let entryIDs: [String]
}

private enum AnkiExportScope {
    case selectionOrFiltered
    case learningList
    case all
}

private struct AnkiArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct VocabOriginalPlayButton: View {
    @Bindable var state: AppState
    let entry: VocabEntry
    var labeled = true

    private var isPlaying: Bool {
        state.playingVocabEntryID == entry.id && state.player.isPlaying
    }

    var body: some View {
        Button {
            state.toggleVocabSentencePlayback(entry)
        } label: {
            if labeled {
                Label(
                    isPlaying ? "Pause" : "Play original",
                    systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill"
                )
                .inspectorActionLabel()
            } else {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Palette.gold)
        .disabled(!state.canPlayVocabSentence(entry))
        .accessibilityLabel(isPlaying ? "Pause original narration" : "Play original narration")
        .accessibilityHint("Plays the original audiobook narration for this card.")
        .help(
            state.canPlayVocabSentence(entry)
                ? "Play the original audiobook narration"
                : "The original chapter is not in the library"
        )
    }
}

private struct VocabCard: View {
    @Bindable var state: AppState
    let entry: VocabEntry
    let assistantBodySize: CGFloat
    let onOpen: () -> Void
    let onToggleLearnList: () -> Void
    let selectedForExport: Bool
    let onToggleExportSelection: () -> Void
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.gold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.goldSoft)
                    .clipShape(Capsule())
                Spacer()
                Button(action: onToggleExportSelection) {
                    Image(systemName: selectedForExport ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
#if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
#endif
                .foregroundStyle(selectedForExport ? Palette.terracotta : Palette.dim)
                .accessibilityLabel(selectedForExport ? "Remove from Anki export selection" : "Select for Anki export")
                VocabOriginalPlayButton(state: state, entry: entry, labeled: false)
                Button(action: onOpen) {
                    Label("Open in text", systemImage: "text.alignleft")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                Button(action: onToggleLearnList) {
                    Label(
                        entry.isInLearnList ? "In learn list" : "Add to learn list",
                        systemImage: entry.isInLearnList ? "star.fill" : "star"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(entry.isInLearnList ? Palette.gold : Palette.dim)
                .accessibilityHint(
                    entry.isInLearnList
                        ? "Removes this item from focused learn-list reviews."
                        : "Adds this item to focused learn-list reviews."
                )
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(entry.word)")
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

            if dictionaryHTML != nil || !dictionarySummary.isEmpty {
                labeled(entry.dictionaryName.map { "Apple Dictionary · \($0)" } ?? "Apple Dictionary") {
                    if !dictionarySummary.isEmpty {
                        DictionarySummaryView(lines: dictionarySummary)
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
                labeled("LLM translation") {
                    GlossBody(text: translation, size: assistantBodySize)
                    if let model = entry.translationModel, !model.isEmpty {
                        Text("Model: \(model)")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.gold)
                    }
                }
            }
        }
        .padding(14)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var dictionarySummary: [String] {
        DictionaryLookup.concisePreview(
            definition: entry.definition,
            html: entry.dictionaryHTML,
            limit: 3
        )
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
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            content()
        }
    }
}
