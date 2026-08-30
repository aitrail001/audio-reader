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

enum EPUBParser {
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
        let epub = URL(fileURLWithPath: epubPath)
        guard FileManager.default.fileExists(atPath: epub.path) else { return nil }
        if isPackage(at: epub) {
            return document(fromPackageRoot: epub)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        guard (try? FileManager.default.unzipItem(at: epub, to: tmp)) != nil else { return nil }
        return document(fromPackageRoot: tmp)
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

    private static func packageMetadata(in root: URL) -> (title: String?, author: String?) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return (nil, nil)
        }
        var opf: URL?
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "opf" {
            opf = url
            break
        }
        guard let opf,
              let xml = (try? String(contentsOf: opf, encoding: .utf8))
                ?? (try? String(contentsOf: opf, encoding: .isoLatin1))
        else { return (nil, nil) }
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

/// Thin wrapper so we don't import NaturalLanguage everywhere.
private struct NLWrapper {
    func enumerateSentences(in text: String, body: @escaping (NSRange) -> Void) {
        let s = text as NSString
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.bySentences, .localized]) { _, range, _, _ in
            body(range)
        }
    }
}
