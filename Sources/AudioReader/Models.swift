import Foundation
import CryptoKit
#if canImport(AudioReaderDomain)
// Re-export so other AudioReader files see Domain IDs under SPM; Xcode compiles those sources into this module.
@_exported import AudioReaderDomain
#endif
#if canImport(AudioReaderLocalStore)
@_exported import AudioReaderLocalStore
#endif
#if canImport(AudioReaderNetworking)
@_exported import AudioReaderNetworking
#endif

enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    static var displayName: String { "Version \(marketing) (build \(build))" }
}

enum BookSource: String, Codable, Sendable {
    case localFolder
    case files
    case deviceAudiobooks
}

struct Book: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var author: String?
    var folderPath: String
    var coverPath: String?
    var ebookPath: String?
    var chapters: [Chapter]
    var source: BookSource = .localFolder

    var bookID: BookID {
        get { BookID(rawValue: id) }
        set { id = newValue.rawValue }
    }
}

struct Chapter: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var index: Int
    var title: String
    var audioPath: String
    var duration: TimeInterval?
    var startTime: TimeInterval?

    var audioStart: TimeInterval { startTime ?? 0 }

    var chapterID: ChapterID {
        get { ChapterID(rawValue: id) }
        set { id = newValue.rawValue }
    }
}

struct TranscriptWord: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Double?

    var display: String { text }
    var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum EPUBAlignmentStatus: String, Codable, CaseIterable, Sendable {
    case unprocessable
    case wrongBookLikely
    case differentEdition
    case uncertain
    case trusted

    var title: String {
        switch self {
        case .unprocessable: "EPUB unreadable"
        case .wrongBookLikely: "Wrong EPUB likely"
        case .differentEdition: "Different edition"
        case .uncertain: "EPUB match uncertain"
        case .trusted: "EPUB alignment trusted"
        }
    }
}

struct EPUBAlignmentMetrics: Codable, Equatable, Sendable {
    var extractedWordCount: Int
    var extractedSentenceCount: Int
    var sampledAnchorCount: Int
    var matchedAnchorCount: Int
    var matchedCoverage: Double
    var medianScore: Double
    var lowerPercentileScore: Double
    var backwardJumps: Int
    var longestUnmatchedPassage: Int
    var titleSimilarity: Double?
    var authorSimilarity: Double?
    var candidateComparisons: Int
    var detailedAlignmentPerformed: Bool

    static let empty = EPUBAlignmentMetrics(
        extractedWordCount: 0,
        extractedSentenceCount: 0,
        sampledAnchorCount: 0,
        matchedAnchorCount: 0,
        matchedCoverage: 0,
        medianScore: 0,
        lowerPercentileScore: 0,
        backwardJumps: 0,
        longestUnmatchedPassage: 0,
        titleSimilarity: nil,
        authorSimilarity: nil,
        candidateComparisons: 0,
        detailedAlignmentPerformed: false
    )
}

struct EPUBAlignmentAssessment: Codable, Equatable, Sendable {
    var status: EPUBAlignmentStatus
    var reason: String
    var metrics: EPUBAlignmentMetrics
}

struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var start: TimeInterval
    var end: TimeInterval
    var words: [TranscriptWord]
    var ebookText: String?
    var alignmentScore: Double?
    /// Nil for legacy transcripts, which intentionally fails closed.
    var individualEbookMatchTrusted: Bool? = nil
    /// Separate document-level gate. A strong sentence match is insufficient by itself.
    var documentEbookUseAllowed: Bool? = nil

    var spokenText: String {
        words.map(\.text).joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayText: String {
        trustedEbookText ?? spokenText
    }

    var trustedEbookText: String? {
        guard individualEbookMatchTrusted == true,
              documentEbookUseAllowed == true,
              let ebookText,
              !ebookText.isEmpty
        else { return nil }
        return ebookText
    }
}

