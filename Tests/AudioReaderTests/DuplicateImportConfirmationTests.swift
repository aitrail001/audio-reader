import Foundation
import Testing
import ZIPFoundation
@testable import AudioReader

@Suite("Duplicate import confirmation")
struct DuplicateImportConfirmationTests {
    @Test("Exact audio duplicate is detected without changing the library")
    func exactAudioDuplicatePreflightIsReadOnly() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let first = try fixture.audio(named: "First.m4b", contents: "identical audio")
        _ = try AudiobookImportService.importFiles([first], into: fixture.library)
        let second = try fixture.audio(named: "Renamed.m4b", contents: "identical audio")
        let before = try fixture.librarySnapshot()

        let preflight = try AudiobookImportService.preflightFiles([second], into: fixture.library)

        #expect(preflight.requiresConfirmation)
        #expect(preflight.duplicates.count == 1)
        #expect(try fixture.librarySnapshot() == before)
        #expect(LibraryScanner.scan(root: fixture.library).count == 1)
    }

    @Test("A repackaged EPUB with the same publication content is a semantic duplicate")
    func semanticEPUBDuplicateRequiresConfirmation() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let first = try fixture.epub(named: "First Edition", extraFile: nil)
        _ = try AudiobookImportService.importFiles([first], into: fixture.library)
        let repackaged = try fixture.epub(named: "Repackaged Edition", extraFile: "ignored.txt")
        let before = try fixture.librarySnapshot()

        let preflight = try AudiobookImportService.preflightFiles([repackaged], into: fixture.library)

        #expect(preflight.requiresConfirmation)
        #expect(preflight.duplicates.first?.title == "A Shared Book")
        #expect(try fixture.librarySnapshot() == before)
    }

    @Test("An expanded Apple Books EPUB remains one duplicate identity across repeat import")
    func expandedEPUBRepeatImportRequiresConfirmation() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let expanded = try fixture.expandedEPUB(named: "Expanded Apple Book")
        _ = try AudiobookImportService.importFiles([expanded], into: fixture.library)
        let before = try fixture.librarySnapshot()

        let preflight = try AudiobookImportService.preflightFiles([expanded], into: fixture.library)

        #expect(preflight.requiresConfirmation)
        #expect(preflight.duplicates.count == 1)
        #expect(try fixture.librarySnapshot() == before)
        _ = try AudiobookImportService.importFiles(
            [expanded],
            into: fixture.library,
            duplicatePolicy: .confirmedReimport
        )
        #expect(LibraryScanner.scan(root: fixture.library).count == 2)
    }

    @Test("An existing expanded EPUB can be enriched with missing audio")
    func expandedEPUBWithMissingAudioIsEnrichment() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let expanded = try fixture.expandedEPUB(named: "Expanded Audio Book")
        let imported = try AudiobookImportService.importFiles([expanded], into: fixture.library)
        let audio = try fixture.audio(named: "Expanded Audio Book.m4b", contents: "new companion audio")

        let preflight = try AudiobookImportService.preflightFiles([expanded, audio], into: fixture.library)

        #expect(!preflight.requiresConfirmation)
        #expect(preflight.enrichesExistingBook)
        let enriched = try AudiobookImportService.importFiles([expanded, audio], into: fixture.library)
        #expect(enriched.folder.standardizedFileURL == imported.folder.standardizedFileURL)
        #expect(LibraryScanner.scan(root: fixture.library).count == 1)
        #expect(LibraryScanner.scan(root: fixture.library).first?.chapters.contains(where: \.hasAudio) == true)
    }

    @Test("An existing expanded EPUB can be enriched with missing cover artwork")
    func expandedEPUBWithMissingCoverIsEnrichment() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let expanded = try fixture.expandedEPUB(named: "Expanded Covered Book")
        let imported = try AudiobookImportService.importFiles([expanded], into: fixture.library)
        let cover = fixture.incoming.appendingPathComponent("manual-cover.jpg")
        try Data("new companion cover".utf8).write(to: cover)

        let preflight = try AudiobookImportService.preflightFiles([expanded, cover], into: fixture.library)

        #expect(!preflight.requiresConfirmation)
        #expect(preflight.enrichesExistingBook)
        let enriched = try AudiobookImportService.importFiles([expanded, cover], into: fixture.library)
        #expect(enriched.folder.standardizedFileURL == imported.folder.standardizedFileURL)
        #expect(LibraryScanner.scan(root: fixture.library).count == 1)
        #expect(LibraryScanner.scan(root: fixture.library).first?.coverPath != nil)
    }

    @Test("Companion validation failure leaves an expanded EPUB book unchanged")
    func expandedEPUBCompanionFailureIsAtomic() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let expanded = try fixture.expandedEPUB(named: "Expanded Atomic Book")
        let imported = try AudiobookImportService.importFiles([expanded], into: fixture.library)
        let cover = fixture.incoming.appendingPathComponent("late-cover.jpg")
        try Data("must not be copied".utf8).write(to: cover)
        let invalidEPUB = fixture.incoming.appendingPathComponent("Broken.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidEPUB, withIntermediateDirectories: true)
        try Data("not an EPUB package".utf8).write(to: invalidEPUB.appendingPathComponent("broken.txt"))
        let before = try fixture.librarySnapshot()

        #expect(throws: AudiobookImportError.self) {
            try AudiobookImportService.addCompanionFiles([cover, invalidEPUB], to: imported.folder)
        }

        #expect(try fixture.librarySnapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: imported.folder.appendingPathComponent(cover.lastPathComponent).path))
    }

    @Test("Cancelling leaves the duplicate untouched while confirmation deliberately creates another copy")
    func cancelAndConfirmHaveDistinctOutcomes() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let first = try fixture.audio(named: "Original.m4b", contents: "same bytes")
        _ = try AudiobookImportService.importFiles([first], into: fixture.library)
        let duplicate = try fixture.audio(named: "Duplicate.m4b", contents: "same bytes")
        let beforeCancel = try fixture.librarySnapshot()

        _ = try AudiobookImportService.preflightFiles([duplicate], into: fixture.library)
        #expect(try fixture.librarySnapshot() == beforeCancel)

        _ = try AudiobookImportService.importFiles(
            [duplicate],
            into: fixture.library,
            duplicatePolicy: .confirmedReimport
        )
        #expect(LibraryScanner.scan(root: fixture.library).count == 2)
    }

    @Test("Device audio content match stays read-only until confirmed metadata enrichment")
    func deviceAudioContentMatchRequiresConfirmationBeforeMetadataWrites() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let filesAudio = try fixture.audio(named: "Files Book.m4a", contents: "shared device bytes")
        let imported = try AudiobookImportService.importFiles([filesAudio], into: fixture.library)
        let stagedAudio = try fixture.audio(named: "Device Export.m4a", contents: "shared device bytes")
        let before = try fixture.librarySnapshot()

        let cancelled = try AudiobookImportService.stageDeviceAudiobookFile(
            stagedAudio,
            deviceID: 42,
            title: "Device Book",
            in: fixture.library
        )
        let cancelledFolder = try #require(cancelled.stagingFolder)

        #expect(cancelled.identity.requiresConfirmation)
        #expect(cancelled.identity.duplicates.first?.existingFolder.standardizedFileURL == imported.folder.standardizedFileURL)
        #expect(!cancelledFolder.standardizedFileURL.path.hasPrefix(fixture.library.standardizedFileURL.path))
        #expect(try fixture.librarySnapshot() == before)
        cancelled.discard()
        #expect(!FileManager.default.fileExists(atPath: cancelledFolder.path))
        #expect(try fixture.librarySnapshot() == before)

        let confirmed = try AudiobookImportService.stageDeviceAudiobookFile(
            stagedAudio,
            deviceID: 42,
            title: "Device Book",
            in: fixture.library
        )
        defer { confirmed.discard() }

        let enriched = try AudiobookImportService.confirmDeviceAudiobookMatch(
            confirmed.identity,
            deviceID: 42,
            title: "Device Book",
            author: "Device Author"
        )

        #expect(enriched.standardizedFileURL == imported.folder.standardizedFileURL)
        #expect(LibraryScanner.scan(root: fixture.library).count == 1)
        #expect(try String(
            contentsOf: enriched.appendingPathComponent(".audioreader-device-id"),
            encoding: .utf8
        ) == "42")
        #expect(try String(
            contentsOf: enriched.appendingPathComponent(".audioreader-source"),
            encoding: .utf8
        ) == BookSource.deviceAudiobooks.rawValue)
    }

    @Test("Adding a missing EPUB companion remains enrichment rather than duplicate re-import")
    func missingCompanionDoesNotRequireConfirmation() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let audio = try fixture.audio(named: "A Shared Book.m4b", contents: "stable audio")
        _ = try AudiobookImportService.importFiles([audio], into: fixture.library)
        let epub = try fixture.epub(named: "Companion", extraFile: nil)

        let preflight = try AudiobookImportService.preflightFiles([audio, epub], into: fixture.library)

        #expect(!preflight.requiresConfirmation)
        #expect(preflight.enrichesExistingBook)
        _ = try AudiobookImportService.importFiles([audio, epub], into: fixture.library)
        let books = LibraryScanner.scan(root: fixture.library)
        #expect(books.count == 1)
        #expect(books.first?.ebookPath != nil)
    }

    @Test("Adding missing cover artwork remains enrichment rather than duplicate re-import")
    func missingCoverDoesNotRequireConfirmation() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let audio = try fixture.audio(named: "Covered Book.m4b", contents: "stable covered audio")
        _ = try AudiobookImportService.importFiles([audio], into: fixture.library)
        let cover = fixture.incoming.appendingPathComponent("cover.png")
        try Data("cover fixture".utf8).write(to: cover)

        let preflight = try AudiobookImportService.preflightFiles([audio, cover], into: fixture.library)

        #expect(!preflight.requiresConfirmation)
        #expect(preflight.enrichesExistingBook)
        _ = try AudiobookImportService.importFiles([audio, cover], into: fixture.library)
        let books = LibraryScanner.scan(root: fixture.library)
        #expect(books.count == 1)
        #expect(books.first?.coverPath != nil)
    }

    @Test("Folder preflight finds every duplicate before importing any new sibling")
    func folderPreflightIsAtomicAndReadOnly() throws {
        let fixture = try DuplicateImportFixture()
        defer { fixture.remove() }
        let original = try fixture.audio(named: "Original.m4b", contents: "duplicate bytes")
        _ = try AudiobookImportService.importFiles([original], into: fixture.library)
        let collection = fixture.root.appendingPathComponent("Collection", isDirectory: true)
        let duplicateBook = collection.appendingPathComponent("Duplicate", isDirectory: true)
        let newBook = collection.appendingPathComponent("New", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateBook, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newBook, withIntermediateDirectories: true)
        try Data("duplicate bytes".utf8).write(to: duplicateBook.appendingPathComponent("copy.m4b"))
        try Data("new bytes".utf8).write(to: newBook.appendingPathComponent("new.m4b"))
        let before = try fixture.librarySnapshot()

        let preflight = try AudiobookImportService.preflightFolder(collection, into: fixture.library)

        #expect(preflight.requiresConfirmation)
        #expect(preflight.duplicates.count == 1)
        #expect(try fixture.librarySnapshot() == before)
    }

    @Test("macOS and iPad import surfaces route duplicates through native confirmation")
    func platformImportSurfacesExposeConfirmation() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let service = try source("Sources/AudioReader/AudiobookImportService.swift", repository: repository)
        let macImporter = try source("Sources/AudioReader/MacAudiobookImporter.swift", repository: repository)
        let macRoot = try source("Sources/AudioReader/RootView.swift", repository: repository)
        let appleBooksView = try source("Sources/AudioReader/MacAppleBooksView.swift", repository: repository)
        let appleBooksLibrary = try source("Sources/AudioReader/MacAppleBooksLibrary.swift", repository: repository)
        let iPadRoot = try source("Sources/AudioReader/IPadRootView.swift", repository: repository)
        let appState = try source("Sources/AudioReader/AppState.swift", repository: repository)

        #expect(service.contains("preflightFiles"))
        #expect(service.contains("preflightFolder"))
        #expect(macImporter.contains("NSAlert"))
        #expect(macImporter.contains("confirmedReimport"))
        #expect(macRoot.contains("pendingAppleBooksDuplicate"))
        #expect(macRoot.contains("pendingDuplicateImport: $pendingAppleBooksDuplicate"))
        #expect(appleBooksView.contains(".alert(\"Import another copy?\""))
        #expect(appleBooksView.contains("@Binding var pendingDuplicateImport"))
        #expect(appleBooksView.contains("onConfirmDuplicate"))
        #expect(appleBooksLibrary.contains("duplicatePolicy: AudiobookDuplicateImportPolicy = .keepExisting"))
        #expect(iPadRoot.contains("pendingDuplicateImport"))
        #expect(iPadRoot.contains("Import another copy?"))
        #expect(appState.contains("pendingExternalEPUBDuplicate"))
        #expect(appState.contains("confirmExternalEPUBImport"))
    }

    private func source(_ path: String, repository: URL) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }
}

