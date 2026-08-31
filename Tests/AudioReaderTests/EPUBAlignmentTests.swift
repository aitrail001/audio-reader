import Foundation
import Testing
import ZIPFoundation
@testable import AudioReader

@Suite("EPUB document validation and trusted alignment")
struct EPUBAlignmentTests {
    @MainActor
    @Test("Missing EPUB state requires a selected book without a companion ebook")
    func identifiesMissingEbook() {
        let state = AppState()
        #expect(!state.currentBookIsMissingEbook)

        state.books = [Book(
            id: "missing-ebook-book",
            title: "Book Without EPUB",
            author: nil,
            folderPath: "/tmp/book-without-epub",
            coverPath: nil,
            ebookPath: nil,
            chapters: []
        )]
        state.selectedBookID = "missing-ebook-book"
        #expect(state.currentBookIsMissingEbook)

        state.books[0].ebookPath = "/tmp/book-with-epub.epub"
        #expect(!state.currentBookIsMissingEbook)
    }

    @Test("An isolated layout move does not reject an otherwise ordered edition")
    func toleratesIsolatedLayoutMove() {
        let spokenOrder = [1, 2, 3, 4, 0, 5, 6, 7].map { Self.bookSentences[$0] }
        let result = Aligner.align(
            segments: spokenOrder.map(Self.segment),
            document: EPUBDocument(
                text: Self.bookSentences.joined(separator: " "),
                title: "The Lantern Atlas",
                author: "Morgan Vale"
            ),
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.metrics.backwardJumps == 1)
        #expect(result.assessment.status == .trusted)
        #expect(result.segments.allSatisfy { $0.trustedEbookText != nil })
    }

    @Test("CJK text is segmented and aligned without space-delimited words")
    func alignsChineseText() {
        let sentences = [
            "系统中的反馈回路会随着时间改变整体行为。",
            "库存记录了流入和流出长期累积产生的结果。",
            "延迟会让决策者误判现在采取行动造成的影响。",
            "边界取决于我们提出的问题以及观察采用的尺度。",
            "信息流能够改变规则并重新塑造参与者的选择。",
            "增长受到资源限制时通常不会永远保持指数速度。",
            "韧性来自多样性冗余以及适应意外变化的能力。",
            "理解结构可以帮助读者找到更有效的干预位置。",
        ]
        let document = EPUBDocument(text: sentences.joined(), title: "系统思考", author: "作者")

        let result = Aligner.align(
            segments: sentences.map(Self.segment),
            document: document,
            expectedMetadata: .init(title: "系统思考", author: "作者")
        )

        #expect(EPUBParser.sentences(from: document.text).count == sentences.count)
        #expect(Aligner.tokenize(sentences[0]).count > 4)
        #expect(result.assessment.status == .trusted)
        #expect(result.segments.allSatisfy { $0.trustedEbookText != nil })
    }

    @Test("A correct EPUB becomes trusted only from document-level evidence")
    func trustsCompatibleDocument() throws {
        let spoken = Self.bookSentences.map(Self.segment)
        let document = EPUBDocument(
            text: Self.bookSentences.joined(separator: " "),
            title: "The Lantern Atlas",
            author: "Morgan Vale"
        )

        let result = Aligner.align(
            segments: spoken,
            document: document,
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.status == .trusted)
        #expect(result.assessment.metrics.matchedCoverage >= 0.75)
        #expect(result.segments.allSatisfy { $0.trustedEbookText != nil })
    }

    @Test("Content anchors can trust a compatible EPUB without title or author metadata")
    func trustsMetadataFreeCompatibleDocument() {
        let result = Aligner.align(
            segments: Self.bookSentences.map(Self.segment),
            document: EPUBDocument(text: Self.bookSentences.joined(separator: " "), title: nil, author: nil),
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.status == .trusted)
        #expect(result.assessment.metrics.titleSimilarity == nil)
        #expect(result.assessment.metrics.authorSimilarity == nil)
    }

