import Foundation
import Testing
import ZIPFoundation
@testable import AudioReader

@Suite("EPUB chapters and cover")
struct EPUBStructureTests {
    @Test("NCX table of contents becomes titled chapters and a cover page")
    func splitsChaptersFromNCXAndCover() throws {
        let fixture = try StructureFixture()
        defer { fixture.remove() }
        let epub = try fixture.makeNCXBook()

        let structure = try #require(EPUBParser.structure(from: epub.path))

        #expect(structure.title == "Thinking in Layers")
        #expect(structure.author == "Dana Meadow")
        #expect(structure.cover?.fileExtension == "png")
        #expect(structure.cover?.data == StructureFixture.png1x1)
        #expect(structure.chapters.map(\.title) == [
            "Cover",
            "Title Page",
            "Copyright Page",
            "One. The Basics",
            "Two. A Brief Visit",
            "Appendix",
            "Glossary",
            "Notes"
        ])
        #expect(structure.chapters.first?.isCover == true)
        #expect(structure.chapters.first?.locator == EPUBParser.coverLocator)

        let basics = try #require(structure.chapters.first { $0.title == "One. The Basics" })
        #expect(basics.text.contains("stocks and flows"))
        #expect(!basics.text.contains("copyright notice"))
        #expect(!basics.text.contains("glossary definition"))

        let appendix = try #require(structure.chapters.first { $0.title == "Appendix" })
        #expect(appendix.text.contains("appendix overview"))
        #expect(!appendix.text.contains("glossary definition"))

        let glossary = try #require(structure.chapters.first { $0.title == "Glossary" })
        #expect(glossary.text.contains("glossary definition"))
        #expect(!glossary.text.contains("source notes remain"))

        let notes = try #require(structure.chapters.first { $0.title == "Notes" })
        #expect(notes.text.contains("source notes remain"))
        #expect(!notes.text.contains("glossary definition"))
    }

    @Test("EPUB3 nav documents split chapters when NCX is absent")
    func splitsChaptersFromEPUB3Nav() throws {
        let fixture = try StructureFixture()
        defer { fixture.remove() }
        let epub = try fixture.makeNavBook()

        let structure = try #require(EPUBParser.structure(from: epub.path))

        #expect(structure.chapters.map(\.title) == [
            "Cover",
            "Introduction: Life by Design",
            "1. Start Where You Are"
        ])
        let introduction = try #require(structure.chapters.first { $0.title.hasPrefix("Introduction") })
        #expect(introduction.text.contains("design thinking"))
        #expect(!introduction.text.contains("Start Where You Are chapter body"))
        let start = try #require(structure.chapters.first { $0.title.hasPrefix("1.") })
        #expect(start.text.contains("Start Where You Are chapter body"))
        #expect(!start.text.contains("design thinking"))
    }

    @Test("Cover image is found from OPF cover metadata")
    func extractsCoverFromPackageMetadata() throws {
        let fixture = try StructureFixture()
        defer { fixture.remove() }
        let epub = try fixture.makeNCXBook()

        let cover = try #require(EPUBParser.coverImage(from: epub.path))

        #expect(cover.fileExtension == "png")
        #expect(cover.data == StructureFixture.png1x1)
    }

    @Test("Exploded Apple Books packages expose the same chapters and cover")
    func readsExplodedPackageStructure() throws {
        let fixture = try StructureFixture()
        defer { fixture.remove() }
        let package = try fixture.makeNCXBook(exploded: true)

        #expect(EPUBParser.isPackage(at: package))
        let structure = try #require(EPUBParser.structure(from: package.path))
        #expect(structure.chapters.contains { $0.isCover })
        #expect(structure.chapters.contains { $0.title == "One. The Basics" })
        #expect(EPUBParser.coverImage(from: package.path)?.data == StructureFixture.png1x1)
    }

    @Test("A chapter transcript uses only that chapter's EPUB text")
    func buildsPerChapterEbookTranscript() throws {
        let fixture = try StructureFixture()
        defer { fixture.remove() }
        let epub = try fixture.makeNCXBook()
        let structure = try #require(EPUBParser.structure(from: epub.path))
        let basics = try #require(structure.chapters.first { $0.title == "One. The Basics" })
        let chapter = Chapter(
            id: "basics",
            index: 3,
            title: basics.title,
            audioPath: "",
            ebookLocator: basics.locator
        )
        let book = Book(
            id: "book",
            title: "Thinking in Layers",
            author: "Dana Meadow",
            folderPath: "/tmp",
            coverPath: nil,
            ebookPath: epub.path,
            chapters: [chapter]
        )

        let transcript = try #require(Transcript.makeFromEbook(chapter: chapter, book: book, text: basics.text))

        #expect(transcript.segments.contains { $0.displayText.contains("stocks and flows") })
        #expect(!transcript.segments.contains { $0.displayText.contains("copyright notice") })
        #expect(Transcript.makeFromEbook(
            chapter: Chapter(
                id: "cover",
                index: 0,
                title: "Cover",
                audioPath: "",
                ebookLocator: EPUBParser.coverLocator
            ),
            book: book,
            text: ""
        ) == nil)
    }

    @Test("Ebook-only library scan uses TOC chapters and stores the cover")
    func scansEbookOnlyBookIntoTOCChapters() throws {
        let fixture = try StructureFixture()
        defer { fixture.remove() }
        let library = fixture.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let epub = try fixture.makeNCXBook()

        try AudiobookImportService.importFiles([epub], into: library)
        let book = try #require(LibraryScanner.scan(root: library).first)

        #expect(book.hasAudio == false)
        #expect(book.chapters.map(\.title) == [
            "Cover",
            "Title Page",
            "Copyright Page",
            "One. The Basics",
            "Two. A Brief Visit",
            "Appendix",
            "Glossary",
            "Notes"
        ])
        #expect(book.chapters.first?.isCover == true)
        #expect(book.coverPath?.hasSuffix("cover.png") == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(book.coverPath))) == StructureFixture.png1x1)

        let basics = try #require(book.chapters.first { $0.title == "One. The Basics" })
        let structure = try #require(EPUBParser.structure(from: book.ebookPath ?? ""))
        let chapterText = try #require(structure.chapters.first { $0.locator == basics.ebookLocator }).text
        let transcript = try #require(Transcript.makeFromEbook(chapter: basics, book: book, text: chapterText))
        #expect(transcript.segments.contains { $0.displayText.contains("stocks and flows") })
        #expect(!transcript.segments.contains { $0.displayText.contains("A brief visit to the systems zoo") })
    }

    @Test("Cover chapters count as ready without a transcript")
    func treatsCoverAsReady() {
        let cover = Chapter(
            id: "cover-id",
            index: 0,
            title: "Cover",
            audioPath: "",
            ebookLocator: EPUBParser.coverLocator
        )
        let text = Chapter(
            id: "text-id",
            index: 1,
            title: "One. The Basics",
            audioPath: "",
            ebookLocator: "chapter1.xhtml"
        )
        let book = Book(
            id: "book",
            title: "Book",
            author: nil,
            folderPath: "/tmp",
            coverPath: nil,
            ebookPath: "/tmp/book.epub",
            chapters: [cover, text]
        )

        let ready = Persistence.readyChapterIDs(in: [book], transcripts: [])

        #expect(ready.contains("cover-id"))
        #expect(!ready.contains("text-id"))
    }
}

