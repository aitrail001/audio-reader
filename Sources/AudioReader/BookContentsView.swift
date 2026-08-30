import SwiftUI

struct BookContentsView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Book", selection: $state.bookContentsTab) {
                    ForEach(BookContentsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(16)

                switch state.bookContentsTab {
                case .contents:
                    contentsList
                case .bookmarks:
                    bookmarksList
                case .search:
                    searchList
                }
            }
            .background(Palette.bg)
            .navigationTitle(state.selectedBook?.title ?? "Contents")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { state.showBookContents = false }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private var contentsList: some View {
        List {
            if let book = state.selectedBook {
                ForEach(book.chapters) { chapter in
                    Button {
                        state.showBookContents = false
                        state.open(chapter: chapter, in: book, autoplay: false)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chapter.title)
                                    .foregroundStyle(Palette.ink)
                                if chapter.isCover {
                                    Text("Cover")
                                        .font(.caption)
                                        .foregroundStyle(Palette.dim)
                                }
                            }
                            Spacer()
                            if chapter.id == state.selectedChapterID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Palette.gold)
                                    .accessibilityLabel("Current chapter")
                            }
                        }
                    }
                    .accessibilityAddTraits(chapter.id == state.selectedChapterID ? [.isSelected] : [])
                }
            }
        }
        .listStyle(.plain)
    }

    private var bookmarksList: some View {
        Group {
            if state.bookmarksForSelectedBook.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark",
                    description: Text("Bookmark the current place to return to it later.")
                )
            } else {
                List(state.bookmarksForSelectedBook) { bookmark in
                    Button {
                        state.openBookmark(bookmark)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bookmark.chapterTitle)
                                .foregroundStyle(Palette.ink)
                            Text(bookmark.snippet)
                                .font(.subheadline)
                                .foregroundStyle(Palette.dim)
                                .lineLimit(3)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var searchList: some View {
        VStack(spacing: 0) {
            TextField("Search this book", text: $state.bookSearchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityLabel("Search this book")
            if let book = state.selectedBook {
                let hits = state.searchHits(in: book)
                if state.bookSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage: "magnifyingglass",
                        description: Text("Find a word or phrase in this book.")
                    )
                } else if hits.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("Nothing in this book matches that search.")
                    )
                } else {
                    List(hits) { hit in
                        Button {
                            state.openSearchHit(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.chapterTitle)
                                    .foregroundStyle(Palette.ink)
                                Text(hit.snippet)
                                    .font(.subheadline)
                                    .foregroundStyle(Palette.dim)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}
