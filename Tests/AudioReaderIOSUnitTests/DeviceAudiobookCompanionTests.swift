#if os(iOS)
import XCTest
@testable import AudioReader

@MainActor
final class DeviceAudiobookCompanionTests: XCTestCase {
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

        let firstAddition = try await library.addCompanion(item, to: bookFolder)
        let repeatAddition = try await library.addCompanion(item, to: bookFolder)
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

        do {
            _ = try await library.addCompanion(item, to: missingTarget)
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
