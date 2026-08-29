import SwiftUI

struct RootView: View {
    @Bindable var state: AppState
    @State private var importResult: String?
#if os(macOS)
    @State private var showMacAppleBooks = false
    @State private var macAppleBooks = MacAppleBooksLibrary()
    @State private var importingAppleBookID: String?
    @State private var pendingMacBookDelete: Book?
    @State private var macBookDeleteError: String?
#endif

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            switch state.tab {
            case .library:
                LibraryView(state: state)
            case .player:
                PlayerView(state: state)
            case .vocab:
                VocabularyView(state: state)
            case .settings:
                SettingsView(state: state)
            }
        }
        .background(Palette.bg)
        .safeAreaInset(edge: .top, spacing: 0) {
            WorkStatusBanner(
                library: state.libraryScanProgress,
                accountMessage: state.account.activityMessage
            )
        }
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
        .sheet(isPresented: $showMacAppleBooks) {
            MacAppleBooksView(
                library: macAppleBooks,
                importingID: importingAppleBookID,
                onImport: importAppleBook
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

                Button(action: importFiles) {
                    Label("Files", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.plain)

                Button(action: importFolder) {
                    Label("Folders", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
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
            Label(syncStatusTitle, systemImage: syncStatusSymbol)
                .font(.callout)
                .foregroundStyle(state.account.errorMessage == nil ? Palette.dim : Palette.terracotta)
                .accessibilityIdentifier("sync.status")
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

    private var syncStatusTitle: String {
        if state.account.errorMessage != nil { return "Sync needs attention" }
        if let activity = state.account.activityMessage, !activity.isEmpty { return activity }
        switch state.account.mode {
        case .local: return "Local only"
        case .signedInSyncOff: return "Sync off"
        case .signedInSyncOn: return "Up to date"
        }
    }

    private var syncStatusSymbol: String {
        if state.account.errorMessage != nil { return "exclamationmark.icloud" }
        return state.account.mode.isSyncEnabled ? "checkmark.icloud" : "icloud.slash"
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
                try macAppleBooks.importAudiobook(item, into: libraryRoot)
                macAppleBooks.message = "Imported \(item.title) into AudioReader."
                importResult = "Imported \(item.title) from Apple Books."
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
        .accessibilityLabel("Background jobs, \(state.backgroundJobs.count) queued or running")
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
                        Text(job.state == .queued ? "Queued" : "Running")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(job.state == .queued ? Palette.mute : Palette.gold)
                        Text(job.bookTitle)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(job.chapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if job.state == .queued {
                            ProgressView(value: 0)
                        } else if let fraction = job.fraction {
                            ProgressView(value: fraction)
                        } else {
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
                .accessibilityLabel("\(job.state == .queued ? "Queued" : "Running") \(job.stage), \(job.bookTitle), \(job.chapterTitle)")
                .accessibilityHint("Open this chapter in the player")
                if job.id != state.backgroundJobs.last?.id {
                    Divider()
                }
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
    }
}
