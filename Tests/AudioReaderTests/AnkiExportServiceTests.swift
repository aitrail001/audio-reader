import AVFoundation
import Foundation
import Testing
import ZIPFoundation
@testable import AudioReader

@Suite("Local Anki transport export")
struct AnkiExportServiceTests {
    @Test("writes Anki headers, Unicode TSV, a manifest, and flat media in stable order")
    func writesPortableZip() async throws {
        let fixture = try Fixture()
        let writer = FakeClipWriter()
        let service = AnkiExportService(temporaryRoot: fixture.temporaryRoot)
        let cards = [
            card(id: "z-card", expression: "冰\t山", sentence: "Line one\nLine two", media: fixture.media),
            card(id: "a-card", expression: "alpha", sentence: "First", media: fixture.media),
        ]

        let report = try await service.export(cards: cards, to: fixture.output, clipWriter: writer)
        let extracted = try fixture.unzip()
        let notes = try String(contentsOf: extracted.appendingPathComponent("notes.tsv"), encoding: .utf8)

        #expect(notes.hasPrefix("#separator:Tab\n#html:true\n#columns:Stable ID\tExpression"))
        #expect(notes.contains("#tags column:10"))
        #expect(notes.firstRange(of: "a-card")!.lowerBound < notes.firstRange(of: "z-card")!.lowerBound)
        #expect(notes.contains("冰 山"))
        #expect(notes.contains("Line one<br>Line two"))
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("manifest.json").path))
        #expect(report.cardCount == 2)
        #expect(report.audioClipCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m4a" }.count == 1)
        #expect(await writer.callCount == 1)
    }

    @Test("pads and clamps chapter-relative M4B bounds")
    func padsAndClampsBounds() async throws {
        let fixture = try Fixture()
        let writer = FakeClipWriter()
        let service = AnkiExportService(temporaryRoot: fixture.temporaryRoot)
        var item = card(id: "one", expression: "word", sentence: "Sentence", media: fixture.media)
        item.audio = AnkiAudioSource(
            mediaURL: fixture.media,
            sentenceStart: 1,
            sentenceEnd: 3,
            chapterOffset: 100,
            mediaDuration: 102,
            isProtected: false
        )

        _ = try await service.export(cards: [item], to: fixture.output, clipWriter: writer)
        let call = try #require(await writer.calls.first)
        #expect(call.start == 100.75)
        #expect(call.end == 102)
    }

    @Test("neutralizes formula-like leading text without altering ordinary hyphens inside text")
    func neutralizesFormulaLikeFields() async throws {
        let fixture = try Fixture()
        let service = AnkiExportService(temporaryRoot: fixture.temporaryRoot)
        let cards = ["=one", "+two", "-three", "@four"].enumerated().map { index, expression in
            AnkiExportCard(
                stableID: "card-\(index)",
                expression: expression,
                resolvedSentence: "ordinary - hyphen",
                gloss: "Meaning",
                book: "Book",
                chapter: "Chapter",
                timestamp: 1
            )
        }

        _ = try await service.export(cards: cards, to: fixture.output, clipWriter: FakeClipWriter())
        let notes = try String(contentsOf: fixture.unzip().appendingPathComponent("notes.tsv"), encoding: .utf8)

        #expect(notes.contains("\t'=one\t"))
        #expect(notes.contains("\t'+two\t"))
        #expect(notes.contains("\t'-three\t"))
        #expect(notes.contains("\t'@four\t"))
        #expect(notes.contains("ordinary - hyphen"))
    }

    @Test("missing and protected media produce text-only cards and omission entries")
    func recordsPartialMediaWithoutFailingExport() async throws {
        let fixture = try Fixture()
        let writer = FakeClipWriter()
        let service = AnkiExportService(temporaryRoot: fixture.temporaryRoot)
        var missing = card(id: "missing", expression: "missing", sentence: "Sentence", media: fixture.media)
        missing.audio?.mediaURL = fixture.root.appendingPathComponent("absent.m4b")
        var protected = card(id: "protected", expression: "protected", sentence: "Sentence", media: fixture.media)
        protected.audio?.isProtected = true

        let report = try await service.export(cards: [missing, protected], to: fixture.output, clipWriter: writer)
        let notes = try String(contentsOf: fixture.unzip().appendingPathComponent("notes.tsv"), encoding: .utf8)

        #expect(report.cardCount == 2)
        #expect(report.audioClipCount == 0)
        #expect(report.omissions.map(\.reason).sorted(by: { $0.rawValue < $1.rawValue }) == [.missingMedia, .protectedMedia])
        #expect(!notes.contains("[sound:"))
        #expect(await writer.callCount == 0)
    }

    @Test("cancellation removes staging files and does not publish a partial ZIP")
    func cancellationCleansUp() async throws {
        let fixture = try Fixture()
        let service = AnkiExportService(temporaryRoot: fixture.temporaryRoot)
        let writer = FakeClipWriter(error: CancellationError())

        await #expect(throws: CancellationError.self) {
            try await service.export(
                cards: [card(id: "one", expression: "word", sentence: "Sentence", media: fixture.media)],
                to: fixture.output,
                clipWriter: writer
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporaryRoot.path).isEmpty)
    }

    @Test("AVFoundation writer produces a playable clip with the requested duration")
    func writesRealAudioDuration() async throws {
        let fixture = try Fixture()
        let source = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        try #require(FileManager.default.fileExists(atPath: source.path), "macOS voice instruction fixture is unavailable")
        let destination = fixture.root.appendingPathComponent("clip.m4a")

        let written = try await AVAudioClipWriter().writeClip(
            from: source,
            start: 0,
            end: 0.5,
            to: destination
        )
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds

        #expect(abs(written - 0.5) < 0.01)
        #expect(abs(duration - 0.5) < 0.08)
    }

    private func card(id: String, expression: String, sentence: String, media: URL) -> AnkiExportCard {
        AnkiExportCard(
            stableID: id,
            expression: expression,
            resolvedSentence: sentence,
            gloss: "Meaning",
            book: "Book",
            author: "Author",
            chapter: "Chapter",
            timestamp: 1,
            tags: ["audioreader", "learning"],
            audio: AnkiAudioSource(
                mediaURL: media,
                sentenceStart: 1,
                sentenceEnd: 2,
                chapterOffset: 0,
                mediaDuration: 10,
                isProtected: false
            )
        )
    }
}

private actor FakeClipWriter: AudioClipWriting {
    struct Call: Sendable {
        var source: URL
        var start: TimeInterval
        var end: TimeInterval
        var destination: URL
    }

    private(set) var calls: [Call] = []
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var callCount: Int { calls.count }

    func writeClip(
        from sourceURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        to destinationURL: URL
    ) async throws -> TimeInterval {
        if let error { throw error }
        calls.append(.init(source: sourceURL, start: start, end: end, destination: destinationURL))
        try Data("m4a".utf8).write(to: destinationURL)
        return end - start
    }
}

private struct Fixture {
    let root: URL
    let temporaryRoot: URL
    let output: URL
    let media: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("anki-export-test-\(UUID().uuidString)")
        temporaryRoot = root.appendingPathComponent("staging", isDirectory: true)
        output = root.appendingPathComponent("cards.zip")
        media = root.appendingPathComponent("book.m4b")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: media)
    }

    func unzip() throws -> URL {
        let destination = root.appendingPathComponent("unzipped", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: output, to: destination)
        return destination
    }
}
