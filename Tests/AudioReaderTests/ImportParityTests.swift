import Foundation
import Testing
import ZIPFoundation
@testable import AudioReader

@Suite("Cross-platform import parity")
struct ImportParityTests {
    @Test("new installs follow the system appearance")
    func defaultAppearanceFollowsSystem() {
        #expect(AppSettings.default.appearance == AppAppearance.system.rawValue)
    }
    @Test("EPUB text extraction uses the sandbox-safe ZIP implementation")
    func extractsEPUBText() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("epub", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let html = "<html><body><p>This chapter contains enough meaningful words to verify shared EPUB extraction on every supported platform.</p></body></html>"
        try Data(html.utf8).write(to: source.appendingPathComponent("chapter.xhtml"))
        let epub = fixture.root.appendingPathComponent("book.epub")
        try FileManager.default.zipItem(at: source, to: epub, shouldKeepParent: false, compressionMethod: .deflate)

        let document = try #require(EPUBParser.document(from: epub.path))

        #expect(document.text.contains("shared EPUB extraction"))
    }

    @Test("EPUB spine sections remain independently navigable")
    func preservesEPUBSpineSections() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let epub = try makeEPUB(
            in: fixture.root,
            name: "Sectioned Book",
            title: "Sectioned Book",
            author: "Ada Reader",
            sections: [
                ("Opening", "The opening section contains enough meaningful words for dictionary and translation study."),
                ("Arrival", "The arrival section contains another complete passage for review and chapter navigation."),
            ]
        )

        let document = try #require(EPUBParser.document(from: epub.path))

