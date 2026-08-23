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
            }
        }
        .background(Palette.bg)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Section", selection: $state.tab) {
                    ForEach(AppTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    state.chooseLibrary()
                } label: {
                    Label("Library folder", systemImage: "folder")
                }
            }
#if os(macOS)
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button(action: importFiles) {
                        Label("Audiobook Files…", systemImage: "doc.badge.plus")
                    }
                    Button(action: importFolder) {
                        Label("Audiobook Folder…", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        showMacAppleBooks = true
                    } label: {
                        Label("Apple Books…", systemImage: "books.vertical")
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
#endif
            ToolbarItem(placement: .automatic) {
                Picker("Theme", selection: $state.settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.menuLabel).tag(mode.rawValue)
                    }
                }
                .onChange(of: state.settings.appearance) { _, _ in state.persistSettings() }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    state.showSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .sheet(isPresented: $state.showSettings) {
            SettingsView(state: state)
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
        .task { await state.boot() }
    }

    private var sidebar: some View {
        List(selection: $state.selectedBookID) {
#if os(macOS)
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
#endif
            Section("Books") {
                ForEach(state.books) { book in
                    HStack(spacing: 12) {
                        if let path = book.coverPath, let img = CoverImageCache.shared.image(for: path) {
                            Image(platformImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: "book.closed")
                                .frame(width: 32, height: 32)
                                .foregroundStyle(Palette.gold)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                            Text("\(book.chapters.count) chapters")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(book.id)
                    .padding(.vertical, 4)
#if os(macOS)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingMacBookDelete = book
                        } label: {
                            Label("Delete Book", systemImage: "trash")
                        }
                    }
#endif
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.selectedBookID) { _, id in
            if let book = state.books.first(where: { $0.id == id }) {
                state.selectedChapterID = book.chapters.first?.id
                state.tab = .library
            }
        }
    }

#if os(macOS)
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
