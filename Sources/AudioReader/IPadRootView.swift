import CoreGraphics

enum IPadBackgroundJobsToolbarPlacement: Equatable {
    case content
    case detail

    static func owner(
        isVocabularySelected: Bool,
        isReaderActive: Bool,
        isSettingsSelected: Bool = false,
        hasSelectedBook: Bool
    ) -> Self {
        isVocabularySelected || isReaderActive || isSettingsSelected || hasSelectedBook ? .detail : .content
    }
}

enum IPadSplitColumnPolicy: Equatable {
    static let sidebarMin: CGFloat = 180
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMax: CGFloat = 300
    static let contentMin: CGFloat = 200
    static let contentIdeal: CGFloat = 260
    static let contentMax: CGFloat = 560

    enum Mode: Equatable {
        case library
        case readingFocused
        case readingWithLibrary
        case vocabularyFocused
        case settings
    }

    static func mode(
        isReaderActive: Bool,
        isVocabularySelected: Bool,
        isSettingsSelected: Bool = false,
        showsLibraryAlongside: Bool
    ) -> Mode {
        if isSettingsSelected {
            return .settings
        }
        if isReaderActive {
            return showsLibraryAlongside ? .readingWithLibrary : .readingFocused
        }
        if isVocabularySelected {
            return .vocabularyFocused
        }
        return .library
    }
}

#if os(iOS)
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum IPadLibrarySource: String, CaseIterable, Identifiable {
    case allBooks
    case nowReading
    case deviceAudiobooks
    case files
    case folders
    case vocabulary
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allBooks: "All Books"
        case .nowReading: "Now Reading"
        case .deviceAudiobooks: "Device Audiobooks"
        case .files: "Files"
        case .folders: "Folders"
        case .vocabulary: "Vocabulary"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .allBooks: "books.vertical"
        case .nowReading: "text.alignleft"
        case .deviceAudiobooks: "ipad.and.iphone"
        case .files: "doc"
        case .folders: "folder"
        case .vocabulary: "bookmark"
        case .settings: "gearshape"
        }
    }
}

private enum IPadImportRequest: Identifiable {
    case files
    case folder
    case ebook(bookID: String)

    var id: String {
        switch self {
        case .files: "files"
        case .folder: "folder"
        case .ebook(let bookID): "ebook-\(bookID)"
        }
    }

    var contentTypes: [UTType] {
        switch self {
        case .files: [.mp3, .mpeg4Audio, .epub, .image, .audio]
        case .folder: [.folder]
        case .ebook: [.epub]
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .files: true
        case .folder, .ebook: false
        }
    }
    var importsAsCopy: Bool {
        switch self {
        case .files, .ebook: true
        case .folder: false
        }
    }
}

struct IPadRootView: View {
    @Bindable var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsLibraryAlongsideReader = false
    @State private var source: IPadLibrarySource? = .allBooks
    @State private var deviceLibrary = DeviceAudiobookLibrary()
    @State private var importRequest: IPadImportRequest?
    @State private var importingDeviceID: UInt64?
    @State private var importMessage: String?
    @State private var importError: String?
    @State private var pendingBookDelete: Book?