struct Transcript: Codable, Sendable {
    var chapterID: String
    var audioPath: String
    var chapterStart: TimeInterval? = nil
    var createdAt: Date
    var locale: String
    var segments: [TranscriptSegment]
    var source: String
    var ebookAligned: Bool
    /// Nil for legacy transcripts. Their old 0.52 matches are never trusted automatically.
    var ebookAlignment: EPUBAlignmentAssessment? = nil
    var ebookUseOverride: Bool? = nil

    init(
        chapterID: String,
        audioPath: String,
        chapterStart: TimeInterval? = nil,
        createdAt: Date,
        locale: String,
        segments: [TranscriptSegment],
        source: String,
        ebookAligned: Bool,
        ebookAlignment: EPUBAlignmentAssessment? = nil,
        ebookUseOverride: Bool? = nil
    ) {
        self.chapterID = chapterID
        self.audioPath = audioPath
        self.chapterStart = chapterStart
        self.createdAt = createdAt
        self.locale = locale
        self.segments = segments
        self.source = source
        self.ebookAligned = ebookAligned
        self.ebookAlignment = ebookAlignment
        self.ebookUseOverride = ebookUseOverride
    }

    private enum CodingKeys: String, CodingKey {
        case chapterID
        case audioPath
        case chapterStart
        case createdAt
        case locale
        case segments
        case source
        case ebookAligned
        case ebookAlignment
        case ebookUseOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterID = try container.decode(String.self, forKey: .chapterID)
        audioPath = try container.decode(String.self, forKey: .audioPath)
        chapterStart = try container.decodeIfPresent(TimeInterval.self, forKey: .chapterStart)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        locale = try container.decode(String.self, forKey: .locale)
        segments = try container.decode([TranscriptSegment].self, forKey: .segments)
        source = try container.decode(String.self, forKey: .source)
        ebookAlignment = try container.decodeIfPresent(
            EPUBAlignmentAssessment.self,
            forKey: .ebookAlignment
        )
        ebookUseOverride = try container.decodeIfPresent(Bool.self, forKey: .ebookUseOverride)

        // Legacy transcripts have no document assessment and therefore fail closed,
        // regardless of the old aggregate ebookAligned flag or 0.52 segment scores.
        let documentUseAllowed = ebookAlignment?.status == .trusted || ebookUseOverride == true
        for index in segments.indices {
            segments[index].documentEbookUseAllowed =
                segments[index].individualEbookMatchTrusted == true && documentUseAllowed
        }
        ebookAligned = segments.contains { $0.trustedEbookText != nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chapterID, forKey: .chapterID)
        try container.encode(audioPath, forKey: .audioPath)
        try container.encodeIfPresent(chapterStart, forKey: .chapterStart)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(locale, forKey: .locale)
        try container.encode(segments, forKey: .segments)
        try container.encode(source, forKey: .source)
        try container.encode(ebookAligned, forKey: .ebookAligned)
        try container.encodeIfPresent(ebookAlignment, forKey: .ebookAlignment)
        try container.encodeIfPresent(ebookUseOverride, forKey: .ebookUseOverride)
    }

    var words: [TranscriptWord] { segments.flatMap(\.words) }

    var duration: TimeInterval {
        segments.last?.end ?? 0
    }

    var alignmentStatus: EPUBAlignmentStatus {
        ebookAlignment?.status ?? .uncertain
    }

    mutating func allowEbookTextAnyway() {
        ebookUseOverride = true
        for index in segments.indices {
            segments[index].documentEbookUseAllowed = segments[index].individualEbookMatchTrusted == true
        }
        ebookAligned = segments.contains { $0.trustedEbookText != nil }
    }

    func belongs(to chapter: Chapter) -> Bool {
        guard chapterID == chapter.id else { return false }
        guard let expectedStart = chapter.startTime else { return true }
        guard let chapterStart else { return false }
        return abs(chapterStart - expectedStart) < 0.01
    }
}