        #expect(document.title == "Sectioned Book")
        #expect(document.author == "Ada Reader")
        #expect(document.sections.map(\.title) == ["Opening", "Arrival"])
        #expect(document.sections[1].text.contains("another complete passage"))
    }

    @Test("EPUB 3 contents split nested chapters within one spine document")
    func splitsEPUB3NavigationChapters() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let epub = try makeNavigationEPUB(in: fixture.root, usesNCX: false)

        let document = try #require(EPUBParser.document(from: epub.path))

        #expect(document.sections.map(\.title) == ["Part One", "The Arrival", "The Crossing"])
        #expect(document.sections.map(\.navigationLevel) == [0, 1, 1])
        #expect(document.cover?.data == navigationEPUBCoverData)
        #expect(document.sections[0].text.contains("opening passage"))
        #expect(!document.sections[0].text.contains("arrival chapter"))
        #expect(document.sections[1].text.contains("arrival chapter"))
        #expect(!document.sections[1].text.contains("crossing chapter"))
        #expect(document.sections[2].text.contains("crossing chapter"))
    }

    @Test("EPUB 2 NCX remains a chapter-title fallback")
    func usesEPUB2NCXNavigationFallback() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let epub = try makeNavigationEPUB(in: fixture.root, usesNCX: true)

        let document = try #require(EPUBParser.document(from: epub.path))

        #expect(document.sections.map(\.title) == ["Part One", "The Arrival", "The Crossing"])
        #expect(document.sections.map(\.navigationLevel) == [0, 1, 1])
        #expect(document.cover?.data == navigationEPUBCoverData)
    }

    @Test("EPUB cover metadata is extracted and imported as library artwork")
    func importsEPUBCoverArtwork() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let epub = try makeNavigationEPUB(in: incoming, usesNCX: false)

        let document = try #require(EPUBParser.document(from: epub.path))
        _ = try AudiobookImportService.importFiles([epub], into: library)
        let book = try #require(LibraryScanner.scan(root: library).first)
        let coverPath = try #require(book.coverPath)

        #expect(document.cover?.fileExtension == "png")
        #expect(document.cover?.data == navigationEPUBCoverData)
        #expect(URL(fileURLWithPath: coverPath).pathExtension.lowercased() == "png")
        #expect(try Data(contentsOf: URL(fileURLWithPath: coverPath)) == navigationEPUBCoverData)
    }

    @Test("EPUB search reports matching contents sections with readable snippets")
    func searchesAcrossEPUBSections() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let epub = try makeNavigationEPUB(in: fixture.root, usesNCX: false)
        let document = try #require(EPUBParser.document(from: epub.path))

        let results = EPUBParser.search("lantern", in: document)

        #expect(results.map(\.sectionIndex) == [1, 2])
        #expect(results.map(\.sectionTitle) == ["The Arrival", "The Crossing"])
        #expect(results.allSatisfy { $0.snippet.localizedCaseInsensitiveContains("lantern") })
    }

    @Test("EPUB reader preserves short published sentences between longer prose")
    func readerPreservesAllPublishedSentences() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let prose = "This opening sentence contains several words for the reader. Hi. This closing sentence also contains several words."
        let epub = try makeEPUB(
            in: fixture.root,
            name: "Short Sentences",
            title: "Short Sentences",
            author: nil,
            sections: [
                (
                    "Greeting",
                    prose
                ),
            ]
        )
        let transcript = try #require(EPUBParser.readerTranscript(
            from: epub.path,
            sectionIndex: 0,
            chapterID: "short-sentences"
        ))

        let published = prose.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let reconstructed = transcript.segments.map(\.displayText).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        #expect(reconstructed == published)
        #expect(transcript.segments.contains { $0.displayText == "Hi." })
    }

    @Test("EPUB reader preserves published punctuation and spacing")
    func readerPreservesPunctuationSpacing() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let prose = #"The guide said, "Hello, patient world." Please don't panic; we're completely ready."#
        let epub = try makeEPUB(
            in: fixture.root,
            name: "Punctuation",
            title: "Punctuation",
            author: nil,
            sections: [
                (
                    "Dialogue",
                    prose
                ),
            ]
        )
        let transcript = try #require(EPUBParser.readerTranscript(
            from: epub.path,
            sectionIndex: 0,
            chapterID: "punctuation"
        ))

        let published = prose.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let reconstructed = transcript.segments.map(\.displayText).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        #expect(reconstructed == published)
        #expect(reconstructed.contains(#"said, "Hello, patient world.""#))
        #expect(reconstructed.contains("don't panic; we're completely ready."))
    }

    @Test("EPUB-only file import creates a readable logical book")
    func importsEPUBOnlyFile() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let epub = try makeEPUB(
            in: incoming,
            name: "Readable Book",
            title: "Readable Book",
            author: "E. Book",
            sections: [
                ("One", "This EPUB-only chapter provides enough words to support reading and language study."),
                ("Two", "A second EPUB-only chapter provides navigation without requiring any audiobook file."),
            ]
        )

        let result = try AudiobookImportService.importFiles([epub], into: library)
        let book = try #require(LibraryScanner.scan(root: library).first)

        #expect(result.createdBook)
        #expect(book.title == "Readable Book")
        #expect(book.author == "E. Book")
        #expect(book.mediaAvailability == .ebookOnly)
        #expect(book.chapters.map(\.title) == ["One", "Two"])
        #expect(book.chapters.allSatisfy { !$0.hasAudio && $0.ebookSectionIndex != nil })
    }

    @Test("Nested folder import discovers EPUB-only, audio-only, and paired books")
    func importsNestedMixedCollection() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let collection = fixture.root.appendingPathComponent("collection", isDirectory: true)
        let ebookFolder = collection.appendingPathComponent("Ebook", isDirectory: true)
        let audioFolder = collection.appendingPathComponent("Audio", isDirectory: true)
        let pairedFolder = collection.appendingPathComponent("Paired", isDirectory: true)
        let nestedFolder = collection.appendingPathComponent("Shelf/Deep Ebook", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        for folder in [ebookFolder, audioFolder, pairedFolder, nestedFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        _ = try makeEPUB(
            in: ebookFolder,
            name: "Ebook",
            title: "Ebook",
            author: nil,
            sections: [("Read", "This ebook-only nested title contains enough meaningful words for a readable section.")]
        )
        _ = try makeEPUB(
            in: nestedFolder,
            name: "Deep Ebook",
            title: "Deep Ebook",
            author: nil,
            sections: [("Read", "This deeply nested EPUB title remains a separate logical book in the imported collection.")]
        )
        try Data("audio only".utf8).write(to: audioFolder.appendingPathComponent("Audio.m4b"))
        try Data("paired audio".utf8).write(to: pairedFolder.appendingPathComponent("Paired.m4b"))
        _ = try makeEPUB(
            in: pairedFolder,
            name: "Paired",
            title: "Paired",
            author: nil,
            sections: [("Read", "This paired nested title contains enough meaningful words for its companion text.")]
        )

        let results = try AudiobookImportService.importFolder(collection, into: library)
        let books = LibraryScanner.scan(root: library)

        #expect(results.count == 4)
        #expect(books.contains { $0.title == "Deep Ebook" })
        #expect(Set(books.map(\.mediaAvailability)) == [.ebookOnly, .audioOnly, .audioAndEbook])
    }

    @Test("EPUB-only folder import rejects unreadable books before creating a destination")
    func rejectsUnreadableEPUBOnlyFolder() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("Unreadable", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("not an EPUB archive".utf8).write(to: source.appendingPathComponent("Unreadable.epub"))

        var rejection: AudiobookImportError?
        do {
            _ = try AudiobookImportService.importFolder(source, into: library)
        } catch let error as AudiobookImportError {
            rejection = error
        } catch {
            throw error
        }

        #expect({
            if case .invalidEbook? = rejection { return true }
            return false
        }())
        #expect(!FileManager.default.fileExists(atPath: library.path))
    }

    @Test("Explicit audio attachment preserves EPUB identity and reading state keys")
    func explicitlyAttachesAudioToEPUBBook() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let epub = try makeEPUB(
            in: incoming,
            name: "Attach Later",
            title: "Attach Later",
            author: nil,
            sections: [("Read", "This imported EPUB retains its logical identity when audio is explicitly attached later.")]
        )
        let imported = try AudiobookImportService.importFiles([epub], into: library)
        let before = try #require(LibraryScanner.scan(root: library).first)
        let audio = incoming.appendingPathComponent("Attach Later.m4b")
        try Data("later audio bytes".utf8).write(to: audio)

        _ = try AudiobookImportService.addCompanionFiles([audio], to: imported.folder)
        let after = try #require(LibraryScanner.scan(root: library).first)

        #expect(after.id == before.id)
        #expect(after.ebookPath == before.ebookPath)
        #expect(after.mediaAvailability == .audioAndEbook)
        #expect(after.chapters.contains { $0.hasAudio })
        #expect(after.chapters.contains { $0.id == before.chapters.first?.id })
        let durationLoaded = await LibraryScanner.loadDurations(for: after)
        #expect(durationLoaded.chapters.contains { $0.id == before.chapters.first?.id })
    }

    @MainActor
    @Test("Opening an EPUB-only section prepares published text without loading audio")
    func opensEPUBOnlySectionWithoutAudio() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let bookFolder = fixture.root.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        let epub = try makeEPUB(
            in: bookFolder,
            name: "Book",
            title: "Book",
            author: nil,
            sections: [("First", "Published EPUB wording supports dictionary vocabulary translation summary chat quiz and review.")]
        )
        let book = try #require(LibraryScanner.scan(root: fixture.root).first)
        let chapter = try #require(book.chapters.first)
        let state = AppState()
        state.books = [book]

        state.open(chapter: chapter, in: book, autoplay: true)

        #expect(state.player.loadedPath == nil)
        #expect(state.transcript?.source == "EPUB")
        #expect(state.transcript?.segments.first?.displayText.contains("Published EPUB wording") == true)
        #expect(state.selectedChapterID == chapter.id)
        let vocab = VocabEntry(
            id: "epub-word",
            word: "Published",
            context: "Published EPUB wording supports dictionary vocabulary translation summary chat quiz and review.",
            bookID: book.id,
            bookTitle: book.title,
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            timestamp: 0,
            addedAt: Date()
        )
        #expect(!state.canPlayVocabSentence(vocab))
        #expect(epub.resolvingSymlinksInPath().path == book.ebookPath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        })
    }

    @MainActor
    @Test("Contents and search results open the matching EPUB chapter")
    func opensEPUBNavigationResult() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let bookFolder = fixture.root.appendingPathComponent("Navigation Book", isDirectory: true)
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        _ = try makeNavigationEPUB(in: bookFolder, usesNCX: false)
        let book = try #require(LibraryScanner.scan(root: fixture.root).first)
        let state = AppState()
        state.books = [book]

        let opened = state.openEbookSection(at: 2, in: book, matching: "lantern")

        #expect(opened)
        #expect(state.selectedChapter?.title == "The Crossing")
        #expect(state.transcript?.segments.contains { $0.displayText.contains("crossing chapter") } == true)
        #expect(state.scrollSegmentID != nil)
    }

    @MainActor
    @Test("legacy EPUB-only catalog repair survives reload and opens title and chapter text")
    func repairsLegacyEPUBOnlySectionIdentity() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let bookFolder = fixture.root.appendingPathComponent("Repair Book", isDirectory: true)
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        _ = try makeNavigationEPUB(in: bookFolder, usesNCX: false)
        let scanned = try #require(LibraryScanner.scan(root: fixture.root).first)
        let store = LocalSQLiteStore(fileURL: fixture.root.appendingPathComponent("library.sqlite"))
        let legacy = StoredBook(
            id: scanned.bookID,
            title: scanned.title,
            author: scanned.author,
            source: scanned.source.rawValue,
            chapters: scanned.chapters.map {
                StoredChapter(id: $0.chapterID, index: $0.index, title: $0.title)
            }
        )
        try store.saveBook(legacy)
        try store.saveAssets(StoredLocalAsset.snapshots(for: scanned), bookID: legacy.id)

        let restored = try #require(Persistence.loadCatalogBooks(database: store).first)

        #expect(restored.chapters.map(\.ebookSectionIndex) == [0, 1, 2])
        #expect(restored.chapters.allSatisfy { $0.ebookSectionIndex == $0.index })
        #expect(try store.loadBooks().first?.chapters.map(\.ebookSectionIndex) == [0, 1, 2])
        #expect(try store.pendingMutations().count == 1)

        let state = AppState()
        state.textSource = .spoken
        state.books = [restored]
        let titlePage = try #require(restored.chapters.first)
        state.open(chapter: titlePage, in: restored, autoplay: false)

        #expect(state.selectedChapter?.ebookSectionIndex == 0)
        #expect(state.transcript?.segments.first?.displayText.contains("opening passage") == true)
        #expect(state.readerTextSource == .original)
        #expect(state.textSource == .spoken)

        #expect(state.openEbookSection(at: 2, in: restored))
        #expect(state.selectedChapter?.title == "The Crossing")
        #expect(state.transcript?.segments.contains { $0.displayText.contains("crossing chapter") } == true)
    }

    @Test("legacy repair never assigns EPUB sections to paired audio chapters")
    func doesNotRepairPairedAudioChaptersAsEbookSections() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("Paired", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let epub = try makeEPUB(
            in: folder,
            name: "Paired",
            title: "Paired",
            author: nil,
            sections: [("One", "Published text belongs to a paired audiobook and must not replace audio chapter identity.")]
        )
        let audio = folder.appendingPathComponent("Paired.m4b")
        try Data("audio".utf8).write(to: audio)
        let book = Book(
            id: "paired-book",
            title: "Paired",
            folderPath: folder.path,
            ebookPath: epub.path,
            chapters: [Chapter(id: "audio-chapter", index: 0, title: "Audio", audioPath: audio.path)]
        )
        let store = LocalSQLiteStore(fileURL: fixture.root.appendingPathComponent("library.sqlite"))
        let stored = StoredBook(book)
        try store.saveBook(stored)
        try store.saveAssets(StoredLocalAsset.snapshots(for: book), bookID: stored.id)

        let restored = try #require(Persistence.loadCatalogBooks(database: store).first)

        #expect(restored.mediaAvailability == .audioAndEbook)
        #expect(restored.chapters.first?.ebookSectionIndex == nil)
        #expect(try store.pendingMutations().isEmpty)
    }

    @Test("legacy EPUB repair rejects malformed and partially repaired chapter mappings")
    func doesNotRepairMalformedEPUBOnlyChapterMappings() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("Malformed Repair", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try makeNavigationEPUB(in: folder, usesNCX: false)
        let scanned = try #require(LibraryScanner.scan(root: fixture.root).first)
        #expect(scanned.chapters.count == 3)

        let cases: [(name: String, positions: [Int], partialSectionIndex: Int?)] = [
            ("duplicate", [0, 0, 2], nil),
            ("negative", [-1, 0, 1], nil),
            ("missing-and-out-of-range", [0, 1, 3], nil),
            ("missing-chapter", [0, 1], nil),
            ("partial", [0, 1, 2], 0),
        ]
        for testCase in cases {
            let databaseURL = fixture.root.appendingPathComponent("\(testCase.name).sqlite")
            let store = LocalSQLiteStore(fileURL: databaseURL)
            var chapters = zip(scanned.chapters, testCase.positions).enumerated().map { offset, pair in
                StoredChapter(
                    id: pair.0.chapterID,
                    index: pair.1,
                    title: pair.0.title,
                    ebookSectionIndex: testCase.partialSectionIndex.flatMap { offset == 0 ? $0 : nil }
                )
            }
            if testCase.name == "duplicate" {
                chapters[0].id = ChapterID(rawValue: "z-duplicate")
                chapters[1].id = ChapterID(rawValue: "a-duplicate")
            }
            let legacy = StoredBook(
                id: scanned.bookID,
                title: scanned.title,
                author: scanned.author,
                source: scanned.source.rawValue,
                chapters: chapters
            )
            try store.saveBook(legacy)
            try store.saveAssets(StoredLocalAsset.snapshots(for: scanned), bookID: legacy.id)

            _ = try Persistence.loadCatalogBooks(database: store)
            let reloaded = try #require(try store.loadBooks().first)
            let chaptersByID = Dictionary(uniqueKeysWithValues: reloaded.chapters.map { ($0.id, $0) })

            #expect(reloaded.id == legacy.id, "case: \(testCase.name)")
            #expect(reloaded.title == legacy.title, "case: \(testCase.name)")
            #expect(reloaded.author == legacy.author, "case: \(testCase.name)")
            #expect(reloaded.source == legacy.source, "case: \(testCase.name)")
            #expect(chaptersByID.count == legacy.chapters.count, "case: \(testCase.name)")
            for chapter in legacy.chapters {
                #expect(chaptersByID[chapter.id] == chapter, "case: \(testCase.name), chapter: \(chapter.id.rawValue)")
            }
            #expect(try store.pendingMutations().isEmpty, "case: \(testCase.name)")
        }
    }

