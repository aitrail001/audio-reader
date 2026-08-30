import Foundation
import Testing
@testable import AudioReader

@Suite("Apple Books-style reading session")
struct ReadingSessionTests {
    @Test("Book search finds chapter sentences case-insensitively and keeps a snippet")
    func searchesChapters() {
        let chapters = [
            Chapter(id: "c1", index: 0, title: "Cover", audioPath: "", ebookLocator: EPUBParser.coverLocator),
            Chapter(id: "c2", index: 1, title: "One. The Basics", audioPath: ""),
            Chapter(id: "c3", index: 2, title: "Two. A Brief Visit", audioPath: "")
        ]
        let transcript = Transcript(
            chapterID: "c2",
            audioPath: "",
            createdAt: Date(),
            locale: "en",
            segments: [
                Self.segment(id: "s1", text: "The basics of stocks and flows explain how a system remembers."),
                Self.segment(id: "s2", text: "Feedback loops change the behavior of the whole.")
            ],
            source: TranscriptSource.ebook,
            ebookAligned: true
        )

        let hits = BookSearch.hits(
            query: "STOCKS",
            chapters: chapters,
            transcriptsByChapterID: ["c2": transcript],
            epubTextByLocator: ["chapter2.xhtml": "A brief visit to the systems zoo introduces reinforcing loops."]
        )

        #expect(hits.map(\.chapterID) == ["c2"])
        #expect(hits[0].segmentID == "s1")
        #expect(hits[0].chapterTitle == "One. The Basics")
        #expect(hits[0].snippet.localizedCaseInsensitiveContains("stocks"))
        #expect(BookSearch.hits(query: "   ", chapters: chapters, transcriptsByChapterID: [:], epubTextByLocator: [:]).isEmpty)
    }

    @Test("Book search falls back to EPUB chapter text when a chapter has no transcript")
    func searchesUnopenedEbookChapters() {
        let chapter = Chapter(id: "c3", index: 0, title: "Two. A Brief Visit", audioPath: "", ebookLocator: "chapter2.xhtml")
        let hits = BookSearch.hits(
            query: "systems zoo",
            chapters: [chapter],
            transcriptsByChapterID: [:],
            epubTextByLocator: ["chapter2.xhtml": "A brief visit to the systems zoo introduces reinforcing loops."]
        )

        #expect(hits.count == 1)
        #expect(hits[0].chapterID == "c3")
        #expect(hits[0].segmentID == nil)
        #expect(hits[0].snippet.localizedCaseInsensitiveContains("systems zoo"))
    }

    @Test("Reading progress weights the current chapter inside the book")
    func computesProgress() {
        let cover = ReadingProgress.make(chapterIndex: 0, chapterCount: 8, segmentIndex: 0, segmentCount: 0)
        let mid = ReadingProgress.make(chapterIndex: 3, chapterCount: 8, segmentIndex: 4, segmentCount: 10)

        #expect(cover.caption == "Cover")
        #expect(cover.bookFraction == 0)
        #expect(mid.caption == "Chapter 4 of 8")
        #expect(abs(mid.bookFraction - (3.4 / 8)) < 0.0001)
        #expect(mid.chapterFraction == 0.4)
    }

    @Test("A bookmark matches the current chapter and sentence")
    func bookmarkIdentity() {
        let bookmark = ReadingBookmark(
            id: "b1",
            bookID: "book",
            chapterID: "ch",
            chapterTitle: "One",
            segmentID: "s2",
            snippet: "Feedback loops change the behavior of the whole.",
            createdAt: Date()
        )

        #expect(bookmark.matches(bookID: "book", chapterID: "ch", segmentID: "s2"))
        #expect(!bookmark.matches(bookID: "book", chapterID: "ch", segmentID: "s1"))
        #expect(ReadingBookmark.makeID(bookID: "book", chapterID: "ch", segmentID: "s2") == ReadingBookmark.makeID(bookID: "book", chapterID: "ch", segmentID: "s2"))
    }

