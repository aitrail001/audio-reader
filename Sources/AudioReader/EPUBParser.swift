import Foundation
import ZIPFoundation

struct EPUBDocument: Equatable, Sendable {
    var text: String
    var title: String?
    var author: String?

    var wordCount: Int { Aligner.tokenize(text).count }
    var sentenceCount: Int { EPUBParser.sentences(from: text).count }
}

struct EPUBBookMetadata: Equatable, Sendable {
    var title: String
    var author: String?
}

struct EPUBCoverImage: Equatable, Sendable {
    var data: Data
    var fileExtension: String
}

struct EPUBChapter: Equatable, Sendable {
    var title: String
    var locator: String
    var text: String
    var isCover: Bool
}

struct EPUBStructure: Equatable, Sendable {
    var title: String?
    var author: String?
    var chapters: [EPUBChapter]
    var cover: EPUBCoverImage?

    var bodyText: String {
        chapters.filter { !$0.isCover }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

enum EPUBParser {
    static let coverLocator = "cover"

    static func extractText(from epubPath: String) -> String? {
        document(from: epubPath)?.text
    }

    static func isPackage(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        let meta = url.appendingPathComponent("META-INF/container.xml")
        let mimetype = url.appendingPathComponent("mimetype")
        return FileManager.default.fileExists(atPath: meta.path)
            || FileManager.default.fileExists(atPath: mimetype.path)
    }

    static func document(from epubPath: String) -> EPUBDocument? {
        withPackageRoot(epubPath) { document(fromPackageRoot: $0) }
    }

    static func structure(from epubPath: String) -> EPUBStructure? {
        withPackageRoot(epubPath) { structure(fromPackageRoot: $0) }
    }

    static func coverImage(from epubPath: String) -> EPUBCoverImage? {
        withPackageRoot(epubPath) { coverImage(in: $0) }
    }

    static func packageFile(from source: URL, to destination: URL) throws {
        if isPackage(at: source) {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.zipItem(
                at: source,
                to: destination,
                shouldKeepParent: false,
                compressionMethod: .deflate
            )
            return
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func sentences(from text: String) -> [String] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        let tokenizer = NLWrapper()
        tokenizer.enumerateSentences(in: text) { range in
            ranges.append(range)
        }
        if ranges.isEmpty {
            return text
                .components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { Aligner.tokenize($0).count >= 4 }
        }
        return ranges.compactMap { range -> String? in
            let s = ns.substring(with: range)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Aligner.tokenize(s).count >= 4 ? s : nil
        }
    }

    private static func withPackageRoot<T>(_ epubPath: String, _ body: (URL) -> T?) -> T? {
        let epub = URL(fileURLWithPath: epubPath)
        guard FileManager.default.fileExists(atPath: epub.path) else { return nil }
        if isPackage(at: epub) {
            return body(epub)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        guard (try? FileManager.default.unzipItem(at: epub, to: tmp)) != nil else { return nil }
        return body(tmp)
    }

    private static func document(fromPackageRoot root: URL) -> EPUBDocument? {
        let htmls = contentDocuments(in: root)
        var parts: [String] = []
        for file in htmls {
            let raw = (try? String(contentsOf: file, encoding: .utf8))
                ?? (try? String(contentsOf: file, encoding: .isoLatin1))
            guard let raw else { continue }
            let text = stripHTML(raw)
            if isBoilerplate(text) { continue }
            parts.append(text)
        }
        let joined = parts.joined(separator: "\n\n")
        guard !joined.isEmpty else { return nil }
        let metadata = packageMetadata(in: root)
        return EPUBDocument(text: joined, title: metadata.title, author: metadata.author)
    }

    private static func structure(fromPackageRoot root: URL) -> EPUBStructure? {
        let package = parsePackage(in: root)
        let metadata = packageMetadata(in: root)
        let cover = coverImage(in: root, package: package)
        var chapters = tocChapters(in: root, package: package)
        if chapters.isEmpty {
            chapters = spineChapters(in: root, package: package)
        }
        if chapters.isEmpty {
            chapters = fallbackChapters(in: root)
        }
        if cover != nil, chapters.first?.isCover != true {
            chapters.insert(
                EPUBChapter(title: "Cover", locator: coverLocator, text: "", isCover: true),
                at: 0
            )
        }
        if chapters.isEmpty, cover == nil, metadata.title == nil, metadata.author == nil {
            return nil
        }
        guard !chapters.isEmpty else { return nil }
        return EPUBStructure(
            title: metadata.title,
            author: metadata.author,
            chapters: chapters,
            cover: cover
        )
    }

    private static func contentDocuments(in root: URL) -> [URL] {
        let skipBits = ["toc", "nav", "ncx", "cover", "cvi", "cop", "copyright", "ded", "ack", "next-reads", "landmarks"]
        let fm = FileManager.default
        let spine = spineHrefs(in: root)
        if !spine.isEmpty {
            return spine.compactMap { href -> URL? in
                let name = href.lowercased()
                if skipBits.contains(where: { name.contains($0) }) { return nil }
                let url = resolve(href: href, in: root)
                return url.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            }
        }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "xhtml" || ext == "html" || ext == "htm" else { continue }
            let name = url.lastPathComponent.lowercased()
            if skipBits.contains(where: { name.contains($0) }) { continue }
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func spineHrefs(in root: URL) -> [String] {
        parsePackage(in: root).spineHrefs
    }

    private static func packageMetadata(in root: URL) -> (title: String?, author: String?) {
        guard let xml = parsePackage(in: root).opfXML else { return (nil, nil) }
        return (
            firstElement(named: "title", in: xml),
            firstElement(named: "creator", in: xml)
        )
    }

    private static func firstElement(named localName: String, in xml: String) -> String? {
        let pattern = #"<(?:(?:[A-Za-z0-9_-]+):)?\#(localName)\b[^>]*>([\s\S]*?)</(?:(?:[A-Za-z0-9_-]+):)?\#(localName)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: xml)
        else { return nil }
        let value = stripHTML(String(xml[range]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func resolve(href: String, in root: URL) -> URL? {
        let fm = FileManager.default
        let decoded = href.removingPercentEncoding ?? href
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            let needle = decoded.split(separator: "/").last.map(String.init)?.lowercased()
            for case let url as URL in enumerator {
                if url.lastPathComponent.lowercased() == needle { return url }
                if url.path.lowercased().hasSuffix(decoded.lowercased()) { return url }
            }
        }
        return nil
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</p>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</div>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</h[1-6]>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#160;", with: " ")
        s = s.replacingOccurrences(of: "&#x00A0;", with: " ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&#x2019;", with: "'", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&#x2018;", with: "'", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&#x201C;", with: "\"", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&#x201D;", with: "\"", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&apos;", with: "'")
        s = s.replacingOccurrences(of: #"\r"#, with: "")
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBoilerplate(_ text: String) -> Bool {
        let lower = text.lowercased()
        if text.count < 80 { return true }
        if lower.contains("table of contents") && text.count < 1500 { return true }
        if lower.contains("copyright") && text.count < 400 { return true }
        return false
    }

    private struct PackageIndex {
        var opfXML: String?
        var itemsByID: [String: ManifestItem] = [:]
        var spineHrefs: [String] = []
        var coverID: String?
    }

    private struct ManifestItem {
        var id: String
        var href: String
        var mediaType: String
        var properties: String
    }

    private struct TOCEntry {
        var title: String
        var href: String
        var fragment: String?
        var locator: String
        var fileKey: String
    }

    private static func parsePackage(in root: URL) -> PackageIndex {
        guard let opf = firstFile(in: root, extension: "opf"),
              let xml = (try? String(contentsOf: opf, encoding: .utf8))
                ?? (try? String(contentsOf: opf, encoding: .isoLatin1))
        else { return PackageIndex() }

        var itemsByID: [String: ManifestItem] = [:]
        let itemRegex = try? NSRegularExpression(pattern: #"<item\b([^>]+)/?>"#, options: [.caseInsensitive])
        let ns = xml as NSString
        itemRegex?.matches(in: xml, range: NSRange(location: 0, length: ns.length)).forEach { match in
            guard match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: xml) else { return }
            let attrs = xmlAttributes(String(xml[range]))
            guard let id = attrs["id"], let href = attrs["href"] else { return }
            let decoded = href.removingPercentEncoding ?? href
            itemsByID[id] = ManifestItem(
                id: id,
                href: decoded,
                mediaType: attrs["media-type"] ?? "",
                properties: attrs["properties"] ?? ""
            )
        }

        var spineHrefs: [String] = []
        let spineRegex = try? NSRegularExpression(pattern: #"<itemref\b([^>]+)/?>"#, options: [.caseInsensitive])
        spineRegex?.matches(in: xml, range: NSRange(location: 0, length: ns.length)).forEach { match in
            guard match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: xml) else { return }
            let attrs = xmlAttributes(String(xml[range]))
            guard let idref = attrs["idref"], let href = itemsByID[idref]?.href else { return }
            spineHrefs.append(href)
        }

        var coverID: String?
        let metaRegex = try? NSRegularExpression(pattern: #"<meta\b([^>]+)/?>"#, options: [.caseInsensitive])
        metaRegex?.matches(in: xml, range: NSRange(location: 0, length: ns.length)).forEach { match in
            guard match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: xml) else { return }
            let attrs = xmlAttributes(String(xml[range]))
            if attrs["name"]?.lowercased() == "cover", let content = attrs["content"], !content.isEmpty {
                coverID = content
            }
        }
        if coverID == nil {
            coverID = itemsByID.values.first { $0.properties.lowercased().split(separator: " ").contains("cover-image") }?.id
        }

        return PackageIndex(opfXML: xml, itemsByID: itemsByID, spineHrefs: spineHrefs, coverID: coverID)
    }

    private static func xmlAttributes(_ raw: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][\w:.-]*)\s*=\s*("([^"]*)"|'([^']*)')"#,
            options: []
        )
        let ns = raw as NSString
        regex?.matches(in: raw, range: NSRange(location: 0, length: ns.length)).forEach { match in
            guard match.numberOfRanges >= 2, let nameRange = Range(match.range(at: 1), in: raw) else { return }
            let value: String
            if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound, let range = Range(match.range(at: 3), in: raw) {
                value = String(raw[range])
            } else if match.numberOfRanges > 4, match.range(at: 4).location != NSNotFound, let range = Range(match.range(at: 4), in: raw) {
                value = String(raw[range])
            } else {
                return
            }
            attrs[String(raw[nameRange]).lowercased()] = value
        }
        return attrs
    }

    private static func coverImage(in root: URL) -> EPUBCoverImage? {
        coverImage(in: root, package: parsePackage(in: root))
    }

    private static func coverImage(in root: URL, package: PackageIndex) -> EPUBCoverImage? {
        var href: String?
        if let coverID = package.coverID {
            href = package.itemsByID[coverID]?.href
        }
        if href == nil {
            href = package.itemsByID.values.first {
                $0.properties.lowercased().split(separator: " ").contains("cover-image")
            }?.href
        }
        let url: URL?
        if let href, let resolved = resolve(href: href, in: root) {
            url = resolved
        } else {
            url = firstFile(in: root, named: ["cover.jpg", "cover.jpeg", "cover.png", "cover.webp"])
        }
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let ext: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            ext = "png"
        } else if url.pathExtension.lowercased() == "webp" {
            ext = "webp"
        } else if url.pathExtension.lowercased() == "png" {
            ext = "png"
        } else {
            ext = "jpg"
        }
        return EPUBCoverImage(data: data, fileExtension: ext)
    }

    private static func tocChapters(in root: URL, package: PackageIndex) -> [EPUBChapter] {
        let entries = tocEntries(in: root, package: package)
        guard !entries.isEmpty else { return [] }
        return chapters(from: entries, in: root, package: package)
    }

    private static func spineChapters(in root: URL, package: PackageIndex) -> [EPUBChapter] {
        let skip = ["toc", "nav", "ncx"]
        let entries: [TOCEntry] = package.spineHrefs.compactMap { href in
            let name = fileKey(href)
            if skip.contains(where: { name.contains($0) }) { return nil }
            if name.contains("cover") { return nil }
            guard let url = resolve(href: href, in: root) else { return nil }
            let html = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                ?? ""
            let title = headingTitle(in: html) ?? prettyFallbackTitle(href)
            return makeTOCEntry(title: title, href: href)
        }
        return chapters(from: entries, in: root, package: package)
    }

    private static func fallbackChapters(in root: URL) -> [EPUBChapter] {
        contentDocuments(in: root).enumerated().compactMap { index, url in
            let raw = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            guard let raw else { return nil }
            let text = stripHTML(raw)
            guard !text.isEmpty else { return nil }
            return EPUBChapter(
                title: headingTitle(in: raw) ?? (index == 0 ? "Text" : "Chapter \(index + 1)"),
                locator: url.lastPathComponent,
                text: text,
                isCover: false
            )
        }
    }

    private static func tocEntries(in root: URL, package: PackageIndex) -> [TOCEntry] {
        if let nav = navDocument(in: root, package: package),
           let html = (try? String(contentsOf: nav, encoding: .utf8))
            ?? (try? String(contentsOf: nav, encoding: .isoLatin1)),
           let entries = entriesFromNav(html),
           !entries.isEmpty {
            return uniqueEntries(entries)
        }
        if let ncx = ncxDocument(in: root, package: package),
           let xml = (try? String(contentsOf: ncx, encoding: .utf8))
            ?? (try? String(contentsOf: ncx, encoding: .isoLatin1)) {
            return uniqueEntries(entriesFromNCX(xml))
        }
        return []
    }

    private static func navDocument(in root: URL, package: PackageIndex) -> URL? {
        if let item = package.itemsByID.values.first(where: {
            $0.properties.lowercased().split(separator: " ").contains("nav")
        }) {
            return resolve(href: item.href, in: root)
        }
        return firstFile(in: root, named: ["nav.xhtml", "nav.html", "toc.xhtml"])
    }

    private static func ncxDocument(in root: URL, package: PackageIndex) -> URL? {
        if let item = package.itemsByID.values.first(where: {
            $0.mediaType.lowercased().contains("ncx") || $0.href.lowercased().hasSuffix(".ncx")
        }) {
            return resolve(href: item.href, in: root)
        }
        return firstFile(in: root, extension: "ncx")
    }

    private static func entriesFromNav(_ html: String) -> [TOCEntry]? {
        let tocHTML = navSlice(in: html, type: "toc") ?? navSlice(in: html, type: nil) ?? html
        let regex = try? NSRegularExpression(
            pattern: #"<a\b([^>]*)>([\s\S]*?)</a>"#,
            options: [.caseInsensitive]
        )
        let ns = tocHTML as NSString
        var entries: [TOCEntry] = []
        regex?.matches(in: tocHTML, range: NSRange(location: 0, length: ns.length)).forEach { match in
            guard match.numberOfRanges >= 3,
                  let attrRange = Range(match.range(at: 1), in: tocHTML),
                  let titleRange = Range(match.range(at: 2), in: tocHTML)
            else { return }
            let attrs = xmlAttributes(String(tocHTML[attrRange]))
            guard let href = attrs["href"], !href.isEmpty else { return }
            let title = stripHTML(String(tocHTML[titleRange]))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            entries.append(makeTOCEntry(title: title, href: href))
        }
        return entries.isEmpty ? nil : entries
    }

    private static func navSlice(in html: String, type: String?) -> String? {
        let pattern: String
        if let type {
            pattern = #"<nav\b[^>]*(?:epub:type|type)\s*=\s*["'][^"']*\#(type)[^"']*["'][^>]*>([\s\S]*?)</nav>"#
        } else {
            pattern = #"<nav\b[^>]*>([\s\S]*?)</nav>"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    private static func entriesFromNCX(_ xml: String) -> [TOCEntry] {
        let regex = try? NSRegularExpression(
            pattern: #"<navPoint\b[^>]*>[\s\S]*?<navLabel>\s*<text>([\s\S]*?)</text>\s*</navLabel>\s*<content\b[^>]*\bsrc="([^"]+)""#,
            options: [.caseInsensitive]
        )
        let ns = xml as NSString
        var entries: [TOCEntry] = []
        regex?.matches(in: xml, range: NSRange(location: 0, length: ns.length)).forEach { match in
            guard match.numberOfRanges >= 3,
                  let titleRange = Range(match.range(at: 1), in: xml),
                  let hrefRange = Range(match.range(at: 2), in: xml)
            else { return }
            let title = stripHTML(String(xml[titleRange]))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let href = String(xml[hrefRange])
            guard !title.isEmpty, !href.isEmpty else { return }
            entries.append(makeTOCEntry(title: title, href: href))
        }
        return entries
    }

    private static func makeTOCEntry(title: String, href: String) -> TOCEntry {
        let decoded = href.removingPercentEncoding ?? href
        let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? "")
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        let locator: String
        if let fragment, !fragment.isEmpty {
            locator = "\(fileKey(path))#\(fragment)"
        } else {
            locator = fileKey(path)
        }
        return TOCEntry(
            title: title,
            href: path,
            fragment: fragment?.isEmpty == true ? nil : fragment,
            locator: locator,
            fileKey: fileKey(path)
        )
    }

    private static func uniqueEntries(_ entries: [TOCEntry]) -> [TOCEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            if seen.contains(entry.locator) { return false }
            seen.insert(entry.locator)
            return true
        }
    }

    private static func chapters(from entries: [TOCEntry], in root: URL, package: PackageIndex) -> [EPUBChapter] {
        guard !entries.isEmpty else { return [] }
        let spineKeys = package.spineHrefs.map(fileKey)
        let htmlCache = NSCache<NSString, NSString>()
        func html(for href: String) -> String {
            let key = fileKey(href) as NSString
            if let cached = htmlCache.object(forKey: key) {
                return cached as String
            }
            guard let url = resolve(href: href, in: root) else { return "" }
            let raw = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                ?? ""
            htmlCache.setObject(raw as NSString, forKey: key)
            return raw
        }

        return entries.enumerated().map { index, entry in
            let next = index + 1 < entries.count ? entries[index + 1] : nil
            let text = chapterText(
                from: entry,
                to: next,
                spineKeys: spineKeys,
                spineHrefs: package.spineHrefs,
                html: html
            )
            return EPUBChapter(title: entry.title, locator: entry.locator, text: text, isCover: false)
        }
    }

    private static func chapterText(
        from entry: TOCEntry,
        to next: TOCEntry?,
        spineKeys: [String],
        spineHrefs: [String],
        html: (String) -> String
    ) -> String {
        if let next, next.fileKey == entry.fileKey {
            return splitHTML(html(entry.href), from: entry.fragment, to: next.fragment)
        }

        var parts: [String] = []
        let startHTML = html(entry.href)
        parts.append(splitHTML(startHTML, from: entry.fragment, to: nil))

        let startIndex = spineKeys.firstIndex(of: entry.fileKey)
        let endIndex = next.flatMap { spineKeys.firstIndex(of: $0.fileKey) }
        if let startIndex {
            let lastExclusive = endIndex ?? spineHrefs.count
            if startIndex + 1 < lastExclusive {
                for href in spineHrefs[(startIndex + 1)..<lastExclusive] {
                    if fileKey(href) == entry.fileKey { continue }
                    if let next, fileKey(href) == next.fileKey { break }
                    let body = stripHTML(html(href))
                    if !body.isEmpty { parts.append(body) }
                }
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func splitHTML(_ html: String, from startFragment: String?, to endFragment: String?) -> String {
        let start = startFragment.flatMap { fragmentLocation($0, in: html) } ?? html.startIndex
        let end = endFragment.flatMap { fragmentLocation($0, in: html) } ?? html.endIndex
        guard start < end else { return stripHTML(html) }
        return stripHTML(String(html[start..<end]))
    }

    private static func fragmentLocation(_ fragment: String, in html: String) -> String.Index? {
        let decoded = fragment.removingPercentEncoding ?? fragment
        let candidates = [decoded, fragment].filter { !$0.isEmpty }
        for id in candidates {
            let patterns = [
                "id=\"\(id)\"",
                "id='\(id)'",
                "name=\"\(id)\"",
                "name='\(id)'"
            ]
            for pattern in patterns {
                if let range = html.range(of: pattern, options: .caseInsensitive) {
                    return range.lowerBound
                }
            }
        }
        return nil
    }

    private static func headingTitle(in html: String) -> String? {
        let heading = #"<(h[1-6])\b[^>]*>([\s\S]*?)</\1>"#
        if let regex = try? NSRegularExpression(pattern: heading, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges >= 3,
           let range = Range(match.range(at: 2), in: html) {
            let title = stripHTML(String(html[range]))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return firstElement(named: "title", in: html)
    }

    private static func prettyFallbackTitle(_ href: String) -> String {
        let base = URL(fileURLWithPath: href).deletingPathExtension().lastPathComponent
        let cleaned = base.replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
        return cleaned.isEmpty ? "Chapter" : cleaned.localizedCapitalized
    }

    private static func fileKey(_ href: String) -> String {
        let decoded = (href.removingPercentEncoding ?? href)
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? href
        return (decoded.split(separator: "/").last.map(String.init) ?? decoded).lowercased()
    }

    private static func firstFile(in root: URL, extension ext: String) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == ext.lowercased() {
            return url
        }
        return nil
    }

    private static func firstFile(in root: URL, named names: [String]) -> URL? {
        let wanted = Set(names.map { $0.lowercased() })
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where wanted.contains(url.lastPathComponent.lowercased()) {
            return url
        }
        return nil
    }
}

/// Thin wrapper so we don't import NaturalLanguage everywhere.
private struct NLWrapper {
    func enumerateSentences(in text: String, body: @escaping (NSRange) -> Void) {
        let s = text as NSString
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.bySentences, .localized]) { _, range, _, _ in
            body(range)
        }
    }
}
