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
    @State private var selectedForExport: Set<String> = []
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

    private var filterRequest: VocabularyFilterRequest {
        VocabularyFilterRequest(
            revision: state.vocabularyLearningRevision,
            query: query,
            bookFilter: bookFilter,
            category: category,
            list: listFilter,
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
            ToolbarItem(placement: .secondaryAction) {
                Button("Review by list or book") { showReviewSetup = true }
                    .disabled(state.vocab.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                ankiExportMenu
            }
        }
#endif
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
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                refreshClock = Date()
            }
        }
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

    private var workspaceNavigation: some View {
        HStack(spacing: 8) {
            ForEach(VocabularyWorkspaceSection.allCases) { section in
                Button {
                    workspaceSection = section
                } label: {
                    Label(section.title, systemImage: section.symbol)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(workspaceSection == section ? Palette.ink : Palette.dim)
                .background(
                    workspaceSection == section ? Palette.goldSoft : Palette.panel2,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(workspaceSection == section ? Palette.gold.opacity(0.55) : Palette.line)
                }
                .accessibilityIdentifier("words.section.\(section.rawValue)")
                .accessibilityValue(workspaceSection == section ? "Selected" : "Not selected")
            }
        }
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
            filters
            if isFiltering && projection.filtered.isEmpty {
                ProgressView("Preparing vocabulary…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if projection.filtered.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    List {
                        ForEach(page.entries) { entry in
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
                    paginationControls
                }
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
                Text("\(projection.filtered.count) of \(state.vocab.count)")
                    .foregroundStyle(Palette.dim)
                    .font(.system(size: 12))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    startDueReview()
                } label: {
                    Label("Review \(projection.due.count) due in this view", systemImage: "rectangle.stack.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.terracotta)
                .frame(minHeight: 44)
                .disabled(projection.due.isEmpty || isFiltering)
                .accessibilityIdentifier("words.reviewDue")
                .accessibilityHint("Starts a due-first review using the current Words filters.")
                Button("Review by list or book") { showReviewSetup = true }
                    .buttonStyle(.borderless)
                    .disabled(state.vocab.isEmpty)
                ankiExportMenu
                Text("\(projection.listCounts[.saved, default: 0]) in My list")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
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

    private var ankiExportMenu: some View {
        Menu {
            Button(selectedForExport.isEmpty ? "Current filtered view" : "Selected items (\(selectedForExport.count))") {
                startAnkiExport(scope: .selectionOrFiltered)
            }
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
        case .selectionOrFiltered:
            entries = selectedForExport.isEmpty
                ? projection.filtered
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
                Text("\(projection.filtered.count) of \(state.vocab.count)")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
                Spacer()
                Text("\(projection.listCounts[.saved, default: 0]) in My list")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
#endif
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.mute)
                TextField("Search words, phrases, sentences, books", text: $query)
                    .textFieldStyle(.plain)
                if isFiltering {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Filtering vocabulary")
                }
            }
            .padding(10)
            .background(Palette.panel2)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Picker("Book", selection: $bookFilter) {
                Text("All books").tag("all")
                ForEach(projection.books) { book in
                    Text(book.title).tag(book.id)
                }
            }
            .pickerStyle(.menu)

            Picker("List", selection: $listFilter) {
                ForEach(VocabularyListFilter.allCases) { list in
                    Label(
                        "\(list.title) (\(projection.listCounts[list, default: 0]))",
                        systemImage: list.symbol
                    )
                    .tag(list)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("words.listFilter")
            .accessibilityValue(
                "\(listFilter.title), \(projection.filtered.count) shown"
            )
            .accessibilityHint("Filters the current book by saved membership or automatic study stage.")

            Text("My list is the list you control. New, Learning, Review, and Due now update automatically as you study.")
                .font(.caption)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            categoryFilters
        }
        .padding(.horizontal, 24)
#if os(iOS)
        .padding(.top, 8)
        .padding(.bottom, 6)
#else
        .padding(.bottom, 8)
#endif
    }

    @ViewBuilder
    private var categoryFilters: some View {
#if os(iOS)
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                categoryFilterButtons
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Vocabulary categories")
#else
        HStack(spacing: 8) {
            categoryFilterButtons
        }
#endif
    }

    @ViewBuilder
    private var categoryFilterButtons: some View {
        categoryChip(
            nil,
            title: "All",
            symbol: "square.grid.2x2",
            count: projection.allCategoryCount
        )
        ForEach(VocabCategory.allCases) { cat in
            categoryChip(
                cat,
                title: cat.title,
                symbol: cat.symbol,
                count: projection.categoryCounts[cat, default: 0]
            )
        }
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
            .buttonStyle(.borderless)
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
            Image(systemName: "backward.end")
        }
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#endif
        .disabled(page.index == 0)
        .accessibilityLabel("First page")
        .accessibilityIdentifier("words.pageFirst")
    }

    private var previousPageButton: some View {
        Button {
            pageIndex = max(0, page.index - 1)
        } label: {
            Image(systemName: "chevron.left")
        }
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#endif
        .disabled(page.index == 0)
        .accessibilityLabel("Previous page")
        .accessibilityIdentifier("words.pagePrevious")
    }

    private var nextPageButton: some View {
        Button {
            pageIndex = min(page.pageCount - 1, page.index + 1)
        } label: {
            Image(systemName: "chevron.right")
        }
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#endif
        .disabled(page.index == page.pageCount - 1)
        .accessibilityLabel("Next page")
        .accessibilityIdentifier("words.pageNext")
    }

    private var lastPageButton: some View {
        Button {
            pageIndex = page.pageCount - 1
        } label: {
            Image(systemName: "forward.end")
        }
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#endif
        .disabled(page.index == page.pageCount - 1)
        .accessibilityLabel("Last page")
        .accessibilityIdentifier("words.pageLast")
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
        return listFilter.symbol
    }

    private var emptyTitle: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching vocabulary" }
        return switch listFilter {
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
        return switch listFilter {
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
    let selectedForExport: Bool
    let onToggleExportSelection: () -> Void
    let onDelete: () -> Void
    @State private var dictHeight: CGFloat = 140
    @State private var showDictHTML = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dictionary = VocabularyDictionaryPresentation(entry: entry)
        VStack(alignment: .leading, spacing: 10) {
            cardHeader

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
        .accessibilityIdentifier("words.card.\(entry.id)")
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
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var cardActions: some View {
#if os(iOS)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                exportSelectionButton
                VocabOriginalPlayButton(state: state, entry: entry, labeled: false)
                openInTextButton
                learnListButton
                deleteButton
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    exportSelectionButton
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
            exportSelectionButton
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
        .accessibilityLabel(selectedForExport ? "Remove from Anki export selection" : "Select for Anki export")
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
