import Foundation
#if os(macOS)
import CoreServices
import AppKit
#else
import UIKit
#endif

struct DictionaryHit: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var html: String
    var preview: String
}

enum DictionaryLookup {
    static let chinesePreferred = [
        "牛津英汉汉英词典",
        "现代汉语规范词典",
        "现代汉语同义词典",
        "汉语成语词典",
        "译典通英汉双向字典",
        "Simplified Chinese - English"
    ]

    static func headword(_ raw: String) -> String {
        raw.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    static func installedNames() -> [String] {
#if os(macOS)
        dictionaries().map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
#else
        ["iPadOS Dictionary"]
#endif
    }

    static func searchOrder(
        preferredName: String?,
        language: StudyLanguage,
        installedNames: [String]
    ) -> [String] {
        let targetNames = dictionaryNames(for: language)
        let fallbackNames = ["Oxford Dictionary of English", "New Oxford American Dictionary"]
        var result: [String] = []
        var seen = Set<String>()

        func appendInstalled(_ requestedName: String) {
            guard let installed = installedNames.first(where: {
                $0.caseInsensitiveCompare(requestedName) == .orderedSame
            }), seen.insert(installed).inserted else { return }
            result.append(installed)
        }

        if let preferredName,
           targetNames.contains(where: { $0.caseInsensitiveCompare(preferredName) == .orderedSame }) {
            appendInstalled(preferredName)
        }
        targetNames.forEach(appendInstalled)
        fallbackNames.forEach(appendInstalled)
        return result
    }

    static func recommendedName(language: StudyLanguage, installedNames: [String]) -> String? {
        if let systemDictionary = installedNames.first(where: {
            $0.caseInsensitiveCompare("iPadOS Dictionary") == .orderedSame
        }) {
            return systemDictionary
        }
        return searchOrder(preferredName: nil, language: language, installedNames: installedNames).first
    }

    private static func dictionaryNames(for language: StudyLanguage) -> [String] {
        switch language {
        case .zhHans:
            chinesePreferred
        case .zhHant:
            ["Traditional Chinese - English", "Traditional Chinese", "Traditional Chinese Common Words"]
        case .ja:
            ["Sanseido The WISDOM English-Japanese Japanese-English Dictionary", "Japanese - English"]
        case .ko:
            ["Korean - English", "Korean"]
        case .es:
            ["Spanish - English", "Spanish"]
        case .fr:
            ["French - English", "French"]
        case .de:
            ["German - English", "German", "Duden Dictionary Data Set I"]
        case .en:
            ["Oxford Dictionary of English", "New Oxford American Dictionary", "Apple Dictionary"]
        }
    }

#if os(macOS)
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedDicts: [InstalledDict]?
#endif

    static func lookup(
        _ raw: String,
        preferredName: String?,
        language: StudyLanguage = .en
    ) -> [DictionaryHit] {
#if os(macOS)
        let word = headword(raw)
        guard !word.isEmpty else { return [] }
        let dicts = dictionaries()
        let byName = Dictionary(uniqueKeysWithValues: dicts.map { ($0.name, $0) })
        let searchNames = searchOrder(
            preferredName: preferredName,
            language: language,
            installedNames: dicts.map(\.name)
        )

        var hits: [DictionaryHit] = []
        for name in searchNames {
            guard let dict = byName[name] else { continue }
            if let hit = search(word, in: dict) {
                hits.append(hit)
            } else if language == .zhHans && chinesePreferred.contains(name) {
                let hint = chineseMonolingualHint(for: name, word: word)
                    ?? "「\(name)」没有 “\(word)” 的条目。"
                hits.append(DictionaryHit(name: name, html: wrappedHTML("<p>\(hint)</p>"), preview: hint))
            }
        }
        return hits
#else
        []
#endif
    }

    static func openDictionaryApp() {
#if os(macOS)
        let app = URL(fileURLWithPath: "/System/Applications/Dictionary.app")
        if FileManager.default.fileExists(atPath: app.path) {
            NSWorkspace.shared.open(app)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Dictionary.app"))
#endif
    }

    @MainActor
    static func hasSystemDefinition(_ raw: String, language: StudyLanguage = .en) -> Bool {
#if os(macOS)
        !lookup(raw, preferredName: nil, language: language).isEmpty
#else
        let word = headword(raw)
        return !word.isEmpty && UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: word)
#endif
    }

    @MainActor
    static func lookUpInDictionary(_ raw: String) {
        let word = headword(raw)
#if os(macOS)
        if let url = URL(string: "dict://\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)") {
            NSWorkspace.shared.open(url)
        }
#else
        guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: word) else { return }
        Task { @MainActor in
            let controller = UIReferenceLibraryViewController(term: word)
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController
            else { return }
            var presenter = root
            while let presented = presenter.presentedViewController { presenter = presented }
            presenter.present(controller, animated: true)
        }
#endif
    }

#if os(macOS)
    private struct InstalledDict {
        var name: String
        var ref: DCSDictionary
    }

