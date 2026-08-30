import Foundation

struct AppleBooksEbookRecord: Equatable, Sendable {
    var id: String
    var title: String
    var author: String
    var path: URL
    var bookType: String
}

enum AppleBooksEbookCatalog {
    static func records(fromPlist data: Data) throws -> [AppleBooksEbookRecord] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = object as? [String: Any] else { return [] }
        let books = (root["Books"] as? [[String: Any]]) ?? []
        return books.compactMap(record(from:))
    }

    private static func record(from item: [String: Any]) -> AppleBooksEbookRecord? {
        let type = ((item["BKBookType"] as? String) ?? "").lowercased()
        guard type == "epub" || type == "ebook" || type == "book" else { return nil }
        guard let path = item["path"] as? String, !path.isEmpty else { return nil }
        let title = string(from: item, keys: ["itemName", "BKDisplayName", "BKTrackTitle"])
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let author = string(from: item, keys: ["artistName", "BKArtistName"]) ?? "Unknown author"
        let id = string(from: item, keys: ["BKGeneratedItemId"]) ?? path
        return AppleBooksEbookRecord(
            id: id,
            title: title,
            author: author,
            path: URL(fileURLWithPath: path),
            bookType: type
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