private struct DuplicateImportFixture {
    let root: URL
    let incoming: URL
    let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-import-\(UUID().uuidString)", isDirectory: true)
        incoming = root.appendingPathComponent("Incoming", isDirectory: true)
        library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    }

    func audio(named name: String, contents: String) throws -> URL {
        let directory = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func epub(named name: String, extraFile: String?) throws -> URL {
        let source = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let meta = source.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = source.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: meta.appendingPathComponent("container.xml"))
        try Data("""
        <package xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>A Shared Book</dc:title><dc:creator>Same Author</dc:creator></metadata>
          <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """.utf8).write(to: oebps.appendingPathComponent("content.opf"))
        try Data("<html><body><p>The same meaningful published passage appears in both packages for duplicate identity.</p></body></html>".utf8)
            .write(to: oebps.appendingPathComponent("chapter.xhtml"))
        if let extraFile {
            try Data("archive-only difference".utf8).write(to: source.appendingPathComponent(extraFile))
        }
        let destination = incoming.appendingPathComponent("\(name)-\(UUID().uuidString).epub")
        try FileManager.default.zipItem(at: source, to: destination, shouldKeepParent: false, compressionMethod: .deflate)
        return destination
    }

    func expandedEPUB(named name: String) throws -> URL {
        let archive = try epub(named: name, extraFile: nil)
        let destination = incoming.appendingPathComponent("\(name)-\(UUID().uuidString).epub", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: archive, to: destination)
        return destination
    }

    func librarySnapshot() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: library.path) else { return [:] }
        let enumerator = FileManager.default.enumerator(at: library, includingPropertiesForKeys: [.isRegularFileKey])
        return try (enumerator?.compactMap { $0 as? URL } ?? []).reduce(into: [:]) { snapshot, url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
            snapshot[url.path.replacingOccurrences(of: library.path, with: "")] = try Data(contentsOf: url)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