#if os(macOS)
    @MainActor
    @Test("macOS Apple Books reads and imports expanded EPUB downloads")
    func macAppleBooksReadsExpandedEPUBDownloads() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let archive = try makeNavigationEPUB(in: fixture.root, usesNCX: false)
        let booksRoot = fixture.root.appendingPathComponent("Books", isDirectory: true)
        _ = try expandEPUB(archive, in: booksRoot)

        let items = try await MacAppleBooksLibrary.readDownloadedBooks(in: booksRoot)
        let item = try #require(items.first)

        #expect(items.count == 1)
        #expect(item.title == "Navigation Book")
        #expect(item.author == "Page Turner")
        #expect(item.artworkData == navigationEPUBCoverData)
        #expect(!item.isProtected)
        #expect(item.canImport)

        let importedRoot = fixture.root.appendingPathComponent("Imported", isDirectory: true)
        try MacAppleBooksLibrary().importAudiobook(item, into: importedRoot)
        let book = try #require(LibraryScanner.scan(root: importedRoot).first)
        let coverPath = try #require(book.coverPath)

        #expect(book.title == "Navigation Book")
        #expect(book.author == "Page Turner")
        #expect(book.source == .appleBooks)
        #expect(try Data(contentsOf: URL(fileURLWithPath: coverPath)) == navigationEPUBCoverData)
    }

    @Test("macOS Apple Books keeps encrypted EPUB reading content unavailable")
    func macAppleBooksRejectsEncryptedExpandedEPUBContent() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let archive = try makeNavigationEPUB(in: fixture.root, usesNCX: false)
        let booksRoot = fixture.root.appendingPathComponent("Books", isDirectory: true)
        let expanded = try expandEPUB(archive, in: booksRoot)
        try Data("""
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
            <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <CipherData><CipherReference URI="OEBPS/content.xhtml"/></CipherData>
          </EncryptedData>
        </encryption>
        """.utf8).write(to: expanded.appendingPathComponent("META-INF/encryption.xml"))

        let item = try #require(
            try await MacAppleBooksLibrary.readDownloadedBooks(in: booksRoot).first
        )

        #expect(item.isProtected)
        #expect(!item.canImport)
    }

    @Test("macOS Apple Books allows expanded EPUBs with obfuscated fonts")
    func macAppleBooksAllowsExpandedEPUBWithObfuscatedFonts() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let archive = try makeNavigationEPUB(in: fixture.root, usesNCX: false)
        let booksRoot = fixture.root.appendingPathComponent("Books", isDirectory: true)
        let expanded = try expandEPUB(archive, in: booksRoot)
        let fonts = expanded.appendingPathComponent("OEBPS/fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data("obfuscated font fixture".utf8).write(to: fonts.appendingPathComponent("body.otf"))
        try Data("""
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
            <EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <CipherData><CipherReference URI="OEBPS/fonts/body.otf"/></CipherData>
          </EncryptedData>
        </encryption>
        """.utf8).write(to: expanded.appendingPathComponent("META-INF/encryption.xml"))

        let item = try #require(
            try await MacAppleBooksLibrary.readDownloadedBooks(in: booksRoot).first
        )

        #expect(item.title == "Navigation Book")
        #expect(!item.isProtected)
        #expect(item.canImport)
    }

    @Test("macOS Apple Books exposes only accessible downloaded media")
    func macAppleBooksImportConstraint() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let epub = try makeEPUB(
            in: fixture.root,
            name: "Apple Book",
            title: "Apple Book",
            author: "Book Author",
            sections: [("Read", "This accessible downloaded EPUB contains readable published words for import.")]
        )
        let item = MacAppleBookItem(
            id: epub.path,
            title: "Apple Book",
            author: "Book Author",
            duration: 0,
            location: epub,
            artworkData: nil,
            isProtected: false,
            isCloud: false,
            kind: .ebook
        )
        var protected = item
        protected.isProtected = true
        var cloud = item
        cloud.isCloud = true

        #expect(item.canImport)
        #expect(!protected.canImport)
        #expect(!cloud.canImport)
    }

    @MainActor
    @Test("macOS Apple Books attaches either missing companion without replacing existing media")
    func macAppleBooksAttachesMissingCompanions() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let epub = try makeEPUB(
            in: incoming,
            name: "Apple Companion",
            title: "Apple Companion",
            author: "Book Author",
            sections: [("Read", "This Apple Books EPUB remains readable after its audiobook companion is attached.")]
        )
        let audio = incoming.appendingPathComponent("Apple Companion.m4b")
        try Data("apple books companion audio".utf8).write(to: audio)
        let appleBooks = MacAppleBooksLibrary()

        let ebookOnly = try AudiobookImportService.importFiles([epub], into: library).folder
        let audioItem = MacAppleBookItem(
            id: audio.path,
            title: "Apple Companion",
            author: "Book Author",
            duration: 0,
            location: audio,
            artworkData: nil,
            isProtected: false,
            isCloud: false,
            kind: .audiobook
        )

        #expect(try appleBooks.addCompanion(audioItem, to: ebookOnly, required: .audiobook) == [audio.lastPathComponent])
        let pairedFromEbook = try #require(LibraryScanner.scan(root: library).first)
        let attachedEbookPath = try #require(pairedFromEbook.ebookPath)
        #expect(pairedFromEbook.mediaAvailability == .audioAndEbook)
        #expect(FileManager.default.fileExists(atPath: attachedEbookPath))
        #expect(try appleBooks.addCompanion(audioItem, to: ebookOnly, required: .audiobook).isEmpty)
        #expect(LibraryScanner.scan(root: library).first?.mediaAvailability == .audioAndEbook)

        let secondLibrary = fixture.root.appendingPathComponent("second-library", isDirectory: true)
        let audioOnly = try AudiobookImportService.importFiles([audio], into: secondLibrary).folder
        let ebookItem = MacAppleBookItem(
            id: epub.path,
            title: "Apple Companion",
            author: "Book Author",
            duration: 0,
            location: epub,
            artworkData: nil,
            isProtected: false,
            isCloud: false,
            kind: .ebook
        )

        #expect(try appleBooks.addCompanion(ebookItem, to: audioOnly, required: .ebook) == [epub.lastPathComponent])
        let pairedFromAudio = try #require(LibraryScanner.scan(root: secondLibrary).first)
        #expect(pairedFromAudio.mediaAvailability == .audioAndEbook)
        #expect(pairedFromAudio.chapters.contains { $0.hasAudio })
    }

    @MainActor
    @Test("macOS Apple Books rejects a second same-type companion without mutating the book")
    func macAppleBooksRejectsSameTypeCompanionsWithoutMutation() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let firstEPUB = try makeEPUB(
            in: incoming,
            name: "First Edition",
            title: "First Edition",
            author: "Book Author",
            sections: [("Read", "The first EPUB must remain the effective readable publication after rejection, preserving every published sentence and the current reading position for the selected book.")]
        )
        let secondEPUB = try makeEPUB(
            in: incoming,
            name: "Second Edition",
            title: "Second Edition",
            author: "Book Author",
            sections: [("Read", "This different EPUB contains enough readable publication text for validation but must never be copied into the selected book or become its effective reading content.")]
        )
        let firstAudio = incoming.appendingPathComponent("First Audio.m4b")
        let secondAudio = incoming.appendingPathComponent("Second Audio.m4b")
        try Data("first audio bytes".utf8).write(to: firstAudio)
        try Data("different second audio bytes".utf8).write(to: secondAudio)
        let appleBooks = MacAppleBooksLibrary()

        let ebookOnly = try AudiobookImportService.importFiles([firstEPUB], into: library).folder
        let ebookSnapshot = try directorySnapshot(ebookOnly)
        let secondEPUBItem = MacAppleBookItem(
            id: secondEPUB.path,
            title: "Second Edition",
            author: "Book Author",
            duration: 0,
            location: secondEPUB,
            artworkData: nil,
            isProtected: false,
            isCloud: false,
            kind: .ebook
        )
        #expect(throws: AudiobookImportError.self) {
            try appleBooks.addCompanion(secondEPUBItem, to: ebookOnly, required: .audiobook)
        }
        #expect(try directorySnapshot(ebookOnly) == ebookSnapshot)
        #expect(LibraryScanner.scan(root: library).first?.ebookPath?.hasSuffix("First Edition.epub") == true)

        let secondLibrary = fixture.root.appendingPathComponent("second-library", isDirectory: true)
        let audioOnly = try AudiobookImportService.importFiles([firstAudio], into: secondLibrary).folder
        let audioSnapshot = try directorySnapshot(audioOnly)
        let secondAudioItem = MacAppleBookItem(
            id: secondAudio.path,
            title: "Second Audio",
            author: "Book Author",
            duration: 0,
            location: secondAudio,
            artworkData: nil,
            isProtected: false,
            isCloud: false,
            kind: .audiobook
        )
        #expect(throws: AudiobookImportError.self) {
            try appleBooks.addCompanion(secondAudioItem, to: audioOnly, required: .ebook)
        }
        #expect(try directorySnapshot(audioOnly) == audioSnapshot)
        #expect(LibraryScanner.scan(root: secondLibrary).first?.chapters.first?.audioPath.hasSuffix("First Audio.m4b") == true)
    }

    @Test("macOS Apple Books derives one unambiguous missing capability while metadata-only books allow either")
    func macAppleBooksCompanionRequirementsFollowMediaAvailability() {
        #expect(MacAppleBooksCompanionRequirement(mediaAvailability: .ebookOnly) == .audiobook)
        #expect(MacAppleBooksCompanionRequirement(mediaAvailability: .audioOnly) == .ebook)
        #expect(MacAppleBooksCompanionRequirement(mediaAvailability: .metadataOnly) == .either)
        #expect(MacAppleBooksCompanionRequirement(mediaAvailability: .audioAndEbook) == nil)
    }
