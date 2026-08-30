#if os(macOS)
import AppKit
import AVFoundation
import Foundation

enum MacAppleBookKind: String, Hashable, Sendable {
    case audiobook
    case ebook
}

struct MacAppleBookItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var author: String
    var duration: TimeInterval
    var location: URL?
    var artworkData: Data?
    var isProtected: Bool
    var isCloud: Bool
    var kind: MacAppleBookKind = .audiobook

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
        isLoading = true
        defer { isLoading = false }
        items = await Task.detached(priority: .userInitiated) {
            await Self.loadItems()
        }.value
        let audiobooks = items.filter { $0.kind == .audiobook }
        let ebooks = items.filter { $0.kind == .ebook }
        let availableAudio = audiobooks.filter(\.canImport).count
        let availableEbooks = ebooks.filter(\.canImport).count
        let unavailable = items.count - availableAudio - availableEbooks
        if unavailable > 0 {
            message = "Found \(availableAudio) importable audiobooks, \(availableEbooks) importable EPUBs, and \(unavailable) protected or unreadable titles."
        } else {
            message = "Found \(availableAudio) downloaded audiobooks and \(availableEbooks) EPUBs in Apple Books."
        }
    }

    nonisolated private static func loadItems() async -> [MacAppleBookItem] {
        let booksRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books")
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")
        let listed = AppleBooksLocalLibrary.list(booksRoot: booksRoot, iCloudRoot: iCloud)
        var items: [MacAppleBookItem] = []
        items.reserveCapacity(listed.count)
        for entry in listed {
            switch entry.kind {
            case .audiobook:
                items.append(await audiobookItem(from: entry))
            case .ebook:
                items.append(ebookItem(from: entry))
            }
        }
        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func audiobookItem(from entry: AppleBooksListedItem) async -> MacAppleBookItem {
        guard !entry.isMissing, FileManager.default.fileExists(atPath: entry.path.path) else {
            return MacAppleBookItem(
                id: entry.id,
                title: entry.title,
                author: entry.author,
                duration: 0,
                location: entry.path,
                artworkData: nil,
                isProtected: false,
                isCloud: true,
                kind: .audiobook
            )
        }
        do {
            var item = try await item(for: entry.path)
            item.id = entry.id
            item.title = entry.title
            if entry.author != "Unknown author" {
                item.author = entry.author
            }
            item.kind = .audiobook
            return item
        } catch {
            return MacAppleBookItem(
                id: entry.id,
                title: entry.title,
                author: entry.author,
                duration: 0,
                location: entry.path,
                artworkData: nil,
                isProtected: true,
                isCloud: false,
                kind: .audiobook
            )
        }
    }

    nonisolated private static func item(for url: URL) async throws -> MacAppleBookItem {
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

    nonisolated private static func metadataString(
        _ identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async throws -> String? {
        let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
        return try await item?.load(.stringValue)
    }

    nonisolated private static func ebookItem(from entry: AppleBooksListedItem) -> MacAppleBookItem {
        let exists = !entry.isMissing && FileManager.default.fileExists(atPath: entry.path.path)
        let metadata = exists && (entry.title.isEmpty || entry.author == "Unknown author")
            ? EPUBParser.metadata(from: entry.path.path)
            : nil
        let cover = exists ? EPUBParser.coverImage(from: entry.path.path) : nil
        return MacAppleBookItem(
            id: entry.id,
            title: entry.title.isEmpty ? (metadata?.title ?? entry.path.deletingPathExtension().lastPathComponent) : entry.title,
            author: entry.author == "Unknown author" ? (metadata?.author ?? entry.author) : entry.author,
            duration: 0,
            location: entry.path,
            artworkData: cover?.data,
            isProtected: false,
            isCloud: !exists,
            kind: .ebook
        )
    }

    @discardableResult
    func importAudiobook(
        _ item: MacAppleBookItem,
        into libraryRoot: URL,
        existing: ExistingBookImport = .skip
    ) throws -> AudiobookImportResult {
        guard item.canImport, let location = item.location else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        let result = try AudiobookImportService.importFiles(
            [location],
            into: libraryRoot,
            existing: existing
        )
        if result.outcome == .alreadyImported {
            return .init(
                folder: result.folder,
                createdBook: false,
                addedFileNames: [],
                outcome: .alreadyImported,
                title: item.title
            )
        }
        let folder = result.folder
        try AudiobookImportService.writeMarkers(
            source: .deviceAudiobooks,
            title: item.title,
            author: item.author,
            to: folder
        )
        if let artworkData = item.artworkData {
            try artworkData.write(to: folder.appendingPathComponent("cover.jpg"), options: .atomic)
        }
        return .init(
            folder: folder,
            createdBook: result.createdBook,
            addedFileNames: result.addedFileNames,
            outcome: result.outcome,
            title: item.title
        )
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
