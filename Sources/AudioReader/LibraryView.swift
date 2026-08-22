import SwiftUI
import AppKit

struct LibraryView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 18) {
                ForEach(state.books) { book in
                    BookCard(book: book, selected: book.id == state.selectedBookID)
                        .onTapGesture {
                            state.selectedBookID = book.id
                            state.selectedChapterID = book.chapters.first?.id
                        }
                }
            }
            .padding(24)
        }
        .background(Palette.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let book = state.selectedBook {
                ChapterStrip(state: state, book: book)
            }
        }
    }
}

private struct BookCard: View {
    let book: Book
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.panel2)
                if let path = book.coverPath, let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
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
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Palette.gold : Palette.line, lineWidth: selected ? 2 : 1)
            )

            Text(book.title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            HStack {
                Text(book.author ?? "Unknown author")
                    .foregroundStyle(Palette.dim)
                Spacer()
                Text("\(book.chapters.count) ch")
                    .foregroundStyle(Palette.mute)
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ChapterStrip: View {
    @Bindable var state: AppState
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Palette.ink)
                    Text("\(book.chapters.count) chapters" + (book.ebookPath == nil ? " · audio only" : " · ebook found"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
                Spacer()
                Button("Open player") {
                    if let ch = book.chapters.first(where: { $0.id == state.selectedChapterID }) ?? book.chapters.first {
                        state.open(chapter: ch, in: book, autoplay: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.terracotta)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(book.chapters) { ch in
                        let ready = Persistence.loadTranscript(chapterID: ch.id, audioPath: ch.audioPath) != nil
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
