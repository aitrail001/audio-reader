import Foundation

struct StudyLemma: Hashable, Codable, Sendable {
    var language: String
    var form: String

    static func make(language: String, surface: String) -> StudyLemma? {
        let form = DictionaryLookup.headword(surface).lowercased()
        guard !form.isEmpty else { return nil }
        return StudyLemma(language: language, form: form)
    }
}

enum WordFamiliarity: String, Equatable, Sendable {
    case unknown
    case learning
    case known
}

enum VocabReviewPrompt: String, CaseIterable, Identifiable, Codable, Sendable {
    case recognition
    case cloze
    case reverse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recognition: "Recognition"
        case .cloze: "Cloze"
        case .reverse: "Reverse"
        }
    }
}

struct KnownLemmaRecord: Hashable, Codable, Sendable {
    var language: String
    var form: String
    var updatedAt: Date

    var lemma: StudyLemma { StudyLemma(language: language, form: form) }
}

struct ChapterCoverage: Equatable, Sendable {
    var contentCount: Int
    var knownCount: Int
    var learningCount: Int
    var unknownCount: Int

    var percentKnown: Int {
        guard contentCount > 0 else { return 0 }
        return Int(((Double(knownCount + learningCount) / Double(contentCount)) * 100).rounded())
    }

    var titleFragment: String {
        "Known \(percentKnown)% · \(learningCount) learning · \(unknownCount) new"
    }

    var caption: String {
        "This chapter · \(titleFragment)"
    }

    static let empty = ChapterCoverage(
        contentCount: 0,
        knownCount: 0,
        learningCount: 0,
        unknownCount: 0
    )
}

struct ChapterStudyItem: Identifiable, Equatable, Sendable {
    var id: String
    var lemma: StudyLemma
    var surface: String
    var familiarity: WordFamiliarity
    var segmentID: String
    var wordID: String
    var timestamp: TimeInterval
}

enum StudyTokenIndex {
    static let englishStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "for", "from",
        "by", "with", "as", "is", "are", "was", "were", "be", "been", "being", "it", "its",
        "this", "that", "these", "those", "i", "you", "he", "she", "we", "they", "me", "him",
        "her", "us", "them", "my", "your", "his", "our", "their", "not", "no", "do", "does",
        "did", "have", "has", "had", "will", "would", "can", "could", "should", "may", "might",
        "so", "than", "then", "there", "here", "what", "which", "who", "when", "where", "how",
        "why", "about", "into", "over", "after", "before", "up", "down", "out", "off", "too",
        "very", "just", "also", "only", "oh", "ah", "um", "uh"
    ]

    static func languageKey(for transcription: TranscriptionLanguage) -> String {
        transcription.languageCode
    }

    static func languageKey(localeIdentifier: String) -> String {
        if let language = TranscriptionLanguage.matching(localeIdentifier: localeIdentifier) {
            return languageKey(for: language)
        }
        return Locale(identifier: localeIdentifier).language.languageCode?.identifier
            ?? localeIdentifier.split(separator: "-").first.map(String.init)?.lowercased()
            ?? localeIdentifier.lowercased()
    }

    static func lemma(from surface: String, language: String) -> StudyLemma? {
        StudyLemma.make(language: language, surface: surface)
    }

    static func isContentWord(_ lemma: StudyLemma) -> Bool {
        if lemma.language.lowercased().hasPrefix("en") {
            return !englishStopwords.contains(lemma.form)
        }
        return true
    }

    static func tokens(in segment: TranscriptSegment) -> [TranscriptWord] {
        if !segment.words.isEmpty { return segment.words }
        let source = segment.trustedEbookText ?? segment.spokenText
        return syntheticTokens(in: segment, text: source, idComponent: "spoken")
    }

    static func tokens(in segment: TranscriptSegment, source: TextSource) -> [TranscriptWord] {
        guard source == .original, let ebookText = segment.trustedEbookText else {
            return tokens(in: segment)
        }
        return syntheticTokens(in: segment, text: ebookText, idComponent: "ebook")
    }

    private static func syntheticTokens(
        in segment: TranscriptSegment,
        text: String,
        idComponent: String
    ) -> [TranscriptWord] {
        let parts = text.split { $0.isWhitespace || $0.isNewline }
        guard !parts.isEmpty else { return [] }
        let duration = max(segment.end - segment.start, 0.01)
        let slice = duration / Double(parts.count)
        return parts.enumerated().map { index, part in
            let start = segment.start + (Double(index) * slice)
            return TranscriptWord(
                id: "\(segment.id)-\(idComponent)-\(index)",
                text: String(part),
                start: start,
                end: start + slice,
                confidence: nil
            )
        }
    }

    static func sentenceText(in segment: TranscriptSegment) -> String {
        let parts = tokens(in: segment)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return segment.displayText }
        return parts.joined(separator: " ")
    }
}

