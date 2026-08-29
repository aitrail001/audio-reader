import SwiftUI

struct LibraryView: View {
    @Bindable var state: AppState
    @State private var pendingBookDelete: Book?
    @State private var deleteError: String?
    @State private var bookUpdateResult: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)], spacing: 24) {
                ForEach(state.books) { book in
                    BookCard(
                        book: book,
                        selected: book.id == state.selectedBookID,
                        transcribedCount: state.transcribedChapterCount(in: book)
                    )
                        .onTapGesture {
                            state.selectedBookID = book.id
                            state.selectedChapterID = book.chapters.first?.id
                        }
#if os(macOS)
                        .onTapGesture(count: 2) {
                            if let chapter = book.chapters.first(where: { $0.id == state.selectedChapterID }) ?? book.chapters.first {
                                state.open(chapter: chapter, in: book, autoplay: false)
                            }
                        }
#endif
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingBookDelete = book
                            } label: {
                                Label("Delete Book", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(24)
        }
        .background(Palette.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let book = state.selectedBook {
                ChapterStrip(
                    state: state,
                    book: book,
                    onAddEbook: { addCompanionFiles(to: book) },
                    onDelete: { pendingBookDelete = book }
                )
            }
        }
        .overlay {
            if let progress = state.libraryScanProgress, state.books.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(progress.stage)
                        .font(.headline)
                    Text(progress.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
        .alert("Move book to Trash?", isPresented: Binding(
            get: { pendingBookDelete != nil },
            set: { if !$0 { pendingBookDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingBookDelete = nil }
            Button("Move to Trash", role: .destructive) {
                if let book = pendingBookDelete {
                    deleteBook(book)
                }
                pendingBookDelete = nil
            }
        } message: {
            Text("Move “\(pendingBookDelete?.title ?? "this book")” out of the AudioReader library and into Trash? Vocabulary entries will be kept.")
        }
        .alert("Could Not Delete Book", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "Unknown error")
        }
        .alert("Book Updated", isPresented: Binding(
            get: { bookUpdateResult != nil },
            set: { if !$0 { bookUpdateResult = nil } }
        )) {
            Button("OK", role: .cancel) { bookUpdateResult = nil }
        } message: {
            Text(bookUpdateResult ?? "")
        }
    }

    private func deleteBook(_ book: Book) {
#if os(macOS)
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
                in: URL(fileURLWithPath: state.settings.libraryPath, isDirectory: true)
            )
            Task {
                await state.rescan()
                state.selectedBookID = state.books.first?.id
                state.selectedChapterID = state.books.first?.chapters.first?.id
            }
        } catch {
            deleteError = error.localizedDescription
        }
#endif
    }

    private func addCompanionFiles(to book: Book) {
#if os(macOS)
        do {
            guard let added = try MacAudiobookImporter.chooseCompanionFiles(for: book) else { return }
            bookUpdateResult = added.isEmpty
                ? "Those companion files are already attached to \(book.title)."
                : "Added \(added.joined(separator: ", ")) to \(book.title)."
            Task {
                await state.rescan()
                state.selectedBookID = state.books.first(where: { $0.title == book.title })?.id
            }
        } catch {
            bookUpdateResult = error.localizedDescription
        }
#endif
    }
}

private struct BookCard: View {
    let book: Book
    let selected: Bool
    let transcribedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.panel2)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    if let path = book.coverPath, let img = CoverImageCache.shared.image(for: path) {
                        Image(platformImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(Palette.gold)
                            Text(book.title)
                                .font(.system(.caption, design: .serif))
                                .foregroundStyle(Palette.dim)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                    }
                }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Palette.gold : Palette.line, lineWidth: selected ? 2 : 1)
            )

            Text(book.title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .frame(minHeight: 34, alignment: .topLeading)
            HStack {
                Text(book.author ?? "Unknown author")
                    .foregroundStyle(Palette.dim)
                Spacer()
                Text("\(transcribedCount)/\(book.chapters.count) transcribed")
                    .foregroundStyle(Palette.mute)
            }
            .font(.system(size: 11))
        }
        .padding(12)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChapterStrip: View {
    @Bindable var state: AppState
    let book: Book
    let onAddEbook: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Palette.ink)
                    Text("\(book.chapters.count) chapters · \(state.transcribedChapterCount(in: book)) transcribed" + (book.ebookPath == nil ? " · audio only" : " · ebook found"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                    AudiobookLanguagePicker(state: state, book: book)
                }
                Spacer()
                Button("Open player") {
                    if let ch = book.chapters.first(where: { $0.id == state.selectedChapterID }) ?? book.chapters.first {
                        state.open(chapter: ch, in: book, autoplay: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.terracotta)
                Button(action: onAddEbook) {
                    Label(book.ebookPath == nil ? "Add EPUB" : "Add Another EPUB", systemImage: "book.pages")
                }
                .buttonStyle(.bordered)
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(book.chapters) { ch in
                        let ready = state.readyChapterIDs.contains(ch.id)
                        Button {
                            state.open(chapter: ch, in: book, autoplay: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ch.title)
                                    .font(.system(size: 12, weight: .medium))
                                Text(ch.duration.map(formatClock) ?? "—")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.dim)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(ch.id == state.selectedChapterID ? Palette.goldSoft : Palette.panel2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ready ? Palette.gold.opacity(0.5) : Palette.line, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Palette.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }
}

/// Slim status strip for library scan and account cloud work. Must not cover the
/// rest of the window — Settings and reading stay interactive while this is visible.
struct WorkStatusBanner: View {
    var library: LibraryScanProgress?
    var accountMessage: String?

    var body: some View {
        if library == nil && (accountMessage == nil || accountMessage?.isEmpty == true) {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                if let library, let fraction = library.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 160)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let library {
                        Text(library.stage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(library.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let accountMessage, !accountMessage.isEmpty {
                        Text(accountMessage)
                            .font(.system(size: 12, weight: library == nil ? .semibold : .regular))
                            .foregroundStyle(library == nil ? Palette.ink : Palette.dim)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("AudioReader activity")
            .accessibilityValue(statusValue)
        }
    }

    private var statusValue: String {
        [library.map { "\($0.stage). \($0.detail)" }, accountMessage]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}
