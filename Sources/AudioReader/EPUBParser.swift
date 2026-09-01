import Foundation
import ZIPFoundation

struct EPUBDocument: Equatable, Sendable {
    var text: String
    var title: String?
    var author: String?
    var sections: [EPUBSection] = []
    var cover: EPUBCover? = nil

    var wordCount: Int { Aligner.tokenize(text).count }
    var sentenceCount: Int { EPUBParser.sentences(from: text).count }
}

struct EPUBSection: Equatable, Sendable {
    var title: String
    var text: String
    var navigationLevel: Int = 0
}

struct EPUBCover: Equatable, Sendable {
    var data: Data
    var fileExtension: String
}

struct EPUBSearchResult: Identifiable, Equatable, Sendable {
    var sectionIndex: Int
    var sectionTitle: String
    var snippet: String

    var id: Int { sectionIndex }
}

struct EPUBBookMetadata: Equatable, Sendable {
    var title: String
    var author: String?
}

enum EPUBParser {
    static func extractText(from epubPath: String) -> String? {
        document(from: epubPath)?.text
    }

    static func document(from epubPath: String) -> EPUBDocument? {
        let epub = URL(fileURLWithPath: epubPath)
        guard FileManager.default.fileExists(atPath: epub.path) else { return nil }

        if (try? epub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return document(in: epub)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        guard (try? FileManager.default.unzipItem(at: epub, to: tmp)) != nil else { return nil }

        return document(in: tmp)
    }

    /// Apple Books stores downloaded EPUBs as expanded `.epub` directories;
    /// parse that package root directly without weakening encrypted-spine checks.
    private static func document(in root: URL) -> EPUBDocument? {
        let package = packageInfo(in: root)
        guard !hasEncryptedReadingContent(in: root, package: package) else { return nil }
        let navigation = package.flatMap { navigationEntries(for: $0) } ?? []
        let navigatedSections = navigationSections(from: navigation)
        let sections = navigatedSections.isEmpty
            ? spineSections(in: root, package: package)
            : navigatedSections
        let joined = sections.map(\.text).joined(separator: "\n\n")
        guard !joined.isEmpty else { return nil }
        return EPUBDocument(
            text: joined,
            title: package?.title,
            author: package?.author,
            sections: sections,
            cover: package.flatMap(cover(in:))
        )
    }

    static func search(_ query: String, in document: EPUBDocument) -> [EPUBSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return document.sections.enumerated().compactMap { index, section in
            let normalized = (section.title + "\n" + section.text).replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            guard let match = normalized.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
                return nil
            }
            let location = normalized.distance(from: normalized.startIndex, to: match.lowerBound)
            let lower = max(0, location - 55)
            let upper = min(normalized.count, lower + 150)
            let start = normalized.index(normalized.startIndex, offsetBy: lower)
            let end = normalized.index(normalized.startIndex, offsetBy: upper)
            var snippet = String(normalized[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if lower > 0 { snippet = "…" + snippet }
            if upper < normalized.count { snippet += "…" }
            return EPUBSearchResult(sectionIndex: index, sectionTitle: section.title, snippet: snippet)
        }
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

    /// Adapts immutable published text to the reader's existing sentence model;
    /// synthetic timing is identity/navigation metadata and must never drive audio.
    static func readerTranscript(
        from epubPath: String,
        sectionIndex: Int,
        chapterID: String
    ) -> Transcript? {
        guard let document = document(from: epubPath),
              document.sections.indices.contains(sectionIndex)
        else { return nil }
        let section = document.sections[sectionIndex]
        let headingPrefix = section.title + "\n"
        let readableText = section.text.hasPrefix(headingPrefix)
            ? String(section.text.dropFirst(headingPrefix.count))
            : section.text
        let sentenceTexts = readerSentences(from: readableText)
        let readableSentences = sentenceTexts.isEmpty ? [section.text] : sentenceTexts
        var cursor: TimeInterval = 0
        let segments = readableSentences.enumerated().compactMap { index, sentence -> TranscriptSegment? in
            let tokens = tokenStrings(in: sentence)
            guard !tokens.isEmpty else { return nil }
            let words = tokens.enumerated().map { wordIndex, token in
                TranscriptWord(
                    id: LibraryScanner.stableID("\(chapterID)#\(index)#\(wordIndex)"),
                    text: token,
                    start: cursor + Double(wordIndex) * 0.1,
                    end: cursor + Double(wordIndex + 1) * 0.1,
                    confidence: nil
                )
            }
            let start = cursor
            cursor += max(1, Double(tokens.count) * 0.1)
            return TranscriptSegment(
                id: LibraryScanner.stableID("\(chapterID)#epub-sentence-\(index)"),
                start: start,
                end: cursor,
                words: words
            )
        }
        guard !segments.isEmpty else { return nil }
        return Transcript(
            chapterID: chapterID,
            audioPath: epubPath,
            createdAt: Date(),
            locale: "und",
            segments: segments,
            source: "EPUB",
            ebookAligned: false
        )
    }

    private static func tokenStrings(in text: String) -> [String] {
        let pattern = #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*|[^\s\p{L}\p{N}]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.enumerated().map { index, match in
            let end = matches.indices.contains(index + 1) ? matches[index + 1].range.location : ns.length
            return ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
        }
    }

    /// Reader segmentation preserves every published sentence; the public
    /// alignment helper intentionally filters short utterances as low-signal.
    private static func readerSentences(from text: String) -> [String] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        let tokenizer = NLWrapper()
        tokenizer.enumerateSentences(in: text) { range in
            ranges.append(range)
        }
        let segmented = ranges.compactMap { range -> String? in
            let sentence = ns.substring(with: range)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
        if !segmented.isEmpty { return segmented }
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? [] : [normalized]
    }

    private struct PackageInfo {
        var title: String?
        var author: String?
        var rootURL: URL
        var spineURLs: [URL]
        var navigationURL: URL?
        var ncxURL: URL?
        var coverURL: URL?
    }

    private struct NavigationEntry {
        var title: String
        var resourceURL: URL
        var fragment: String?
        var level: Int
    }

    /// The package manifest is the source of truth for reading order, contents,
    /// and cover artwork; filenames are only a fallback for malformed EPUBs.
    private static func packageInfo(in root: URL) -> PackageInfo? {
        guard let opf = packageURL(in: root),
              let data = try? Data(contentsOf: opf)
        else { return nil }
        let parser = XMLParser(data: data)
        let delegate = EPUBPackageParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let base = opf.deletingLastPathComponent()
        let itemURL: (String) -> URL? = { id in
            guard let href = delegate.manifest[id]?.href else { return nil }
            return resolvedResource(href, relativeTo: base, within: root)
        }
        let navigationID = delegate.manifest.first { _, item in
            item.properties.contains("nav")
        }?.key
        let ncxID = delegate.spineTOCID ?? delegate.manifest.first { _, item in
            item.mediaType.caseInsensitiveCompare("application/x-dtbncx+xml") == .orderedSame
        }?.key
        let coverID = delegate.manifest.first { _, item in
            item.properties.contains("cover-image")
        }?.key ?? delegate.legacyCoverID
        return PackageInfo(
            title: delegate.title,
            author: delegate.author,
            rootURL: root,
            spineURLs: delegate.spineIDs.compactMap(itemURL),
            navigationURL: navigationID.flatMap(itemURL),
            ncxURL: ncxID.flatMap(itemURL),
            coverURL: coverID.flatMap(itemURL)
        )
    }

    private static func packageURL(in root: URL) -> URL? {
        let container = root.appendingPathComponent("META-INF/container.xml")
        if let data = try? Data(contentsOf: container) {
            let parser = XMLParser(data: data)
            let delegate = EPUBContainerParser()
            parser.delegate = delegate
            if parser.parse(), let path = delegate.packagePath {
                let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                let safeRoot = root.standardizedFileURL.resolvingSymlinksInPath()
                if url.path.hasPrefix(safeRoot.path + "/"),
                   FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "opf" {
            return url
        }
        return nil
    }

    private static func navigationEntries(for package: PackageInfo) -> [NavigationEntry] {
        if let navigationURL = package.navigationURL,
           let data = try? Data(contentsOf: navigationURL) {
            let parser = XMLParser(data: data)
            let delegate = EPUB3NavigationParser()
            parser.delegate = delegate
            if parser.parse() {
                let entries = makeNavigationEntries(
                    delegate.entries,
                    relativeTo: navigationURL.deletingLastPathComponent(),
                    within: package.rootURL
                )
                if !entries.isEmpty { return entries }
            }
        }
        if let ncxURL = package.ncxURL,
           let data = try? Data(contentsOf: ncxURL) {
            let parser = XMLParser(data: data)
            let delegate = EPUB2NCXParser()
            parser.delegate = delegate
            if parser.parse() {
                return makeNavigationEntries(
                    delegate.entries,
                    relativeTo: ncxURL.deletingLastPathComponent(),
                    within: package.rootURL
                )
            }
        }
        return []
    }

    private static func makeNavigationEntries(
        _ parsed: [ParsedNavigationEntry],
        relativeTo base: URL,
        within root: URL
    ) -> [NavigationEntry] {
        var seen = Set<String>()
        return parsed.compactMap { entry in
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let parts = entry.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard let path = parts.first.map(String.init), !path.isEmpty else { return nil }
            guard let resource = resolvedResource(path, relativeTo: base, within: root) else { return nil }
            let fragment = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
            let key = resource.path + "#" + (fragment ?? "")
            guard seen.insert(key).inserted,
                  FileManager.default.fileExists(atPath: resource.path)
            else { return nil }
            return NavigationEntry(
                title: title,
                resourceURL: resource,
                fragment: fragment,
                level: max(0, entry.level)
            )
        }
    }

    private static func navigationSections(from entries: [NavigationEntry]) -> [EPUBSection] {
        var documents: [URL: String] = [:]
        for entry in entries where documents[entry.resourceURL] == nil {
            documents[entry.resourceURL] = readTextFile(entry.resourceURL)
        }
        return entries.enumerated().compactMap { index, entry in
            guard let raw = documents[entry.resourceURL] else { return nil }
            let start: String.Index
            if let fragment = entry.fragment {
                guard let anchor = anchorRange(for: fragment, in: raw) else { return nil }
                start = anchor.lowerBound
            } else {
                start = bodyContentRange(in: raw).lowerBound
            }
            let nextStart = entries.dropFirst(index + 1).first { $0.resourceURL == entry.resourceURL }?
                .fragment
                .flatMap { anchorRange(for: $0, in: raw)?.lowerBound }
            let end = nextStart.flatMap { $0 > start ? $0 : nil }
                ?? bodyContentRange(in: raw).upperBound
            guard start < end else { return nil }
            let text = stripHTML(String(raw[start..<end]))
            guard !text.isEmpty else { return nil }
            return EPUBSection(title: entry.title, text: text, navigationLevel: entry.level)
        }
    }

    private static func spineSections(in root: URL, package: PackageInfo?) -> [EPUBSection] {
        let htmls: [URL]
        if let package, !package.spineURLs.isEmpty {
            htmls = package.spineURLs
        } else {
            htmls = contentDocuments(in: root)
        }
        var sections: [EPUBSection] = []
        for (index, file) in htmls.enumerated() {
            guard let raw = readTextFile(file) else { continue }
            let text = stripHTML(raw)
            if isBoilerplate(text) { continue }
            sections.append(EPUBSection(
                title: sectionTitle(in: raw) ?? "Section \(index + 1)",
                text: text
            ))
        }
        return sections
    }

    private static func cover(in package: PackageInfo) -> EPUBCover? {
        guard let url = package.coverURL,
              LibraryScanner.coverExt.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= 20 * 1_024 * 1_024,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return EPUBCover(data: data, fileExtension: url.pathExtension.lowercased())
    }

    /// Font obfuscation is compatible with reading, but encrypted spine
    /// documents are not imported because AudioReader must not bypass DRM.
    private static func hasEncryptedReadingContent(in root: URL, package: PackageInfo?) -> Bool {
        let encryption = root.appendingPathComponent("META-INF/encryption.xml")
        guard let data = try? Data(contentsOf: encryption) else { return false }
        let parser = XMLParser(data: data)
        let delegate = EPUBEncryptionParser()
        parser.delegate = delegate
        guard parser.parse(), !delegate.resourcePaths.isEmpty else { return false }

        let encryptedURLs = delegate.resourcePaths.compactMap {
            resolvedResource($0, relativeTo: root, within: root)
        }
        if let package, !package.spineURLs.isEmpty {
            let spinePaths = Set(package.spineURLs.map { $0.standardizedFileURL.path })
            return encryptedURLs.contains { spinePaths.contains($0.standardizedFileURL.path) }
        }
        return encryptedURLs.contains {
            ["htm", "html", "xhtml"].contains($0.pathExtension.lowercased())
        }
    }

    private static func resolvedResource(_ href: String, relativeTo base: URL, within root: URL) -> URL? {
        let decoded = href.removingPercentEncoding ?? href
        let candidate = URL(fileURLWithPath: decoded, relativeTo: base)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let safeRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(safeRoot.path + "/") else { return nil }
        return candidate
    }

    private static func readTextFile(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
    }

    private static func anchorRange(for fragment: String, in html: String) -> Range<String.Index>? {
        let escaped = NSRegularExpression.escapedPattern(for: fragment)
        let pattern = #"<[^>]+\b(?:id|name)\s*=\s*[\"']"# + escaped + #"[\"'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        else { return nil }
        return Range(match.range, in: html)
    }

    private static func bodyContentRange(in html: String) -> Range<String.Index> {
        let opening = html.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
        let closing = html.range(of: "</body>", options: [.caseInsensitive, .backwards])
        let lower = opening?.upperBound ?? html.startIndex
        let upper = closing?.lowerBound ?? html.endIndex
        return lower <= upper ? lower..<upper : html.startIndex..<html.endIndex
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
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var opf: URL?
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "opf" {
            opf = url
            break
        }
        guard let opf, let xml = try? String(contentsOf: opf, encoding: .utf8) else { return [] }

        var idToHref: [String: String] = [:]
        let itemRegex = try? NSRegularExpression(pattern: #"<item\b[^>]*\bid="([^"]+)"[^>]*\bhref="([^"]+)""#, options: [.caseInsensitive])
        let itemRegex2 = try? NSRegularExpression(pattern: #"<item\b[^>]*\bhref="([^"]+)"[^>]*\bid="([^"]+)""#, options: [.caseInsensitive])
        let ns = xml as NSString
        itemRegex?.matches(in: xml, range: NSRange(location: 0, length: ns.length)).forEach { m in
            if m.numberOfRanges >= 3,
               let idR = Range(m.range(at: 1), in: xml),
               let hrefR = Range(m.range(at: 2), in: xml) {
                idToHref[String(xml[idR])] = String(xml[hrefR]).removingPercentEncoding ?? String(xml[hrefR])
            }
        }
        itemRegex2?.matches(in: xml, range: NSRange(location: 0, length: ns.length)).forEach { m in
            if m.numberOfRanges >= 3,
               let hrefR = Range(m.range(at: 1), in: xml),
               let idR = Range(m.range(at: 2), in: xml) {
                idToHref[String(xml[idR])] = String(xml[hrefR]).removingPercentEncoding ?? String(xml[hrefR])
            }
        }

        var hrefs: [String] = []
        let spineRegex = try? NSRegularExpression(pattern: #"<itemref\b[^>]*\bidref="([^"]+)""#, options: [.caseInsensitive])
        spineRegex?.matches(in: xml, range: NSRange(location: 0, length: ns.length)).forEach { m in
            if m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: xml) {
                let id = String(xml[r])
                if let href = idToHref[id] { hrefs.append(href) }
            }
        }
        return hrefs
    }

    private static func sectionTitle(in html: String) -> String? {
        let pattern = #"<h[1-6]\b[^>]*>([\s\S]*?)</h[1-6]>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let title = stripHTML(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func resolve(href: String, in root: URL) -> URL? {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            let needle = href.split(separator: "/").last.map(String.init)?.lowercased()
            for case let url as URL in enumerator {
                if url.lastPathComponent.lowercased() == needle { return url }
                if url.path.lowercased().hasSuffix(href.lowercased()) { return url }
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
}

private struct ParsedNavigationEntry {
    var title: String
    var href: String
    var level: Int
}

private struct EPUBManifestItem {
    var href: String
    var mediaType: String
    var properties: Set<String>
}

private func xmlLocalName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
}

private func xmlAttribute(_ localName: String, in attributes: [String: String]) -> String? {
    attributes.first { xmlLocalName($0.key) == localName.lowercased() }?.value
}

private func normalizedXMLText(_ value: String) -> String {
    value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    var packagePath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard xmlLocalName(elementName) == "rootfile", packagePath == nil else { return }
        packagePath = xmlAttribute("full-path", in: attributeDict)?.removingPercentEncoding
    }
}

private final class EPUBPackageParser: NSObject, XMLParserDelegate {
    var title: String?
    var author: String?
    var manifest: [String: EPUBManifestItem] = [:]
    var spineIDs: [String] = []
    var spineTOCID: String?
    var legacyCoverID: String?

    private var capturedElement: String?
    private var capturedText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch xmlLocalName(elementName) {
        case "title", "creator":
            capturedElement = xmlLocalName(elementName)
            capturedText = ""
        case "item":
            guard let id = xmlAttribute("id", in: attributeDict),
                  let href = xmlAttribute("href", in: attributeDict)
            else { return }
            manifest[id] = EPUBManifestItem(
                href: href.removingPercentEncoding ?? href,
                mediaType: xmlAttribute("media-type", in: attributeDict) ?? "",
                properties: Set((xmlAttribute("properties", in: attributeDict) ?? "")
                    .split(whereSeparator: \.isWhitespace).map(String.init))
            )
        case "spine":
            spineTOCID = xmlAttribute("toc", in: attributeDict)
        case "itemref":
            if let idref = xmlAttribute("idref", in: attributeDict) { spineIDs.append(idref) }
        case "meta":
            if xmlAttribute("name", in: attributeDict)?.lowercased() == "cover" {
                legacyCoverID = xmlAttribute("content", in: attributeDict)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturedElement != nil { capturedText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = xmlLocalName(elementName)
        guard local == capturedElement else { return }
        let value = normalizedXMLText(capturedText)
        if local == "title", title == nil, !value.isEmpty { title = value }
        if local == "creator", author == nil, !value.isEmpty { author = value }
        capturedElement = nil
        capturedText = ""
    }
}

private final class EPUBEncryptionParser: NSObject, XMLParserDelegate {
    var resourcePaths: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard xmlLocalName(elementName) == "cipherreference",
              let uri = xmlAttribute("uri", in: attributeDict)
        else { return }
        resourcePaths.append(uri.components(separatedBy: "#").first ?? uri)
    }
}

private final class EPUB3NavigationParser: NSObject, XMLParserDelegate {
    var entries: [ParsedNavigationEntry] = []

    private var inTOC = false
    private var listDepth = 0
    private var currentHref: String?
    private var currentLevel = 0
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = xmlLocalName(elementName)
        if local == "nav" {
            let types = (xmlAttribute("type", in: attributeDict) ?? "")
                .split(whereSeparator: \.isWhitespace)
            if types.contains(where: { $0.lowercased() == "toc" }) { inTOC = true }
        } else if inTOC, local == "ol" {
            listDepth += 1
        } else if inTOC, local == "a", let href = xmlAttribute("href", in: attributeDict) {
            currentHref = href
            currentLevel = max(0, listDepth - 1)
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentHref != nil { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = xmlLocalName(elementName)
        if inTOC, local == "a", let href = currentHref {
            entries.append(.init(title: normalizedXMLText(currentText), href: href, level: currentLevel))
            currentHref = nil
            currentText = ""
        } else if inTOC, local == "ol" {
            listDepth = max(0, listDepth - 1)
        } else if inTOC, local == "nav" {
            inTOC = false
            listDepth = 0
        }
    }
}

private final class EPUB2NCXParser: NSObject, XMLParserDelegate {
    var entries: [ParsedNavigationEntry] = []

    private struct Point {
        var title = ""
        var href: String?
        var emitted = false
        var isCapturingTitle = false
    }

    private var inNavMap = false
    private var points: [Point] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = xmlLocalName(elementName)
        if local == "navmap" {
            inNavMap = true
        } else if inNavMap, local == "navpoint" {
            points.append(Point())
        } else if inNavMap, local == "text", !points.isEmpty {
            points[points.count - 1].isCapturingTitle = true
        } else if inNavMap, local == "content", !points.isEmpty {
            points[points.count - 1].href = xmlAttribute("src", in: attributeDict)
            emitCurrentPointIfReady()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !points.isEmpty, points[points.count - 1].isCapturingTitle else { return }
        points[points.count - 1].title += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = xmlLocalName(elementName)
        if inNavMap, local == "text", !points.isEmpty {
            points[points.count - 1].isCapturingTitle = false
        } else if inNavMap, local == "navpoint", !points.isEmpty {
            emitCurrentPointIfReady()
            points.removeLast()
        } else if local == "navmap" {
            inNavMap = false
        }
    }

    private func emitCurrentPointIfReady() {
        guard !points.isEmpty,
              !points[points.count - 1].emitted,
              let href = points[points.count - 1].href
        else { return }
        let title = normalizedXMLText(points[points.count - 1].title)
        guard !title.isEmpty else { return }
        entries.append(.init(title: title, href: href, level: points.count - 1))
        points[points.count - 1].emitted = true
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