struct StudyIndex: Equatable, Sendable {
    var language: String
    var learning: Set<StudyLemma>
    var known: Set<StudyLemma>
    var coverage: ChapterCoverage
    var priming: [ChapterStudyItem]

    static let empty = StudyIndex(
        language: "",
        learning: [],
        known: [],
        coverage: .empty,
        priming: []
    )

    static func build(
        segments: [TranscriptSegment],
        language: String,
        vocab: [VocabEntry],
        knownRecords: [KnownLemmaRecord],
        primingLimit: Int = 200
    ) -> StudyIndex {
        let learning = WordFamiliarityResolver.learningLemmas(from: vocab, language: language)
        let known = WordFamiliarityResolver.knownLemmas(from: knownRecords, language: language)
        var seen = Set<StudyLemma>()
        var knownCount = 0
        var learningCount = 0
        var unknownCount = 0
        var priming: [ChapterStudyItem] = []
        let limit = max(1, primingLimit)

        for segment in segments {
            for word in StudyTokenIndex.tokens(in: segment) {
                guard let lemma = StudyLemma.make(language: language, surface: word.text),
                      StudyTokenIndex.isContentWord(lemma),
                      seen.insert(lemma).inserted
                else { continue }
                let familiarity = WordFamiliarityResolver.status(
                    lemma: lemma,
                    learning: learning,
                    known: known
                )
                switch familiarity {
                case .known: knownCount += 1
                case .learning: learningCount += 1
                case .unknown: unknownCount += 1
                }
                if familiarity != .known, priming.count < limit {
                    priming.append(
                        ChapterStudyItem(
                            id: word.id,
                            lemma: lemma,
                            surface: DictionaryLookup.headword(word.text),
                            familiarity: familiarity,
                            segmentID: segment.id,
                            wordID: word.id,
                            timestamp: word.start
                        )
                    )
                }
            }
        }

        return StudyIndex(
            language: language,
            learning: learning,
            known: known,
            coverage: ChapterCoverage(
                contentCount: seen.count,
                knownCount: knownCount,
                learningCount: learningCount,
                unknownCount: unknownCount
            ),
            priming: priming
        )
    }

    func familiarity(for surface: String) -> WordFamiliarity {
        guard let lemma = StudyLemma.make(language: language, surface: surface) else { return .unknown }
        return WordFamiliarityResolver.status(lemma: lemma, learning: learning, known: known)
    }
}

enum WordFamiliarityResolver {
    static func learningLemmas(from vocab: [VocabEntry], language: String) -> Set<StudyLemma> {
        let language = StudyTokenIndex.languageKey(localeIdentifier: language)
        return Set<StudyLemma>(vocab.compactMap { entry in
            guard entry.category == .word,
                  entry.sourceLanguage.map({ StudyTokenIndex.languageKey(localeIdentifier: $0) }) == language else {
                return nil
            }
            return StudyLemma.make(language: language, surface: entry.word)
        })
    }

    static func knownLemmas(from records: [KnownLemmaRecord], language: String) -> Set<StudyLemma> {
        Set(records.compactMap { record in
            guard record.language == language else { return nil }
            return record.lemma
        })
    }

    static func status(
        lemma: StudyLemma,
        learning: Set<StudyLemma>,
        known: Set<StudyLemma>
    ) -> WordFamiliarity {
        if learning.contains(lemma) { return .learning }
        if known.contains(lemma) { return .known }
        return .unknown
    }

    static func status(
        surface: String,
        language: String,
        vocab: [VocabEntry],
        known: [KnownLemmaRecord]
    ) -> WordFamiliarity? {
        guard let lemma = StudyLemma.make(language: language, surface: surface) else { return nil }
        return status(
            lemma: lemma,
            learning: learningLemmas(from: vocab, language: language),
            known: knownLemmas(from: known, language: language)
        )
    }
}

