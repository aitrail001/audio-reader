import Foundation

enum BookContentsTab: String, CaseIterable, Identifiable, Sendable {
    case contents
    case bookmarks
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contents: "Contents"
        case .bookmarks: "Bookmarks"
        case .search: "Search"
        }
    }
}

struct ReadingPosition: Codable, Equatable, Sendable, Identifiable {
    var bookID: String
    var chapterID: String
    var segmentID: String?
    var updatedAt: Date

    var id: String { bookID }
}

struct ReadingBookmark: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var bookID: String
    var chapterID: String
    var chapterTitle: String
    var segmentID: String?
    var snippet: String
    var createdAt: Date

    func matches(bookID: String, chapterID: String, segmentID: String?) -> Bool {
        self.bookID == bookID
            && self.chapterID == chapterID
            && self.segmentID == segmentID
    }

    static func makeID(bookID: String, chapterID: String, segmentID: String?) -> String {
        [bookID, chapterID, segmentID ?? ""].joined(separator: "#")
    }
}

struct BookSearchHit: Equatable, Identifiable, Sendable {
    var chapterID: String
    var chapterTitle: String
    var segmentID: String?
    var snippet: String

    var id: String { "\(chapterID)#\(segmentID ?? "")#\(snippet)" }
}

enum BookSearch {
    static func hits(
        query: String,
        chapters: [Chapter],
        transcriptsByChapterID: [String: Transcript],
        epubTextByLocator: [String: String]
    ) -> [BookSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 1 else { return [] }
        var hits: [BookSearchHit] = []
        for chapter in chapters where !chapter.isCover {
            if let transcript = transcriptsByChapterID[chapter.id] {
                for segment in transcript.segments {
                    let text = segment.displayText
                    if let snippet = snippet(in: text, matching: needle) {
                        hits.append(BookSearchHit(
                            chapterID: chapter.id,
                            chapterTitle: chapter.title,
                            segmentID: segment.id,
                            snippet: snippet
                        ))
                    }
                    if hits.count >= 50 { return hits }
                }
                continue
            }
            if let locator = chapter.ebookLocator,
               let text = epubTextByLocator[locator],
               let snippet = snippet(in: text, matching: needle) {
                hits.append(BookSearchHit(
                    chapterID: chapter.id,
                    chapterTitle: chapter.title,
                    segmentID: nil,
                    snippet: snippet
                ))
            }
            if hits.count >= 50 { return hits }
        }
        return hits
    }

    static func snippet(in text: String, matching query: String, radius: Int = 42) -> String? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start != text.startIndex { snippet = "…" + snippet }
        if end != text.endIndex { snippet += "…" }
        return snippet
    }
}

struct ReadingProgress: Equatable, Sendable {
    var chapterIndex: Int
    var chapterCount: Int
    var segmentIndex: Int
    var segmentCount: Int

    var chapterFraction: Double {
        guard segmentCount > 0 else { return 0 }
        return min(1, Double(segmentIndex) / Double(segmentCount))
    }

    var bookFraction: Double {
        guard chapterCount > 0 else { return 0 }
        return min(1, (Double(chapterIndex) + chapterFraction) / Double(chapterCount))
    }

    var caption: String {
        if chapterCount <= 1, segmentCount == 0 { return "Cover" }
        if chapterCount <= 1 {
            return segmentCount == 0 ? "Cover" : "\(min(segmentIndex + 1, segmentCount)) of \(segmentCount)"
        }
        if segmentCount == 0 { return chapterIndex == 0 ? "Cover" : "Chapter \(chapterIndex + 1) of \(chapterCount)" }
        return "Chapter \(chapterIndex + 1) of \(chapterCount)"
    }

    static func make(
        chapterIndex: Int,
        chapterCount: Int,
        segmentIndex: Int,
        segmentCount: Int
    ) -> ReadingProgress {
        ReadingProgress(
            chapterIndex: max(0, chapterIndex),
            chapterCount: max(0, chapterCount),
            segmentIndex: max(0, segmentIndex),
            segmentCount: max(0, segmentCount)
        )
    }
}