    @Test("A corrupt or text-poor EPUB is unprocessable")
    func rejectsUnprocessableDocuments() {
        let spoken = Self.bookSentences.map(Self.segment)

        let corrupt = Aligner.align(
            segments: spoken,
            document: nil,
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )
        let textPoor = Aligner.align(
            segments: spoken,
            document: EPUBDocument(text: "Only a cover and copyright notice.", title: nil, author: nil),
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(corrupt.assessment.status == .unprocessable)
        #expect(textPoor.assessment.status == .unprocessable)
        #expect(textPoor.segments.allSatisfy { $0.ebookText == nil })
    }

    @Test("Parser rejects corrupt archives and exposes text-poor archives for quality assessment")
    func parserFeedsUnprocessableAssessment() throws {
        let fixture = try AlignmentFixture()
        defer { fixture.remove() }
        let corrupt = fixture.root.appendingPathComponent("corrupt.epub")
        try Data("not a zip archive".utf8).write(to: corrupt)
        #expect(EPUBParser.document(from: corrupt.path) == nil)

        let source = fixture.root.appendingPathComponent("poor-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let shortHTML = "<html><body><p>A short preview names a few characters but contains far too little book content for safe alignment.</p></body></html>"
        try Data(shortHTML.utf8).write(to: source.appendingPathComponent("preview.xhtml"))
        let poorEPUB = fixture.root.appendingPathComponent("poor.epub")
        try FileManager.default.zipItem(at: source, to: poorEPUB, shouldKeepParent: false, compressionMethod: .deflate)
        let parsed = try #require(EPUBParser.document(from: poorEPUB.path))

        let result = Aligner.align(
            segments: Self.bookSentences.map(Self.segment),
            document: parsed,
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )
        #expect(result.assessment.status == .unprocessable)
    }

    @Test("Parser extracts EPUB package title and author metadata")
    func extractsPackageMetadata() throws {
        let fixture = try AlignmentFixture()
        defer { fixture.remove() }
        let epub = try fixture.makeEPUB(
            named: "metadata.epub",
            in: fixture.root,
            text: Self.bookSentences.joined(separator: " "),
            title: "The Lantern Atlas",
            author: "Morgan Vale"
        )

        let parsed = try #require(EPUBParser.document(from: epub.path))

        #expect(parsed.title == "The Lantern Atlas")
        #expect(parsed.author == "Morgan Vale")
    }

    @Test("Replacing an EPUB validates the new file before removing the old one")
    func safelyReplacesEbook() throws {
        let fixture = try AlignmentFixture()
        defer { fixture.remove() }
        let book = fixture.root.appendingPathComponent("book", isDirectory: true)
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let old = book.appendingPathComponent("old.epub")
        try Data("old archive".utf8).write(to: old)
        let corrupt = incoming.appendingPathComponent("corrupt.epub")
        try Data("not an epub".utf8).write(to: corrupt)

        #expect(throws: AudiobookImportError.self) {
            try AudiobookImportService.replaceEbook(corrupt, in: book)
        }
        #expect(FileManager.default.fileExists(atPath: old.path))

        let replacement = try fixture.makeEPUB(
            named: "replacement.epub",
            in: incoming,
            text: Self.bookSentences.joined(separator: " ")
        )
        let installed = try AudiobookImportService.replaceEbook(replacement, in: book)

        #expect(installed.lastPathComponent == "replacement.epub")
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @MainActor
    @Test("Replacing an EPUB invalidates persisted text from the previous document")
    func replacementInvalidatesOldAlignment() throws {
        let fixture = try AlignmentFixture()
        defer { fixture.remove() }
        let bookFolder = fixture.root.appendingPathComponent("book", isDirectory: true)
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let old = try fixture.makeEPUB(
            named: "old.epub",
            in: bookFolder,
            text: Self.bookSentences.joined(separator: " ")
        )
        let replacement = try fixture.makeEPUB(
            named: "replacement.epub",
            in: incoming,
            text: Self.bookSentences.reversed().joined(separator: " ")
        )
        let chapterID = "replacement-\(UUID().uuidString)"
        let chapter = Chapter(
            id: chapterID,
            index: 0,
            title: "Chapter",
            audioPath: bookFolder.appendingPathComponent("chapter.m4b").path
        )
        var segment = Self.segment(Self.bookSentences[0])
        segment.ebookText = Self.bookSentences[0]
        segment.alignmentScore = 1
        segment.individualEbookMatchTrusted = true
        segment.documentEbookUseAllowed = true
        let saved = Transcript(
            chapterID: chapterID,
            audioPath: chapter.audioPath,
            createdAt: Date(),
            locale: "en-US",
            segments: [segment],
            source: "test",
            ebookAligned: true,
            ebookAlignment: .init(status: .trusted, reason: "test", metrics: .empty)
        )
        let book = Book(
            id: "book-\(UUID().uuidString)",
            title: "Book",
            author: nil,
            folderPath: bookFolder.path,
            coverPath: nil,
            ebookPath: old.path,
            chapters: [chapter]
        )
        try Persistence.store.saveBook(StoredBook(book))
        try Persistence.saveTranscript(saved)
        let state = AppState()
        state.books = [book]
        state.selectedBookID = state.books[0].id
        state.selectedChapterID = chapterID
        state.transcript = saved

        try state.replaceCurrentEbook(with: replacement)

        let reloaded = try #require(Persistence.loadTranscript(for: chapter))
        #expect(reloaded.ebookAligned == false)
        #expect(reloaded.alignmentStatus == .uncertain)
        #expect(reloaded.segments[0].ebookText == nil)
        #expect(reloaded.segments[0].displayText == reloaded.segments[0].spokenText)
    }

    @MainActor
    @Test("A failed EPUB install keeps the old EPUB and trusted transcript together")
    func failedReplacementPreservesOldEbookAndTranscript() throws {
        let fixture = try AlignmentFixture()
        defer { fixture.remove() }
        let bookFolder = fixture.root.appendingPathComponent("book", isDirectory: true)
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let old = try fixture.makeEPUB(
            named: "old.epub",
            in: bookFolder,
            text: Self.bookSentences.joined(separator: " ")
        )
        let oldBytes = try Data(contentsOf: old)
        let replacement = try fixture.makeEPUB(
            named: "blocked.epub",
            in: incoming,
            text: Self.bookSentences.joined(separator: " ")
        )
        try FileManager.default.createDirectory(
            at: bookFolder.appendingPathComponent("blocked.epub", isDirectory: true),
            withIntermediateDirectories: true
        )
        let chapterID = "failed-replacement-\(UUID().uuidString)"
        let chapter = Chapter(
            id: chapterID,
            index: 0,
            title: "Chapter",
            audioPath: bookFolder.appendingPathComponent("chapter.m4b").path
        )
        var segment = Self.segment(Self.bookSentences[0])
        segment.ebookText = Self.bookSentences[0]
        segment.alignmentScore = 1
        segment.individualEbookMatchTrusted = true
        segment.documentEbookUseAllowed = true
        let saved = Transcript(
            chapterID: chapterID,
            audioPath: chapter.audioPath,
            createdAt: Date(),
            locale: "en-US",
            segments: [segment],
            source: "test",
            ebookAligned: true,
            ebookAlignment: .init(status: .trusted, reason: "test", metrics: .empty)
        )
        let book = Book(
            id: "book-\(UUID().uuidString)",
            title: "Book",
            author: nil,
            folderPath: bookFolder.path,
            coverPath: nil,
            ebookPath: old.path,
            chapters: [chapter]
        )
        try Persistence.store.saveBook(StoredBook(book))
        try Persistence.saveTranscript(saved)
        let persistedTranscriptBefore = try JSONEncoder.iso.encode(
            #require(Persistence.loadTranscript(chapterID: chapterID))
        )
        let state = AppState()
        state.books = [book]
        state.selectedBookID = state.books[0].id
        state.selectedChapterID = chapterID
        state.transcript = saved

        var didThrow = false
        do {
            try state.replaceCurrentEbook(with: replacement)
        } catch {
            didThrow = true
        }

        let reloaded = try #require(Persistence.loadTranscript(for: chapter))
        #expect(didThrow)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(try Data(contentsOf: old) == oldBytes)
        #expect(try JSONEncoder.iso.encode(
            #require(Persistence.loadTranscript(chapterID: chapterID))
        ) == persistedTranscriptBefore)
        #expect(state.books[0].ebookPath == old.path)
        #expect(reloaded.ebookAligned)
        #expect(reloaded.alignmentStatus == .trusted)
        #expect(reloaded.segments[0].trustedEbookText == Self.bookSentences[0])
    }