    var body: some View {
        Group {
            if source == .settings {
                settingsSplit
                    .navigationSplitViewStyle(.automatic)
            } else {
                librarySplit
                    .navigationSplitViewStyle(.prominentDetail)
            }
        }
        .tint(Palette.terracotta)
        .safeAreaInset(edge: .top, spacing: 0) {
            WorkStatusBanner(
                library: state.libraryScanProgress,
                accountMessage: state.account.activityMessage
            )
        }
        .sheet(item: $state.chapterStudyPresentation) { _ in
            ChapterStudyListView(state: state)
        }
        .alert("Could Not Open Background Job", isPresented: Binding(
            get: { state.backgroundJobNavigationError != nil },
            set: { if !$0 { state.backgroundJobNavigationError = nil } }
        )) {
            Button("OK", role: .cancel) { state.backgroundJobNavigationError = nil }
        } message: {
            Text(state.backgroundJobNavigationError ?? "The original chapter is no longer available.")
        }
        .sheet(item: $importRequest) { request in
            IPadDocumentPicker(request: request) { result in
                switch request {
                case .files: importFiles(result)
                case .folder: importFolder(result)
                case .ebook(let bookID): importEbook(result, bookID: bookID)
                }
                importRequest = nil
            }
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown import error")
        }
        .alert("Delete book?", isPresented: Binding(
            get: { pendingBookDelete != nil },
            set: { if !$0 { pendingBookDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingBookDelete = nil }
            Button("Delete Book", role: .destructive) {
                if let book = pendingBookDelete {
                    deleteBook(book)
                }
                pendingBookDelete = nil
            }
        } message: {
            Text("Delete “\(pendingBookDelete?.title ?? "this book")” and its imported audio, ebook, cover, and chapter metadata from AudioReader? Vocabulary entries will be kept. This cannot be undone.")
        }
        .task {
#if DEBUG
            if UITestLaunchScenario.isRequested {
                UITestLaunchScenario.applyIfRequested(to: state)
            } else {
                await state.boot()
            }
#else
            await state.boot()
#endif
            if state.tab == .settings {
                source = .settings
                applyColumnMode(
                    isReaderActive: false,
                    isSettingsSelected: true,
                    showsLibraryAlongsideReader: false
                )
            } else if state.tab == .player {
                source = .nowReading
                applyColumnMode(isReaderActive: true, showsLibraryAlongsideReader: false)
            } else if state.tab == .vocab {
                source = .vocabulary
                applyColumnMode(
                    isReaderActive: false,
                    isVocabularySelected: true,
                    showsLibraryAlongsideReader: false
                )
            }
        }
        .onChange(of: source) { _, selected in
            if selected == .deviceAudiobooks {
                Task { await deviceLibrary.requestAccessAndReload() }
            }
            if selected == .vocabulary {
                state.tab = .vocab
            } else if selected == .nowReading {
                state.tab = .player
            } else if selected == .settings {
                state.tab = .settings
            } else if state.tab != .library {
                state.tab = .library
            }
        }
        .onChange(of: state.tab) { _, tab in
            if tab == .settings {
                source = .settings
            } else if tab == .player {
                source = .nowReading
            } else if tab == .vocab {
                source = .vocabulary
            }
            applyColumnMode(
                isReaderActive: tab == .player,
                isVocabularySelected: tab == .vocab,
                isSettingsSelected: tab == .settings,
                showsLibraryAlongsideReader: false
            )
        }
    }

    private func applyColumnMode(
        isReaderActive: Bool,
        isVocabularySelected: Bool = false,
        isSettingsSelected: Bool = false,
        showsLibraryAlongsideReader: Bool
    ) {
        self.showsLibraryAlongsideReader = showsLibraryAlongsideReader
        switch IPadSplitColumnPolicy.mode(
            isReaderActive: isReaderActive,
            isVocabularySelected: isVocabularySelected,
            isSettingsSelected: isSettingsSelected,
            showsLibraryAlongside: showsLibraryAlongsideReader
        ) {
        case .library, .settings:
            columnVisibility = .all
        case .readingFocused, .vocabularyFocused:
            columnVisibility = .detailOnly
        case .readingWithLibrary:
            columnVisibility = .doubleColumn
        }
    }

    private var librarySidebar: some View {
        sourceSidebar
            .navigationTitle("Library")
            .navigationSplitViewColumnWidth(
                min: IPadSplitColumnPolicy.sidebarMin,
                ideal: IPadSplitColumnPolicy.sidebarIdeal,
                max: IPadSplitColumnPolicy.sidebarMax
            )
    }

    private var librarySplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            librarySidebar
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(
                    min: IPadSplitColumnPolicy.contentMin,
                    ideal: IPadSplitColumnPolicy.contentIdeal,
                    max: IPadSplitColumnPolicy.contentMax
                )
                .toolbar {
                    backgroundJobsToolbar(for: .content)
                }
        } detail: {
            detailColumn
                .toolbar {
                    backgroundJobsToolbar(for: .detail)
                }
        }
    }

