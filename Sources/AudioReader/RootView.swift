import SwiftUI
import AppKit

struct RootView: View {
    @Bindable var state: AppState

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
        .task { await state.boot() }
    }

    private var sidebar: some View {
        List(selection: $state.selectedBookID) {
            Section("Books") {
                ForEach(state.books) { book in
                    HStack(spacing: 10) {
                        if let path = book.coverPath, let img = NSImage(contentsOfFile: path) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: "book.closed")
                                .frame(width: 32, height: 32)
                                .foregroundStyle(Palette.gold)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                            Text("\(book.chapters.count) chapters")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(book.id)
                    .padding(.vertical, 2)
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
}