enum VocabSourceLanguageMigration {
    static func migrated(
        _ vocab: [VocabEntry],
        books: [Book],
        languageForBook: (Book) -> String
    ) -> [VocabEntry] {
        var booksByID: [String: Book] = [:]
        for book in books {
            booksByID[book.id] = book
            booksByID[LibraryScanner.legacyAbsolutePathID(for: book)] = book
        }
        let booksByTitle = Dictionary(grouping: books) { $0.title.lowercased() }

        return vocab.map { entry in
            guard entry.sourceLanguage == nil else { return entry }
            let titleMatches = booksByTitle[entry.bookTitle.lowercased()] ?? []
            guard let book = booksByID[entry.bookID] ?? (titleMatches.count == 1 ? titleMatches[0] : nil) else {
                return entry
            }
            var migrated = entry
            migrated.sourceLanguage = StudyTokenIndex.languageKey(
                localeIdentifier: languageForBook(book)
            )
            return migrated
        }
    }
}

enum ReaderWindowTitle {
    static func make(book: String?, chapter: String?, coverage: ChapterCoverage) -> String {
        var parts = [book, chapter]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if coverage.contentCount > 0 {
            parts.append(coverage.titleFragment)
        }
        return parts.joined(separator: " · ")
    }
}

enum ChapterCoverageCalculator {
    static func snapshot(
        segments: [TranscriptSegment],
        language: String,
        vocab: [VocabEntry],
        known: [KnownLemmaRecord]
    ) -> ChapterCoverage {
        StudyIndex.build(
            segments: segments,
            language: language,
            vocab: vocab,
            knownRecords: known
        ).coverage
    }
}

enum ChapterPrimingList {
    static func build(
        segments: [TranscriptSegment],
        language: String,
        vocab: [VocabEntry],
        known: [KnownLemmaRecord],
        limit: Int = 200
    ) -> [ChapterStudyItem] {
        StudyIndex.build(
            segments: segments,
            language: language,
            vocab: vocab,
            knownRecords: known,
            primingLimit: limit
        ).priming
    }
}

enum StudyTextMatch {
    static func firstWholeTokenRange(of rawTerm: String, in text: String) -> Range<String.Index>? {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let needsWordBoundaries = term.unicodeScalars.contains { scalar in
            (0x0041...0x024F).contains(scalar.value)
                || (0x1E00...0x1EFF).contains(scalar.value)
                || (0x0030...0x0039).contains(scalar.value)
        }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            if !needsWordBoundaries || hasWordBoundaries(range, in: text) {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func hasWordBoundaries(_ range: Range<String.Index>, in text: String) -> Bool {
        let startsAtBoundary = range.lowerBound == text.startIndex
            || !isWordCharacter(text[text.index(before: range.lowerBound)])
        let endsAtBoundary = range.upperBound == text.endIndex
            || !isWordCharacter(text[range.upperBound])
        return startsAtBoundary && endsAtBoundary
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }
    }
}

enum VocabCloze {
    static let blank = "____"

    static func blankedSentence(for entry: VocabEntry) -> String {
        let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return entry.context }
        if let range = StudyTextMatch.firstWholeTokenRange(of: word, in: entry.context) {
            return String(entry.context[..<range.lowerBound])
                + blank
                + String(entry.context[range.upperBound...])
        }
        return blank
    }
}

enum VocabReversePrompt {
    static func promptText(for entry: VocabEntry) -> String? {
        if let translation = entry.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty {
            return translation
        }
        if let definition = entry.definition?.trimmingCharacters(in: .whitespacesAndNewlines),
           !definition.isEmpty {
            return definition
        }
        return nil
    }

    static func effectivePrompt(
        for entry: VocabEntry,
        requested: VocabReviewPrompt
    ) -> VocabReviewPrompt {
        if requested == .reverse, promptText(for: entry) == nil {
            return .recognition
        }
        return requested
    }
}

enum KnownLemmaStore {
    static func upsert(
        _ lemma: StudyLemma,
        into records: [KnownLemmaRecord],
        at date: Date = Date()
    ) -> [KnownLemmaRecord] {
        var next = records.filter { $0.lemma != lemma }
        next.append(KnownLemmaRecord(language: lemma.language, form: lemma.form, updatedAt: date))
        return next.sorted {
            if $0.language != $1.language { return $0.language < $1.language }
            return $0.form < $1.form
        }
    }

    static func remove(
        _ lemma: StudyLemma,
        from records: [KnownLemmaRecord]
    ) -> [KnownLemmaRecord] {
        records.filter { $0.lemma != lemma }
    }
}