    @Test("An unrelated EPUB is rejected before per-segment full-book scans")
    func rejectsWrongBookDuringPreflight() {
        let spoken = Self.bookSentences.map(Self.segment)
        let unrelated = [
            "Gardeners loosen compacted soil before planting delicate spring bulbs near the eastern fence.",
            "A balanced compost mixture feeds young roots while preserving moisture through the hottest afternoons.",
            "Pruning crossed branches improves airflow and gives orchard trees a stronger shape for winter.",
            "Native flowers provide pollen for insects and tolerate long dry periods without constant watering.",
            "The greenhouse vents open automatically when midday temperatures rise above the safe growing range.",
            "Seed packets should be labelled with planting dates so every tray can be monitored accurately.",
            "Rain barrels reduce demand on town water while supplying vegetables during brief summer droughts.",
            Self.bookSentences[3],
        ]
        let document = EPUBDocument(
            text: unrelated.joined(separator: " "),
            title: "Practical Garden Seasons",
            author: "Robin Field"
        )

        let result = Aligner.align(
            segments: spoken,
            document: document,
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.status == .wrongBookLikely)
        #expect(result.assessment.metrics.detailedAlignmentPerformed == false)
        #expect(result.segments.allSatisfy { $0.ebookText == nil })
    }

    @Test("One incidental sentence match cannot trust a transcript")
    func oneMatchDoesNotTrust() {
        let one = [Self.segment(Self.bookSentences[0])]
        let document = EPUBDocument(
            text: Self.bookSentences.joined(separator: " "),
            title: "The Lantern Atlas",
            author: "Morgan Vale"
        )

        let result = Aligner.align(
            segments: one,
            document: document,
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.status != .trusted)
        #expect(result.segments[0].ebookText != nil)
        #expect(result.segments[0].trustedEbookText == nil)
        #expect(result.segments[0].displayText == result.segments[0].spokenText)
    }

