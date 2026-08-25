import Foundation

struct GlossPresentation: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case translation
            case learningNotes
            case sentenceMeaning
            case examples
            case other
        }

        var kind: Kind
        var title: String
        var paragraphs: [Paragraph]
        var notes: [Note]
        var examples: [Example]
    }

    struct Paragraph: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case body
            case bullet
            case numbered
        }

        var text: String
        var kind: Kind
    }

    struct Example: Equatable, Sendable {
        var source: String
        var translation: String?
    }

    struct Note: Equatable, Sendable {
        var source: String
        var category: String
        var explanation: String
    }

    var sections: [Section]

    static func parse(_ text: String) -> GlossPresentation {
        var sections: [Section] = []
        var current = Section(kind: .other, title: "", paragraphs: [], notes: [], examples: [])

        func appendCurrent() {
            guard !current.title.isEmpty
                    || !current.paragraphs.isEmpty
                    || !current.notes.isEmpty
                    || !current.examples.isEmpty
            else { return }
            sections.append(current)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(rawLine)
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let legacy = legacyHeading(for: line) {
                appendCurrent()
                current = Section(
                    kind: legacy.kind,
                    title: legacy.title,
                    paragraphs: [],
                    notes: [],
                    examples: []
                )
                if !legacy.content.isEmpty {
                    if legacy.kind == .learningNotes, let note = parseNote(legacy.content) {
                        current.notes.append(note)
                    } else if legacy.kind == .examples {
                        current.examples.append(Example(source: legacy.content, translation: nil))
                    } else {
                        current.paragraphs.append(paragraph(for: legacy.content))
                    }
                }
            } else if let heading = heading(for: line) {
                appendCurrent()
                current = Section(
                    kind: heading.kind,
                    title: heading.title,
                    paragraphs: [],
                    notes: [],
                    examples: []
                )
            } else if !line.isEmpty {
                if current.kind == .learningNotes, let note = parseNote(line) {
                    current.notes.append(note)
                } else if current.kind == .examples, let source = bulletText(line) {
                    current.examples.append(Example(source: source, translation: nil))
                } else if current.kind == .examples, !current.examples.isEmpty {
                    let lastIndex = current.examples.index(before: current.examples.endIndex)
                    let existing = current.examples[lastIndex].translation
                    current.examples[lastIndex].translation = [existing, line]
                        .compactMap { $0 }
                        .joined(separator: " ")
                } else {
                    current.paragraphs.append(paragraph(for: line))
                }
            }
        }
        appendCurrent()
        return GlossPresentation(sections: sections)
    }

    private static func legacyHeading(
        for line: String
    ) -> (kind: Section.Kind, title: String, content: String)? {
        let headings: [(prefix: String, kind: Section.Kind, title: String)] = [
            ("本句释义", .sentenceMeaning, "Meaning in this sentence"),
            ("译文", .translation, "Translation"),
            ("短语", .learningNotes, "Language & Context"),
            ("例句", .examples, "Examples"),
            ("释义", .sentenceMeaning, "Meaning in this sentence")
        ]
        guard let heading = headings.first(where: { line.hasPrefix($0.prefix) }) else { return nil }
        let content = line.dropFirst(heading.prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
        return (heading.kind, heading.title, content)
    }

    private static func heading(for line: String) -> (kind: Section.Kind, title: String)? {
        switch line.uppercased() {
        case GlossTextFormat.translationHeading:
            return (.translation, "Translation")
        case GlossTextFormat.learningNotesHeading, GlossTextFormat.phrasesHeading:
            return (.learningNotes, "Language & Context")
        case GlossTextFormat.sentenceMeaningHeading:
            return (.sentenceMeaning, "Meaning in this sentence")
        case GlossTextFormat.examplesHeading:
            return (.examples, "Examples")
        default:
            if GlossTextFormat.isHeading(line) {
                return (.other, line.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
            }
            if line.hasPrefix("#") {
                let title = line.drop(while: { $0 == "#" || $0.isWhitespace })
                return title.isEmpty ? nil : (.other, String(title))
            }
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                return (.other, String(line.dropFirst(2).dropLast(2)))
            }
            if line.hasSuffix(":"),
               line.count <= 80,
               !line.contains(". "),
               bulletText(line) == nil,
               line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) == nil {
                return (.other, String(line.dropLast()).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
    }

    private static func paragraph(for line: String) -> Paragraph {
        if let text = bulletText(line) {
            return Paragraph(text: text, kind: .bullet)
        }
        if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return Paragraph(text: String(line[range.upperBound...]), kind: .numbered)
        }
        return Paragraph(text: line, kind: .body)
    }

    private static func bulletText(_ line: String) -> String? {
        let markers = ["• ", "- ", "· ", "* "]
        guard let marker = markers.first(where: { line.hasPrefix($0) }) else { return nil }
        return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseNote(_ line: String) -> Note? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "•-· "))
        let pattern = #"^(.+?)\s+[—-]\s+\[([^\]]+)\]\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let sourceRange = Range(match.range(at: 1), in: trimmed),
              let categoryRange = Range(match.range(at: 2), in: trimmed),
              let explanationRange = Range(match.range(at: 3), in: trimmed)
        else { return nil }
        return Note(
            source: String(trimmed[sourceRange]),
            category: String(trimmed[categoryRange]),
            explanation: String(trimmed[explanationRange])
        )
    }
}
