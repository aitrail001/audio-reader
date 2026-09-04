import OSLog
import SwiftUI
import UniformTypeIdentifiers

private enum VocabularyWorkspaceSection: String, CaseIterable, Identifiable {
    case today
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .library: "Vocabulary"
        }
    }

    var symbol: String {
        switch self {
        case .today: "rectangle.stack.fill"
        case .library: "books.vertical"
        }
    }
}

private enum VocabularyLibraryScope: String, CaseIterable, Identifiable {
    case all
    case learning
    case myList
    case known

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .learning: "Learning"
        case .myList: "My List"
        case .known: "Known"
        }
    }
}

struct VocabularyView: View {
    private static let performanceLog = Logger(
        subsystem: "com.johnsonzhang.AudioReader",
        category: "vocabulary-performance"
    )
    @Bindable var state: AppState
    var onOpenInText: () -> Void = {}
    @State private var query = ""
    @State private var bookFilter: String = "all"
    @State private var category: VocabCategory? = nil
    @State private var listFilter: VocabularyListFilter = .all
    @State private var pendingDelete: VocabEntry?
    @State private var reviewRequest: VocabularyReviewRequest?
    @State private var showReviewSetup = false
    @State private var exportSelection = AnkiExportSelectionState()
    @State private var isExporting = false
    @State private var ankiDocument: AnkiArchiveDocument?
    @State private var showAnkiExporter = false
    @State private var pendingAnkiReport: AnkiExportReport?
    @State private var ankiReport: AnkiExportReport?
    @State private var ankiExportError: String?
    @State private var projection = VocabularyFilterProjection.empty
    @State private var learningSnapshot = VocabularyLearningSnapshot.empty
    @State private var isFiltering = true
    @State private var refreshClock = Date()
    @State private var learningSnapshotRequest: VocabularyLearningRefreshRequest?
    @State private var pageIndex = 0
    @State private var workspaceSection: VocabularyWorkspaceSection = .today
    @State private var libraryScope: VocabularyLibraryScope = .all
    @State private var pendingDetail: VocabEntry?
    @State private var showAddKnownWord = false
    @State private var knownWordDraft = ""

    private var effectiveListFilter: VocabularyListFilter {
        switch libraryScope {
        case .all: listFilter
        case .learning: .learning
        case .myList: .saved
        case .known: .all
        }
    }

    private var filterRequest: VocabularyFilterRequest {
        VocabularyFilterRequest(
            revision: state.vocabularyLearningRevision,
            query: query,
            bookFilter: bookFilter,
            category: category,
            list: effectiveListFilter,
            minute: Int(refreshClock.timeIntervalSince1970 / 60)
        )
    }

    private var learningRefreshRequest: VocabularyLearningRefreshRequest {
        VocabularyLearningRefreshRequest(
            revision: state.vocabularyLearningRevision,
            minute: Int(refreshClock.timeIntervalSince1970 / 60)
        )
    }

    private var page: VocabularyPage {
        VocabularyPage(entries: projection.filtered, requestedIndex: pageIndex)
    }

    var body: some View {
        exportPresentationContent
    }

    private var baseContent: some View {
        VStack(spacing: 0) {
#if os(macOS)
            header
#endif
            workspaceNavigation
            workspaceContent
        }
        .background(Palette.bg)
#if os(iOS)
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if exportSelection.isActive {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelAnkiExportSelection() }
                }
                ToolbarItem(placement: .principal) {
                    Text("\(exportSelection.selectedCount) selected")
                        .accessibilityLabel("Temporary Anki export selection")
                        .accessibilityValue("\(exportSelection.selectedCount) selected")
                        .accessibilityIdentifier("anki.selection.count")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isExporting ? "Preparing…" : "Export") {
                        startAnkiExport(scope: .selection)
                    }
                    .disabled(exportSelection.selectedCount == 0 || isExporting)
                    .accessibilityHint("Exports the temporary selection without changing review progress or My List.")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startDueReview()
                    } label: {
                        Label("\(projection.due.count) due in this view", systemImage: "rectangle.stack.fill")
                    }
                    .disabled(projection.due.isEmpty || isFiltering)
                    .accessibilityIdentifier("words.reviewDue")
                    .accessibilityHint("Starts a due-first review using the current Words filters.")
                }
                ToolbarItem(placement: .topBarTrailing) { vocabularyUtilitiesMenu }
            }
        }
