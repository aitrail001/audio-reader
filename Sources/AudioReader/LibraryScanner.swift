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
        let epubs = files.filter { $0.pathExtension.lowercased() == "epub" }
        guard !audio.isEmpty || !epubs.isEmpty else { return nil }

        let structure = epubs.first.flatMap { EPUBParser.structure(from: $0.path) }
        let chapters: [Chapter]
        if audio.isEmpty {
            if let structure, !structure.chapters.isEmpty {
                chapters = structure.chapters.enumerated().map { idx, part in
                    Chapter(
                        id: stableID(persistentPathIdentity(folder.path) + "#ebook#" + part.locator),
                        index: idx,
                        title: part.title,
                        audioPath: "",
                        duration: nil,
                        ebookLocator: part.locator
                    )
                }
            } else {
                chapters = [
                    Chapter(
                        id: stableID(persistentPathIdentity(folder.path) + "#ebook"),
                        index: 0,
                        title: "Text",
                        audioPath: "",
                        duration: nil
                    )
                ]
            }
        } else {
            let chapterMP3s = audio
                .filter { $0.pathExtension.lowercased() == "mp3" }
                .filter { !$0.path.lowercased().contains("/ebook") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            let numbered = chapterMP3s.filter {
                !$0.deletingLastPathComponent().lastPathComponent.contains("不分章节")
            }
            let resolvedChapters: [URL]
            if numbered.count >= 2 {
                resolvedChapters = numbered
            } else if !chapterMP3s.isEmpty {
                resolvedChapters = chapterMP3s
            } else {
                resolvedChapters = audio.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
            }
            chapters = resolvedChapters.enumerated().map { idx, url in
                Chapter(
                    id: stableID(url.path),
                    index: idx,
                    title: prettyChapterTitle(url, index: idx),
                    audioPath: url.path,
                    duration: nil
                )
            }
        }
        guard !chapters.isEmpty else { return nil }

        let covers = files.filter { coverExt.contains($0.pathExtension.lowercased()) }
        let m4bs = audio.filter { $0.pathExtension.lowercased() == "m4b" }
        let folderName = folder.lastPathComponent
        let title = prettyBookTitle(folderName: folderName, m4b: m4bs.first, epub: epubs.first)
        let author = guessAuthor(from: m4bs.first) ?? guessAuthor(from: epubs.first) ?? structure?.author
        let source = sourceMarker(in: folder)
        let markedTitle = textMarker(named: ".audioreader-title", in: folder)
        let markedAuthor = textMarker(named: ".audioreader-author", in: folder)
        var coverPath = covers.first?.path
        if coverPath == nil, let image = structure?.cover ?? epubs.first.flatMap({ EPUBParser.coverImage(from: $0.path) }) {
            coverPath = try? EmbeddedArtwork.store(image.data, in: folder).path
        }

        return Book(
            id: stableID(folder.path),
            title: markedTitle ?? structure?.title ?? title,
            author: markedAuthor ?? author,
            folderPath: folder.path,
            coverPath: coverPath,
            ebookPath: epubs.first?.path,
            chapters: chapters,
            source: source
        )
    }

    static func loadDurations(for book: Book) async -> Book {
        var copy = book
        let folder = URL(fileURLWithPath: copy.folderPath, isDirectory: true)
        if copy.coverPath == nil,
           let audioPath = copy.chapters.first(where: \.hasAudio)?.audioPath,
           let artwork = await EmbeddedArtwork.extract(from: URL(fileURLWithPath: audioPath)),
           let cover = try? EmbeddedArtwork.store(
               artwork,
               in: folder
           ) {
            copy.coverPath = cover.path
        }
        if copy.chapters.count == 1,
           let audioPath = copy.chapters.first(where: \.hasAudio)?.audioPath {
            let persisted = M4BChapterExtractor.load(in: folder)
            if !persisted.isEmpty {
                copy.chapters = M4BChapterExtractor.makeChapters(audioPath: audioPath, metadata: persisted)
                return copy
            }
        }
        var loaded: [Chapter] = []
        for chapter in copy.chapters {
            guard chapter.hasAudio else {
                loaded.append(chapter)
                continue
            }
            let url = URL(fileURLWithPath: chapter.audioPath)
            if ["m4a", "m4b"].contains(url.pathExtension.lowercased()) {
                let embedded = await M4BChapterExtractor.extract(from: url)
                if !embedded.isEmpty {
                    loaded.append(contentsOf: M4BChapterExtractor.makeChapters(audioPath: url.path, metadata: embedded))
                    continue
                }
            }
            var updated = chapter
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                updated.duration = duration.seconds
            }
            loaded.append(updated)
        }
        copy.chapters = loaded.enumerated().map { index, chapter in
            var updated = chapter
            updated.index = index
            return updated
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
        if let epub {
            let base = epub.deletingPathExtension().lastPathComponent
            if !base.isEmpty { return cleanTitle(base) }
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
        SHA256.hash(data: Data(persistentPathIdentity(path).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func legacyAbsolutePathID(for book: Book) -> String {
        SHA256.hash(data: Data(book.folderPath.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func legacyAbsolutePathID(for chapter: Chapter) -> String {
        let identity = chapter.startTime.map { "\(chapter.audioPath)#\(String(format: "%.3f", $0))" }
            ?? chapter.audioPath
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func persistentPathIdentity(_ path: String) -> String {
        let marker = "/ImportedBooks/"
        guard let range = path.range(of: marker) else { return path }
        return "ImportedBooks/" + path[range.upperBound...]
    }

    static func containsAudio(in folder: URL) -> Bool {
        allFiles(in: folder).contains { audioExt.contains($0.pathExtension.lowercased()) }
    }

    static func containsEbook(in folder: URL) -> Bool {
        allFiles(in: folder).contains { ebookExt.contains($0.pathExtension.lowercased()) }
    }

    static func containsImportableBook(in folder: URL) -> Bool {
        containsAudio(in: folder) || containsEbook(in: folder)
    }

    private static func sourceMarker(in folder: URL) -> BookSource {
        guard let raw = textMarker(named: ".audioreader-source", in: folder),
              let source = BookSource(rawValue: raw)
        else { return .localFolder }
        return source
    }

    private static func textMarker(named name: String, in folder: URL) -> String? {
        guard let raw = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