    private static func dictionaries() -> [InstalledDict] {
        cacheLock.lock()
        if let cachedDicts {
            cacheLock.unlock()
            return cachedDicts
        }
        cacheLock.unlock()
        guard let unmanaged = DCSCopyAvailableDictionaries() else { return [] }
        let set = unmanaged.takeRetainedValue()
        let count = CFSetGetCount(set)
        var pointers = Array<UnsafeRawPointer?>(repeating: nil, count: count)
        pointers.withUnsafeMutableBufferPointer { buffer in
            CFSetGetValues(set, buffer.baseAddress)
        }
        var out: [InstalledDict] = []
        out.reserveCapacity(count)
        for pointer in pointers {
            guard let pointer else { continue }
            let dict = Unmanaged<DCSDictionary>.fromOpaque(pointer).takeUnretainedValue()
            let name = (DCSDictionaryGetName(dict)?.takeUnretainedValue() as String?)
                ?? (DCSDictionaryGetShortName(dict)?.takeUnretainedValue() as String?)
                ?? "Dictionary"
            out.append(InstalledDict(name: name, ref: dict))
        }
        cacheLock.lock()
        cachedDicts = out
        cacheLock.unlock()
        return out
    }

    private static func search(_ word: String, in dict: InstalledDict) -> DictionaryHit? {
        guard let recsUnmanaged = DCSCopyRecordsForSearchString(dict.ref, word as CFString, nil, nil) else {
            return nil
        }
        let recs = recsUnmanaged.takeRetainedValue() as NSArray
        guard recs.count > 0 else { return nil }
        var htmlParts: [String] = []
        var textParts: [String] = []
        for rec in recs.prefix(3) {
            let cf = rec as CFTypeRef
            if let html = DCSRecordCopyData(cf)?.takeRetainedValue() as String? {
                htmlParts.append(extractBody(html))
            }
            if let def = DCSRecordCopyDefinition(cf)?.takeRetainedValue() as String?, !def.isEmpty {
                textParts.append(def)
            } else if let hw = DCSRecordGetHeadword(cf)?.takeUnretainedValue() as String? {
                textParts.append(hw)
            }
        }
        guard !htmlParts.isEmpty || !textParts.isEmpty else { return nil }
        let html = wrappedHTML(htmlParts.joined(separator: "<hr />"))
        let joinedDefs = textParts.joined(separator: "\n\n")
        let preview: String
        if looksLikeMarkup(joinedDefs) || joinedDefs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preview = plainPreview(from: htmlParts.joined(separator: "\n"))
        } else {
            preview = collapseWhitespace(joinedDefs)
        }
        return DictionaryHit(name: dict.name, html: html, preview: preview)
    }