#endif

    @Test("File import copies audio and companion ebook with source metadata")
    func importsFiles() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let audio = incoming.appendingPathComponent("Sample Book.m4b")
        let ebook = incoming.appendingPathComponent("Sample Book.epub")
        try Data("audio fixture".utf8).write(to: audio)
        try Data("ebook fixture".utf8).write(to: ebook)

        try AudiobookImportService.importFiles([audio, ebook], into: library)

        let book = library.appendingPathComponent("Sample Book", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: book.appendingPathComponent("Sample Book.m4b").path))
        #expect(FileManager.default.fileExists(atPath: book.appendingPathComponent("Sample Book.epub").path))
        let source = try String(contentsOf: book.appendingPathComponent(".audioreader-source"), encoding: .utf8)
        #expect(source == BookSource.files.rawValue)
    }

    @Test("Imported device audiobook is discoverable with its source metadata")
    func discoversImportedDeviceAudiobook() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let book = try AudiobookImportService.newBookFolder(title: "Device Book", in: fixture.root)
        try AudiobookImportService.writeMarkers(
            source: .deviceAudiobooks,
            title: "Device Book",
            author: "Device Author",
            to: book
        )
        try Data("audio fixture".utf8).write(to: book.appendingPathComponent("audiobook.m4a"))

        let scanned = LibraryScanner.scan(root: fixture.root)
        let imported = try #require(scanned.first)

        #expect(scanned.count == 1)
        #expect(imported.title == "Device Book")
        #expect(imported.author == "Device Author")
        #expect(imported.source == .deviceAudiobooks)
    }

    @Test("Folder import produces a discoverable local book")
    func importsFolder() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("audio fixture".utf8).write(to: source.appendingPathComponent("chapter.m4b"))

        try AudiobookImportService.importFolder(source, into: library)
        let scanned = LibraryScanner.scan(root: library)
        let imported = try #require(scanned.first)

        #expect(scanned.count == 1)
        #expect(imported.source == .localFolder)
        #expect(imported.chapters.count == 1)
    }

    @Test("Importing the same audio content twice does not duplicate the book")
    func deduplicatesExactAudioContent() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("first", isDirectory: true)
        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let bytes = Data("the exact same audiobook bytes".utf8)
        let firstAudio = first.appendingPathComponent("Original Name.m4b")
        let secondAudio = second.appendingPathComponent("Completely Different Name.m4b")
        try bytes.write(to: firstAudio)
        try bytes.write(to: secondAudio)

        try AudiobookImportService.importFiles([firstAudio], into: library)
        try AudiobookImportService.importFiles([secondAudio], into: library)

        #expect(LibraryScanner.scan(root: library).count == 1)
    }

    @Test("Books with the same name but different audio content remain distinct")
    func doesNotDeduplicateByName() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("first", isDirectory: true)
        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstAudio = first.appendingPathComponent("Same Name.m4b")
        let secondAudio = second.appendingPathComponent("Same Name.m4b")
        try Data("first edition audio".utf8).write(to: firstAudio)
        try Data("different edition audio".utf8).write(to: secondAudio)

        try AudiobookImportService.importFiles([firstAudio], into: library)
        try AudiobookImportService.importFiles([secondAudio], into: library)

        #expect(LibraryScanner.scan(root: library).count == 2)
    }

    @Test("Re-importing exact audio can enrich the existing book with an EPUB")
    func enrichesExistingBookWithEbook() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let audio = incoming.appendingPathComponent("Study Book.m4b")
        let ebook = try makeEPUB(
            in: incoming,
            name: "Study Book",
            title: "Study Book",
            author: nil,
            sections: [("Read", "This later companion ebook contains enough meaningful published words for alignment.")]
        )
        try Data("stable audiobook content".utf8).write(to: audio)

        try AudiobookImportService.importFiles([audio], into: library)
        try AudiobookImportService.importFiles([audio, ebook], into: library)

        let books = LibraryScanner.scan(root: library)
        let book = try #require(books.first)
        #expect(books.count == 1)
        #expect(book.ebookPath != nil)
    }

    @Test("Persisted device chapter ranges split exported M4A audio")
    func loadsPersistedDeviceChapters() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("Device Book", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio fixture".utf8).write(to: folder.appendingPathComponent("audiobook.m4a"))
        let sidecar = """
        [
          {"title":"Introduction","start":0,"duration":42.5},
          {"title":"Chapter One","start":42.5,"duration":180.25}
        ]
        """
        try Data(sidecar.utf8).write(to: folder.appendingPathComponent(".audioreader-chapters.json"))

        let scanned = try #require(LibraryScanner.scan(root: fixture.root).first)
        let loaded = await LibraryScanner.loadDurations(for: scanned)
        let second = try #require(loaded.chapters.dropFirst().first)

        #expect(loaded.chapters.count == 2)
        #expect(second.title == "Chapter One")
        #expect(second.audioStart == 42.5)
    }

    @Test("iPad playback speeds provide five-percent increments from half to double speed")
    func providesGranularPlaybackSpeeds() {
        #expect(PlaybackSpeedCatalog.values.first == 0.5)
        #expect(PlaybackSpeedCatalog.values.last == 2.0)
        #expect(PlaybackSpeedCatalog.values.count == 31)
        #expect(PlaybackSpeedCatalog.values.contains(0.95))
        #expect(PlaybackSpeedCatalog.values.contains(1.05))
    }

    @MainActor
    @Test("Opening a vocabulary entry reports whether reader navigation succeeded")
    func reportsVocabularyReaderNavigation() {
        let state = AppState()
        let chapter = Chapter(
            id: "chapter-id",
            index: 0,
            title: "Chapter One",
            audioPath: "/tmp/missing-audio.m4b"
        )
        state.books = [Book(
            id: "book-id",
            title: "Book",
            author: nil,
            folderPath: "/tmp",
            coverPath: nil,
            ebookPath: nil,
            chapters: [chapter]
        )]
        let entry = VocabEntry(
            id: "entry-id",
            word: "example",
            context: "An example sentence.",
            bookID: "book-id",
            bookTitle: "Book",
            chapterID: "chapter-id",
            chapterTitle: "Chapter One",
            timestamp: 1,
            addedAt: Date()
        )
        var missing = entry
        missing.bookID = "missing-book"
        missing.bookTitle = "Entirely Absent"

        #expect(state.jumpToVocab(entry))
        #expect(state.tab == .player)
        #expect(state.selectedBookID == "book-id")
        #expect(state.selectedChapterID == "chapter-id")
        #expect(!state.jumpToVocab(missing))
    }

    @Test("Book deletion is limited to a direct child of the imported library")
    func deletesOnlyScopedImportedBook() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        let book = library.appendingPathComponent("Book", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: book.appendingPathComponent("chapter.m4b"))

        try AudiobookImportService.deleteBookFolder(book, in: library)

        #expect(!FileManager.default.fileExists(atPath: book.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(throws: AudiobookImportError.self) {
            try AudiobookImportService.deleteBookFolder(outside, in: library)
        }
    }

    @Test("Embedded audiobook artwork is persisted as a discoverable cover")
    func persistsEmbeddedArtwork() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let book = fixture.root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let cover = try EmbeddedArtwork.store(pngHeader, in: book)

        #expect(cover.lastPathComponent == "cover.png")
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(try Data(contentsOf: cover) == pngHeader)
    }

    @Test("Embedded M4B metadata becomes independently ranged chapters")
    func createsRangedM4BChapters() {
        let metadata = [
            EmbeddedM4BChapter(title: "Introduction", start: 0, duration: 42.5),
            EmbeddedM4BChapter(title: "Chapter One", start: 42.5, duration: 180.25)
        ]

        let chapters = M4BChapterExtractor.makeChapters(audioPath: "/tmp/book.m4b", metadata: metadata)

        #expect(chapters.count == 2)
        #expect(chapters[0].title == "Introduction")
        #expect(chapters[0].audioStart == 0)
        #expect(chapters[0].duration == 42.5)
        #expect(chapters[1].title == "Chapter One")
        #expect(chapters[1].audioStart == 42.5)
        #expect(chapters[1].duration == 180.25)
        #expect(chapters[0].id != chapters[1].id)
    }

    @Test("Embedded M4B transcripts require the matching chapter start")
    func distinguishesEmbeddedChapterTranscripts() {
        let chapter = Chapter(
            id: "chapter-two",
            index: 1,
            title: "Chapter Two",
            audioPath: "/tmp/book.m4b",
            duration: 120,
            startTime: 42.5
        )
        let legacy = Transcript(
            chapterID: chapter.id,
            audioPath: chapter.audioPath,
            createdAt: Date(),
            locale: "en-US",
            segments: [],
            source: "SpeechAnalyzer",
            ebookAligned: false
        )
        var matching = legacy
        matching.chapterStart = 42.5
        var different = legacy
        different.chapterStart = 0

        #expect(legacy.belongs(to: chapter) == false)
        #expect(matching.belongs(to: chapter))
        #expect(different.belongs(to: chapter) == false)
    }

    @Test("vNext imported book chapter and asset identities survive iOS container path changes")
    func preservesVNextImportedBookIdentityAcrossContainerChanges() {
        let oldFolder = "/private/var/mobile/Containers/Data/Application/OLD/Documents/ImportedBooks-vNext/The Ride"
        let currentFolder = "/var/mobile/Containers/Data/Application/NEW/Documents/ImportedBooks-vNext/The Ride"
        let oldPath = "\(oldFolder)/book.m4b"
        let currentPath = "\(currentFolder)/book.m4b"
        let oldBookID = LibraryScanner.stableID(oldFolder)
        let currentBookID = LibraryScanner.stableID(currentFolder)
        let oldChapterID = LibraryScanner.stableID("\(oldPath)#0.000")
        let currentChapterID = LibraryScanner.stableID("\(currentPath)#0.000")
        let oldBook = Book(
            id: oldBookID,
            title: "The Ride",
            folderPath: oldFolder,
            chapters: [Chapter(id: oldChapterID, index: 0, title: "One", audioPath: oldPath, startTime: 0)]
        )
        let currentBook = Book(
            id: currentBookID,
            title: "The Ride",
            folderPath: currentFolder,
            chapters: [Chapter(id: currentChapterID, index: 0, title: "One", audioPath: currentPath, startTime: 0)]
        )

        #expect(oldBookID == currentBookID)
        #expect(oldChapterID == currentChapterID)
        #expect(StoredLocalAsset.snapshots(for: oldBook).map(\.id) == StoredLocalAsset.snapshots(for: currentBook).map(\.id))
        #expect(
            LibraryScanner.stableID("/old/Documents/ImportedBooks/Legacy/book.m4b")
                == LibraryScanner.stableID("/new/Documents/ImportedBooks/Legacy/book.m4b")
        )
    }

    @Test("Chapter translation groups sentences by the configured block size")
    func groupsChapterTranslationBlocks() {
        var segments: [TranscriptSegment] = []
        for index in 1...7 {
            segments.append(TranscriptSegment(
                id: "segment-\(index)",
                start: Double(index),
                end: Double(index + 1),
                words: [.init(id: "word-\(index)", text: "Sentence \(index).", start: Double(index), end: Double(index + 1), confidence: nil)]
            ))
        }

        let blocks = ChapterTranslationBatch.blocks(segments, size: 3)

        #expect(blocks.map(\.count) == [3, 3, 1])
        #expect(blocks.flatMap { $0 }.map(\.id) == segments.map(\.id))

        let aligned = ChapterTranslationBatch.alignedBlock(containing: segments[4], in: segments, size: 3)
        #expect(aligned.map(\.id) == ["segment-4", "segment-5", "segment-6"])
        #expect(ChapterTranslationBatch.alignedBlock(containing: segments[0], in: segments, size: 3).map(\.id) == ["segment-1", "segment-2", "segment-3"])
    }

    @Test("Chapter translation parses one reviewable result per sentence")
    func parsesChapterTranslationResults() throws {
        let response = """
        ```json
        [
          {
            "id": "segment-1",
            "translation": "第一句。",
            "phrases": [
              {"source": "break the ice", "explanation": "打破沉默，缓和气氛"}
            ]
          },
          {
            "id": "segment-2",
            "translation": "第二句。",
            "phrases": []
          }
        ]
        ```
        """

        let results = try ChapterTranslationBatch.parse(response, expectedIDs: ["segment-1", "segment-2"])

        #expect(results.count == 2)
        #expect(results[0].id == "segment-1")
        #expect(results[0].glossText.contains("TRANSLATION:\n第一句。"))
        #expect(results[0].glossText.contains("break the ice"))
        #expect(results[1].glossText.contains("LANGUAGE AND CONTEXT NOTES:\nNone"))
    }

    @Test("Chapter translation display labels stay in the English app UI")
    func formatsChapterTranslationWithoutChineseLabels() throws {
        let response = """
        {
          "translations": [
            {
              "id": "segment-1",
              "translation": "Ella rompió el hielo.",
              "phrases": [
                {"source": "break the ice", "explanation": "romper el hielo"}
              ]
            }
          ]
        }
        """

        let result = try #require(
            ChapterTranslationBatch.parse(response, expectedIDs: ["segment-1"]).first
        )

        #expect(result.glossText.contains("TRANSLATION:\nElla rompió el hielo."))
        #expect(result.glossText.contains("LANGUAGE AND CONTEXT NOTES:"))
        #expect(!result.glossText.contains("译文"))
        #expect(!result.glossText.contains("短语"))
    }

    @Test("Accepted sentence glosses capture phrasal verbs from the English section label")
    func extractsPhrasalVerbsFromEnglishGlossLabel() throws {
        let phrases = GlossPhrases.extract(from: """
        TRANSLATION:
        Ella rompió el hielo.

        PHRASAL VERBS AND PHRASES:
        • **break the ice** — romper el hielo
        """)

        let phrase = try #require(phrases.first)
        #expect(phrase.phrase == "break the ice")
        #expect(phrase.meaning == "romper el hielo")
    }

    @Test("Non-Chinese translation prompts apply the target language to every generated field")
    func appliesNonChineseTargetLanguageThroughoutPrompts() {
        for language in [StudyLanguage.ja, .ko, .es, .fr, .de, .en] {
            let sentence = ReadingAssistantPrompt.sentenceTranslation(
                language: language,
                metadata: "Book: Test",
                context: "TARGET id=one: Test.",
                targetIDs: ["one"]
            )
            let word = ReadingAssistantPrompt.word(language: language)
            let summary = ReadingAssistantPrompt.chapterSummary(language: language)

            #expect(sentence.system.contains("Translate each requested English target sentence naturally into \(language.promptName)"))
            #expect(sentence.system.contains("all phrasal verbs and idioms"))
            #expect(sentence.system.contains("Return valid JSON only"))
            #expect(sentence.system.contains("Do not use Chinese anywhere in the response"))
            #expect(word.contains("Write every explanation and example translation in \(language.promptName)"))
            #expect(word.contains("Do not use Chinese anywhere in the response"))
            #expect(summary.contains("Summarise it concisely in \(language.promptName)"))
            #expect(summary.contains("\"overview\":\"one concise paragraph in \(language.promptName)\""))
            #expect(summary.contains("Do not use Chinese anywhere in the response"))
        }
    }

    @Test("Dictionary search follows the translation language instead of a stale Chinese preference")
    func ordersDictionariesForTargetLanguage() {
        let installed = [
            "牛津英汉汉英词典",
            "Spanish - English",
            "Spanish",
            "Oxford Dictionary of English"
        ]

        let spanish = DictionaryLookup.searchOrder(
            preferredName: "牛津英汉汉英词典",
            language: .es,
            installedNames: installed
        )
        let chinese = DictionaryLookup.searchOrder(
            preferredName: "牛津英汉汉英词典",
            language: .zhHans,
            installedNames: installed
        )

        #expect(spanish == ["Spanish - English", "Spanish", "Oxford Dictionary of English"])
        #expect(!spanish.contains("牛津英汉汉英词典"))
        #expect(chinese.first == "牛津英汉汉英词典")
    }

    @Test("Dictionary HTML preserves native Oxford sense flow and typography")
    func normalizesDictionaryHTML() {
        let raw = """
        <body>
          <span class="hg"><span class="hw">encompass</span><span class="syl_txt">en·com·pass</span></span>
          <span class="se2 hasSn">
            <span class="gp x_xdh sn ty_label tg_se2">1</span>
            <span class="msDict t_first"><span class="gg">[with object]</span> <span class="df">surround and hold within</span><span class="gp tg_df">: </span><span class="eg"><span class="ex">a vast halo encompassing the Milky Way galaxy.</span></span></span>
            <span class="msDict hasSn t_subsense"><span class="gp sn tg_msDict">• </span><span class="df">include comprehensively</span></span>
          </span>
          <span class="subEntryBlock t_derivatives"><span class="gp x_xoLblBlk">DERIVATIVES</span><span class="subEntry"><span class="l">encompassment</span> <span class="pos">noun</span></span></span>
        </body>
        """

        let rendered = DictionaryLookup.displayHTML(raw, dark: false)

        #expect(rendered.contains("<span class=\"gp tg_df\">: </span>"))
        #expect(rendered.contains("<span class=\"gp sn tg_msDict\">• </span>"))
        #expect(rendered.contains("body * { font-weight: 400 !important; }"))
        #expect(rendered.contains(".syl_txt { display: none; }"))
        #expect(rendered.contains(".se2 > .x_xdh,"))
        #expect(rendered.contains(".eg { display: inline; }"))
        #expect(rendered.contains(".subEntryBlock"))
    }

    @Test("Vocabulary dictionary previews keep only concise primary senses")
    func summarizesDictionaryEntryForVocabulary() {
        let html = """
        <body>
          <span class="se2"><span d:def="1" class="df">a set of connected things forming a whole</span><span class="eg"><span class="ex">the railway system</span></span></span>
          <span class="se2"><span class="df">a specialist subsense that belongs in the full entry</span></span>
          <span class="se2"><span class="df" d:def="1">an organized method or scheme</span></span>
          <span class="se2"><span d:def="1" class="df">the prevailing political order</span></span>
          <span class="subEntryBlock">PHRASES all systems go</span>
        </body>
        """

        let preview = DictionaryLookup.concisePreview(
            definition: "system | pronunciation | noun 1 every flattened detail and example",
            html: html,
            limit: 2
        )

        #expect(preview == [
            "a set of connected things forming a whole",
            "an organized method or scheme"
        ])
        #expect(!preview.joined().contains("railway"))
        #expect(!preview.joined().contains("PHRASES"))
    }

    @Test("Vocabulary dictionary previews summarize plain translated definitions")
    func summarizesPlainDictionaryDefinition() {
        let preview = DictionaryLookup.concisePreview(
            definition: "制度；教育或金融体制；封建制度；用于某事的方法；系统；装置",
            html: nil,
            limit: 3
        )

        #expect(preview == ["制度", "教育或金融体制", "封建制度"])
    }

    @Test("iPad dictionary state does not retain a stale Chinese preference")
    func normalizesIPadDictionaryPreference() {
        let name = DictionaryLookup.recommendedName(
            language: .ko,
            installedNames: ["iPadOS Dictionary"]
        )

        #expect(name == "iPadOS Dictionary")
    }

    @Test("Incomplete chapter JSON preserves valid sentences and identifies the retry remainder")
    func preservesPartialChapterTranslationResults() throws {
        let response = """
        {
          "translations": [
            {"id":"segment-1","translation":"第一句。","phrases":[]},
            {"id":"unexpected","translation":"忽略。","phrases":[]}
          ]
        }
        """

        let parsed = try ChapterTranslationBatch.parseAvailable(
            response,
            expectedIDs: ["segment-1", "segment-2"]
        )

        #expect(parsed.results.map(\.id) == ["segment-1"])
        #expect(parsed.missingIDs == ["segment-2"])
        #expect(ChapterTranslationBatch.maximumAttempts == 3)
    }

    @Test("Qwen request effort is normalized for each documented model family")
    func normalizesQwenRequestEffort() {
        #expect(QwenRequestPolicy.supportedEfforts(model: "qwen3.7-plus") == QwenEffort.allCases)
        #expect(QwenRequestPolicy.supportedEfforts(model: "deepseek-v4-flash-0731") == QwenEffort.allCases)
        #expect(QwenRequestPolicy.supportedEfforts(model: "glm-5.2") == QwenEffort.allCases)
        #expect(QwenRequestPolicy.effort(model: "qwen3.7-plus", requested: "xhigh", thinking: true, api: .responses) == "xhigh")
        #expect(QwenRequestPolicy.effort(model: "qwen3.7-plus", requested: "high", thinking: false, api: .responses) == "none")
        #expect(QwenRequestPolicy.effort(model: "deepseek-v4-flash-0731", requested: "minimal", thinking: true, api: .responses) == "minimal")
        #expect(QwenRequestPolicy.effort(model: "glm-5.2", requested: "medium", thinking: true, api: .responses) == "medium")
        #expect(QwenRequestPolicy.effort(model: "deepseek-v4-flash-0731", requested: "low", thinking: true, api: .chat) == "low")
        #expect(QwenRequestPolicy.effort(model: "deepseek-v4-flash", requested: "medium", thinking: true, api: .chat) == "high")
        #expect(QwenRequestPolicy.effort(model: "glm-5.2", requested: "xhigh", thinking: true, api: .chat) == "max")
        #expect(QwenRequestPolicy.effort(model: "qwen3.7-max-preview", requested: "high", thinking: false, api: .responses) == "high")
        #expect(QwenRequestPolicy.effort(model: "custom-model", requested: "high", thinking: true, api: .chat) == nil)
    }

    @Test("Thinking-only Qwen models normalize none to a supported effort")
    func normalizesThinkingOnlyQwenEffort() {
        let supported = QwenRequestPolicy.supportedEfforts(model: "qwen3.7-max-preview")

        #expect(!supported.contains(.none))
        #expect(supported.contains(.minimal))
        #expect(QwenRequestPolicy.effort(
            model: "qwen3.7-max-preview",
            requested: QwenEffort.none.rawValue,
            thinking: false,
            api: .responses
        ) == QwenEffort.minimal.rawValue)
    }

    @Test("Thinking-only Qwen requests never disable thinking")
    func preservesThinkingForThinkingOnlyQwenRequests() throws {
        let responsesRequest = try LLMRequestBuilder.responses(
            provider: .qwenCloud,
            apiKey: "test-key",
            baseURL: "https://example.com/compatible-mode/v1",
            model: "qwen3.7-max-preview",
            system: "Be concise.",
            user: "Reply only OK.",
            effort: QwenEffort.none.rawValue,
            enableThinking: false
        )
        let responsesBody = try #require(responsesRequest.httpBody)
        let responsesJSON = try #require(JSONSerialization.jsonObject(with: responsesBody) as? [String: Any])
        let reasoning = try #require(responsesJSON["reasoning"] as? [String: String])

        #expect(responsesJSON["enable_thinking"] == nil)
        #expect(reasoning["effort"] == QwenEffort.minimal.rawValue)

        let chatRequest = try LLMRequestBuilder.chat(
            provider: .qwenCloud,
            apiKey: "test-key",
            baseURL: "https://example.com/compatible-mode/v1",
            model: "qwen3.7-max-preview",
            system: "Be concise.",
            user: "Reply only OK.",
            effort: QwenEffort.none.rawValue,
            enableThinking: false
        )
        let chatBody = try #require(chatRequest.httpBody)
        let chatJSON = try #require(JSONSerialization.jsonObject(with: chatBody) as? [String: Any])

        #expect(chatJSON["enable_thinking"] == nil)
    }

    @Test("QwenCloud defaults to no reasoning and preserves it in Chat fallback")
    func defaultsQwenEffortToNone() throws {
        #expect(AppSettings.default.qwenEffort == QwenEffort.none.rawValue)

        let request = try LLMRequestBuilder.chat(
            provider: .qwenCloud,
            apiKey: "test-key",
            baseURL: "https://example.com/compatible-mode/v1",
            model: "qwen3.7-plus",
            system: "Be concise.",
            user: "Reply only OK.",
            effort: QwenEffort.none.rawValue,
            enableThinking: true
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["enable_thinking"] as? Bool == false)
        #expect(json["reasoning_effort"] == nil)
    }

    @Test("Existing settings migrate once from the former high effort default")
    func migratesLegacyQwenEffortDefault() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["qwenEffort"] = "high"
        object.removeValue(forKey: "qwenEffortPolicyVersion")

        let migrated = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(migrated.qwenEffort == QwenEffort.none.rawValue)
        #expect(migrated.qwenEffortPolicyVersion == 1)
    }

    @Test("Structured chapter requests use schema enforcement supported by each API")
    func buildsStructuredChapterRequest() throws {
        let qwenRequest = try LLMRequestBuilder.responses(
            provider: .qwenCloud,
            apiKey: "test-key",
            baseURL: "https://example.com/compatible-mode/v1",
            model: "qwen3.7-plus",
            system: "Return JSON output.",
            user: "Translate this sentence.",
            effort: "medium",
            enableThinking: true,
            structuredJSON: true
        )
        let qwenBody = try #require(qwenRequest.httpBody)
        let qwenJSON = try #require(JSONSerialization.jsonObject(with: qwenBody) as? [String: Any])
        let tools = try #require(qwenJSON["tools"] as? [[String: Any]])
        let reasoning = try #require(qwenJSON["reasoning"] as? [String: String])
        let toolName = tools.first?["name"] as? String

        #expect(qwenJSON["tool_choice"] as? String == "required")
        #expect(toolName == "submit_translations")
        #expect(reasoning["effort"] == "medium")

        let glmRequest = try LLMRequestBuilder.responses(
            provider: .qwenCloud,
            apiKey: "test-key",
            baseURL: "https://example.com/compatible-mode/v1",
            model: "glm-5.2",
            system: "Return JSON output.",
            user: "Translate this sentence.",
            effort: "low",
            enableThinking: true,
            structuredJSON: true
        )
        let glmBody = try #require(glmRequest.httpBody)
        let glmJSON = try #require(JSONSerialization.jsonObject(with: glmBody) as? [String: Any])
        let glmReasoning = try #require(glmJSON["reasoning"] as? [String: String])
        #expect(glmReasoning["effort"] == "low")
        #expect(glmJSON["tool_choice"] as? String == "required")

        let chatRequest = try LLMRequestBuilder.chat(
            provider: .qwenCloud,
            apiKey: "test-key",
            baseURL: "https://example.com/compatible-mode/v1",
            model: "deepseek-v4-flash",
            system: "Return JSON output.",
            user: "Translate this sentence.",
            effort: "max",
            enableThinking: true,
            structuredJSON: true
        )
        let chatBody = try #require(chatRequest.httpBody)
        let chatJSON = try #require(JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        let format = try #require(chatJSON["response_format"] as? [String: String])
        #expect(format["type"] == "json_object")
        #expect(chatJSON["reasoning_effort"] as? String == "max")
    }

    @Test("Legacy settings gain a safe chapter translation block size")
    func defaultsChapterTranslationBlockSize() throws {
        let legacy = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object.removeValue(forKey: "chapterTranslationBlockSize")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.chapterTranslationBlockSize == 5)
    }

    @Test("Legacy settings gain safe reader appearance defaults")
    func defaultsReaderAppearance() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["readerFont", "readerBold", "readerLineSpacing", "readerWordSpacing", "readerMargin"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.readerFont == ReaderFontChoice.newYork.rawValue)
        #expect(decoded.readerBold == false)
        #expect(decoded.readerLineSpacing == 1)
        #expect(decoded.readerWordSpacing == 2)
        #expect(decoded.readerMargin == 32)
    }

    @Test("Reader line spacing changes wrapped lines and the space between sentence rows")
    func appliesReaderLineSpacingThroughoutText() {
        let compact = ReaderType.metrics(columnWidth: 600, scale: 1, lineSpacing: 0.7)
        let expanded = ReaderType.metrics(columnWidth: 600, scale: 1, lineSpacing: 2)

        #expect(compact.line < expanded.line)
        #expect(compact.paragraph < expanded.paragraph)
    }

    @Test("Reader position resolves its current segment and word together")
    @MainActor
    func resolvesCurrentReaderPosition() throws {
        let first = TranscriptSegment(
            id: "first",
            start: 0,
            end: 2,
            words: [
                TranscriptWord(id: "one", text: "One ", start: 0, end: 1, confidence: nil),
                TranscriptWord(id: "two", text: "two.", start: 1, end: 2, confidence: nil),
            ],
            ebookText: nil,
            alignmentScore: nil
        )
        let second = TranscriptSegment(
            id: "second",
            start: 2,
            end: 4,
            words: [TranscriptWord(id: "three", text: "Three.", start: 2, end: 4, confidence: nil)],
            ebookText: nil,
            alignmentScore: nil
        )
        let state = AppState()
        state.transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/book.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: [first, second],
            source: "test",
            ebookAligned: false
        )
        state.player.currentTime = 1.5

        let position = state.currentReaderPosition

        #expect(position.segment?.id == "first")
        #expect(position.word?.id == "two")
    }

    @Test("Reader scroll targets are chapter-scoped and cross-chapter moves do not animate")
    func scopesReaderScrollTargetsToChapter() {
        let chapterThree = ReaderScrollTarget(chapterID: "chapter-3", segmentID: "segment-10")
        let chapterFour = ReaderScrollTarget(chapterID: "chapter-4", segmentID: "segment-1")

        #expect(chapterThree.segmentID(for: "chapter-3") == "segment-10")
        #expect(chapterThree.segmentID(for: "chapter-4") == nil)
        #expect(ReaderScrollTarget.shouldAnimate(from: chapterThree, to: chapterFour) == false)
        #expect(ReaderScrollTarget.shouldAnimate(
            from: chapterThree,
            to: ReaderScrollTarget(chapterID: "chapter-3", segmentID: "segment-11")
        ))
    }

    @MainActor
    @Test("Background jobs keep the book and chapter where the work started")
    func preservesBackgroundJobOrigin() throws {
        let state = AppState()
        state.transcriptionJobOrigin = BackgroundJobOrigin(
            bookTitle: "Origin Book",
            chapterTitle: "Origin Chapter"
        )
        state.isTranscribing = true
        state.transcriptionProgress = TranscriptionProgress(fraction: 0.4, message: "Analysing audio")
        state.chapterTranslationJobOrigin = BackgroundJobOrigin(
            bookTitle: "Translation Book",
            chapterTitle: "Translation Chapter"
        )
        state.isChapterAssistantWorking = true
        state.chapterTranslationProgress = LibraryScanProgress(
            stage: "Translating chapter",
            detail: "10 of 20 drafts ready",
            completed: 10,
            total: 20
        )

        let jobs = state.backgroundJobs

        #expect(jobs.count == 2)
        #expect(jobs[0].bookTitle == "Origin Book")
        #expect(jobs[0].chapterTitle == "Origin Chapter")
        #expect(jobs[0].fraction == 0.4)
        #expect(jobs[1].bookTitle == "Translation Book")
        #expect(jobs[1].chapterTitle == "Translation Chapter")
        #expect(jobs[1].fraction == 0.5)
    }

    @Test("Chapter translation checkpoints preserve restart state")
    func preservesChapterTranslationCheckpoint() throws {
        let checkpoint = ChapterTranslationCheckpoint(
            chapterID: "chapter-7",
            language: "zh-Hans",
            mode: .retranslateAll,
            nextSegmentIndex: 24,
            totalSentences: 60,
            status: .awaitingReview,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let decoded = try JSONDecoder.iso.decode(
            ChapterTranslationCheckpoint.self,
            from: JSONEncoder.iso.encode(checkpoint)
        )

        #expect(decoded == checkpoint)
        #expect(decoded.id == "chapter-7|zh-Hans")
        #expect(decoded.mode == .retranslateAll)
    }

    @MainActor
    @Test("Chapter translation stop is requested gracefully while the current block remains active")
    func requestsGracefulChapterTranslationStop() {
        let state = AppState()
        state.isChapterAssistantWorking = true
        state.chapterTranslationProgress = LibraryScanProgress(
            stage: "Translating chapter",
            detail: "5 of 20 drafts ready",
            completed: 5,
            total: 20
        )

        state.requestChapterTranslationStop()

        #expect(state.chapterTranslationStopRequested)
        #expect(state.isChapterAssistantWorking)
        #expect(state.chapterTranslationProgress?.detail == "Stop requested · finishing the current block")
    }

    @Test("Chapter drafts are accepted as one in-memory batch")
    func acceptsChapterDraftsAsBatch() {
        let decidedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let drafts = (0..<5_000).map { index in
            GlossEntry(
                id: "gloss-\(index)",
                kind: .sentence,
                language: "zh-Hans",
                source: "Sentence \(index)",
                context: nil,
                text: "Translation \(index)",
                status: .pending,
                model: "qwen3.7-flash",
                bookID: "book",
                bookTitle: "Book",
                chapterID: "chapter",
                chapterTitle: "Chapter",
                timestamp: Double(index),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                decidedAt: nil,
                replacedText: "Old translation",
                replacedModel: "old-model"
            )
        }

        let accepted = GlossBatch.accepting(drafts, at: decidedAt)

        #expect(accepted.count == drafts.count)
        #expect(accepted.allSatisfy { $0.status == .accepted })
        #expect(accepted.allSatisfy { $0.decidedAt == decidedAt })
        #expect(accepted.allSatisfy { $0.replacedText == nil && $0.replacedModel == nil })
    }

    @Test("Pending review scopes repeated sentences to the current book and chapter while recovering legacy IDs")
    func scopesPendingChapterSentenceTranslations() {
        let audioPath = "/var/mobile/Containers/Data/Application/CURRENT/Documents/ImportedBooks/Current Book/book.m4b"
        let chapter = Chapter(
            id: LibraryScanner.stableID("\(audioPath)#42.500"),
            index: 1,
            title: "Chapter One",
            audioPath: audioPath,
            duration: 120,
            startTime: 42.5
        )
        let book = Book(
            id: LibraryScanner.stableID(URL(fileURLWithPath: audioPath).deletingLastPathComponent().path),
            title: "Current Book",
            author: nil,
            folderPath: URL(fileURLWithPath: audioPath).deletingLastPathComponent().path,
            coverPath: nil,
            ebookPath: nil,
            chapters: [chapter]
        )
        let legacyBookID = LibraryScanner.legacyAbsolutePathID(for: book)
        let legacyChapterID = LibraryScanner.legacyAbsolutePathID(for: chapter)
        let otherAudioPath = "/var/mobile/Containers/Data/Application/CURRENT/Documents/ImportedBooks/Other Copy/book.m4b"
        let otherBookID = LibraryScanner.stableID(URL(fileURLWithPath: otherAudioPath).deletingLastPathComponent().path)
        let otherChapterID = LibraryScanner.stableID("\(otherAudioPath)#42.500")
        #expect(legacyBookID != book.id)
        #expect(legacyChapterID != chapter.id)
        #expect(otherBookID != book.id)
        #expect(otherChapterID != chapter.id)
        let current = GlossEntry(
            id: "current",
            kind: .sentence,
            language: "zh-Hans",
            source: "Current sentence.",
            context: nil,
            text: "当前句子。",
            status: .pending,
            model: "qwen3.8-max",
            bookID: book.id,
            bookTitle: book.title,
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            createdAt: Date()
        )
        var anotherPending = current
        anotherPending.id = "another"
        anotherPending.source = "Another sentence."
        var accepted = current
        accepted.id = "accepted"
        accepted.status = .accepted
        var otherChapter = current
        otherChapter.id = "other-chapter"
        otherChapter.chapterID = "chapter-2"
        otherChapter.source = "Other chapter sentence."
        var repeatedInOtherChapter = current
        repeatedInOtherChapter.id = "repeated-other-chapter"
        repeatedInOtherChapter.chapterID = "chapter-2"
        repeatedInOtherChapter.chapterTitle = "Chapter Two"
        var repeatedInOtherBook = current
        repeatedInOtherBook.id = "repeated-other-book"
        repeatedInOtherBook.bookID = otherBookID
        repeatedInOtherBook.chapterID = otherChapterID
        var otherLanguage = current
        otherLanguage.id = "other-language"
        otherLanguage.language = "ja"
        var legacyContainerChapter = current
        legacyContainerChapter.id = "legacy-container-chapter"
        legacyContainerChapter.bookID = legacyBookID
        legacyContainerChapter.chapterID = legacyChapterID
        legacyContainerChapter.source = "Legacy sentence."
        var pendingWord = current
        pendingWord.id = "word"
        pendingWord.kind = .word

        let pending = GlossBatch.pendingSentences(
            in: [current, anotherPending, accepted, otherChapter, repeatedInOtherChapter, repeatedInOtherBook, otherLanguage, legacyContainerChapter, pendingWord],
            bookID: book.id,
            legacyBookID: legacyBookID,
            chapterID: chapter.id,
            legacyChapterID: legacyChapterID,
            language: "zh-Hans",
            currentSentenceSources: ["Current sentence.", "Another sentence.", "Legacy sentence."]
        )

        #expect(pending.map(\.id) == ["current", "another", "legacy-container-chapter"])
    }

    @Test("Chapter gloss index resolves canonical and legacy sentence entries")
    func indexesChapterGlosses() throws {
        let canonical = GlossEntry(
            id: GlossEntry.makeID(kind: .sentence, language: "zh-Hans", source: "First sentence.", context: nil),
            kind: .sentence,
            language: "zh-Hans",
            source: "First sentence.",
            context: nil,
            text: "第一句。",
            status: .accepted,
            model: "qwen3.7-flash",
            chapterID: "chapter",
            createdAt: Date()
        )
        var legacy = canonical
        legacy.id = "legacy-id"
        legacy.source = "  SECOND   SENTENCE. "
        legacy.text = "第二句。"
        let index = ChapterGlossIndex(glosses: [canonical, legacy], language: "zh-Hans")

        #expect(index.gloss(source: "First sentence.")?.text == "第一句。")
        #expect(index.gloss(source: "Second sentence.")?.text == "第二句。")
        #expect(index.gloss(source: "Missing sentence.") == nil)
    }

    @Test("Chapter gloss index cache reuses one build until its inputs change")
    func cachesChapterGlossIndex() throws {
        let chinese = GlossEntry(
            id: GlossEntry.makeID(kind: .sentence, language: "zh-Hans", source: "First sentence.", context: nil),
            kind: .sentence,
            language: "zh-Hans",
            source: "First sentence.",
            context: nil,
            text: "第一句。",
            status: .accepted,
            model: "qwen3.7-flash",
            chapterID: "chapter",
            createdAt: Date()
        )
        var cache = ChapterGlossIndexCache()

        let first = cache.index(glosses: [chinese], generation: 0, language: "zh-Hans")
        for _ in 0..<100 {
            let reused = cache.index(glosses: [chinese], generation: 0, language: "zh-Hans")
            #expect(reused === first)
            #expect(reused.gloss(source: "First sentence.")?.text == "第一句。")
        }

        var updatedChinese = chinese
        updatedChinese.text = "更新的第一句。"
        let updated = cache.index(glosses: [updatedChinese], generation: 1, language: "zh-Hans")
        #expect(updated !== first)
        #expect(updated.gloss(source: "First sentence.")?.text == "更新的第一句。")

        var japanese = chinese
        japanese.id = GlossEntry.makeID(kind: .sentence, language: "ja", source: "First sentence.", context: nil)
        japanese.language = "ja"
        japanese.text = "最初の文。"
        let changedLanguage = cache.index(glosses: [updatedChinese, japanese], generation: 1, language: "ja")
        #expect(changedLanguage !== updated)
        #expect(changedLanguage.gloss(source: "First sentence.")?.text == "最初の文。")
    }

    @Test("Vocabulary preserves the translation model attribution")
    func preservesVocabularyTranslationModel() throws {
        let entry = VocabEntry(
            id: "entry",
            word: "example",
            translation: "示例",
            translationLanguage: "zh-Hans",
            translationModel: "deepseek-v4-flash-0731",
            context: "An example.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 0,
            addedAt: Date()
        )

        let decoded = try JSONDecoder.iso.decode(VocabEntry.self, from: JSONEncoder.iso.encode(entry))

        #expect(decoded.translationModel == "deepseek-v4-flash-0731")
    }

    @Test("macOS package and every Xcode configuration share the semantic version")
    func keepsAppVersionsSynchronized() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistData = try Data(contentsOf: repository.appendingPathComponent("Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        let iPadPlistData = try Data(contentsOf: repository.appendingPathComponent("Info-iPad.plist"))
        let iPadPlist = try #require(
            PropertyListSerialization.propertyList(from: iPadPlistData, format: nil) as? [String: Any]
        )
        let project = try String(
            contentsOf: repository.appendingPathComponent("AudioReader.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let xcodeMac = try String(
            contentsOf: repository.appendingPathComponent("Xcode/Info-macOS.plist"),
            encoding: .utf8
        )
        let xcodeIOS = try String(
            contentsOf: repository.appendingPathComponent("Xcode/Info-iOS.plist"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: repository.appendingPathComponent("Sources/AudioReader/AudioReaderApp.swift"),
            encoding: .utf8
        )

        #expect(plist["CFBundleShortVersionString"] as? String == "2.4.1")
        #expect(plist["CFBundleVersion"] as? String == "102")
        #expect(iPadPlist["CFBundleShortVersionString"] as? String == "2.4.1")
        #expect(iPadPlist["CFBundleVersion"] as? String == "102")
        #expect(project.components(separatedBy: "MARKETING_VERSION = 2.4.1;").count - 1 == 4)
        #expect(project.components(separatedBy: "CURRENT_PROJECT_VERSION = 102;").count - 1 == 4)
        #expect(plist["LSEnvironment"] == nil)
        #expect(iPadPlist["LSEnvironment"] == nil)
        #expect(plist["ProductAPIBaseURL"] as? String == ProductAPI.hostedProductionBaseURL.absoluteString)
        #expect(iPadPlist["ProductAPIBaseURL"] as? String == ProductAPI.hostedProductionBaseURL.absoluteString)
        #expect(xcodeMac.contains("ProductAPIBaseURL"))
        #expect(xcodeIOS.contains("ProductAPIBaseURL"))
        #expect(iPadPlist["UIBackgroundModes"] as? [String] == ["audio"])
        #expect(xcodeIOS.contains("UIBackgroundModes"))
        #expect(xcodeIOS.contains("audio"))
        let iPadDocumentTypes = try #require(iPadPlist["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(iPadDocumentTypes.contains { documentType in
            (documentType["LSItemContentTypes"] as? [String])?.contains("org.idpf.epub-container") == true
        })
        #expect(xcodeIOS.contains("org.idpf.epub-container"))
        #expect(appSource.contains(".onOpenURL"))
        #expect(appSource.contains("importExternalEPUB"))
        let macATS = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        let iPadATS = try #require(iPadPlist["NSAppTransportSecurity"] as? [String: Any])
        #expect(macATS["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(iPadATS["NSAllowsLocalNetworking"] as? Bool == true)
    }

    @Test("Xcode exposes Debug-only UI tests plus iOS companion behavior tests")
    func keepsDeterministicUITestTargets() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent("AudioReader.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let macTests = try String(
            contentsOf: repository.appendingPathComponent("UITests/AudioReaderMacOSUITests/AudioReaderMacOSUITests.swift"),
            encoding: .utf8
        )
        let iPadTests = try String(
            contentsOf: repository.appendingPathComponent("UITests/AudioReaderIOSUITests/AudioReaderIOSUITests.swift"),
            encoding: .utf8
        )
        let iPadCompanionTests = try String(
            contentsOf: repository.appendingPathComponent("Tests/AudioReaderIOSUnitTests/DeviceAudiobookCompanionTests.swift"),
            encoding: .utf8
        )

        #expect(project.contains("AudioReader-macOSUITests"))
        #expect(project.contains("AudioReader-iOSUITests"))
        #expect(project.contains("AudioReader-iOSUnitTests"))
        #expect(project.components(separatedBy: "TEST_TARGET_NAME =").count - 1 == 3)
        #expect(macTests.contains("--uitesting"))
        #expect(iPadTests.contains("--uitesting"))
        #expect(macTests.contains("--uitesting-reduce-motion"))
        #expect(iPadTests.contains("--uitesting-reduce-motion"))
        #expect(macTests.contains("Import Audio or EPUB"))
        #expect(iPadTests.contains("library.importMedia"))
        #expect(macTests.contains("transcript.restore"))
        #expect(iPadTests.contains("transcript.restore"))
        #expect(macTests.contains("words.actions"))
        #expect(iPadTests.contains("anki.export"))
        #expect(iPadCompanionTests.contains("library.addCompanion"))
        #expect(iPadCompanionTests.contains("M4BChapterExtractor.load"))
    }
}

