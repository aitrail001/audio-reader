import Foundation
import AVFoundation
import CryptoKit

enum LibraryScanner {
    static let audioExt: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "caf"]
    static let ebookExt: Set<String> = ["epub"]
    static let coverExt: Set<String> = ["jpg", "jpeg", "png", "webp"]

    static func scan(root: URL) -> [Book] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var books: [Book] = []
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let book = book(from: entry) {
                books.append(book)
            }
        }
        return books
    }

    private static func book(from folder: URL) -> Book? {
        let files = allFiles(in: folder)
        let audio = files.filter { audioExt.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { return nil }

        let chapterMP3s = audio
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .filter { !$0.path.lowercased().contains("/ebook") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let m4bs = audio.filter { $0.pathExtension.lowercased() == "m4b" }

        let numbered = chapterMP3s.filter {
            !$0.deletingLastPathComponent().lastPathComponent.contains("不分章节")
        }
        let resolvedChapters: [URL]
        if numbered.count >= 2 {
            resolvedChapters = numbered
        } else if !chapterMP3s.isEmpty {
            resolvedChapters = chapterMP3s
        } else {
            resolvedChapters = m4bs
        }

        let chapters = resolvedChapters.enumerated().map { idx, url in
            Chapter(
                id: stableID(url.path),
                index: idx,
                title: prettyChapterTitle(url, index: idx),
                audioPath: url.path,
                duration: nil
            )
        }
        guard !chapters.isEmpty else { return nil }

        let epubs = files.filter { $0.pathExtension.lowercased() == "epub" }
        let covers = files.filter { coverExt.contains($0.pathExtension.lowercased()) }

        let folderName = folder.lastPathComponent
        let title = prettyBookTitle(folderName: folderName, m4b: m4bs.first, epub: epubs.first)
        let author = guessAuthor(from: m4bs.first) ?? guessAuthor(from: epubs.first)

        return Book(
            id: stableID(folder.path),
            title: title,
            author: author,
            folderPath: folder.path,
            coverPath: covers.first?.path,
            ebookPath: epubs.first?.path,
            chapters: chapters
        )
    }

    static func loadDurations(for book: Book) async -> Book {
        var copy = book
        for i in copy.chapters.indices {
            let url = URL(fileURLWithPath: copy.chapters[i].audioPath)
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                copy.chapters[i].duration = duration.seconds
            }
        }
        return copy
    }

    private static func allFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            out.append(url)
        }
        return out
    }

    private static func prettyBookTitle(folderName: String, m4b: URL?, epub: URL?) -> String {
        if let m4b {
            let base = m4b.deletingPathExtension().lastPathComponent
            if let range = base.range(of: " - ") {
                let head = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if head.count >= 4 { return head }
            }
        }
        return cleanTitle(folderName)
    }

    private static func cleanTitle(_ raw: String) -> String {
        var t = raw
        t = t.replacingOccurrences(of: #"\s*\(Unabridged\)\s*"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? raw : t
    }

    private static func prettyChapterTitle(_ url: URL, index: Int) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        if let regex = try? NSRegularExpression(pattern: #"^(\d+)"#),
           let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let range = Range(match.range(at: 1), in: raw),
           let n = Int(raw[range]) {
            return "Chapter \(n)"
        }
        return "Chapter \(index + 1)"
    }

    private static func guessAuthor(from url: URL?) -> String? {
        guard let url else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        if let range = base.range(of: " - ", options: .backwards) {
            let author = String(base[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if author.count > 2 && author.count < 60 { return author }
        }
        return nil
    }

    static func stableID(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