    @Test("Reading positions round-trip through persistence")
    func persistsPositionsAndBookmarks() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let positionsURL = fixture.appendingPathComponent("positions.json")
        let bookmarksURL = fixture.appendingPathComponent("bookmarks.json")
        let position = ReadingPosition(bookID: "book", chapterID: "ch2", segmentID: "s4", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let bookmark = ReadingBookmark(
            id: "b1",
            bookID: "book",
            chapterID: "ch2",
            chapterTitle: "Two",
            segmentID: "s4",
            snippet: "A saved place.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        Persistence.saveReadingPositions([position], to: positionsURL)
        Persistence.saveBookmarks([bookmark], to: bookmarksURL)
        let loadedPositions = Persistence.loadReadingPositions(from: positionsURL)
        let loadedBookmarks = Persistence.loadBookmarks(from: bookmarksURL)

        #expect(loadedPositions == [position])
        #expect(loadedBookmarks == [bookmark])
        #expect(Persistence.mostRecentReadingPosition(in: loadedPositions)?.bookID == "book")
    }

    @MainActor
    @Test("Opening a book resumes the last chapter and sentence")
    func resumesLastPlace() {
        let first = Chapter(id: "c1", index: 0, title: "Cover", audioPath: "", ebookLocator: EPUBParser.coverLocator)
        let second = Chapter(id: "c2", index: 1, title: "One. The Basics", audioPath: "")
        let book = Book(
            id: "book",
            title: "Thinking in Layers",
            author: nil,
            folderPath: "/tmp",
            coverPath: nil,
            ebookPath: nil,
            chapters: [first, second]
        )
        let savedPositions = Persistence.loadReadingPositions()
        let savedBookmarks = Persistence.loadBookmarks()
        defer {
            Persistence.saveReadingPositions(savedPositions)
            Persistence.saveBookmarks(savedBookmarks)
        }
        let state = AppState()
        state.books = [book]
        state.bookmarks = []
        state.readingPositions = [
            "book": ReadingPosition(bookID: "book", chapterID: "c2", segmentID: "s9", updatedAt: Date())
        ]

        state.openBook(book, autoplay: false)

        #expect(state.selectedBookID == "book")
        #expect(state.selectedChapterID == "c2")
        #expect(state.tab == .player)
    }

    @MainActor
    @Test("Bookmarking the current sentence can be toggled off")
    func togglesBookmark() {
        let chapter = Chapter(id: "c1", index: 0, title: "One", audioPath: "/tmp/one.m4b")
        let book = Book(
            id: "book",
            title: "Book",
            author: nil,
            folderPath: "/tmp",
            coverPath: nil,
            ebookPath: nil,
            chapters: [chapter]
        )
        let segment = Self.segment(id: "s1", text: "The basics of stocks and flows explain how a system remembers.")
        let savedBookmarks = Persistence.loadBookmarks()
        defer { Persistence.saveBookmarks(savedBookmarks) }
        let state = AppState()
        state.books = [book]
        state.bookmarks = []
        state.selectedBookID = book.id
        state.selectedChapterID = chapter.id
        state.transcript = Transcript(
            chapterID: chapter.id,
            audioPath: chapter.audioPath,
            createdAt: Date(),
            locale: "en",
            segments: [segment],
            source: "test",
            ebookAligned: false
        )
        state.focusedSegmentID = segment.id

        #expect(!state.isCurrentLocationBookmarked)
        state.toggleBookmark()
        #expect(state.isCurrentLocationBookmarked)
        #expect(state.bookmarksForSelectedBook.count == 1)
        #expect(state.bookmarksForSelectedBook[0].snippet.contains("stocks"))
        state.toggleBookmark()
        #expect(!state.isCurrentLocationBookmarked)
        #expect(state.bookmarksForSelectedBook.isEmpty)
    }

    @Test("Legacy settings default the reader theme to Original")
    func defaultsReaderTheme() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "readerTheme")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.readerTheme == ReaderTheme.original.rawValue)
        #expect(ReaderTheme.allCases.map(\.menuLabel) == ["Original", "Quiet", "Night"])
    }

    @MainActor
    @Test("Selecting a book restores the last chapter without opening the player")
    func selectBookRestoresChapter() {
        let first = Chapter(id: "c1", index: 0, title: "Cover", audioPath: "")
        let second = Chapter(id: "c2", index: 1, title: "One", audioPath: "")
        let book = Book(
            id: "book",
            title: "Book",
            author: nil,
            folderPath: "/tmp",
            coverPath: nil,
            ebookPath: nil,
            chapters: [first, second]
        )
        let state = AppState()
        state.books = [book]
        state.readingPositions = [
            "book": ReadingPosition(bookID: "book", chapterID: "c2", segmentID: nil, updatedAt: Date())
        ]

        state.selectBook(book)

        #expect(state.selectedChapterID == "c2")
        #expect(state.tab != .player)
    }

    private static func segment(id: String, text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: 0,
            end: 1,
            words: [
                TranscriptWord(id: "\(id)-w", text: text, start: 0, end: 1, confidence: 1)
            ],
            ebookText: text,
            alignmentScore: 1,
            individualEbookMatchTrusted: true,
            documentEbookUseAllowed: true
        )
    }
}
