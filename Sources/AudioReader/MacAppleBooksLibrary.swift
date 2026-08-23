#if os(macOS)
import AppKit
import AVFoundation
import Foundation

struct MacAppleBookItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var author: String
    var duration: TimeInterval
    var location: URL?
    var artworkData: Data?
    var isProtected: Bool
    var isCloud: Bool

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
        do {
            items = try await Task.detached(priority: .userInitiated) {
                try await Self.readDownloadedAudiobooks()
            }.value
            let available = items.filter(\.canImport).count
            let unavailable = items.count - available
            message = unavailable > 0
                ? "Found \(available) importable and \(unavailable) protected audiobooks downloaded by Apple Books."
                : "Found \(available) downloaded audiobooks in Apple Books."
        } catch {
            items = []
            message = "Downloaded Apple Books audiobooks could not be read: \(error.localizedDescription)"
        }
    }

    nonisolated private static func readDownloadedAudiobooks() async throws -> [MacAppleBookItem] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books/Audiobooks")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let supported = Set(["m4b", "m4a", "mp3"])
        let urls = enumerator.compactMap { $0 as? URL }.filter { url in
            supported.contains(url.pathExtension.lowercased())
        }
        var found: [MacAppleBookItem] = []
        for url in urls {
            found.append(try await item(for: url))
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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
            isCloud: false
        )
    }

    nonisolated private static func metadataString(
        _ identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async throws -> String? {
        let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
        return try await item?.load(.stringValue)
    }

    func importAudiobook(_ item: MacAppleBookItem, into libraryRoot: URL) throws {
        guard item.canImport, let location = item.location else {
            throw AudiobookImportError.protectedOrUnavailable
        }
        let result = try AudiobookImportService.importFiles([location], into: libraryRoot)
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