private struct TemporaryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func directorySnapshot(_ folder: URL) throws -> [String: Data] {
    let files = try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    )
    return try Dictionary(uniqueKeysWithValues: files.compactMap { file in
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
        return (file.lastPathComponent, try Data(contentsOf: file))
    })
}

private func makeEPUB(
    in directory: URL,
    name: String,
    title: String,
    author: String?,
    sections: [(title: String, text: String)]
) throws -> URL {
    let source = directory.appendingPathComponent(".\(name)-epub-source", isDirectory: true)
    let meta = source.appendingPathComponent("META-INF", isDirectory: true)
    let content = source.appendingPathComponent("OEBPS", isDirectory: true)
    try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
    try Data("""
    <?xml version="1.0"?>
    <container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """.utf8).write(to: meta.appendingPathComponent("container.xml"))
    let manifest = sections.indices.map { index in
        "<item id=\"s\(index)\" href=\"s\(index).xhtml\" media-type=\"application/xhtml+xml\"/>"
    }.joined()
    let spine = sections.indices.map { "<itemref idref=\"s\($0)\"/>" }.joined()
    let creator = author.map { "<dc:creator>\($0)</dc:creator>" } ?? ""
    try Data("""
    <package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>\(title)</dc:title>\(creator)</metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
    """.utf8).write(to: content.appendingPathComponent("content.opf"))
    for (index, section) in sections.enumerated() {
        try Data("<html><body><h1>\(section.title)</h1><p>\(section.text)</p></body></html>".utf8)
            .write(to: content.appendingPathComponent("s\(index).xhtml"))
    }
    let epub = directory.appendingPathComponent("\(name).epub")
    try FileManager.default.zipItem(at: source, to: epub, shouldKeepParent: false, compressionMethod: .deflate)
    try FileManager.default.removeItem(at: source)
    return epub
}