struct LibraryScanProgress: Equatable, Sendable {
    var stage: String
    var detail: String
    var completed: Int
    var total: Int

    var fraction: Double? {
        guard total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}

struct BackgroundJobOrigin: Equatable, Sendable {
    var bookID: String?
    var bookTitle: String
    var chapterID: String?
    var chapterTitle: String

    init(
        bookID: String? = nil,
        bookTitle: String,
        chapterID: String? = nil,
        chapterTitle: String
    ) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
    }
}

struct BackgroundJob: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case transcription
        case chapterTranslation
        case sentenceTranslation
        case wordTranslation
        case chapterChat
        case chapterSummary
    }

    enum State: String, Sendable {
        case queued
        case running
    }

    var id: UUID
    var kind: Kind
    var state: State
    var bookID: String?
    var bookTitle: String
    var chapterID: String?
    var chapterTitle: String
    var targetID: String?
    var stage: String
    var detail: String
    var fraction: Double?

    init(
        id: UUID = UUID(),
        kind: Kind,
        state: State = .running,
        bookID: String? = nil,
        bookTitle: String,
        chapterID: String? = nil,
        chapterTitle: String,
        targetID: String? = nil,
        stage: String,
        detail: String,
        fraction: Double?
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.targetID = targetID
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
    }

    var origin: BackgroundJobOrigin {
        BackgroundJobOrigin(
            bookID: bookID,
            bookTitle: bookTitle,
            chapterID: chapterID,
            chapterTitle: chapterTitle
        )
    }

    var symbol: String {
        switch kind {
        case .transcription: "waveform.badge.mic"
        case .chapterTranslation: "character.book.closed"
        case .sentenceTranslation: "text.alignleft"
        case .wordTranslation: "textformat.abc"
        case .chapterChat: "bubble.left.and.bubble.right"
        case .chapterSummary: "list.bullet.rectangle"
        }
    }
}

struct LLMChatMessage: Identifiable, Hashable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
}

enum VocabCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case word
    case phrase
    case sentence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .word: "Words"
        case .phrase: "Phrases"
        case .sentence: "Sentences"
        }
    }

    var symbol: String {
        switch self {
        case .word: "textformat.abc"
        case .phrase: "quote.bubble"
        case .sentence: "text.alignleft"
        }
    }
}

