import SwiftUI
import Foundation
#if DEBUG
import ZIPFoundation
#endif

@main
struct AudioReaderApp: App {
    @State private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let args = CommandLine.arguments
#if DEBUG
        _state = State(initialValue: AppState(
            composition: args.contains("--uitesting") ? .inMemory() : .live
        ))
#else
        _state = State(initialValue: AppState(composition: .live))
#endif
#if os(macOS)
        if args.contains("--scan") {
            Cli.scan()
            Foundation.exit(0)
        }
        if let idx = args.firstIndex(of: "--transcribe"), args.indices.contains(idx + 1) {
            let audio = args[idx + 1]
            let ebook = args.indices.contains(idx + 2) ? args[idx + 2] : nil
            Cli.transcribe(audioPath: audio, ebookPath: ebook)
            Foundation.exit(0)
        }
#endif
    }

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            RootView(state: state)
                .frame(minWidth: 980, minHeight: 640)
                .background(Palette.bg)
                .preferredColorScheme(AppAppearance(rawValue: state.settings.appearance)?.colorScheme)
                .uiTestMotionEnvironment()
                .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("Navigate") {
                Button("Library") { state.tab = .library }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Now Reading") { state.tab = .player }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Words") { state.tab = .vocab }
                    .keyboardShortcut("3", modifiers: [.command])
                Divider()
                Button("Settings") { state.tab = .settings }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            CommandMenu("Playback") {
                Button(state.player.isPlaying ? "Pause" : "Play") {
                    state.togglePlay()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("Replay sentence") { state.replaySentence() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Previous sentence") { state.skipSentence(direction: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("Next sentence") { state.skipSentence(direction: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option])
                Button("Skip back") { state.skipPlayback(seconds: -state.settings.skipSeconds) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Skip forward") { state.skipPlayback(seconds: state.settings.skipSeconds) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Toggle("Loop sentence", isOn: Binding(
                    get: { state.loopSentence },
                    set: { state.setSentenceLoop($0) }
                ))
                    .keyboardShortcut("l", modifiers: [.command])
                Toggle("Listen First", isOn: Binding(
                    get: { state.settings.deepReadingMode },
                    set: { state.setDeepReadingMode($0) }
                ))
                    .keyboardShortcut("d", modifiers: [.command])
                Button("Continue with next sentence") { state.continueDeepReading() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!state.canContinueDeepReading)
            }
            CommandMenu("Study") {
                Toggle("Study overlay", isOn: Binding(
                    get: { state.settings.showStudyOverlay },
                    set: {
                        state.settings.showStudyOverlay = $0
                        state.persistSettings()
                    }
                ))
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Mark known") { state.markSelectedWordKnown(true) }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(state.selectedWord == nil)
                Button("Chapter words") {
                    state.presentChapterStudyList()
                }
                    .disabled(state.transcript == nil)
                Button("Shadow this sentence") {
                    state.presentShadowing()
                }
                    .disabled(state.transcript == nil)
                Button("Chapter quiz") {
                    state.presentChapterQuiz()
                }
                    .disabled(state.transcript == nil)
            }
            CommandMenu("Library") {
                Button("Choose Books Folder…") { state.chooseLibrary() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Rescan Library") {
                    Task { await state.rescan() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Transcribe Chapter") { state.transcribeSelected() }
                    .keyboardShortcut("t", modifiers: [.command])
            }
        }
#else
        WindowGroup {
            IPadRootView(state: state)
                .preferredColorScheme(AppAppearance(rawValue: state.settings.appearance)?.colorScheme)
                .uiTestMotionEnvironment()
                .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
                .onOpenURL { url in
                    Task { await state.importExternalEPUB(url) }
                }
        }
#endif
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        if phase != .active {
            state.flushReaderProgress()
        }
    }
}

private extension View {
    @ViewBuilder
    func uiTestMotionEnvironment() -> some View {
#if DEBUG
        environment(
            \.uiTestReduceMotion,
            CommandLine.arguments.contains("--uitesting-reduce-motion")
        )
#else
        self
#endif
    }
}

private struct UITestReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var uiTestReduceMotion: Bool {
        get { self[UITestReduceMotionKey.self] }
        set { self[UITestReduceMotionKey.self] = newValue }
    }
}