private struct StructureFixture {
    static let png1x1 = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderEPUBStructure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeNCXBook(exploded: Bool = false) throws -> URL {
        let source = root.appendingPathComponent("ncx-\(UUID().uuidString)", isDirectory: true)
        let meta = source.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = source.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile media-type="application/oebps-package+xml" full-path="OEBPS/content.opf"/>
          </rootfiles>
        </container>
        """.utf8).write(to: meta.appendingPathComponent("container.xml"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Thinking in Layers</dc:title>
            <dc:creator>Dana Meadow</dc:creator>
            <dc:identifier id="bookid">urn:uuid:structure-ncx</dc:identifier>
            <meta name="cover" content="cover-image"/>
          </metadata>
          <manifest>
            <item id="cover-image" href="cover.png" media-type="image/png"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="title" href="titlepage.xhtml" media-type="application/xhtml+xml"/>
            <item id="copy" href="copyright.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
            <item id="app" href="appendix.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="title"/>
            <itemref idref="copy"/>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
            <itemref idref="app"/>
          </spine>
        </package>
        """.utf8).write(to: oebps.appendingPathComponent("content.opf"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1" playOrder="1">
              <navLabel><text>Title Page</text></navLabel>
              <content src="titlepage.xhtml"/>
            </navPoint>
            <navPoint id="n2" playOrder="2">
              <navLabel><text>Copyright Page</text></navLabel>
              <content src="copyright.xhtml"/>
            </navPoint>
            <navPoint id="n3" playOrder="3">
              <navLabel><text>One. The Basics</text></navLabel>
              <content src="chapter1.xhtml"/>
            </navPoint>
            <navPoint id="n4" playOrder="4">
              <navLabel><text>Two. A Brief Visit</text></navLabel>
              <content src="chapter2.xhtml"/>
            </navPoint>
            <navPoint id="n5" playOrder="5">
              <navLabel><text>Appendix</text></navLabel>
              <content src="appendix.xhtml"/>
              <navPoint id="n6" playOrder="6">
                <navLabel><text>Glossary</text></navLabel>
                <content src="appendix.xhtml#glossary"/>
              </navPoint>
              <navPoint id="n7" playOrder="7">
                <navLabel><text>Notes</text></navLabel>
                <content src="appendix.xhtml#notes"/>
              </navPoint>
            </navPoint>
          </navMap>
        </ncx>
        """.utf8).write(to: oebps.appendingPathComponent("toc.ncx"))
        try StructureFixture.png1x1.write(to: oebps.appendingPathComponent("cover.png"))
        try Data("""
        <html><body><div><svg><image href="cover.png"/></svg></div></body></html>
        """.utf8).write(to: oebps.appendingPathComponent("titlepage.xhtml"))
        try Data("""
        <html><body><p>This copyright notice belongs only to the copyright page and should not leak into later chapters.</p></body></html>
        """.utf8).write(to: oebps.appendingPathComponent("copyright.xhtml"))
        try Data("""
        <html><body><p>The basics of stocks and flows explain how a system remembers its history over time.</p></body></html>
        """.utf8).write(to: oebps.appendingPathComponent("chapter1.xhtml"))
        try Data("""
        <html><body><p>A brief visit to the systems zoo introduces reinforcing loops with enough words for a chapter.</p></body></html>
        """.utf8).write(to: oebps.appendingPathComponent("chapter2.xhtml"))
        try Data("""
        <html><body>
          <p>This appendix overview belongs to the parent appendix chapter before the nested entries.</p>
          <h1 id="glossary">Glossary</h1>
          <p>A glossary definition describes stocks as accumulations with enough words for a chapter.</p>
          <h1 id="notes">Notes</h1>
          <p>These source notes remain in the notes chapter and should not appear in the glossary.</p>
        </body></html>
        """.utf8).write(to: oebps.appendingPathComponent("appendix.xhtml"))

        if exploded {
            let package = root.appendingPathComponent("ExplodedLayers.epub", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: package)
            return package
        }
        let epub = root.appendingPathComponent("Thinking in Layers.epub")
        try FileManager.default.zipItem(at: source, to: epub, shouldKeepParent: false, compressionMethod: .deflate)
        return epub
    }

    func makeNavBook() throws -> URL {
        let source = root.appendingPathComponent("nav-\(UUID().uuidString)", isDirectory: true)
        let meta = source.appendingPathComponent("META-INF", isDirectory: true)
        let epubDir = source.appendingPathComponent("EPUB", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: epubDir, withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile media-type="application/oebps-package+xml" full-path="EPUB/content.opf"/>
          </rootfiles>
        </container>
        """.utf8).write(to: meta.appendingPathComponent("container.xml"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Designing a Path</dc:title>
            <dc:creator>Bill Designer</dc:creator>
            <meta name="cover" content="cover-image"/>
          </metadata>
          <manifest>
            <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="body" href="text00000.html" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="body"/>
          </spine>
        </package>
        """.utf8).write(to: epubDir.appendingPathComponent("content.opf"))
        try Data("""
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body>
            <nav epub:type="toc">
              <ol>
                <li><a href="text00000.html#filepos0000007519">Introduction: Life by Design</a></li>
                <li><a href="text00000.html#filepos0000052444">1. Start Where You Are</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """.utf8).write(to: epubDir.appendingPathComponent("nav.xhtml"))
        try Data("""
        <html><body>
          <span id="filepos0000007519"/>
          <p>Introduction to design thinking with enough meaningful words to keep this chapter distinct.</p>
          <span id="filepos0000052444"/>
          <p>Start Where You Are chapter body stays in the second chapter and should not appear earlier.</p>
        </body></html>
        """.utf8).write(to: epubDir.appendingPathComponent("text00000.html"))
        try StructureFixture.png1x1.write(to: epubDir.appendingPathComponent("cover.png"))
        let epub = root.appendingPathComponent("Designing a Path.epub")
        try FileManager.default.zipItem(at: source, to: epub, shouldKeepParent: false, compressionMethod: .deflate)
        return epub
    }
}