struct VocabEntry: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var word: String
    var category: VocabCategory
    var definition: String?
    var dictionaryName: String?
    var dictionaryHTML: String?
    var translation: String?
    var translationLanguage: String?
    var translationModel: String?
    var sourceLanguage: String?
    var context: String
    var spokenText: String?
    var ebookText: String?
    var bookID: String
    var bookTitle: String
    var chapterID: String
    var chapterTitle: String
    var segmentID: String?
    var wordID: String?
    var timestamp: TimeInterval
    var addedAt: Date
    var reviewCount: Int
    var nextReview: Date?
    var lastReviewedAt: Date?
    var lastReviewQuality: VocabReviewQuality?
    var reviewIntervalDays: Double
    var reviewEaseFactor: Double
    var isInLearnList: Bool

    enum CodingKeys: String, CodingKey {
        case id, word, category, definition, dictionaryName, dictionaryHTML
        case translation, translationLanguage, translationModel, sourceLanguage, context, spokenText, ebookText
        case bookID, bookTitle, chapterID, chapterTitle, segmentID, wordID
        case timestamp, addedAt, reviewCount, nextReview
        case lastReviewedAt, lastReviewQuality, reviewIntervalDays, reviewEaseFactor
        case isInLearnList
    }

    init(
        id: String,
        word: String,
        category: VocabCategory = .word,
        definition: String? = nil,
        dictionaryName: String? = nil,
        dictionaryHTML: String? = nil,
        translation: String? = nil,
        translationLanguage: String? = nil,
        translationModel: String? = nil,
        sourceLanguage: String? = nil,
        context: String,
        spokenText: String? = nil,
        ebookText: String? = nil,
        bookID: String,
        bookTitle: String,
        chapterID: String,
        chapterTitle: String,
        segmentID: String? = nil,
        wordID: String? = nil,
        timestamp: TimeInterval,
        addedAt: Date,
        reviewCount: Int = 0,
        nextReview: Date? = nil,
        lastReviewedAt: Date? = nil,
        lastReviewQuality: VocabReviewQuality? = nil,
        reviewIntervalDays: Double = 0,
        reviewEaseFactor: Double = 2.5,
        isInLearnList: Bool = false
    ) {
        self.id = id
        self.word = word
        self.category = category
        self.definition = definition
        self.dictionaryName = dictionaryName
        self.dictionaryHTML = dictionaryHTML
        self.translation = translation
        self.translationLanguage = translationLanguage
        self.translationModel = translationModel
        self.sourceLanguage = sourceLanguage
        self.context = context
        self.spokenText = spokenText
        self.ebookText = ebookText
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.segmentID = segmentID
        self.wordID = wordID
        self.timestamp = timestamp
        self.addedAt = addedAt
        self.reviewCount = reviewCount
        self.nextReview = nextReview
        self.lastReviewedAt = lastReviewedAt
        self.lastReviewQuality = lastReviewQuality
        self.reviewIntervalDays = reviewIntervalDays
        self.reviewEaseFactor = reviewEaseFactor
        self.isInLearnList = isInLearnList
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        word = try c.decode(String.self, forKey: .word)
        category = try c.decodeIfPresent(VocabCategory.self, forKey: .category) ?? .word
        definition = try c.decodeIfPresent(String.self, forKey: .definition)
        dictionaryName = try c.decodeIfPresent(String.self, forKey: .dictionaryName)
        dictionaryHTML = try c.decodeIfPresent(String.self, forKey: .dictionaryHTML)
        translation = try c.decodeIfPresent(String.self, forKey: .translation)
        translationLanguage = try c.decodeIfPresent(String.self, forKey: .translationLanguage)
        translationModel = try c.decodeIfPresent(String.self, forKey: .translationModel)
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage)
        context = try c.decode(String.self, forKey: .context)
        spokenText = try c.decodeIfPresent(String.self, forKey: .spokenText)
        ebookText = try c.decodeIfPresent(String.self, forKey: .ebookText)
        bookID = try c.decode(String.self, forKey: .bookID)
        bookTitle = try c.decode(String.self, forKey: .bookTitle)
        chapterID = try c.decode(String.self, forKey: .chapterID)
        chapterTitle = try c.decode(String.self, forKey: .chapterTitle)
        segmentID = try c.decodeIfPresent(String.self, forKey: .segmentID)
        wordID = try c.decodeIfPresent(String.self, forKey: .wordID)
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        reviewCount = try c.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        nextReview = try c.decodeIfPresent(Date.self, forKey: .nextReview)
        lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        lastReviewQuality = try c.decodeIfPresent(VocabReviewQuality.self, forKey: .lastReviewQuality)
        reviewIntervalDays = try c.decodeIfPresent(Double.self, forKey: .reviewIntervalDays) ?? 0
        reviewEaseFactor = try c.decodeIfPresent(Double.self, forKey: .reviewEaseFactor) ?? 2.5
        isInLearnList = try c.decodeIfPresent(Bool.self, forKey: .isInLearnList) ?? false
        sanitizeDictionaryFields()
    }

    mutating func sanitizeDictionaryFields() {
        if let html = dictionaryHTML, !html.isEmpty {
            dictionaryHTML = DictionaryLookup.displayHTML(html)
        }
        if let def = definition, DictionaryLookup.looksLikeMarkup(def) {
            if dictionaryHTML == nil || dictionaryHTML?.isEmpty == true {
                dictionaryHTML = DictionaryLookup.displayHTML(def)
            }
            definition = DictionaryLookup.plainPreview(from: def)
        } else if (definition == nil || definition?.isEmpty == true), let html = dictionaryHTML {
            definition = DictionaryLookup.plainPreview(from: html)
        } else if let def = definition, let html = dictionaryHTML, DictionaryLookup.looksLikeMarkup(html) {
            let plain = DictionaryLookup.plainPreview(from: html)
            if !plain.isEmpty, DictionaryLookup.looksLikeMarkup(def) || def.count > 400 {
                definition = plain
            }
        }
    }
}

