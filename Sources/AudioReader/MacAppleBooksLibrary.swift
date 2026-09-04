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

enum MacAppleBooksCompanionRequirement: Equatable, Sendable {
    case audiobook
    case ebook
    case either

    init?(mediaAvailability: BookMediaAvailability) {
        switch mediaAvailability {
        case .ebookOnly: self = .audiobook
        case .audioOnly: self = .ebook
        case .metadataOnly: self = .either
        case .audioAndEbook: return nil
        }
    }

    func accepts(_ kind: MacAppleBookItem.Kind) -> Bool {
        switch (self, kind) {
        case (.audiobook, .audiobook), (.ebook, .ebook), (.either, _): true
        default: false
        }
    }

    var prompt: String {
        switch self {
        case .audiobook: "Choose an accessible downloaded audiobook."
        case .ebook: "Choose a non-DRM EPUB book."
        case .either: "Choose an accessible audiobook or a non-DRM EPUB book."
        }
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

    /// The caller's missing-capability requirement is rechecked against the
    /// folder so stale UI state cannot replace or add a second effective medium.
    func addCompanion(
        _ item: MacAppleBookItem,
        to bookFolder: URL,
        required: MacAppleBooksCompanionRequirement
    ) throws -> [String] {
        guard item.canImport, let location = item.location else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        let requestID = UUID().uuidString
        appleBooksLog.info(
            "apple_books_companion_started message=apple_books_companion_started requestId=\(requestID, privacy: .public) component=apple-books-library kind=\(item.kind.rawValue, privacy: .public)"
        )
        guard required.accepts(item.kind) else {
            appleBooksLog.error(
                "apple_books_companion_finished message=apple_books_companion_finished requestId=\(requestID, privacy: .public) component=apple-books-library outcome=rejected reason=incompatible_kind"
            )
            throw AudiobookImportError.incompatibleCompanion
        }
        if containsMedia(of: item.kind, in: bookFolder) {
            if try isExactRepeat(location, kind: item.kind, in: bookFolder) {
                appleBooksLog.info(
                    "apple_books_companion_finished message=apple_books_companion_finished requestId=\(requestID, privacy: .public) component=apple-books-library outcome=success added_count=0 reason=exact_repeat"
                )
                return []
            }
            appleBooksLog.error(
                "apple_books_companion_finished message=apple_books_companion_finished requestId=\(requestID, privacy: .public) component=apple-books-library outcome=rejected reason=capability_already_present"
            )
            throw AudiobookImportError.incompatibleCompanion
        }
        do {
            let added = try AudiobookImportService.addCompanionFiles([location], to: bookFolder)
            appleBooksLog.info(
                "apple_books_companion_finished message=apple_books_companion_finished requestId=\(requestID, privacy: .public) component=apple-books-library outcome=success added_count=\(added.count, privacy: .public)"
            )
            return added
        } catch {
            appleBooksLog.error(
                "apple_books_companion_finished message=apple_books_companion_finished requestId=\(requestID, privacy: .public) component=apple-books-library outcome=failure error_type=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw error
        }
    }

    /// Metadata-only sync rows deliberately have no local path. Materialize one
    /// under the configured library before attaching Apple Books media.
    func addCompanion(
        _ item: MacAppleBookItem,
        to book: Book,
        in libraryRoot: URL,
        required: MacAppleBooksCompanionRequirement
    ) throws -> [String] {
        guard book.folderPath.isEmpty else {
            return try addCompanion(
                item,
                to: URL(fileURLWithPath: book.folderPath, isDirectory: true),
                required: required
            )
        }
        guard item.canImport, let location = item.location else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        guard required.accepts(item.kind) else {
            throw AudiobookImportError.incompatibleCompanion
        }
        return try AudiobookImportService.addCompanionFiles(
            [location],
            to: book,
            in: libraryRoot
        ).addedFileNames
    }

    private func containsMedia(of kind: MacAppleBookItem.Kind, in folder: URL) -> Bool {
        mediaURLs(of: kind, in: folder).isEmpty == false
    }

    private func isExactRepeat(
        _ source: URL,
        kind: MacAppleBookItem.Kind,
        in folder: URL
    ) throws -> Bool {
        let sourceIsRegular = try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        guard sourceIsRegular else { return false }
        let sourceDigest = try AudiobookImportService.fileDigest(source)
        return try mediaURLs(of: kind, in: folder).contains { candidate in
            let candidateIsRegular = try candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            guard candidateIsRegular else { return false }
            return try AudiobookImportService.fileDigest(candidate) == sourceDigest
        }
    }

    private func mediaURLs(of kind: MacAppleBookItem.Kind, in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let supported = kind == .audiobook ? LibraryScanner.audioExt : LibraryScanner.ebookExt
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, supported.contains(url.pathExtension.lowercased()) else { return nil }
            return url
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
