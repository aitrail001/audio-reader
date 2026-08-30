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
        do {
            items = try await Task.detached(priority: .userInitiated) {
                let audio = try await Self.readDownloadedAudiobooks()
                let ebooks = Self.readDownloadedEbooks()
                return audio + ebooks
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
        } catch {
            items = []
            message = "Downloaded Apple Books titles could not be read: \(error.localizedDescription)"
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

    nonisolated private static func readDownloadedEbooks() -> [MacAppleBookItem] {
        var byPath: [String: MacAppleBookItem] = [:]
        let booksRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books")
        let plistURL = booksRoot.appendingPathComponent("Books.plist")
        if let data = try? Data(contentsOf: plistURL),
           let records = try? AppleBooksEbookCatalog.records(fromPlist: data) {
            for record in records {
                byPath[record.path.path] = ebookItem(from: record)
            }
        }
        for url in ebookPackageURLs(in: booksRoot) {
            if byPath[url.path] == nil {
                byPath[url.path] = ebookItem(at: url, id: url.path, title: nil, author: nil)
            }
        }
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")
        for url in ebookPackageURLs(in: iCloud) {
            if byPath[url.path] == nil {
                byPath[url.path] = ebookItem(at: url, id: url.path, title: nil, author: nil)
            }
        }
        return byPath.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func ebookPackageURLs(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.path.contains("/Audiobooks/") { continue }
            guard url.pathExtension.lowercased() == "epub" else { continue }
            urls.append(url)
            if EPUBParser.isPackage(at: url) {
                enumerator.skipDescendants()
            }
        }
        return urls
    }

    nonisolated private static func ebookItem(from record: AppleBooksEbookRecord) -> MacAppleBookItem {
        ebookItem(at: record.path, id: record.id, title: record.title, author: record.author)
    }

    nonisolated private static func ebookItem(
        at url: URL,
        id: String,
        title: String?,
        author: String?
    ) -> MacAppleBookItem {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let document = exists ? EPUBParser.document(from: url.path) : nil
        return MacAppleBookItem(
            id: id,
            title: title ?? document?.title ?? url.deletingPathExtension().lastPathComponent,
            author: author ?? document?.author ?? "Unknown author",
            duration: 0,
            location: url,
            artworkData: nil,
            isProtected: exists && document == nil,
            isCloud: !exists,
            kind: .ebook
        )
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