#if DEBUG
/// Launch-only fixtures keep UI automation deterministic without shipping fixture strings or data.
enum UITestLaunchScenario {
    static var isRequested: Bool { CommandLine.arguments.contains("--uitesting") }

    @MainActor
    static func applyIfRequested(to state: AppState) {
        let arguments = CommandLine.arguments
        guard arguments.contains("--uitesting") else { return }
        let scenario = arguments.first { $0.hasPrefix("--uitesting-scenario=") }?
            .split(separator: "=", maxSplits: 1)
            .last
            .map(String.init) ?? "library"

        let audioURL = makeAudioFixture()
        let chapter = Chapter(
            id: "ui-chapter-1",
            index: 0,
            title: "A Clear Beginning",
            audioPath: audioURL.path,
            duration: 90
        )
        let book = Book(
            id: "ui-book-1",
            title: "The Listening Garden",
            author: "AudioReader",
            folderPath: "/private/tmp/audioreader-ui-book",
            coverPath: nil,
            ebookPath: nil,
            chapters: [chapter],
            source: .files
        )
        let firstWord = TranscriptWord(id: "ui-word-1", text: "Listening ", start: 0, end: 0.8, confidence: 1)
        let secondWord = TranscriptWord(id: "ui-word-2", text: "changes us.", start: 0.8, end: 2.2, confidence: 1)
        let transcriptSegments = [
            TranscriptSegment(
                id: "ui-sentence-1",
                start: 0,
                end: 2.2,
                words: [firstWord, secondWord],
                ebookText: nil,
                alignmentScore: nil
            ),
            fixtureSegment(id: "ui-sentence-2", text: ["Careful ", "practice ", "builds ", "confidence."], start: 2.2),
            fixtureSegment(id: "ui-sentence-3", text: ["Stories ", "make ", "new ", "phrases ", "memorable."], start: 4.4),
            fixtureSegment(id: "ui-sentence-4", text: ["Active ", "recall ", "strengthens ", "understanding."], start: 6.6),
            fixtureSegment(id: "ui-sentence-5", text: ["Tomorrow ", "brings ", "another ", "chapter."], start: 8.8),
        ]

        if scenario == "epub-reader", let ebook = makeEbookFixture() {
            state.books = [ebook]
            state.open(chapter: ebook.chapters[0], in: ebook, autoplay: false)
            return
        }

        state.books = scenario == "empty-library" ? [] : [book]
        state.selectedBookID = scenario == "empty-library" ? nil : book.id
        state.selectedChapterID = scenario == "empty-library" ? nil : chapter.id
        state.transcript = Transcript(
            chapterID: chapter.id,
            audioPath: chapter.audioPath,
            createdAt: Date(timeIntervalSince1970: 1),
            locale: "en-AU",
            segments: transcriptSegments,
            source: "ui-test",
            ebookAligned: false
        )
        state.vocab = [
            VocabEntry(
                id: "ui-vocab-1",
                word: "listening",
                context: "Listening changes us.",
                bookID: book.id,
                bookTitle: book.title,
                chapterID: chapter.id,
                chapterTitle: chapter.title,
                segmentID: "ui-sentence-1",
                wordID: firstWord.id,
                timestamp: 0,
                addedAt: Date(timeIntervalSince1970: 1)
            )
        ]
        if scenario == "words-rich" {
            state.vocab = makeRichVocabularyFixture(book: book, chapter: chapter)
        }

        switch scenario {
        case "reader": state.tab = .player
        case "listen-first":
            state.tab = .player
            state.prepareUITestListenFirstPause(segmentID: "ui-sentence-4", time: 8.74)
        case "words", "words-rich": state.tab = .vocab
        case "settings": state.tab = .settings
        default: state.tab = .library
        }
    }