#endif

    static func looksLikeMarkup(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return t.hasPrefix("<?xml")
            || t.hasPrefix("<!DOCTYPE")
            || t.hasPrefix("<html")
            || t.contains("<d:entry")
            || t.contains("xmlns:d=")
            || t.contains("<body>")
    }

    static func optionalDisplayHTML(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return displayHTML(raw)
    }

    static func displayHTML(_ raw: String, dark: Bool = true) -> String {
        wrappedHTML(extractBody(raw), dark: dark)
    }

    static func plainPreview(from raw: String) -> String {
        if !looksLikeMarkup(raw) {
            return collapseWhitespace(raw)
        }
        var translations: [String] = []
        let pattern = #"class="trans"[^>]*>([^<]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            regex.enumerateMatches(in: raw, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let chunk = ns.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard chunk.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else {
                    return
                }
                let cleaned = collapseWhitespace(chunk)
                if !cleaned.isEmpty, !translations.contains(cleaned) {
                    translations.append(cleaned)
                }
            }
        }
        if !translations.isEmpty {
            return translations.prefix(8).joined(separator: "；")
        }
        return stripTags(raw)
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripTags(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = collapseWhitespace(s)
        if let xml = s.range(of: "standalone=\"yes\"") {
            s = String(s[xml.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.lowercased().hasPrefix("html public") || s.contains("W3C//DTD") {
            if let body = s.range(of: "learn ", options: .caseInsensitive)
                ?? s.range(of: #"\b[A-Za-z]{3,}\b"#, options: .regularExpression) {
                s = String(s[body.lowerBound...])
            }
        }
        return s
    }

    private static func extractBody(_ html: String) -> String {
        if let start = html.range(of: "<body>", options: .caseInsensitive),
           let end = html.range(of: "</body>", options: .caseInsensitive) {
            return String(html[start.upperBound..<end.lowerBound])
        }
        return html
    }

    static func wrappedHTML(_ body: String, dark: Bool = true) -> String {
        let ink = dark ? "#F3EDE4" : "#2A2118"
        let hw = dark ? "#F8F1E8" : "#1C1611"
        let muted = dark ? "#9A8C7E" : "#6F6458"
        let gold = dark ? "#E8B86D" : "#B07A28"
        let accent = dark ? "#E0A35A" : "#A66A1C"
        let exampleZh = dark ? "#C9B9A8" : "#5C5248"
        let dim = dark ? "#C4B6A6" : "#6A5E54"
        let rule = dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.08)"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8" />
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: \(ink);
            font: 16px/1.7 ui-serif, "Iowan Old Style", Palatino, "Songti SC", "PingFang SC", serif;
            -webkit-font-smoothing: antialiased;
          }
          d\\:entry, .entry { display: block; }
          d\\:prn, d\\:pos, d\\:def { display: none; }

          .hwg { display: block; margin: 0 0 16px; }
          .hw { font-size: 1.25em; font-weight: 650; color: \(hw); }
          .prx, .ph { color: \(muted); font-size: 0.92em; font-weight: 400; }

          .gramb, .x_xd0.hasSn { display: block; margin: 22px 0 10px; }
          .gramb > .x_xdh {
            display: block;
            margin: 0 0 10px;
            font-size: 1.06em;
            font-weight: 650;
            color: \(hw);
          }
          .ps, .pos, .posg { color: \(gold); font-style: italic; font-weight: 500; }
          .frmg, .frm { font-weight: 650; }

          .semb, .se1, .se2, .msDict { display: block; margin: 16px 0 8px; }
          .semb > .x_xdh,
          .semb > .gp.x_xdh,
          .gp.x_xdh.sn.ty_label.tg_semb {
            display: inline;
            margin: 0;
            color: \(accent);
            font-weight: 700;
          }
          .trgg { display: inline; }
          .cnt { color: \(dim); }
          .ind { color: \(dim); }
          .trans { color: \(ink); }
          .trans.ty_pinyin { color: \(muted); margin-left: 0.4em; }
          .lev, .fld { color: \(gold); font-style: italic; font-size: 0.9em; }

          .exg, .eg, .x_xg1 {
            display: block !important;
            margin: 10px 0 2px;
          }
          .exg > .x_xdh {
            display: block;
            margin: 0;
          }
          .ex { font-style: normal; color: \(ink); }
          .sn { color: \(accent); }

          .trg.x_xd3, .trg {
            display: block;
            margin: 2px 0 12px 1.5em;
            color: \(exampleZh);
          }
          .semb > .trgg .trg,
          .trgg .trg {
            display: inline;
            margin: 0;
            color: inherit;
          }

          .df { display: block; margin: 6px 0 8px; }
          .underline { font-style: italic; }
          hr { border: 0; border-top: 1px solid \(rule); margin: 18px 0; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    static func chineseMonolingualHint(for name: String, word: String) -> String? {
        let chineseOnly = name.contains("现代汉语") || name.contains("汉语成语") || name.contains("同义词典") || name.contains("国语")
        let latin = word.unicodeScalars.contains { CharacterSet.letters.contains($0) && $0.isASCII }
        if chineseOnly && latin {
            return "「\(name)」是汉语词典，查英文词通常没有条目。英译中请选「牛津英汉汉英词典」。"
        }
        return nil
    }
}

#if os(macOS)
@_silgen_name("DCSCopyAvailableDictionaries")
private func DCSCopyAvailableDictionaries() -> Unmanaged<CFSet>?
@_silgen_name("DCSDictionaryGetName")
private func DCSDictionaryGetName(_ d: DCSDictionary) -> Unmanaged<CFString>?
@_silgen_name("DCSDictionaryGetShortName")
private func DCSDictionaryGetShortName(_ d: DCSDictionary) -> Unmanaged<CFString>?
@_silgen_name("DCSCopyRecordsForSearchString")
private func DCSCopyRecordsForSearchString(_ d: DCSDictionary, _ s: CFString, _ a: UnsafeRawPointer?, _ b: UnsafeRawPointer?) -> Unmanaged<CFArray>?
@_silgen_name("DCSRecordCopyData")
private func DCSRecordCopyData(_ r: CFTypeRef) -> Unmanaged<CFString>?
@_silgen_name("DCSRecordCopyDefinition")
private func DCSRecordCopyDefinition(_ r: CFTypeRef) -> Unmanaged<CFString>?
@_silgen_name("DCSRecordGetHeadword")
private func DCSRecordGetHeadword(_ r: CFTypeRef) -> Unmanaged<CFString>?
#endif
