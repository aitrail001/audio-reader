import Foundation

enum AppleBooksMediaKind: String, Equatable, Sendable {
    case ebook
    case audiobook
}

struct AppleBooksCatalogRecord: Equatable, Sendable {
    var id: String
    var title: String
    var author: String
    var path: URL
    var bookType: String
    var kind: AppleBooksMediaKind
}

struct AppleBooksEbookRecord: Equatable, Sendable {
    var id: String
    var title: String
    var author: String
    var path: URL
    var bookType: String
}

struct AppleBooksListedItem: Equatable, Sendable {
    var id: String
    var title: String
    var author: String
    var path: URL
    var kind: AppleBooksMediaKind
    var isMissing: Bool
}

enum AppleBooksCatalog {
    static func records(fromPlist data: Data) throws -> [AppleBooksCatalogRecord] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = object as? [String: Any] else { return [] }
        let books = (root["Books"] as? [[String: Any]]) ?? []
        return books.compactMap(record(from:))
    }

    private static func record(from item: [String: Any]) -> AppleBooksCatalogRecord? {
        let type = ((item["BKBookType"] as? String) ?? "").lowercased()
        let kind: AppleBooksMediaKind
        if type == "audiobook" {
            kind = .audiobook
        } else if type == "epub" || type == "ebook" || type == "book" {
            kind = .ebook
        } else {
            return nil
        }
        guard let path = item["path"] as? String, !path.isEmpty else { return nil }
        let title = string(from: item, keys: ["itemName", "BKDisplayName", "BKTrackTitle"])
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let author = string(from: item, keys: ["artistName", "BKArtistName"]) ?? "Unknown author"
        let id = string(from: item, keys: ["BKGeneratedItemId"]) ?? path
        return AppleBooksCatalogRecord(
            id: id,
            title: title,
            author: author,
            path: URL(fileURLWithPath: path),
            bookType: type,
            kind: kind
        )
    }

    private static func string(from item: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = item[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

enum AppleBooksEbookCatalog {
    static func records(fromPlist data: Data) throws -> [AppleBooksEbookRecord] {
        try AppleBooksCatalog.records(fromPlist: data).compactMap { record in
            guard record.kind == .ebook else { return nil }
            return AppleBooksEbookRecord(
                id: record.id,
                title: record.title,
                author: record.author,
                path: record.path,
                bookType: record.bookType
            )
        }
    }
}

enum AppleBooksLocalLibrary {
    private static let audioExt: Set<String> = ["m4b", "m4a", "mp3"]

    static func list(booksRoot: URL, iCloudRoot: URL? = nil) -> [AppleBooksListedItem] {
        var byID: [String: AppleBooksListedItem] = [:]
        var seenPaths = Set<String>()

        func add(_ item: AppleBooksListedItem) {
            let pathKey = item.path.standardizedFileURL.path
            if seenPaths.contains(pathKey) { return }
            seenPaths.insert(pathKey)
            if byID[item.id] == nil {
                byID[item.id] = item
            } else {
                byID[item.id + "::" + pathKey] = item
            }
        }

        let plistURL = booksRoot.appendingPathComponent("Books.plist")
        if let data = try? Data(contentsOf: plistURL),
           let records = try? AppleBooksCatalog.records(fromPlist: data) {
            for record in records {
                add(listedItem(from: record))
            }
        }
        for url in ebookPackageURLs(in: booksRoot) {
            add(
                AppleBooksListedItem(
                    id: url.path,
                    title: displayTitle(for: url),
                    author: "Unknown author",
                    path: url,
                    kind: .ebook,
                    isMissing: false
                )
            )
        }
        for url in audioURLs(in: booksRoot.appendingPathComponent("Audiobooks", isDirectory: true)) {
            add(
                AppleBooksListedItem(
                    id: url.path,
                    title: displayTitle(for: url),
                    author: "Unknown author",
                    path: url,
                    kind: .audiobook,
                    isMissing: false
                )
            )
        }
        if let iCloudRoot {
            for url in ebookPackageURLs(in: iCloudRoot) {
                add(
                    AppleBooksListedItem(
                        id: url.path,
                        title: displayTitle(for: url),
                        author: "Unknown author",
                        path: url,
                        kind: .ebook,
                        isMissing: false
                    )
                )
            }
        }
        return byID.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func audioFile(in folder: URL) -> URL? {
        audioURLs(in: folder).first
    }

    private static func listedItem(from record: AppleBooksCatalogRecord) -> AppleBooksListedItem {
        switch record.kind {
        case .ebook:
            let exists = FileManager.default.fileExists(atPath: record.path.path)
            return AppleBooksListedItem(
                id: record.id,
                title: record.title,
                author: record.author,
                path: record.path,
                kind: .ebook,
                isMissing: !exists
            )
        case .audiobook:
            if let file = resolvedAudioFile(at: record.path) {
                return AppleBooksListedItem(
                    id: record.id,
                    title: record.title,
                    author: record.author,
                    path: file,
                    kind: .audiobook,
                    isMissing: false
                )
            }
            return AppleBooksListedItem(
                id: record.id,
                title: record.title,
                author: record.author,
                path: record.path,
                kind: .audiobook,
                isMissing: true
            )
        }
    }

    private static func resolvedAudioFile(at url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return audioFile(in: url)
        }
        return audioExt.contains(url.pathExtension.lowercased()) ? url : nil
    }

    private static func ebookPackageURLs(in root: URL) -> [URL] {
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

    private static func audioURLs(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { audioExt.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func displayTitle(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if let range = base.range(of: " - ") {
            let head = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if head.count >= 4 { return head }
        }
        return base
    }
}
