import Foundation
import CryptoKit

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
}

struct Chapter: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var index: Int
    var title: String
    var audioPath: String
    var duration: TimeInterval?
    var startTime: TimeInterval?

    var audioStart: TimeInterval { startTime ?? 0 }
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

struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var start: TimeInterval
    var end: TimeInterval
    var words: [TranscriptWord]
    var ebookText: String?
    var alignmentScore: Double?

    var spokenText: String {
        words.map(\.text).joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayText: String {
        if let ebookText, !(ebookText.isEmpty), (alignmentScore ?? 0) >= 0.52 {
            return ebookText
        }
        return spokenText
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

    var words: [TranscriptWord] { segments.flatMap(\.words) }

    var duration: TimeInterval {
        segments.last?.end ?? 0
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

    enum CodingKeys: String, CodingKey {
        case id, word, category, definition, dictionaryName, dictionaryHTML
        case translation, translationLanguage, translationModel, context, spokenText, ebookText
        case bookID, bookTitle, chapterID, chapterTitle, segmentID, wordID
        case timestamp, addedAt, reviewCount, nextReview
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
        nextReview: Date? = nil
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
    struct Phrase: Decodable, Equatable, Sendable {
        var source: String
        var explanation: String
    }

    var id: String
    var translation: String
    var phrases: [Phrase]

    var glossText: String {
        let notes = phrases.isEmpty
            ? "\(GlossTextFormat.phrasesHeading)\nNone"
            : "\(GlossTextFormat.phrasesHeading)\n" + phrases.map { "• \($0.source) — \($0.explanation)" }.joined(separator: "\n")
        return "\(GlossTextFormat.translationHeading)\n\(translation)\n\n\(notes)"
    }
}

enum GlossTextFormat {
    static let translationHeading = "TRANSLATION:"
    static let phrasesHeading = "PHRASAL VERBS AND PHRASES:"
    static let sentenceMeaningHeading = "MEANING IN THIS SENTENCE:"
    static let examplesHeading = "EXAMPLES:"

    static func isHeading(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return [translationHeading, phrasesHeading, sentenceMeaningHeading, examplesHeading].contains(normalized)
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

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .player: "text.alignleft"
        case .vocab: "bookmark"
        }
    }
}
