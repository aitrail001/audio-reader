import Foundation
import Testing
import ZIPFoundation
@testable import AudioReader

@Suite("Cross-platform import parity")
struct ImportParityTests {
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

        let extracted = EPUBParser.extractText(from: epub.path)

        #expect(extracted?.contains("shared EPUB extraction") == true)
    }

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
        let ebook = incoming.appendingPathComponent("Study Book.epub")
        try Data("stable audiobook content".utf8).write(to: audio)
        try Data("later ebook content".utf8).write(to: ebook)

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

    @Test("Chapter readiness is computed once from matching transcript identities")
    func computesChapterReadiness() {
        let embedded = Chapter(
            id: "embedded-two",
            index: 1,
            title: "Embedded Two",
            audioPath: "/tmp/book.m4b",
            duration: 120,
            startTime: 42.5
        )
        let ordinary = Chapter(
            id: "ordinary",
            index: 0,
            title: "Ordinary",
            audioPath: "/tmp/chapter.mp3",
            duration: 60,
            startTime: nil
        )
        let book = Book(
            id: "book",
            title: "Book",
            author: nil,
            folderPath: "/tmp",
            coverPath: nil,
            ebookPath: nil,
            chapters: [embedded, ordinary]
        )
        let staleEmbedded = Transcript(
            chapterID: embedded.id,
            audioPath: embedded.audioPath,
            createdAt: Date(),
            locale: "en-US",
            segments: [],
            source: "SpeechAnalyzer",
            ebookAligned: false
        )
        let ordinaryTranscript = Transcript(
            chapterID: ordinary.id,
            audioPath: ordinary.audioPath,
            createdAt: Date(),
            locale: "en-US",
            segments: [],
            source: "SpeechAnalyzer",
            ebookAligned: false
        )

        let ready = Persistence.readyChapterIDs(in: [book], transcripts: [staleEmbedded, ordinaryTranscript])

        #expect(ready == [ordinary.id])
    }

    @Test("Imported-book chapter identities survive iOS container path changes")
    func preservesImportedBookChapterIdentityAcrossContainerChanges() {
        let oldPath = "/private/var/mobile/Containers/Data/Application/OLD/Documents/ImportedBooks/The Ride/book.m4b"
        let currentPath = "/var/mobile/Containers/Data/Application/NEW/Documents/ImportedBooks/The Ride/book.m4b"

        #expect(LibraryScanner.stableID("\(oldPath)#0.000") == LibraryScanner.stableID("\(currentPath)#0.000"))
    }

    @Test("Readiness recovers transcripts saved under an earlier iOS container")
    func recoversTranscriptAcrossContainerChanges() {
        let oldPath = "/private/var/mobile/Containers/Data/Application/OLD/Documents/ImportedBooks/The Ride/book.m4b"
        let currentPath = "/var/mobile/Containers/Data/Application/NEW/Documents/ImportedBooks/The Ride/book.m4b"
        let chapter = Chapter(
            id: LibraryScanner.stableID("\(currentPath)#42.500"),
            index: 1,
            title: "Chapter Two",
            audioPath: currentPath,
            duration: 120,
            startTime: 42.5
        )
        let transcript = Transcript(
            chapterID: "legacy-absolute-path-id",
            audioPath: oldPath,
            chapterStart: 42.5,
            createdAt: Date(),
            locale: "en-US",
            segments: [],
            source: "SpeechAnalyzer",
            ebookAligned: false
        )
        let book = Book(
            id: "book",
            title: "The Ride",
            author: nil,
            folderPath: currentPath,
            coverPath: nil,
            ebookPath: nil,
            chapters: [chapter]
        )

        #expect(Persistence.readyChapterIDs(in: [book], transcripts: [transcript]) == [chapter.id])
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
        let project = try String(
            contentsOf: repository.appendingPathComponent("AudioReader.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        #expect(plist["CFBundleShortVersionString"] as? String == "1.0.38")
        #expect(plist["CFBundleVersion"] as? String == "39")
        #expect(project.components(separatedBy: "MARKETING_VERSION = 1.0.38;").count - 1 == 4)
        #expect(project.components(separatedBy: "CURRENT_PROJECT_VERSION = 39;").count - 1 == 4)
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