private let navigationEPUBCoverData = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!

private func expandEPUB(_ archive: URL, in directory: URL) throws -> URL {
    let expanded = directory.appendingPathComponent(
        "0123456789ABCDEF0123456789ABCDEF.epub",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)
    try FileManager.default.unzipItem(at: archive, to: expanded)
    return expanded
}

private func makeNavigationEPUB(in directory: URL, usesNCX: Bool) throws -> URL {
    let source = directory.appendingPathComponent(".navigation-epub-source", isDirectory: true)
    let meta = source.appendingPathComponent("META-INF", isDirectory: true)
    let content = source.appendingPathComponent("OEBPS", isDirectory: true)
    try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
    try Data("""
    <?xml version="1.0"?>
    <container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """.utf8).write(to: meta.appendingPathComponent("container.xml"))

    let navigationManifest = usesNCX
        ? #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#
        : #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
    let spineTOC = usesNCX ? #" toc="ncx""# : ""
    let legacyCoverMetadata = usesNCX ? #"<meta name="cover" content="cover"/>"# : ""
    let coverProperties = usesNCX ? "" : #" properties="cover-image""#
    try Data("""
    <package xmlns:dc="http://purl.org/dc/elements/1.1/">
      <metadata>
        <dc:title>Navigation Book</dc:title>
        <dc:creator>Page Turner</dc:creator>
        \(legacyCoverMetadata)
      </metadata>
      <manifest>
        <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
        <item id="cover" href="images/cover.png" media-type="image/png"\(coverProperties)/>
        \(navigationManifest)
      </manifest>
      <spine\(spineTOC)><itemref idref="content"/></spine>
    </package>
    """.utf8).write(to: content.appendingPathComponent("content.opf"))

    try Data("""
    <html><body>
      <h1 id="part-one">Part One</h1><p>This opening passage introduces the setting with enough published words for a reader.</p>
      <h2 id="arrival">Arrival Heading</h2><p>The arrival chapter carries a lantern through the rain for careful language study.</p>
      <h2 id="crossing">Crossing Heading</h2><p>The crossing chapter raises the lantern beside the river and finishes the journey.</p>
    </body></html>
    """.utf8).write(to: content.appendingPathComponent("content.xhtml"))

    if usesNCX {
        try Data("""
        <ncx><navMap>
          <navPoint id="part"><navLabel><text>Part One</text></navLabel><content src="content.xhtml#part-one"/>
            <navPoint id="arrival"><navLabel><text>The Arrival</text></navLabel><content src="content.xhtml#arrival"/></navPoint>
            <navPoint id="crossing"><navLabel><text>The Crossing</text></navLabel><content src="content.xhtml#crossing"/></navPoint>
          </navPoint>
        </navMap></ncx>
        """.utf8).write(to: content.appendingPathComponent("toc.ncx"))
    } else {
        try Data("""
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="content.xhtml#part-one">Part One</a><ol>
              <li><a href="content.xhtml#arrival">The Arrival</a></li>
              <li><a href="content.xhtml#crossing">The Crossing</a></li>
            </ol></li>
          </ol></nav>
        </body></html>
        """.utf8).write(to: content.appendingPathComponent("nav.xhtml"))
    }

    let images = content.appendingPathComponent("images", isDirectory: true)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    try navigationEPUBCoverData.write(to: images.appendingPathComponent("cover.png"))
    let epub = directory.appendingPathComponent(usesNCX ? "Navigation EPUB 2.epub" : "Navigation EPUB 3.epub")
    try FileManager.default.zipItem(at: source, to: epub, shouldKeepParent: false, compressionMethod: .deflate)
    try FileManager.default.removeItem(at: source)
    return epub
}