    /// A private temporary PCM fixture lets automation exercise real seeking
    /// without bundling test media or touching the user's library.
    private static func makeAudioFixture() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioreader-ui-fixture.wav")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        let sampleRate: UInt32 = 8_000
        let sampleCount = Int(sampleRate) * 4
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + sampleCount * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(sampleCount * 2))
        data.append(Data(count: sampleCount * 2))
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// A real EPUB archive keeps reader UI automation on the same parsing and
    /// chapter-navigation path used by imported books without touching user data.
    private static func makeEbookFixture() -> Book? {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "audioreader-ui-epub",
            isDirectory: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        let meta = source.appendingPathComponent("META-INF", isDirectory: true)
        let content = source.appendingPathComponent("OEBPS", isDirectory: true)
        let epub = root.appendingPathComponent("The Paper Lantern.epub")
        do {
            try? fileManager.removeItem(at: root)
            try fileManager.createDirectory(at: meta, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
            try Data("application/epub+zip".utf8).write(
                to: source.appendingPathComponent("mimetype"),
                options: .atomic
            )
            try Data("""
            <?xml version="1.0"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8).write(to: meta.appendingPathComponent("container.xml"), options: .atomic)
            try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>The Paper Lantern</dc:title><dc:creator>AudioReader</dc:creator>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """.utf8).write(to: content.appendingPathComponent("content.opf"), options: .atomic)
            try Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops"><ol>
              <li><a href="chapter.xhtml#one">The Arrival</a></li>
              <li><a href="chapter.xhtml#two">The Lantern Room</a></li>
            </ol></nav></body></html>
            """.utf8).write(to: content.appendingPathComponent("nav.xhtml"), options: .atomic)
            try Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <section id="one"><h1>The Arrival</h1><p>Mara arrived beside the quiet harbour before dawn.</p></section>
              <section id="two"><h1>The Lantern Room</h1><p>The paper lantern revealed a careful message above the desk.</p></section>
            </body></html>
            """.utf8).write(to: content.appendingPathComponent("chapter.xhtml"), options: .atomic)
            let cover = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!
            let embeddedCover = content.appendingPathComponent("cover.png")
            try cover.write(to: embeddedCover, options: .atomic)
            try fileManager.zipItem(
                at: source,
                to: epub,
                shouldKeepParent: false,
                compressionMethod: .deflate
            )
            guard let document = EPUBParser.document(from: epub.path) else { return nil }
            let coverPath = root.appendingPathComponent("cover.png")
            try cover.write(to: coverPath, options: .atomic)
            return Book(
                id: "ui-epub-book",
                title: document.title ?? "The Paper Lantern",
                author: document.author,
                folderPath: root.path,
                coverPath: coverPath.path,
                ebookPath: epub.path,
                chapters: document.sections.enumerated().map { index, section in
                    Chapter(
                        id: "ui-epub-chapter-\(index)",
                        index: index,
                        title: section.title,
                        audioPath: "",
                        duration: nil,
                        ebookSectionIndex: index
                    )
                },
                source: .files
            )
        } catch {
            return nil
        }
    }

    private static func fixtureSegment(
        id: String,
        text: [String],
        start: TimeInterval
    ) -> TranscriptSegment {
        let duration = 2.2 / Double(text.count)
        return TranscriptSegment(
            id: id,
            start: start,
            end: start + 2.2,
            words: text.enumerated().map { index, token in
                TranscriptWord(
                    id: "\(id)-word-\(index)",
                    text: token,
                    start: start + Double(index) * duration,
                    end: start + Double(index + 1) * duration,
                    confidence: 1
                )
            },
            ebookText: nil,
            alignmentScore: nil
        )
    }

    /// A bounded rich fixture verifies the daily queue and the first/last
    /// vocabulary pages without reading or modifying the user's library.
    private static func makeRichVocabularyFixture(book: Book, chapter: Chapter) -> [VocabEntry] {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let due = (0..<4).map { index in
            var entry = VocabEntry(
                id: "ui-vocab-due-\(index)",
                word: "due-\(index)",
                context: "Due card \(index).",
                bookID: book.id,
                bookTitle: book.title,
                chapterID: chapter.id,
                chapterTitle: chapter.title,
                timestamp: Double(index),
                addedAt: now.addingTimeInterval(Double(index))
            )
            entry.reviewCount = 2
            entry.reviewIntervalDays = 3
            entry.nextReview = now.addingTimeInterval(-Double(4 - index))
            return entry
        }
        let new = (0..<81).map { index in
            VocabEntry(
                id: "ui-vocab-new-\(index)",
                word: "new-\(index)",
                context: "New card \(index).",
                bookID: book.id,
                bookTitle: book.title,
                chapterID: chapter.id,
                chapterTitle: chapter.title,
                timestamp: Double(index + 4),
                addedAt: now.addingTimeInterval(Double(index + 4))
            )
        }
        return (due + new).enumerated().map { index, entry in
            var entry = entry
            entry.isInLearnList = index < 3
            return entry
        }
    }
}

#endif
