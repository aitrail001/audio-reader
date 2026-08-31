#if os(macOS)
import AppKit
import AVFoundation
import Foundation
import OSLog

private let appleBooksLog = Logger(
    subsystem: "com.johnsonzhang.AudioReader",
    category: "apple-books-library"
)

struct MacAppleBookItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case audiobook
        case ebook
    }

    var id: String
    var title: String
    var author: String
    var duration: TimeInterval
    var location: URL?
    var artworkData: Data?
    var isProtected: Bool
    var isCloud: Bool
    var kind: Kind = .audiobook

    var canImport: Bool {
        !isProtected && !isCloud && location.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }
}

@MainActor
@Observable
final class MacAppleBooksLibrary {
    var items: [MacAppleBookItem] = []
    var isLoading = false
    var message: String?

    func reload() async {
        guard !isLoading else { return }
        let requestID = UUID().uuidString
        isLoading = true
        defer { isLoading = false }
        appleBooksLog.info(
            "apple_books_scan_started message=apple_books_scan_started requestId=\(requestID, privacy: .public) component=apple-books-library"
        )
        do {
            items = try await Task.detached(priority: .userInitiated) {
                try await Self.readDownloadedBooks()
            }.value
            let available = items.filter(\.canImport).count
            let unavailable = items.count - available
            message = unavailable > 0
                ? "Found \(available) importable and \(unavailable) protected or unreadable downloaded Apple Books titles."
                : "Found \(available) accessible downloaded audiobooks and EPUB books in Apple Books."
            appleBooksLog.info(
                "apple_books_scan_finished message=apple_books_scan_finished requestId=\(requestID, privacy: .public) component=apple-books-library outcome=success total_count=\(self.items.count, privacy: .public) importable_count=\(available, privacy: .public) unavailable_count=\(unavailable, privacy: .public)"
            )
        } catch {
            items = []
            message = "Downloaded Apple Books files could not be read: \(error.localizedDescription)"
            appleBooksLog.error(
                "apple_books_scan_finished message=apple_books_scan_finished requestId=\(requestID, privacy: .public) component=apple-books-library outcome=failure error_type=\(String(reflecting: type(of: error)), privacy: .public)"
            )
        }
    }

    nonisolated private static func readDownloadedBooks() async throws -> [MacAppleBookItem] {
        let booksRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books")
        return try await readDownloadedBooks(in: booksRoot)
    }

    nonisolated static func readDownloadedBooks(in booksRoot: URL) async throws -> [MacAppleBookItem] {
        guard FileManager.default.fileExists(atPath: booksRoot.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: booksRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let supportedAudio = Set(["m4b", "m4a", "mp3"])
        let urls = enumerator.compactMap { $0 as? URL }.filter { url in
            supportedAudio.contains(url.pathExtension.lowercased())
                || url.pathExtension.lowercased() == "epub"
        }
        var found: [MacAppleBookItem] = []
        for url in urls {
            if url.pathExtension.lowercased() == "epub" {
                found.append(ebookItem(for: url))
            } else {
                found.append(try await audiobookItem(for: url))
            }
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func audiobookItem(for url: URL) async throws -> MacAppleBookItem {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.commonMetadata)
        let protected = try await asset.load(.hasProtectedContent)
        let filename = url.deletingPathExtension().lastPathComponent
        let filenameParts = filename.components(separatedBy: " - ")
        let fallbackTitle = filenameParts.first ?? filename
        let fallbackAuthor = filenameParts.dropFirst().last ?? "Unknown author"
        let title = try await metadataString(.commonIdentifierTitle, in: metadata) ?? fallbackTitle
        let author = try await metadataString(.commonIdentifierArtist, in: metadata) ?? fallbackAuthor
        let artwork = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierArtwork
        ).first
        let artworkData = try await artwork?.load(.dataValue)
        return MacAppleBookItem(
            id: url.path,
            title: title,
            author: author,
            duration: duration.isFinite ? duration : 0,
            location: url,
            artworkData: artworkData,
            isProtected: protected,
            isCloud: false,
            kind: .audiobook
        )
    }

    /// Apple Books has no public library API; only already-downloaded files that
    /// macOS grants this process permission to read are considered importable.
    nonisolated private static func ebookItem(for url: URL) -> MacAppleBookItem {
        let document = EPUBParser.document(from: url.path)
        return MacAppleBookItem(
            id: url.path,
            title: document?.title ?? url.deletingPathExtension().lastPathComponent,
            author: document?.author ?? "Unknown author",
            duration: 0,
            location: url,
            artworkData: document?.cover?.data,
            isProtected: document == nil,
            isCloud: false,
            kind: .ebook
        )
    }

    nonisolated private static func metadataString(
        _ identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async throws -> String? {
        let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
        return try await item?.load(.stringValue)
    }

    func importAudiobook(
        _ item: MacAppleBookItem,
        into libraryRoot: URL,
        duplicatePolicy: AudiobookDuplicateImportPolicy = .keepExisting
    ) throws {
        guard item.canImport, let location = item.location else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        let result = try AudiobookImportService.importFiles(
            [location],
            into: libraryRoot,
            duplicatePolicy: duplicatePolicy
        )
        let folder = result.folder
        try AudiobookImportService.writeMarkers(
            source: .appleBooks,
            title: item.title,
            author: item.author,
            to: folder
        )
        if item.kind == .audiobook, let artworkData = item.artworkData {
            try artworkData.write(to: folder.appendingPathComponent("cover.jpg"), options: .atomic)
        }
    }

    func openBooks() {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Books.app"),
            configuration: configuration
        )
    }

    func openInBooks(_ item: MacAppleBookItem) {
        guard let location = item.location else {
            openBooks()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [location],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Books.app"),
            configuration: configuration
        )
    }
}
#endif