    @Test("A partial edition retains verified candidates without replacing speech")
    func retainsPartialEditionMatchesSafely() {
        var partial = Array(Self.bookSentences.prefix(4))
        partial.append(contentsOf: [
            "An appendix describes archival paper, binding thread, and restoration tools used by conservators.",
            "The publisher also includes an interview about maps, memory, and the design of fictional cities.",
            "Reading group questions invite discussion of trust, inheritance, migration, and chosen family.",
            "A final chronology lists historic voyages that inspired several locations in the revised edition.",
        ])
        let result = Aligner.align(
            segments: Self.bookSentences.map(Self.segment),
            document: EPUBDocument(
                text: partial.joined(separator: " "),
                title: "The Lantern Atlas",
                author: "Morgan Vale"
            ),
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.status == .differentEdition)
        #expect(result.segments.contains { $0.ebookText != nil })
        #expect(result.segments.allSatisfy { $0.trustedEbookText == nil })

        var transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/book.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: result.segments,
            source: "test",
            ebookAligned: false,
            ebookAlignment: result.assessment
        )
        transcript.allowEbookTextAnyway()

        let matched = transcript.segments.filter { $0.ebookText != nil }
        let unmatched = transcript.segments.filter { $0.ebookText == nil }
        #expect(matched.allSatisfy { $0.trustedEbookText != nil })
        #expect(unmatched.allSatisfy { $0.displayText == $0.spokenText })
    }

    @Test("Reordered matching text is not trusted")
    func rejectsReorderedEdition() {
        let reordered = [
            Self.bookSentences[0], Self.bookSentences[4], Self.bookSentences[2], Self.bookSentences[6],
            Self.bookSentences[1], Self.bookSentences[7], Self.bookSentences[3], Self.bookSentences[5],
        ]
        let result = Aligner.align(
            segments: Self.bookSentences.map(Self.segment),
            document: EPUBDocument(text: reordered.joined(separator: " "), title: "The Lantern Atlas", author: "Morgan Vale"),
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.status == .uncertain)
        #expect(result.assessment.metrics.backwardJumps > 0)
        #expect(result.segments.allSatisfy { $0.trustedEbookText == nil })
    }

    @Test("Sentence-boundary differences can still produce trusted ordered passages")
    func handlesSentenceBoundaryMismatch() {
        let pairs = stride(from: 0, to: Self.bookSentences.count, by: 2).map {
            "\(Self.bookSentences[$0]) \(Self.bookSentences[$0 + 1])"
        }
        let result = Aligner.align(
            segments: pairs.map(Self.segment),
            document: EPUBDocument(
                text: Self.bookSentences.joined(separator: " "),
                title: "The Lantern Atlas",
                author: "Morgan Vale"
            ),
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.status == .trusted)
        #expect(result.segments.allSatisfy { $0.trustedEbookText != nil })
    }

    @Test("Adjacent split speech can validate a merged EPUB sentence without duplicating its text")
    func handlesSplitSpokenSentence() {
        let splitSpeech = Self.bookSentences.flatMap { sentence -> [TranscriptSegment] in
            let words = sentence.split(separator: " ")
            let midpoint = words.count / 2
            return [
                Self.segment(words[..<midpoint].joined(separator: " ")),
                Self.segment(words[midpoint...].joined(separator: " ")),
            ]
        }
        let result = Aligner.align(
            segments: splitSpeech,
            document: EPUBDocument(
                text: Self.bookSentences.joined(separator: " "),
                title: "The Lantern Atlas",
                author: "Morgan Vale"
            ),
            expectedMetadata: .init(title: "The Lantern Atlas", author: "Morgan Vale")
        )

        #expect(result.assessment.status == .trusted)
        #expect(result.assessment.metrics.matchedCoverage >= 0.70)
        #expect(result.segments.allSatisfy { $0.ebookText == nil })
        #expect(result.segments.allSatisfy { $0.displayText == $0.spokenText })
    }

    @Test("Legacy persisted matches decode fail-closed")
    func legacyTranscriptFailsClosed() throws {
        let segment = Self.segment("Legacy spoken wording stays authoritative for old transcript data.")
        let legacy: [String: Any] = [
            "chapterID": "legacy",
            "audioPath": "/tmp/legacy.m4b",
            "createdAt": "1970-01-01T00:00:00Z",
            "locale": "en-US",
            "segments": [[
                "id": segment.id,
                "start": segment.start,
                "end": segment.end,
                "words": segment.words.map {
                    ["id": $0.id, "text": $0.text, "start": $0.start, "end": $0.end]
                },
                "ebookText": "Untrusted legacy EPUB wording.",
                "alignmentScore": 0.99,
            ]],
            "source": "legacy",
            "ebookAligned": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder.iso.decode(Transcript.self, from: data)

        #expect(decoded.alignmentStatus == .uncertain)
        #expect(decoded.ebookAligned == false)
        #expect(decoded.segments[0].trustedEbookText == nil)
        #expect(decoded.segments[0].displayText == decoded.segments[0].spokenText)
    }

    @MainActor
    @Test("Untrusted raw EPUB text is excluded from vocabulary persistence")
    func excludesUntrustedEbookFromVocabulary() throws {
        var segment = Self.segment("Spoken context remains the only safe persisted source here.")
        segment.ebookText = "Untrusted ebook content must never be saved."
        segment.alignmentScore = 0.99
        segment.individualEbookMatchTrusted = true
        segment.documentEbookUseAllowed = false
        let chapter = Chapter(id: "chapter", index: 0, title: "One", audioPath: "/tmp/book.m4b")
        let state = AppState(composition: .inMemory())
        state.books = [Book(
            id: "book", title: "Book", author: nil, folderPath: "/tmp", coverPath: nil,
            ebookPath: "/tmp/book.epub", chapters: [chapter]
        )]
        state.selectedBookID = "book"
        state.selectedChapterID = "chapter"
        state.vocab = []

        state.addVocab(word: try #require(segment.words.first), segment: segment)

        let saved = try #require(state.vocab.first { $0.word.caseInsensitiveCompare("Spoken") == .orderedSame })
        #expect(saved.context == segment.spokenText)
        #expect(saved.ebookText == nil)
    }

    @MainActor
    @Test("Use Anyway is unavailable until the current EPUB has a transcript assessment")
    func gatesUseAnywayOnAssessment() {
        let state = AppState()
        state.books = [Book(
            id: "book", title: "Book", author: nil, folderPath: "/tmp", coverPath: nil,
            ebookPath: "/tmp/book.epub", chapters: []
        )]
        state.selectedBookID = "book"

        #expect(state.currentEbookAlignment != nil)
        #expect(state.canUseCurrentEbookAnyway == false)

        state.transcript = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/book.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: [Self.segment(Self.bookSentences[0])],
            source: "test",
            ebookAligned: false,
            ebookAlignment: .init(
                status: .wrongBookLikely,
                reason: "Preflight mismatch",
                metrics: .empty
            )
        )

        #expect(state.canUseCurrentEbookAnyway)
    }

    private static let bookSentences = [
        "At dawn the cartographer unfolded a weathered chart beside the quiet northern window.",
        "Silver ink marked a hidden crossing where the river disappeared beneath ancient stone arches.",
        "Mara copied every symbol carefully while her brother counted the bells from the harbour tower.",
        "Their grandmother had warned them that the eastern road changed whenever winter storms arrived.",
        "By noon they reached a cedar bridge guarded by two statues with polished amber eyes.",
        "A ferryman accepted the brass compass and promised to return it after the final crossing.",
        "Beyond the marsh the travellers found blue lanterns hanging above a narrow market street.",
        "That evening Mara understood why the unfinished atlas had been entrusted to their family.",
    ]

    private static func segment(_ text: String) -> TranscriptSegment {
        let tokens = text.split(separator: " ")
        let words = tokens.enumerated().map { index, token in
            TranscriptWord(
                id: UUID().uuidString,
                text: index == tokens.count - 1 ? String(token) : "\(token) ",
                start: Double(index),
                end: Double(index + 1),
                confidence: nil
            )
        }
        return TranscriptSegment(
            id: UUID().uuidString,
            start: 0,
            end: Double(tokens.count),
            words: words,
            ebookText: nil,
            alignmentScore: nil
        )
    }
}

private struct AlignmentFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBAlignmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeEPUB(
        named name: String,
        in folder: URL,
        text: String,
        title: String? = nil,
        author: String? = nil
    ) throws -> URL {
        let source = root.appendingPathComponent(
            "epub-source-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("<html><body><p>\(text)</p></body></html>".utf8)
            .write(to: source.appendingPathComponent("chapter.xhtml"))
        if let title {
            let package = """
            <package xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata>
                <dc:title>\(title)</dc:title>
                <dc:creator>\(author ?? "")</dc:creator>
              </metadata>
              <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """
            try Data(package.utf8).write(to: source.appendingPathComponent("content.opf"))
        }
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.zipItem(
            at: source,
            to: destination,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )
        return destination
    }
}