    private var settingsSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            librarySidebar
        } detail: {
            SettingsView(state: state)
                .toolbar {
                    backgroundJobsToolbar(for: .detail)
                }
        }
    }

    private var sourceSidebar: some View {
        List {
            Section {
                sourceRow(.allBooks)
                sourceRow(.nowReading)
                sourceRow(.vocabulary)
                sourceRow(.settings)
            }
            Section("Sources") {
                sourceRow(.deviceAudiobooks)
                sourceRow(.files)
                sourceRow(.folders)
            }
            Section("Cloud") {
                iPadSyncStatus
            }
        }
        .listStyle(.sidebar)
    }

    private func sourceRow(_ item: IPadLibrarySource) -> some View {
        Button {
            source = item
        } label: {
            Label(item.title, systemImage: item.symbol)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(source == item ? Palette.terracotta.opacity(0.16) : Color.clear)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier(sidebarIdentifier(for: item))
        .accessibilityAddTraits(source == item ? .isSelected : [])
    }

    private func sidebarIdentifier(for item: IPadLibrarySource) -> String {
        switch item {
        case .allBooks: "sidebar.library"
        case .nowReading: "sidebar.nowReading"
        case .vocabulary: "sidebar.words"
        case .settings: "sidebar.settings"
        case .deviceAudiobooks: "source.deviceAudiobooks"
        case .files: "source.files"
        case .folders: "source.folders"
        }
    }

    private var iPadSyncStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountSyncStatusView(session: state.account, compact: true)
            Button {
                Task { await state.account.synchronize() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(state.account.isBusy || !state.account.mode.isSyncEnabled)
            .accessibilityIdentifier("sync.now")
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch source ?? .allBooks {
        case .deviceAudiobooks:
            DeviceAudiobooksView(
                library: deviceLibrary,
                importedBooks: filteredBooks,
                selectedBookID: $state.selectedBookID,
                importingID: importingDeviceID,
                importMessage: importMessage,
                onRefresh: { Task { await deviceLibrary.requestAccessAndReload() } },
                onImport: importDeviceAudiobook,
                onDelete: { pendingBookDelete = $0 }
            )
            .navigationTitle("Apple Books & Device")
        case .settings:
            Color.clear
                .accessibilityHidden(true)
        case .vocabulary:
            List {
                Section("Saved") {
                    LabeledContent("Items", value: "\(state.vocab.count)")
                    LabeledContent("Learn list", value: "\(state.vocab.count(where: \.isInLearnList))")
                }
            }
            .navigationTitle("Saved words")
        case .allBooks, .files, .folders:
            IPadBookList(
                books: filteredBooks,
                selectedBookID: $state.selectedBookID,
                readyChapterIDs: state.readyChapterIDs,
                importMessage: importMessage,
                onDelete: { pendingBookDelete = $0 }
            )
            .navigationTitle((source ?? .allBooks).title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if source == .files {
                        Button { importRequest = .files } label: { Label("Import Files", systemImage: "doc.badge.plus") }
                    } else if source == .folders {
                        Button { importRequest = .folder } label: { Label("Import Folder", systemImage: "folder.badge.plus") }
                    } else {
                        Menu {
                            Button { importRequest = .files } label: { Label("Files", systemImage: "doc.badge.plus") }
                            Button { importRequest = .folder } label: { Label("Folder", systemImage: "folder.badge.plus") }
                        } label: {
                            Label("Import audiobook + EPUB", systemImage: "plus")
                        }
                        .accessibilityIdentifier("library.importPaired")
                    }
                }
            }
        case .nowReading:
            Color.clear.accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if source == .vocabulary {
            VocabularyView(state: state) {
                source = .allBooks
                applyColumnMode(isReaderActive: false, showsLibraryAlongsideReader: false)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        source = .allBooks
                        applyColumnMode(isReaderActive: false, showsLibraryAlongsideReader: false)
                    } label: {
                        Label("Library", systemImage: "chevron.backward")
                    }
                }
            }
        } else if source == .nowReading || state.tab == .player {
            PlayerView(state: state)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            state.tab = .library
                            applyColumnMode(isReaderActive: false, showsLibraryAlongsideReader: false)
                        } label: {
                            Label("Book", systemImage: "chevron.backward")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            applyColumnMode(
                                isReaderActive: true,
                                showsLibraryAlongsideReader: !showsLibraryAlongsideReader
                            )
                        } label: {
                            Label(
                                showsLibraryAlongsideReader ? "Focus Reading" : "Show Library",
                                systemImage: showsLibraryAlongsideReader
                                    ? "rectangle.expand.vertical"
                                    : "sidebar.left"
                            )
                        }
                        .help(showsLibraryAlongsideReader ? "Hide the library columns and maximize reading space" : "Show the book list beside the reader")
                    }
                }
        } else if let book = state.selectedBook {
            IPadBookDetail(
                state: state,
                book: book,
                onAddEbook: { importRequest = .ebook(bookID: book.id) },
                onDelete: { pendingBookDelete = book }
            )
        } else {
            ContentUnavailableView("Choose an audiobook", systemImage: "books.vertical", description: Text("Select a book, or import one from Files, a folder, Apple Books, or the device audiobook library."))
        }
    }

    private var filteredBooks: [Book] {
        switch source ?? .allBooks {
        case .allBooks: state.books
        case .nowReading: state.books
        case .files: state.books.filter { $0.source == .files }
        case .folders: state.books.filter { $0.source == .localFolder }
        case .deviceAudiobooks: state.books.filter { $0.source == .deviceAudiobooks }
        case .vocabulary, .settings: []
        }
    }

    private var backgroundJobsToolbarPlacement: IPadBackgroundJobsToolbarPlacement {
        .owner(
            isVocabularySelected: source == .vocabulary,
            isReaderActive: state.tab == .player,
            isSettingsSelected: source == .settings,
            hasSelectedBook: state.selectedBook != nil
        )
    }

    @ToolbarContentBuilder
    private func backgroundJobsToolbar(
        for placement: IPadBackgroundJobsToolbarPlacement
    ) -> some ToolbarContent {
        if backgroundJobsToolbarPlacement == placement, !state.backgroundJobs.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                BackgroundJobsButton(state: state) {
                    source = .allBooks
                    applyColumnMode(isReaderActive: true, showsLibraryAlongsideReader: false)
                }
            }
        }
    }

    private func importFiles(_ result: Result<[URL], any Error>) {
        do {
            let urls = try result.get()
            let imported = try AudiobookImportService.importFiles(urls)
            if imported.createdBook {
                importMessage = "Imported \(urls.count) selected files."
            } else if !imported.addedFileNames.isEmpty {
                importMessage = "Audiobook already imported; added \(imported.addedFileNames.joined(separator: ", "))."
            } else {
                importMessage = "This exact audiobook is already imported."
            }
            Task { await state.rescan() }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importEbook(_ result: Result<[URL], any Error>, bookID: String) {
        do {
            guard let book = state.books.first(where: { $0.id == bookID }) else { return }
            let urls = try result.get()
            let added = try AudiobookImportService.addCompanionFiles(
                urls,
                to: URL(fileURLWithPath: book.folderPath, isDirectory: true)
            )
            importMessage = added.isEmpty
                ? "This EPUB is already attached to \(book.title)."
                : "Added \(added.joined(separator: ", ")) to \(book.title)."
            Task {
                await state.rescan()
                state.selectedBookID = bookID
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importFolder(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            try AudiobookImportService.importFolder(url)
            importMessage = "Imported \(url.lastPathComponent)."
            Task { await state.rescan() }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importDeviceAudiobook(_ item: DeviceAudiobookItem) {
        guard importingDeviceID == nil else { return }
        importingDeviceID = item.id
        Task {
            defer { importingDeviceID = nil }
            do {
                let result = try await deviceLibrary.importAudiobook(item)
                importMessage = result.createdBook
                    ? "Imported \(item.title)."
                    : "\(item.title) is already imported; its metadata was updated."
                await state.rescan()
                state.selectedBookID = state.books.last {
                    $0.source == .deviceAudiobooks && $0.title == item.title
                }?.id
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func deleteBook(_ book: Book) {
        do {
            if state.selectedBookID == book.id {
                state.cancelTranscription()
                state.player.tearDown()
                state.selectedBookID = nil
                state.selectedChapterID = nil
                state.transcript = nil
                state.tab = .library
            }
            try AudiobookImportService.deleteBookFolder(
                URL(fileURLWithPath: book.folderPath, isDirectory: true),
                in: Persistence.importedBooksURL
            )
            importMessage = "Deleted \(book.title). Vocabulary entries were kept."
            Task {
                await state.rescan()
                if state.selectedBookID == nil {
                    state.selectedBookID = state.books.first?.id
                    state.selectedChapterID = state.books.first?.chapters.first?.id
                }
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct IPadDocumentPicker: UIViewControllerRepresentable {
    let request: IPadImportRequest
    let completion: (Result<[URL], any Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: request.contentTypes,
            asCopy: request.importsAsCopy
        )
        picker.allowsMultipleSelection = request.allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<[URL], any Error>) -> Void

        init(completion: @escaping (Result<[URL], any Error>) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // SwiftUI clears the sheet item when the system picker dismisses.
        }
    }
}

private struct IPadBookList: View {
    let books: [Book]
    @Binding var selectedBookID: String?
    let readyChapterIDs: Set<String>
    let importMessage: String?
    let onDelete: (Book) -> Void
    @State private var query = ""

    private var filteredBooks: [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.author?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        List(selection: $selectedBookID) {
            if let importMessage {
                Section {
                    Label(importMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(filteredBooks) { book in
                    HStack(spacing: 12) {
                        IPadCover(path: book.coverPath, title: book.title, width: 48, height: 70)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(book.author ?? "Unknown author")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(book.chapters.lazy.filter { readyChapterIDs.contains($0.id) }.count)/\(book.chapters.count) transcribed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(book.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            onDelete(book)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search title or author")
        .accessibilityIdentifier("library.search")
        .overlay {
            if books.isEmpty {
                ContentUnavailableView("No audiobooks", systemImage: "books.vertical", description: Text("Use Import to add audiobook audio and its matching EPUB."))
            } else if filteredBooks.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

private struct IPadBookDetail: View {
    @Bindable var state: AppState
    let book: Book
    let onAddEbook: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    IPadCover(path: book.coverPath, title: book.title, width: 140, height: 204)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(book.title)
                            .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        Text(book.author ?? "Unknown author")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Label("\(state.transcribedChapterCount(in: book)) of \(book.chapters.count) chapters transcribed", systemImage: "waveform.badge.checkmark")
                            .foregroundStyle(.secondary)
                        AudiobookLanguagePicker(state: state, book: book)
                    }
                    Spacer()
                }

                Divider()

                Text("Chapters")
                    .font(.title2.bold())
                LazyVStack(spacing: 0) {
                    ForEach(book.chapters) { chapter in
                        Button {
                            state.open(chapter: chapter, in: book, autoplay: false)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapter.title)
                                        .font(.headline)
                                    Text(chapter.duration.map(formatClock) ?? "Duration unavailable")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if state.readyChapterIDs.contains(chapter.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Palette.gold)
                                        .accessibilityLabel("Transcribed")
                                }
                                Image(systemName: "chevron.forward")
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    _ = state.continueReading(book)
                } label: {
                    Label("Open Book", systemImage: "book.pages")
                }
                .accessibilityIdentifier("library.continue")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: onAddEbook) {
                        Label(
                            book.ebookPath == nil ? "Add EPUB" : "Add Another EPUB",
                            systemImage: "book.closed"
                        )
                    }
                    .accessibilityIdentifier("library.repair")
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Book", systemImage: "trash")
                    }
                } label: {
                    Label("Book Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("Book actions")
            }
        }
    }
}

private struct DeviceAudiobooksView: View {
    @Bindable var library: DeviceAudiobookLibrary
    let importedBooks: [Book]
    @Binding var selectedBookID: String?
    let importingID: UInt64?
    let importMessage: String?
    let onRefresh: () -> Void
    let onImport: (DeviceAudiobookItem) -> Void
    let onDelete: (Book) -> Void

    var body: some View {
        List {
            if !importedBooks.isEmpty {
                Section("Imported into AudioReader") {
                    ForEach(importedBooks) { book in
                        Button {
                            selectedBookID = book.id
                        } label: {
                            HStack(spacing: 12) {
                                IPadCover(path: book.coverPath, title: book.title, width: 48, height: 70)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.title).font(.headline).lineLimit(2)
                                    Text(book.author ?? "Unknown author")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Label("Ready in AudioReader", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                onDelete(book)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if let importMessage {
                Section {
                    Label(importMessage, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = library.message {
                Section {
                    Label(message, systemImage: library.authorizationStatus == .authorized ? "checkmark.circle" : "lock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Available on This iPad") {
                ForEach(library.items) { item in
                    HStack(spacing: 12) {
                        deviceCover(item)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline).lineLimit(2)
                            Text(item.author).font(.subheadline).foregroundStyle(.secondary)
                            if item.isProtected {
                                Label("Protected — unavailable for transcription", systemImage: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if item.assetURL == nil {
                                Label("Download unavailable to third-party apps", systemImage: "icloud.slash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(formatClock(item.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if importingID == item.id {
                            ProgressView()
                        } else {
                            Button("Import") { onImport(item) }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                                .disabled(!item.canImport || importingID != nil)
                                .accessibilityIdentifier("library.importDevice.\(item.id)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .overlay {
            if library.isLoading {
                ProgressView("Finding audiobooks…")
            } else if library.items.isEmpty && library.authorizationStatus == .authorized {
                ContentUnavailableView("No device audiobooks found", systemImage: "books.vertical", description: Text("Download an audiobook to this iPad, then refresh."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(library.isLoading)
            }
        }
    }

    @ViewBuilder
    private func deviceCover(_ item: DeviceAudiobookItem) -> some View {
        if let data = item.artworkData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            IPadCover(path: nil, title: item.title, width: 48, height: 70)
        }
    }

}

private struct IPadCover: View {
    let path: String?
    let title: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
            if let path, let image = CoverImageCache.shared.image(for: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .foregroundStyle(Palette.gold)
                    Text(title)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 4)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Cover of \(title)")
    }
}
#endif
