import SwiftUI

struct RootView: View {
    @Bindable var state: AppState
    @State private var importResult: String?
#if os(macOS)
    @State private var showMacAppleBooks = false
    @State private var macAppleBooks = MacAppleBooksLibrary()
    @State private var importingAppleBookID: String?
    @State private var appleBooksCompanionTargetID: String?
    @State private var appleBooksCompanionRequirement: MacAppleBooksCompanionRequirement?
    @State private var pendingAppleBooksDuplicate: MacAppleBookItem?
    @State private var pendingMacBookDelete: Book?
    @State private var macBookDeleteError: String?
#endif

    var body: some View {
        VStack(spacing: 0) {
            WorkStatusBanner(
                library: state.libraryScanProgress,
                accountMessage: state.account.activityMessage
            )

            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            } detail: {
                switch state.tab {
                case .library:
#if os(macOS)
                    LibraryView(state: state) { book in
                        guard let requirement = MacAppleBooksCompanionRequirement(
                            mediaAvailability: book.mediaAvailability
                        ) else { return }
                        pendingAppleBooksDuplicate = nil
                        appleBooksCompanionTargetID = book.id
                        appleBooksCompanionRequirement = requirement
                        showMacAppleBooks = true
                    }
#else
                    LibraryView(state: state)
#endif
                case .player:
                    PlayerView(state: state)
                case .vocab:
                    VocabularyView(state: state)
                case .settings:
                    SettingsView(state: state)
                }
            }
            // The explicit fill keeps a tall detail from pushing the split view above the window,
            // without reintroducing the macOS safe-area/split-resize constraint feedback crash.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
        .toolbar {
            if !state.backgroundJobs.isEmpty {
                ToolbarItem(placement: .automatic) {
                    BackgroundJobsButton(state: state)
                }
            }
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
#if os(macOS)
        .sheet(isPresented: $showMacAppleBooks, onDismiss: {
            appleBooksCompanionTargetID = nil
            appleBooksCompanionRequirement = nil
        }) {
            MacAppleBooksView(
                library: macAppleBooks,
                pendingDuplicateImport: $pendingAppleBooksDuplicate,
                importingID: importingAppleBookID,
                companionBookTitle: appleBooksCompanionTargetID.flatMap { targetID in
                    state.books.first(where: { $0.id == targetID })?.title
                },
                companionRequirement: appleBooksCompanionRequirement,
                onImport: importAppleBook,
                onConfirmDuplicate: confirmAppleBooksDuplicateImport
            )
        }
        .alert("Import Result", isPresented: Binding(
            get: { importResult != nil },
            set: { if !$0 { importResult = nil } }
        )) {
            Button("OK", role: .cancel) { importResult = nil }
        } message: {
            Text(importResult ?? "")
        }
        .alert("Move book to Trash?", isPresented: Binding(
            get: { pendingMacBookDelete != nil },
            set: { if !$0 { pendingMacBookDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingMacBookDelete = nil }
            Button("Move to Trash", role: .destructive) {
                if let book = pendingMacBookDelete { deleteMacBook(book) }
                pendingMacBookDelete = nil
            }
        } message: {
            Text("Move “\(pendingMacBookDelete?.title ?? "this book")” out of the AudioReader library and into Trash? Vocabulary entries will be kept.")
        }
        .alert("Could Not Delete Book", isPresented: Binding(
            get: { macBookDeleteError != nil },
            set: { if !$0 { macBookDeleteError = nil } }
        )) {
            Button("OK", role: .cancel) { macBookDeleteError = nil }
        } message: {
            Text(macBookDeleteError ?? "Unknown error")
        }
#endif
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
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
#if os(macOS)
            Section {
                destinationRow(.library, title: "Library", identifier: "sidebar.library")
                destinationRow(.player, title: "Now Reading", identifier: "sidebar.nowReading")
                destinationRow(.vocab, title: "Words", identifier: "sidebar.words")
                destinationRow(.settings, title: "Settings", identifier: "sidebar.settings")
            }

            Section("Sources") {
                Button {
                    showMacAppleBooks = true
                } label: {
                    Label("Apple Books", systemImage: "books.vertical")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("source.appleBooks")

                Button(action: importFiles) {
                    Label("Files", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Import Audio or EPUB Files")
                .accessibilityIdentifier("source.files")

                Button(action: importFolder) {
                    Label("Folders", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Import Book Folder")
                .accessibilityIdentifier("source.folders")
            }

            Section("Cloud") {
                syncStatus
            }
#endif
        }
        .listStyle(.sidebar)
    }

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { "destination.\(state.tab.rawValue)" },
            set: { value in
                guard let raw = value?.replacingOccurrences(of: "destination.", with: ""),
                      let tab = AppTab(rawValue: raw)
                else { return }
                state.tab = tab
            }
        )
    }

#if os(macOS)
    private func destinationRow(_ tab: AppTab, title: String, identifier: String) -> some View {
        Label(title, systemImage: tab.symbol)
            .tag("destination.\(tab.rawValue)")
            .accessibilityIdentifier(identifier)
    }

    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountSyncStatusView(session: state.account, compact: true)
            Button {
                Task { await state.account.synchronize() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(state.account.isBusy || !state.account.mode.isSyncEnabled)
            .accessibilityIdentifier("sync.now")
        }
        .padding(.vertical, 4)
    }

    private var libraryRoot: URL {
        URL(fileURLWithPath: state.settings.libraryPath, isDirectory: true)
    }

    private func importFiles() {
        do {
            guard let count = try MacAudiobookImporter.chooseFiles(libraryRoot: libraryRoot) else { return }
            importResult = "Imported \(count) selected file\(count == 1 ? "" : "s") into the library."
            Task { await state.rescan() }
        } catch {
            importResult = error.localizedDescription
        }
    }

    private func importFolder() {
        do {
            guard let name = try MacAudiobookImporter.chooseFolder(libraryRoot: libraryRoot) else { return }
            importResult = "Imported \(name) into the library."
            Task { await state.rescan() }
        } catch {
            importResult = error.localizedDescription
        }
    }

    private func deleteMacBook(_ book: Book) {
        do {
            if state.selectedBookID == book.id {
                state.cancelTranscription()
                state.player.tearDown()
                state.selectedBookID = nil
                state.selectedChapterID = nil
                state.transcript = nil
                state.tab = .library
            }
            try AudiobookImportService.trashBookFolder(
                URL(fileURLWithPath: book.folderPath, isDirectory: true),
                in: libraryRoot
            )
            Task {
                await state.rescan()
                state.selectedBookID = state.books.first?.id
                state.selectedChapterID = state.books.first?.chapters.first?.id
            }
        } catch {
            macBookDeleteError = error.localizedDescription
        }
    }

    private func importAppleBook(_ item: MacAppleBookItem) {
        guard importingAppleBookID == nil else { return }
        importingAppleBookID = item.id
        Task {
            defer { importingAppleBookID = nil }
            do {
                guard let location = item.location else {
                    throw AudiobookImportError.protectedOrUnavailable
                }
                if let targetID = appleBooksCompanionTargetID,
                   let requirement = appleBooksCompanionRequirement {
                    guard let book = state.books.first(where: { $0.id == targetID }) else {
                        throw AudiobookImportError.protectedOrUnavailable
                    }
                    let added = try macAppleBooks.addCompanion(
                        item,
                        to: URL(fileURLWithPath: book.folderPath, isDirectory: true),
                        required: requirement
                    )
                    macAppleBooks.message = added.isEmpty
                        ? "That Apple Books file is already attached to \(book.title)."
                        : "Added \(item.title) to \(book.title)."
                    importResult = macAppleBooks.message
                    await state.rescan()
                    state.selectedBookID = targetID
                    if !added.isEmpty { showMacAppleBooks = false }
                    return
                }
                let destinationRoot = libraryRoot
                let preflight = try await Task.detached(priority: .userInitiated) {
                    try AudiobookImportService.preflightFiles([location], into: destinationRoot)
                }.value
                if preflight.requiresConfirmation {
                    pendingAppleBooksDuplicate = item
                    return
                }
                try macAppleBooks.importAudiobook(item, into: libraryRoot)
                macAppleBooks.message = "Imported \(item.title) into AudioReader."
                importResult = "Imported \(item.title) from Apple Books."
                await state.rescan()
            } catch {
                importResult = error.localizedDescription
            }
        }
    }

    private func confirmAppleBooksDuplicateImport(_ item: MacAppleBookItem) {
        pendingAppleBooksDuplicate = nil
        importingAppleBookID = item.id
        Task {
            defer { importingAppleBookID = nil }
            do {
                try macAppleBooks.importAudiobook(
                    item,
                    into: libraryRoot,
                    duplicatePolicy: .confirmedReimport
                )
                macAppleBooks.message = "Imported another copy of \(item.title) into AudioReader."
                importResult = "Imported another copy of \(item.title) from Apple Books."
                await state.rescan()
            } catch {
                importResult = error.localizedDescription
            }
        }
    }
#endif
}

struct BackgroundJobsButton: View {
    @Bindable var state: AppState
    var onOpenJob: () -> Void = {}
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16))
                Text("\(state.backgroundJobs.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Palette.terracotta, in: Circle())
                    .offset(x: 7, y: -7)
            }
            .padding(.trailing, 5)
        }
        .accessibilityLabel("Background jobs, \(state.backgroundJobs.count) active or recent")
        .help("Show background jobs")
        .popover(isPresented: $isPresented) {
            BackgroundJobsView(state: state) { job in
                guard state.openBackgroundJob(job) else { return }
                isPresented = false
                onOpenJob()
            }
        }
    }
}

private struct BackgroundJobsView: View {
    @Bindable var state: AppState
    let onOpenJob: (BackgroundJob) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Background Jobs")
                .font(.headline)
            ForEach(state.backgroundJobs) { job in
                Button {
                    onOpenJob(job)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(job.stage, systemImage: job.symbol)
                            .font(.subheadline.weight(.semibold))
                        Text(statusLabel(for: job.state))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(job.state == .running ? Palette.gold : Palette.mute)
                        Text(job.bookTitle)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(job.chapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if job.state == .queued {
                            ProgressView(value: 0)
                        } else if job.state == .running, let fraction = job.fraction {
                            ProgressView(value: fraction)
                        } else if job.state == .running {
                            ProgressView()
                        }
                        Text(job.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(statusLabel(for: job.state)) \(job.stage), \(job.bookTitle), \(job.chapterTitle)")
                .accessibilityValue(job.detail)
                .accessibilityHint("Open this chapter in the player")
                if job.id != state.backgroundJobs.last?.id {
                    Divider()
                }
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
    }

    private func statusLabel(for state: BackgroundJob.State) -> String {
        switch state {
        case .queued: "Queued"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
