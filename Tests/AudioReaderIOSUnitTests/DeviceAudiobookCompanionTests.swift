#if os(iOS)
import XCTest
@testable import AudioReader

@MainActor
final class DeviceAudiobookCompanionTests: XCTestCase {
    func testAddCompanionMaterializesMetadataOnlySyncedBook() async throws {
        let fixture = try DeviceCompanionFixture()
        defer { fixture.remove() }
        let sourceAudio = fixture.root.appendingPathComponent("Device Audio.m4b")
        try Data("device audio".utf8).write(to: sourceAudio)
        let chapters = [EmbeddedM4BChapter(title: "Opening", start: 0, duration: 12)]
        let library = DeviceAudiobookLibrary(companionLoader: .init(
            stage: { url in .init(audio: url, cleanupFolder: nil) },
            chapters: { _ in chapters }
        ))
        let item = DeviceAudiobookItem(
            id: 21,
            title: "Synced Device Book",
            author: "Book Author",
            duration: 12,
            assetURL: sourceAudio,
            artworkData: nil,
            isProtected: false
        )
        let book = Book(
            id: "synced-device-book",
            title: item.title,
            author: item.author,
            folderPath: "",
            chapters: [Chapter(id: "synced-chapter", index: 0, title: "Book", audioPath: "")],
            source: .deviceAudiobooks
        )

        let added = try await library.addCompanion(item, to: book, in: fixture.root)
        let scanned = try XCTUnwrap(LibraryScanner.scan(root: fixture.root).first)

        XCTAssertEqual(added, [sourceAudio.lastPathComponent])
        XCTAssertEqual(scanned.id, book.id)
        XCTAssertEqual(M4BChapterExtractor.load(in: URL(fileURLWithPath: scanned.folderPath)), chapters)
    }

    func testAddCompanionPreservesExistingEPUBMarkerAndM4BChaptersAndRepeatsAsNoOp() async throws {
        let fixture = try DeviceCompanionFixture()
        defer { fixture.remove() }
        let bookFolder = fixture.root.appendingPathComponent("Selected Book", isDirectory: true)
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        let epub = bookFolder.appendingPathComponent("Published Text.epub")
        let epubBytes = Data("existing epub bytes".utf8)
        try epubBytes.write(to: epub)
        try AudiobookImportService.writeMarkers(
            source: .files,
            title: "Selected Book",
            author: "Book Author",
            to: bookFolder
        )
        let sourceAudio = fixture.root.appendingPathComponent("Apple Books Audio.m4b")
        try Data("device m4b bytes".utf8).write(to: sourceAudio)
        let chapters = [
            EmbeddedM4BChapter(title: "Opening", start: 0, duration: 12),
            EmbeddedM4BChapter(title: "Arrival", start: 12, duration: 18),
        ]
        let loader = DeviceAudiobookCompanionLoader(
            stage: { url in .init(audio: url, cleanupFolder: nil) },
            chapters: { _ in chapters }
        )
        let library = DeviceAudiobookLibrary(companionLoader: loader)
        let item = DeviceAudiobookItem(
            id: 42,
            title: "Apple Books Audio",
            author: "Book Author",
            duration: 30,
            assetURL: sourceAudio,
            artworkData: nil,
            isProtected: false
        )
        let book = Book(
            id: LibraryScanner.stableID(bookFolder.path),
            title: "Selected Book",
            author: "Book Author",
            folderPath: bookFolder.path,
            ebookPath: epub.path,
            chapters: [Chapter(
                id: "published-text",
                index: 0,
                title: "Published Text",
                audioPath: "",
                ebookSectionIndex: 0
            )],
            source: .files
        )

        let firstAddition = try await library.addCompanion(item, to: book, in: fixture.root)
        let repeatAddition = try await library.addCompanion(item, to: book, in: fixture.root)
        XCTAssertEqual(firstAddition, ["Apple Books Audio.m4b"])
        XCTAssertEqual(repeatAddition, [])
        XCTAssertEqual(try Data(contentsOf: epub), epubBytes)
        XCTAssertEqual(
            try String(contentsOf: bookFolder.appendingPathComponent(".audioreader-source"), encoding: .utf8),
            BookSource.files.rawValue
        )
        XCTAssertEqual(M4BChapterExtractor.load(in: bookFolder), chapters)
    }

    func testAddCompanionRemovesExportStagingAfterAttachmentFailure() async throws {
        let fixture = try DeviceCompanionFixture()
        defer { fixture.remove() }
        let stagingFolder = fixture.root.appendingPathComponent("export-staging", isDirectory: true)
        let stagedAudio = stagingFolder.appendingPathComponent("staged.m4a")
        let loader = DeviceAudiobookCompanionLoader(
            stage: { _ in
                try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
                try Data("staged audio".utf8).write(to: stagedAudio)
                return .init(audio: stagedAudio, cleanupFolder: stagingFolder)
            },
            chapters: { _ in [] }
        )
        let library = DeviceAudiobookLibrary(companionLoader: loader)
        let item = DeviceAudiobookItem(
            id: 84,
            title: "Remote Apple Books Audio",
            author: "Book Author",
            duration: 30,
            assetURL: URL(string: "https://example.invalid/device-audiobook")!,
            artworkData: nil,
            isProtected: false
        )
        let missingTarget = fixture.root.appendingPathComponent("missing/Selected Book", isDirectory: true)
        let missingBook = Book(
            id: "missing-book",
            title: "Selected Book",
            folderPath: missingTarget.path,
            chapters: [Chapter(id: "missing-chapter", index: 0, title: "Book", audioPath: "")]
        )

        do {
            _ = try await library.addCompanion(item, to: missingBook, in: fixture.root)
            XCTFail("Expected attachment into a missing book folder to fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagingFolder.path))
        }
    }
}

private struct DeviceCompanionFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderIOSUnitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