#endif
    }

    private var observedContent: some View {
        baseContent
        .task(id: filterRequest) {
            await refreshFilterProjection(for: filterRequest)
        }
        .task(id: learningRefreshRequest) {
            await refreshLearningSnapshot(for: learningRefreshRequest)
        }
        .onChange(of: query) { _, _ in pageIndex = 0 }
        .onChange(of: bookFilter) { _, _ in pageIndex = 0 }
        .onChange(of: category) { _, _ in pageIndex = 0 }
        .onChange(of: listFilter) { _, _ in pageIndex = 0 }
        .onChange(of: libraryScope) { _, _ in pageIndex = 0 }
        .onChange(of: workspaceSection) { _, section in
            if section != .library, exportSelection.isActive {
                leaveAnkiExportMode()
            }
        }
        .onDisappear {
            exportSelection.leaveVocabulary()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                refreshClock = Date()
            }
        }
    }

    private var editorPresentationContent: some View {
        observedContent
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
        .sheet(item: $pendingDetail) { entry in
            vocabularyDetail(entry)
        }
        .sheet(isPresented: $showAddKnownWord) {
            addKnownWordView
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
    }

    private var exportPresentationContent: some View {
        editorPresentationContent
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
            } else if let ankiExportError {
                Text(ankiExportError)
            } else {
                Text("The export could not be prepared.")
            }
        }
    }

    private var addKnownWordView: some View {
        NavigationStack {
            Form {
                TextField("Word", text: $knownWordDraft)
                    .accessibilityIdentifier("words.known.wordField")
                Text("Inflected forms are stored with their canonical word family in the current audiobook language.")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            .navigationTitle("Add known word")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        knownWordDraft = ""
                        showAddKnownWord = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if state.addKnownWord(knownWordDraft) {
                            knownWordDraft = ""
                            showAddKnownWord = false
                        }
                    }
                    .disabled(knownWordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 220)
#endif
    }

    private func vocabularyDetail(_ entry: VocabEntry) -> some View {
        NavigationStack {
            ScrollView {
                VocabCard(
                    state: state,
                    entry: entry,
                    assistantBodySize: AssistantTypography.bodySize(
                        forReaderScale: state.settings.readerFontScale
                    ),
                    onOpen: {
                        pendingDetail = nil
                        if state.jumpToVocab(entry) { onOpenInText() }
                    },
                    onToggleLearnList: {
                        state.setVocabularyLearnList(entry.id, included: !entry.isInLearnList)
                        pendingDetail = nil
                    },
                    showsExportSelection: exportSelection.isActive,
                    selectedForExport: exportSelection.isSelected(entry.id),
                    onToggleExportSelection: { exportSelection.toggle(entry.id) },
                    onDelete: {
                        pendingDetail = nil
                        pendingDelete = entry
                    }
                )
                .padding(16)
            }
            .background(Palette.bg)
            .navigationTitle(entry.word)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { pendingDetail = nil }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
#endif
    }

    private var workspaceNavigation: some View {
        Picker("Words section", selection: $workspaceSection) {
            ForEach(VocabularyWorkspaceSection.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityIdentifier("words.section.\(section.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("words.workspaceSection")
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(Palette.panel)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch workspaceSection {
        case .today:
            ScrollView {
                VocabularyLearningDashboard(
                    snapshot: learningSnapshot,
                    onStartSession: startLearningSession
                )
            }
            .scrollContentBackground(.hidden)
        case .library:
            vocabularyLibrary
        }
    }

    @ViewBuilder
    private var vocabularyLibrary: some View {
        VStack(spacing: 0) {
            libraryScopePicker
            filters
            if libraryScope == .known {
                knownWordList
            } else {
                vocabularyEntryList
            }
        }
    }

    private var libraryScopePicker: some View {
        Picker("Vocabulary list", selection: $libraryScope) {
            ForEach(VocabularyLibraryScope.allCases) { scope in
                Text("\(scope.title) \(count(for: scope))")
                    .tag(scope)
                    .accessibilityIdentifier("words.scope.\(scope.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("words.libraryScope")
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var vocabularyEntryList: some View {
        if isFiltering && projection.filtered.isEmpty {
            ProgressView("Preparing vocabulary…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if projection.filtered.isEmpty {
            empty
        } else {
            VStack(spacing: 0) {
                List {
                    ForEach(page.entries) { entry in
                        VocabularyLibraryRow(
                            entry: entry,
                            showsExportSelection: exportSelection.isActive,
                            selectedForExport: exportSelection.isSelected(entry.id),
                            onOpen: { pendingDetail = entry },
                            onToggleLearning: {
                                state.setVocabularyLearnList(entry.id, included: !entry.isInLearnList)
                            },
                            onMarkKnown: learningLemma(for: entry).map { lemma in
                                {
                                    state.setVocabularyLearnList(entry.id, included: false)
                                    state.markKnown(lemma: lemma, known: true)
                                }
                            },
                            onToggleExportSelection: { exportSelection.toggle(entry.id) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteSwipeButton(entry)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            myListSwipeButton(entry)
                        }
                        .contextMenu {
                            Button("View details") { pendingDetail = entry }
                            Button("Open in text") {
                                if state.jumpToVocab(entry) { onOpenInText() }
                            }
                            Button(entry.isInLearnList ? "Remove from My list" : "Add to My list") {
                                state.setVocabularyLearnList(entry.id, included: !entry.isInLearnList)
                            }
                            if learningLemma(for: entry) != nil {
                                Button("Mark known") { moveToKnown(entry) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) { pendingDelete = entry }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                paginationControls
            }
        }
    }

    @ViewBuilder
    private var knownWordList: some View {
        if filteredKnownWords.isEmpty {
            ContentUnavailableView(
                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No known words yet"
                    : "No matching known words",
                systemImage: "checkmark.seal",
                description: Text("Add a word here or use Common words to add canonical word families in bulk.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(filteredKnownWords, id: \.lemma) { record in
                    VocabularyKnownWordRow(record: record) {
                        state.markKnown(lemma: record.lemma, known: false)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Remove", role: .destructive) {
                            state.markKnown(lemma: record.lemma, known: false)
                        }
                    }
                    .contextMenu {
                        Button("Remove from Known", role: .destructive) {
                            state.markKnown(lemma: record.lemma, known: false)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func myListSwipeButton(_ entry: VocabEntry) -> some View {
        Button {
            state.setVocabularyLearnList(entry.id, included: !entry.isInLearnList)
        } label: {
            Label(
                entry.isInLearnList ? "Remove from My list" : "Add to My list",
                systemImage: entry.isInLearnList ? "star.slash" : "star"
            )
        }
        .tint(Palette.gold)
    }

    private func count(for scope: VocabularyLibraryScope) -> Int {
        switch scope {
        case .all: state.vocab.count
        case .learning: learningSnapshot.queue.learning.count
        case .myList: state.vocab.count(where: \.isInLearnList)
        case .known: state.knownLemmas.count
        }
    }

    private var filteredKnownWords: [KnownLemmaRecord] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.knownLemmas
            .filter { search.isEmpty || $0.form.localizedCaseInsensitiveContains(search) }
            .sorted {
                if $0.language != $1.language { return $0.language < $1.language }
                return $0.form.localizedStandardCompare($1.form) == .orderedAscending
            }
    }

    private func learningLemma(for entry: VocabEntry) -> StudyLemma? {
        guard entry.category == .word else { return nil }
        return StudyLemma.make(language: entry.sourceLanguage ?? state.studyLexiconLanguage, surface: entry.studyForm)
    }

    private func moveToKnown(_ entry: VocabEntry) {
        guard let lemma = learningLemma(for: entry) else { return }
        state.setVocabularyLearnList(entry.id, included: false)
        state.markKnown(lemma: lemma, known: true)
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
                Text("\(projection.filtered.count) of \(state.vocab.count)")
                    .foregroundStyle(Palette.dim)
                    .font(.system(size: 12))
            }
            Spacer()
            if exportSelection.isActive {
                HStack(spacing: 8) {
                    Text("\(exportSelection.selectedCount) selected")
                        .foregroundStyle(Palette.dim)
                        .accessibilityLabel("Temporary Anki export selection")
                        .accessibilityValue("\(exportSelection.selectedCount) selected")
                        .accessibilityIdentifier("anki.selection.count")
                    Button("Cancel") { cancelAnkiExportSelection() }
                    .buttonStyle(.borderless)
                    Button(isExporting ? "Preparing…" : "Export") {
                        startAnkiExport(scope: .selection)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(exportSelection.selectedCount == 0 || isExporting)
                    .accessibilityHint("Exports the temporary selection without changing review progress or My List.")
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        startDueReview()
                    } label: {
                        Label("Review due — \(projection.due.count)", systemImage: "rectangle.stack.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.terracotta)
                    .frame(minHeight: 44)
                    .disabled(projection.due.isEmpty || isFiltering)
                    .accessibilityIdentifier("words.reviewDue")
                    .accessibilityHint("Starts a due-first review using the current Words filters.")
                    vocabularyUtilitiesMenu
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
#endif

    private func startDueReview() {
        guard !projection.due.isEmpty, !isFiltering else { return }
        reviewRequest = VocabularyReviewRequest(entryIDs: projection.due.map(\.id))
    }

    private func startLearningSession() {
        guard learningSnapshotRequest == learningRefreshRequest else { return }
        let entries = learningSnapshot.queue.session
        guard !entries.isEmpty else { return }
        reviewRequest = VocabularyReviewRequest(entryIDs: entries.map(\.id))
    }

    private var vocabularyUtilitiesMenu: some View {
        Menu {
            Button {
                showReviewSetup = true
            } label: {
                Label("Choose review", systemImage: "slider.horizontal.3")
            }
            .disabled(state.vocab.isEmpty)
            ankiExportMenu
            CommonEnglishWordsMenu(state: state)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("Vocabulary actions")
        .accessibilityIdentifier("words.actions")
    }

    private var ankiExportMenu: some View {
        Menu {
            Button("Select for Anki export") { beginAnkiExportSelection() }
            Divider()
            Button("Current filtered view") { startAnkiExport(scope: .filtered) }
            Button("My List") { startAnkiExport(scope: .learningList) }
            Button("All Vocabulary") { startAnkiExport(scope: .all) }
        } label: {
            Label(isExporting ? "Preparing export…" : "Export to Anki", systemImage: "square.and.arrow.up")
        }
        .disabled(state.vocab.isEmpty || isExporting || isFiltering)
        .accessibilityIdentifier("anki.export")
    }

    private func startAnkiExport(scope: AnkiExportScope) {
        let entries: [VocabEntry]
        switch scope {
        case .selection:
            entries = exportSelection.entriesForExport(from: state.vocab)
            // The picker must be transient even if archive preparation or saving fails later.
            exportSelection.completeExport()
        case .filtered:
            entries = projection.filtered
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

    private func beginAnkiExportSelection() {
        workspaceSection = .library
        exportSelection.begin()
        Self.performanceLog.info("message=anki.selection component=vocabulary outcome=started")
    }

    private func cancelAnkiExportSelection() {
        exportSelection.cancel()
        Self.performanceLog.info("message=anki.selection component=vocabulary outcome=cancelled")
    }

    private func leaveAnkiExportMode() {
        exportSelection.leaveVocabulary()
        Self.performanceLog.info("message=anki.selection component=vocabulary outcome=left")
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.mute)
                TextField(
                    libraryScope == .known ? "Search known words" : "Search vocabulary",
                    text: $query
                )
                    .textFieldStyle(.plain)
                if isFiltering && libraryScope != .known {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Filtering vocabulary")
                }
                if libraryScope == .known {
                    Button("Add known word") { showAddKnownWord = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.gold)
                        .foregroundStyle(Palette.inkOnGold)
                        .accessibilityIdentifier("words.known.add")
                    CommonEnglishWordsMenu(state: state)
                } else {
                    vocabularyFilterMenu
                }
            }
            .padding(10)
            .background(Palette.panel2)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(filterSummary)
                .font(.caption)
                .foregroundStyle(Palette.dim)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var vocabularyFilterMenu: some View {
        Menu {
            Section("Book") {
                Button {
                    bookFilter = "all"
                } label: {
                    if bookFilter == "all" { Label("All books", systemImage: "checkmark") }
                    else { Text("All books") }
                }
                ForEach(projection.books) { book in
                    Button {
                        bookFilter = book.id
                    } label: {
                        if bookFilter == book.id { Label(book.title, systemImage: "checkmark") }
                        else { Text(book.title) }
                    }
                }
            }
            if libraryScope == .all {
                Section("Study stage") {
                    ForEach(VocabularyListFilter.allCases) { list in
                        Button {
                            listFilter = list
                        } label: {
                            let title = "\(list.title) (\(projection.listCounts[list, default: 0]))"
                            if listFilter == list { Label(title, systemImage: "checkmark") }
                            else { Text(title) }
                        }
                    }
                }
            }
            Section("Type") {
                Button {
                    category = nil
                } label: {
                    if category == nil { Label("All types", systemImage: "checkmark") }
                    else { Text("All types") }
                }
                .accessibilityIdentifier("words.category.all")
                ForEach(VocabCategory.allCases) { value in
                    Button {
                        category = value
                    } label: {
                        let title = "\(value.title) (\(projection.categoryCounts[value, default: 0]))"
                        if category == value { Label(title, systemImage: "checkmark") }
                        else { Text(title) }
                    }
                    .accessibilityIdentifier("words.category.\(value.rawValue)")
                }
            }
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("words.listFilter")
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#endif
    }

    private var filterSummary: String {
        switch libraryScope {
        case .known:
            "\(filteredKnownWords.count) known word\(filteredKnownWords.count == 1 ? "" : "s")"
        case .learning:
            "\(projection.filtered.count) in Learning · Learning stage is based on review progress."
        case .myList:
            "\(projection.filtered.count) in My List · My list is the list you control."
        case .all:
            "\(projection.filtered.count) of \(state.vocab.count) · \(listFilter.title)"
        }
    }

    @ViewBuilder
    private var paginationControls: some View {
        if page.pageCount > 1 {
            Group {
#if os(iOS)
                compactPaginationControls
#else
                HStack(spacing: 8) {
                    pageRangeLabel
                    Spacer()
                    firstPageButton
                    previousPageButton
                    pagePicker
                    nextPageButton
                    lastPageButton
                }
#endif
            }
#if os(iOS)
            .buttonStyle(.plain)
#else
            .buttonStyle(.borderless)
#endif
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
            .background(Palette.panel)
            .overlay(alignment: .top) {
                Divider().foregroundStyle(Palette.line)
            }
        }
    }

    private var compactPaginationControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                pageRangeLabel
                Spacer()
                pagePicker
            }
            HStack(spacing: 8) {
                firstPageButton
                previousPageButton
                Spacer(minLength: 8)
                nextPageButton
                lastPageButton
            }
        }
    }

    private var pageRangeLabel: some View {
        Text(page.rangeDescription)
            .font(.caption)
            .foregroundStyle(Palette.dim)
            .accessibilityLabel("Showing \(page.rangeDescription)")
            .accessibilityIdentifier("words.pageRange")
    }

    private var pagePicker: some View {
        Picker("Page", selection: $pageIndex) {
            ForEach(0..<page.pageCount, id: \.self) { index in
                Text("Page \(index + 1) of \(page.pageCount)").tag(index)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
#if os(iOS)
        .frame(minHeight: 44)
#endif
        .accessibilityIdentifier("words.pagePicker")
    }

    private var firstPageButton: some View {
        Button {
            pageIndex = 0
        } label: {
            paginationIcon("backward.end")
        }
        .disabled(page.index == 0)
        .accessibilityLabel("First page")
        .accessibilityIdentifier("words.pageFirst")
    }

    private var previousPageButton: some View {
        Button {
            pageIndex = max(0, page.index - 1)
        } label: {
            paginationIcon("chevron.left")
        }
        .disabled(page.index == 0)
        .accessibilityLabel("Previous page")
        .accessibilityIdentifier("words.pagePrevious")
    }

    private var nextPageButton: some View {
        Button {
            pageIndex = min(page.pageCount - 1, page.index + 1)
        } label: {
            paginationIcon("chevron.right")
        }
        .disabled(page.index == page.pageCount - 1)
        .accessibilityLabel("Next page")
        .accessibilityIdentifier("words.pageNext")
    }

    private var lastPageButton: some View {
        Button {
            pageIndex = page.pageCount - 1
        } label: {
            paginationIcon("forward.end")
        }
        .disabled(page.index == page.pageCount - 1)
        .accessibilityLabel("Last page")
        .accessibilityIdentifier("words.pageLast")
    }

    private func paginationIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
#if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
#endif
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: emptySymbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.gold)
            Text(emptyTitle)
                .font(.headline)
                .foregroundStyle(Palette.ink)
            Text(emptyDescription)
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySymbol: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "magnifyingglass" }
        return effectiveListFilter.symbol
    }

    private var emptyTitle: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching vocabulary" }
        return switch effectiveListFilter {
        case .all: "No vocabulary yet"
        case .saved: "My list is empty"
        case .due: "Nothing due now"
        case .new: "No new cards"
        case .learning: "No cards are learning"
        case .review: "No cards are in review"
        }
    }

    private var emptyDescription: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try another search or change the current book, list, or category filters."
        }
        return switch effectiveListFilter {
        case .all:
            "Select a word while reading to add it to Vocabulary."
        case .saved:
            "Choose Add to My list on any vocabulary item to collect it for focused study."
        case .due:
            "Your reviewed cards are scheduled for later."
        case .new:
            "Every card in this view has already started its study schedule."
        case .learning:
            "Cards appear here after review while their interval is under seven days."
        case .review:
            "Cards appear here when their review interval reaches seven days."
        }
    }

    /// Filtering is cancellable and off-main so typing never competes with
    /// playback or review controls for the UI thread.
    private func refreshFilterProjection(for request: VocabularyFilterRequest) async {
        let requestID = UUID().uuidString
        let startedAt = Date()
        isFiltering = true
        if !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        let entries = state.vocab
        Self.performanceLog.info(
            "words_projection_start message=words_projection_start requestId=\(requestID, privacy: .public) component=vocabulary outcome=started total=\(entries.count, privacy: .public)"
        )
        let worker = Task.detached(priority: .userInitiated) {
            try VocabularyFilterProjection.makeCancellable(
                entries: entries,
                query: request.query,
                bookFilter: request.bookFilter,
                category: request.category,
                list: request.list,
                at: Date()
            )
        }
        let result: VocabularyFilterProjection
        do {
            result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            return
        }
        guard !Task.isCancelled, request == filterRequest else { return }
        projection = result
        pageIndex = VocabularyPage(entries: result.filtered, requestedIndex: pageIndex).index
        isFiltering = false
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        Self.performanceLog.info(
            "words_projection_finish message=words_projection_finish requestId=\(requestID, privacy: .public) component=vocabulary outcome=ready filtered=\(result.filtered.count, privacy: .public) availableRows=\(result.filtered.count, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)"
        )
    }

    /// Dashboard analytics depend only on learning-data revisions, not on
    /// search or presentation filters, and are safe to derive off-main.
    private func refreshLearningSnapshot(for request: VocabularyLearningRefreshRequest) async {
        learningSnapshotRequest = nil
        let entries = state.vocab
        let events = state.vocabReviewEvents
        let worker = Task.detached(priority: .utility) {
            try VocabularyLearningAnalytics.snapshotCancellable(entries: entries, events: events, at: Date())
        }
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, request == learningRefreshRequest else { return }
            learningSnapshot = snapshot
            learningSnapshotRequest = request
        } catch {
            return
        }
    }
}

private struct VocabularyFilterRequest: Hashable, Sendable {
    let revision: UInt
    let query: String
    let bookFilter: String
    let category: VocabCategory?
    let list: VocabularyListFilter
    let minute: Int
}

private struct VocabularyLearningRefreshRequest: Hashable, Sendable {
    let revision: UInt
    let minute: Int
}

private struct VocabularyReviewRequest: Identifiable {
    let id = UUID()
    let entryIDs: [String]
}

private enum AnkiExportScope {
    case selection
    case filtered
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

private struct VocabularyLibraryRow: View {
    let entry: VocabEntry
    let showsExportSelection: Bool
    let selectedForExport: Bool
    let onOpen: () -> Void
    let onToggleLearning: () -> Void
    let onMarkKnown: (() -> Void)?
    let onToggleExportSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if showsExportSelection {
                Button(action: onToggleExportSelection) {
                    Image(systemName: selectedForExport ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedForExport ? Palette.terracotta : Palette.dim)
                .accessibilityLabel(selectedForExport ? "Remove from export selection" : "Add to export selection")
                .accessibilityValue(selectedForExport ? "Selected" : "Not selected")
                .accessibilityHint("Temporary selection. Does not change My List or review progress.")
                .accessibilityAddTraits(selectedForExport ? .isSelected : [])
                .accessibilityIdentifier("anki.selection.\(entry.id)")
#if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
#endif
            }

            Button(action: onOpen) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(entry.word)
                                .font(.system(.body, design: .serif, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Text(entry.category.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Palette.gold)
                        }
                        Text("\(entry.bookTitle) · \(entry.chapterTitle)")
                            .font(.caption)
                            .foregroundStyle(Palette.dim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(VocabularyLearningStage.resolve(entry).rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(Palette.dim)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.mute)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.word), \(entry.category.title), \(entry.bookTitle)")
            .accessibilityHint("Opens vocabulary details and editing actions.")

            Button(action: onToggleLearning) {
                Image(systemName: entry.isInLearnList ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(entry.isInLearnList ? Palette.gold : Palette.dim)
            .accessibilityLabel(
                entry.isInLearnList
                    ? "Remove \(entry.word) from My list"
                    : "Add \(entry.word) to My list"
            )
            .accessibilityIdentifier("words.myList.\(entry.id)")
#if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
#endif

            if let onMarkKnown {
                Button(action: onMarkKnown) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.dim)
                .accessibilityLabel("Mark \(entry.word) known")
                .accessibilityIdentifier("words.markKnown.\(entry.id)")
#if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
#endif
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("words.row.\(entry.id)")
    }
}

private struct VocabularyKnownWordRow: View {
    let record: KnownLemmaRecord
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Palette.gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.form)
                    .font(.system(.body, design: .serif, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(record.language.uppercased())
                    .font(.caption2)
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(record.form) from Known")
#if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
#endif
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("words.known.\(record.language).\(record.form)")
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
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#else
        .controlSize(.small)
#endif
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
    let showsExportSelection: Bool
    let selectedForExport: Bool
    let onToggleExportSelection: () -> Void
    let onDelete: () -> Void
    @State private var dictHeight: CGFloat = 140
    @State private var showDictHTML = false
    @State private var showCanonicalEditor = false
    @State private var canonicalDraft = ""
    @State private var meaningChoices: [VocabularyMeaningChoice] = []
    @State private var selectedMeaningID = ""
    @State private var partOfSpeechDraft = VocabularyPartOfSpeech.unknown
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dictionary = VocabularyDictionaryPresentation(entry: entry)
        VStack(alignment: .leading, spacing: 10) {
            cardHeader

            Text("\(entry.bookTitle) · \(entry.chapterTitle) · \(formatClock(entry.timestamp))")
                .font(.system(size: 11))
                .foregroundStyle(Palette.mute)

            studyIdentityControls

            labeled("Original text") {
                Text(entry.ebookText ?? entry.context)
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if dictionary.html != nil || !dictionary.summary.isEmpty {
                labeled(entry.dictionaryName.map { "Apple Dictionary · \($0)" } ?? "Apple Dictionary") {
                    if !dictionary.summary.isEmpty {
                        DictionarySummaryView(lines: dictionary.summary)
                    }
                    if let html = dictionary.html {
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("words.card.\(entry.id)")
        .sheet(isPresented: $showCanonicalEditor) {
            canonicalEditor
        }
    }

    @ViewBuilder
    private var cardHeader: some View {
#if os(iOS)
        VStack(alignment: .leading, spacing: 8) {
            cardTitle
            cardActions
        }
#else
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            cardTitle
            cardActions
        }
#endif
    }

    private var cardTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.word)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .textSelection(.enabled)
            Text(entry.category.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.gold)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Palette.goldSoft)
                .clipShape(Capsule())
            if entry.studyForm.caseInsensitiveCompare(entry.word) != .orderedSame {
                Text("Study as \(entry.studyForm)")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var studyIdentityControls: some View {
        if !entry.reviewEligible {
            Button {
                state.acceptVocabularyForReview(entry.id)
            } label: {
                Label(
                    entry.category == .sentence ? "Save sentence as card" : "Accept phrase suggestion",
                    systemImage: "rectangle.stack.badge.plus"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.gold)
            .foregroundStyle(Palette.inkOnGold)
            .disabled(entry.canonicalizationStatus == .needsReview)
            .accessibilityHint(
                entry.canonicalizationStatus == .needsReview
                    ? "Confirm the study form before accepting this item."
                    : "Adds this item to New without changing My list."
            )
        }
        if entry.canonicalizationStatus == .needsReview {
            Button {
                presentMeaningEditor()
            } label: {
                Label("Confirm meaning", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Choose the plain-language meaning used here before this item can merge with another card.")
        } else {
            Button {
                presentMeaningEditor()
            } label: {
                Label("Edit meaning", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Merge this occurrence with an equivalent card or separate an incorrect merge.")
        }
    }

    private var canonicalEditor: some View {
        NavigationStack {
            Form {
                TextField("Canonical study form", text: $canonicalDraft)
                Picker("Part of speech", selection: $partOfSpeechDraft) {
                    ForEach(VocabularyPartOfSpeech.allCases, id: \.self) { value in
                        Text(value.rawValue.capitalized).tag(value)
                    }
                }
                Section("Meaning in this sentence") {
                    Picker("Meaning", selection: $selectedMeaningID) {
                        ForEach(meaningChoices) { choice in
                            Text(choice.title).tag(choice.id)
                        }
                    }
                    Text(entry.context)
                        .font(.caption)
                        .foregroundStyle(Palette.dim)
                }
                if canSeparateMeaning {
                    Button("Separate meaning", role: .destructive) {
                        state.separateVocabularyMeaning(entry.id)
                        showCanonicalEditor = false
                    }
                    .accessibilityHint("Keeps this occurrence and its review schedule but gives it a separate card.")
                }
            }
            .navigationTitle("Confirm meaning")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCanonicalEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isMergingMeaning ? "Merge cards" : "Save") {
                        guard let choice = selectedMeaningChoice else { return }
                        state.confirmVocabularyMeaning(
                            entry.id,
                            canonicalForm: canonicalDraft,
                            partOfSpeech: partOfSpeechDraft,
                            choice: choice
                        )
                        showCanonicalEditor = false
                    }
                    .disabled(
                        VocabularyCanonicalizer.normalizedForm(canonicalDraft).isEmpty
                            || selectedMeaningChoice == nil
                    )
                }
            }
        }
    }

    private var selectedMeaningChoice: VocabularyMeaningChoice? {
        meaningChoices.first { $0.id == selectedMeaningID }
    }

    private var isMergingMeaning: Bool {
        selectedMeaningChoice?.occurrenceIDs.contains(where: { $0 != entry.id }) == true
    }

    private var canSeparateMeaning: Bool {
        entry.canonicalizationStatus == .confirmed
            && (VocabularyStudyCards.card(containing: entry.id, in: state.vocab)?.occurrences.count ?? 0) > 1
    }

    private func presentMeaningEditor() {
        canonicalDraft = entry.studyForm
        partOfSpeechDraft = entry.partOfSpeech
        meaningChoices = VocabularySenseConfirmation.choices(for: entry, among: state.vocab)
        selectedMeaningID = meaningChoices.first(where: { $0.occurrenceIDs.contains(entry.id) })?.id
            ?? meaningChoices.first?.id
            ?? ""
        showCanonicalEditor = true
    }

    @ViewBuilder
    private var cardActions: some View {
#if os(iOS)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if showsExportSelection {
                    exportSelectionButton
                }
                VocabOriginalPlayButton(state: state, entry: entry, labeled: false)
                openInTextButton
                learnListButton
                deleteButton
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if showsExportSelection {
                        exportSelectionButton
                    }
                    VocabOriginalPlayButton(state: state, entry: entry, labeled: false)
                    openInTextButton
                }
                HStack(spacing: 8) {
                    learnListButton
                    deleteButton
                }
            }
        }
#else
        HStack(spacing: 8) {
            if showsExportSelection {
                exportSelectionButton
            }
            VocabOriginalPlayButton(state: state, entry: entry, labeled: false)
            openInTextButton
            learnListButton
            deleteButton
        }
#endif
    }

    private var exportSelectionButton: some View {
        Button(action: onToggleExportSelection) {
            Image(systemName: selectedForExport ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.plain)
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#endif
        .foregroundStyle(selectedForExport ? Palette.terracotta : Palette.dim)
        .accessibilityLabel(
            selectedForExport
                ? "Remove \(entry.word) from temporary Anki export selection"
                : "Add \(entry.word) to temporary Anki export selection"
        )
        .accessibilityValue(selectedForExport ? "Selected" : "Not selected")
        .accessibilityHint("Temporary selection. Does not change My List or review progress.")
        .accessibilityAddTraits(selectedForExport ? .isSelected : [])
        .accessibilityIdentifier("anki.selection.\(entry.id)")
    }

    private var openInTextButton: some View {
        Button(action: onOpen) {
            Label("Open in text", systemImage: "text.alignleft")
        }
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#else
        .controlSize(.small)
#endif
        .buttonStyle(.borderless)
    }

    private var learnListButton: some View {
        Button(action: onToggleLearnList) {
            Label(
                entry.isInLearnList ? "In My list" : "Add to My list",
                systemImage: entry.isInLearnList ? "star.fill" : "star"
            )
        }
        .buttonStyle(.bordered)
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#else
        .controlSize(.small)
#endif
        .tint(entry.isInLearnList ? Palette.gold : Palette.dim)
        .accessibilityIdentifier("words.myList.\(entry.id)")
        .accessibilityHint(
            entry.isInLearnList
                ? "Removes this item from your saved list."
                : "Adds this item to your saved list for focused study."
        )
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
        }
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#else
        .controlSize(.small)
#endif
        .buttonStyle(.borderless)
        .accessibilityLabel("Delete \(entry.word)")
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