enum TextRevealKind: String, Equatable, Sendable {
    case word
    case sentence
}

enum GlossKind: String, Codable, Sendable {
    case sentence
    case word
}

enum GlossStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
}

struct GlossEntry: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var kind: GlossKind
    var language: String
    var source: String
    var context: String?
    var text: String
    var status: GlossStatus
    var model: String
    var bookID: String?
    var bookTitle: String?
    var chapterID: String?
    var chapterTitle: String?
    var timestamp: TimeInterval?
    var createdAt: Date
    var decidedAt: Date?
    var replacedText: String? = nil
    var replacedModel: String? = nil

    static func makeID(kind: GlossKind, language: String, source: String, context: String?) -> String {
        let raw = "\(kind.rawValue)|\(language)|\(normalize(source))|\(normalize(context ?? ""))"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum GlossBatch {
    static func pendingSentences(
        in entries: [GlossEntry],
        bookID: String,
        legacyBookID: String,
        chapterID: String,
        legacyChapterID: String,
        language: String,
        currentSentenceSources: [String]
    ) -> [GlossEntry] {
        let normalizedSources = Set(currentSentenceSources.map(GlossEntry.normalize))
        return entries.filter {
            guard $0.kind == .sentence, $0.language == language, $0.status == .pending else { return false }
            if $0.bookID == bookID, $0.chapterID == chapterID { return true }
            return $0.bookID == legacyBookID
                && $0.chapterID == legacyChapterID
                && normalizedSources.contains(GlossEntry.normalize($0.source))
        }
    }

    static func accepting(_ entries: [GlossEntry], at date: Date = Date()) -> [GlossEntry] {
        entries.map { entry in
            var accepted = entry
            accepted.status = .accepted
            accepted.decidedAt = date
            accepted.replacedText = nil
            accepted.replacedModel = nil
            return accepted
        }
    }

    static func merging(_ updates: [GlossEntry], into entries: [GlossEntry]) -> [GlossEntry] {
        guard !updates.isEmpty else { return entries }
        var result = entries
        let indexByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        var newEntries: [GlossEntry] = []
        var newIndexByID: [String: Int] = [:]
        newEntries.reserveCapacity(updates.count)
        for update in updates {
            if let index = indexByID[update.id] {
                result[index] = update
            } else if let index = newIndexByID[update.id] {
                newEntries[index] = update
            } else {
                newIndexByID[update.id] = newEntries.count
                newEntries.append(update)
            }
        }
        if !newEntries.isEmpty {
            result.insert(contentsOf: newEntries.reversed(), at: 0)
        }
        return result
    }
}

final class ChapterGlossIndex {
    private var byID: [String: GlossEntry] = [:]
    private var bySource: [String: GlossEntry] = [:]
    private let language: String

    init(glosses: [GlossEntry], language: String) {
        self.language = language
        for gloss in glosses where gloss.kind == .sentence && gloss.language == language && gloss.status != .rejected {
            if byID[gloss.id] == nil { byID[gloss.id] = gloss }
            let source = GlossEntry.normalize(gloss.source)
            if bySource[source] == nil { bySource[source] = gloss }
        }
    }

    func gloss(source: String) -> GlossEntry? {
        let id = GlossEntry.makeID(kind: .sentence, language: language, source: source, context: nil)
        return byID[id] ?? bySource[GlossEntry.normalize(source)]
    }
}

struct ChapterGlossIndexCache {
    private var generation: Int?
    private var language: String?
    private var cachedIndex: ChapterGlossIndex?

    mutating func index(glosses: [GlossEntry], generation: Int, language: String) -> ChapterGlossIndex {
        if let cachedIndex, self.generation == generation, self.language == language {
            return cachedIndex
        }
        let index = ChapterGlossIndex(glosses: glosses, language: language)
        self.generation = generation
        self.language = language
        cachedIndex = index
        return index
    }
}

struct ChapterTranslationResult: Decodable, Equatable, Sendable {
    struct Note: Decodable, Equatable, Sendable {
        var source: String
        var category: String
        var explanation: String
    }

    var id: String
    var translation: String
    var notes: [Note]

    init(id: String, translation: String, notes: [Note] = []) {
        self.id = id
        self.translation = translation
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case translation
        case notes
        case phrases
    }

    private struct LegacyPhrase: Decodable {
        var source: String
        var explanation: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        translation = try container.decode(String.self, forKey: .translation)
        if let decodedNotes = try container.decodeIfPresent([Note].self, forKey: .notes) {
            notes = decodedNotes
        } else {
            notes = try container.decodeIfPresent([LegacyPhrase].self, forKey: .phrases)?.map {
                Note(source: $0.source, category: "phrase", explanation: $0.explanation)
            } ?? []
        }
    }

    var glossText: String {
        let renderedNotes = notes.isEmpty
            ? "\(GlossTextFormat.learningNotesHeading)\nNone"
            : "\(GlossTextFormat.learningNotesHeading)\n" + notes.map {
                "• \($0.source) — [\(Self.categoryLabel($0.category))] \($0.explanation)"
            }.joined(separator: "\n")
        return "\(GlossTextFormat.translationHeading)\n\(translation)\n\n\(renderedNotes)"
    }

    private static func categoryLabel(_ raw: String) -> String {
        switch raw {
        case "phrasal_verb": "Phrasal verb"
        case "phrase": "Phrase"
        case "idiom": "Idiom"
        case "challenging_word": "Challenging word"
        case "challenging_combination": "Challenging combination"
        case "concept": "Concept"
        default:
            raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

enum GlossTextFormat {
    static let translationHeading = "TRANSLATION:"
    static let phrasesHeading = "PHRASAL VERBS AND PHRASES:"
    static let learningNotesHeading = "LANGUAGE AND CONTEXT NOTES:"
    static let sentenceMeaningHeading = "MEANING IN THIS SENTENCE:"
    static let examplesHeading = "EXAMPLES:"

    static func isHeading(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return [translationHeading, phrasesHeading, learningNotesHeading, sentenceMeaningHeading, examplesHeading].contains(normalized)
            || line.hasPrefix("译文")
            || line.hasPrefix("短语")
            || line.hasPrefix("本句释义")
            || line.hasPrefix("例句")
            || line.hasPrefix("释义")
    }
}

struct ChapterTranslationParseResult: Equatable, Sendable {
    var results: [ChapterTranslationResult]
    var missingIDs: [String]
}

enum ChapterTranslationMode: String, Codable, Sendable {
    case continueFromCheckpoint
    case untranslatedOnly
    case retranslateAll
}

enum ChapterTranslationStatus: String, Codable, Sendable {
    case inProgress
    case awaitingReview
    case allAccepted
}

struct ChapterTranslationCheckpoint: Identifiable, Codable, Equatable, Sendable {
    var chapterID: String
    var language: String
    var mode: ChapterTranslationMode
    var nextSegmentIndex: Int
    var totalSentences: Int
    var status: ChapterTranslationStatus
    var updatedAt: Date

    var id: String { Self.makeID(chapterID: chapterID, language: language) }

    static func makeID(chapterID: String, language: String) -> String {
        "\(chapterID)|\(language)"
    }

    init(
        chapterID: String,
        language: String,
        mode: ChapterTranslationMode,
        nextSegmentIndex: Int,
        totalSentences: Int,
        status: ChapterTranslationStatus,
        updatedAt: Date
    ) {
        self.chapterID = chapterID
        self.language = language
        self.mode = mode
        self.nextSegmentIndex = nextSegmentIndex
        self.totalSentences = totalSentences
        self.status = status
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterID = try container.decode(String.self, forKey: .chapterID)
        language = try container.decode(String.self, forKey: .language)
        mode = try container.decodeIfPresent(ChapterTranslationMode.self, forKey: .mode) ?? .untranslatedOnly
        nextSegmentIndex = try container.decode(Int.self, forKey: .nextSegmentIndex)
        totalSentences = try container.decode(Int.self, forKey: .totalSentences)
        status = try container.decode(ChapterTranslationStatus.self, forKey: .status)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

enum ChapterTranslationBatchError: LocalizedError {
    case invalidResponse
    case missingSentences

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The LLM returned a chapter block in an unreadable format."
        case .missingSentences:
            "The LLM did not return one translation for every sentence in the block."
        }
    }
}

enum ChapterTranslationBatch {
    static let maximumAttempts = 3

    private struct Envelope: Decodable {
        var translations: [ChapterTranslationResult]
    }

    static func blocks(_ segments: [TranscriptSegment], size: Int) -> [[TranscriptSegment]] {
        let blockSize = max(1, size)
        return stride(from: 0, to: segments.count, by: blockSize).map { start in
            Array(segments[start..<min(start + blockSize, segments.count)])
        }
    }

    /// Same grouping as `blocks`, so tapping one sentence reuses the chapter-translation chunk.
    static func alignedBlock(
        containing target: TranscriptSegment,
        in segments: [TranscriptSegment],
        size: Int
    ) -> [TranscriptSegment] {
        blocks(segments, size: size).first { block in
            block.contains { $0.id == target.id }
        } ?? [target]
    }

    static func parse(_ raw: String, expectedIDs: [String]) throws -> [ChapterTranslationResult] {
        let parsed = try parseAvailable(raw, expectedIDs: expectedIDs)
        guard parsed.missingIDs.isEmpty else {
            throw ChapterTranslationBatchError.missingSentences
        }
        return parsed.results
    }

    static func parseAvailable(_ raw: String, expectedIDs: [String]) throws -> ChapterTranslationParseResult {
        let decoded = try decodeResults(raw)
        let expected = Set(expectedIDs)
        var byID: [String: ChapterTranslationResult] = [:]
        for result in decoded where expected.contains(result.id) {
            let translation = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty, byID[result.id] == nil else { continue }
            byID[result.id] = result
        }
        return ChapterTranslationParseResult(
            results: expectedIDs.compactMap { byID[$0] },
            missingIDs: expectedIDs.filter { byID[$0] == nil }
        )
    }

    private static func decodeResults(_ raw: String) throws -> [ChapterTranslationResult] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            candidates.append(String(trimmed[first...last]))
        }
        if let first = trimmed.firstIndex(of: "["), let last = trimmed.lastIndex(of: "]"), first <= last {
            candidates.append(String(trimmed[first...last]))
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
                return envelope.translations
            }
            if let array = try? JSONDecoder().decode([ChapterTranslationResult].self, from: data) {
                return array
            }
        }
        throw ChapterTranslationBatchError.invalidResponse
    }
}

enum PlaybackLoop: Equatable, Sendable {
    case off
    case sentence
    case ab(start: TimeInterval, end: TimeInterval)
}

enum TextSource: String, CaseIterable, Identifiable, Sendable {
    case spoken = "Spoken"
    case original = "Ebook"
    case dual = "Both"

    var id: String { rawValue }
}

enum AppTab: String, CaseIterable, Identifiable {
    case library = "Library"
    case player = "Player"
    case vocab = "Words"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .player: "text.alignleft"
        case .vocab: "bookmark"
        case .settings: "gearshape"
        }
    }
}
