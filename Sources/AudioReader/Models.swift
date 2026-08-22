import Foundation
import CryptoKit

struct Book: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var author: String?
    var folderPath: String
    var coverPath: String?
    var ebookPath: String?
    var chapters: [Chapter]
}

struct Chapter: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var index: Int
    var title: String
    var audioPath: String
    var duration: TimeInterval?
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
    var createdAt: Date
    var locale: String
    var segments: [TranscriptSegment]
    var source: String
    var ebookAligned: Bool

    var words: [TranscriptWord] { segments.flatMap(\.words) }

    var duration: TimeInterval {
        segments.last?.end ?? 0
    }
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
        case translation, translationLanguage, context, spokenText, ebookText
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
