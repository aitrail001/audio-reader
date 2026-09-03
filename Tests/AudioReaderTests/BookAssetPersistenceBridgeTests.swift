import Foundation
import Testing
@testable import AudioReader

@Suite("Book asset persistence bridge")
struct BookAssetPersistenceBridgeTests {
    @Test("embedded M4B chapters hash their shared physical file once")
    func embeddedM4BChaptersReuseOneDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("shared-book.m4b")
        try Data("audio".utf8).write(to: audio)
        let audioPath = audio.path
        let book = Book(
            id: "shared-m4b",
            title: "Shared M4B",
            folderPath: directory.path,
            chapters: (0..<16).map { index in
                Chapter(
                    id: "chapter-\(index)",
                    index: index,
                    title: "Chapter \(index + 1)",
                    audioPath: audioPath
                )
            }
        )
        var digestCount = 0

        let assets = StoredLocalAsset.snapshots(for: book) { _ in
            digestCount += 1
            return .init(
                contentHash: "shared-hash",
                byteCount: 5,
                regularFileCount: 1,
                isDirectory: false
            )
        }

        #expect(assets.count == 16)
        #expect(assets.allSatisfy { $0.contentHash == "shared-hash" })
        #expect(digestCount == 1)
    }

    @Test("changed embedded M4B replaces every shared chapter digest in one pass")
    func changedEmbeddedM4BReusesNewDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("shared-book.m4b")
        try Data("audio".utf8).write(to: audio)
        let book = Book(
            id: "changed-shared-m4b",
            title: "Changed Shared M4B",
            folderPath: directory.path,
            chapters: (0..<16).map { index in
                Chapter(
                    id: "chapter-\(index)",
                    index: index,
                    title: "Chapter \(index + 1)",
                    audioPath: audio.path
                )
            }
        )
        let existing = StoredLocalAsset.snapshots(for: book) { _ in
            .init(contentHash: "old-hash", byteCount: 5, regularFileCount: 1, isDirectory: false)
        }
        try Data("updated audio".utf8).write(to: audio)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: audio.path
        )
        var digestCount = 0

        let assets = StoredLocalAsset.snapshots(for: book, reusing: existing) { _ in
            digestCount += 1
            return .init(
                contentHash: "new-hash",
                byteCount: 13,
                regularFileCount: 1,
                isDirectory: false
            )
        }

        #expect(assets.allSatisfy { $0.contentHash == "new-hash" })
        #expect(digestCount == 1)
    }

    @Test("audio EPUB and cover paths round-trip through typed local assets")
    func assetsRoundTripWithoutLibraryRescan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("chapter.m4b")
        let epub = directory.appendingPathComponent("book.epub")
        let cover = directory.appendingPathComponent("cover.jpg")
        try Data("audio".utf8).write(to: audio)
        try Data("epub".utf8).write(to: epub)
        try Data("cover".utf8).write(to: cover)
        let book = Book(
            id: "asset-book",
            title: "Asset Book",
            folderPath: directory.path,
            coverPath: cover.path,
            ebookPath: epub.path,
            chapters: [Chapter(
                id: "asset-chapter",
                index: 0,
                title: "One",
                audioPath: audio.path
            ), Chapter(
                id: "ebook-chapter",
                index: 1,
                title: "Published One",
                audioPath: "",
                ebookSectionIndex: 3
            )]
        )

        let assets = StoredLocalAsset.snapshots(for: book)
        let restored = Book(StoredBook(book), assets: assets)

        #expect(Set(assets.map(\.kind)) == ["audio", "epub", "cover"])
        #expect(assets.allSatisfy { $0.contentHash?.isEmpty == false })
        #expect(assets.allSatisfy { ($0.byteCount ?? 0) > 0 })
        #expect(restored.chapters.first?.audioPath == audio.path)
        #expect(restored.chapters.last?.ebookSectionIndex == 3)
        #expect(restored.ebookPath == epub.path)
        #expect(restored.coverPath == cover.path)
        #expect(restored.mediaAvailability == .audioAndEbook)
    }

    @Test("macOS and iPad delete actions share the transactional AppState path")
    func platformDeleteParity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mac = try String(
            contentsOf: root.appendingPathComponent("Sources/AudioReader/LibraryView.swift"),
            encoding: .utf8
        )
        let ipad = try String(
            contentsOf: root.appendingPathComponent("Sources/AudioReader/IPadRootView.swift"),
            encoding: .utf8
        )

        #expect(mac.contains("state.deleteBookFromLibrary(book)"))
        #expect(ipad.contains("state.deleteBookFromLibrary(book)"))
        #expect(!mac.contains("AudiobookImportService.trashBookFolder"))
        #expect(!ipad.contains("AudiobookImportService.deleteBookFolder"))
    }

    @Test("managed media deletion commits a catalog tombstone and cannot be rescanned")
    func managedMediaDeletionDoesNotResurrect() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("chapter.mp3")
        try Data("audio".utf8).write(to: audio)
        let chapter = Chapter(id: "delete-chapter", index: 0, title: "One", audioPath: audio.path)
        let book = Book(
            id: "delete-book",
            title: "Delete Book",
            folderPath: folder.path,
            chapters: [chapter]
        )
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        let stored = StoredBook(book)
        try store.saveBook(
            stored,
            assets: StoredLocalAsset.snapshots(for: book),
            mutation: AccountSyncApplicator.bookMutation(for: stored)
        )

        try Persistence.deleteBook(book, mediaRoot: root, database: store)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try store.loadBooks().isEmpty)
        #expect(try store.loadAssets(bookID: stored.id).isEmpty)
        #expect(try store.pendingMutations().map(\.operation) == [.delete])
        #expect(LibraryScanner.scan(root: root).isEmpty)
    }

    @Test("metadata-only cloud catalog rows can be deleted without local media")
    func metadataOnlyDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(
            id: "metadata-only-book",
            title: "Cloud Book",
            folderPath: "",
            chapters: [Chapter(id: "cloud-chapter", index: 0, title: "One", audioPath: "")]
        )
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        try store.saveBook(StoredBook(book))

        try Persistence.deleteBook(book, mediaRoot: root, database: store)

        #expect(try store.loadBooks().isEmpty)
        #expect(try store.loadAssets(bookID: BookID(rawValue: book.id)).isEmpty)
        #expect(try store.pendingMutations().map(\.operation) == [.delete])
    }

    @Test("pulled book tombstone suppresses unmanaged media on every later scan")
    func pulledBookDeleteSuppressesRescanWithoutDeletingUnmanagedMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Unmanaged", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = folder.appendingPathComponent("chapter.mp3")
        try Data("unmanaged audio".utf8).write(to: audio)
        let scanned = try #require(LibraryScanner.scan(root: root).first)
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        try store.saveBook(StoredBook(scanned))
        let deletion = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.book.rawValue,
            entityId: AccountSyncApplicator.syncEntityID(scanned.id, kind: "book"),
            operation: OutboxOperation.delete.rawValue,
            revision: 2,
            changedAt: "2026-08-31T00:00:00Z",
            payload: ["localId": .string(scanned.id)]
        )

        try AccountSyncApplicator.applyPage([deletion], cursor: "book-delete-1", to: store)
        let rescanned = LibraryScanner.scan(root: root)
        let reconciled = try Persistence.reconcileScannedBooks(rescanned, database: store)

        #expect(reconciled.isEmpty)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(try store.loadDeletedBookIDs() == [BookID(rawValue: scanned.id)])
        #expect(try store.pendingMutations().isEmpty)
        #expect(try store.loadCursor() == "book-delete-1")
        #expect(try Persistence.reconcileScannedBooks(LibraryScanner.scan(root: root), database: store).isEmpty)
    }

    @Test("pulled book delete on an empty store independently suppresses later media")
    func emptyStorePulledDeleteSuppressesLaterScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Unmanaged", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("later media".utf8).write(to: folder.appendingPathComponent("chapter.mp3"))
        let discovered = try #require(LibraryScanner.scan(root: root).first)
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        let entityID = AccountSyncApplicator.syncEntityID(discovered.id, kind: "book")
        let deletion = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.book.rawValue,
            entityId: entityID,
            operation: OutboxOperation.delete.rawValue,
            revision: 7,
            changedAt: "2026-08-31T00:00:00Z",
            payload: ["localId": .string(discovered.id)]
        )

        try AccountSyncApplicator.applyPage([deletion], cursor: "empty-delete-7", to: store)

        #expect(try store.loadBooks().isEmpty)
        #expect(try store.loadDeletedBookIDs() == [BookID(rawValue: discovered.id)])
        #expect(try store.loadCursor() == "empty-delete-7")
        #expect(try store.loadVersion(entityType: OutboxEntityType.book.rawValue, entityID: entityID)?.serverVersion == 7)
        #expect(try Persistence.reconcileScannedBooks(LibraryScanner.scan(root: root), database: store).isEmpty)
        #expect(try store.pendingMutations().isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("chapter.mp3").path))
    }

    @Test("expanded EPUB directory digest is recursive deterministic and ignores ephemeral metadata")
    func expandedEPUBDirectoryDigestRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.epub", isDirectory: true)
        let second = root.appendingPathComponent("Second.epub", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("OPS/Text", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("chapter two".utf8).write(to: first.appendingPathComponent("OPS/Text/two.xhtml"))
        try Data("chapter one".utf8).write(to: first.appendingPathComponent("OPS/Text/one.xhtml"))
        try Data("chapter one".utf8).write(to: second.appendingPathComponent("OPS/Text/one.xhtml"))
        try Data("chapter two".utf8).write(to: second.appendingPathComponent("OPS/Text/two.xhtml"))
        try Data("noise-a".utf8).write(to: first.appendingPathComponent(".DS_Store"))
        try Data("noise-b".utf8).write(to: second.appendingPathComponent("._temporary"))
        let firstBook = Book(id: "expanded-first", title: "Expanded", folderPath: root.path, ebookPath: first.path, chapters: [])
        let secondBook = Book(id: "expanded-second", title: "Expanded", folderPath: root.path, ebookPath: second.path, chapters: [])

        let firstAsset = try #require(StoredLocalAsset.snapshots(for: firstBook).first)
        let secondAsset = try #require(StoredLocalAsset.snapshots(for: secondBook).first)
        let expectedBytes = Int64(Data("chapter one".utf8).count + Data("chapter two".utf8).count)

        #expect(firstAsset.contentHash == secondAsset.contentHash)
        #expect(firstAsset.byteCount == expectedBytes)
        #expect(secondAsset.byteCount == expectedBytes)
        #expect(firstAsset.metadata["representation"] == "directory")
        #expect(firstAsset.metadata["regularFileCount"] == "2")

        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        let stored = StoredBook(firstBook)
        try store.saveBook(stored)
        try store.saveAssets([firstAsset], bookID: stored.id)
        #expect(try LocalSQLiteStore(fileURL: store.url).loadAssets(bookID: stored.id) == [firstAsset])
    }
}
