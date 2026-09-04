import Foundation

public struct StoredSettings: Codable, Equatable, Sendable {
    public var libraryPath: String
    public var playbackRate: Double
    public var textSource: String
    public var skipSeconds: Double
    public var transcriptionLanguage: String
    public var bookTranscriptionLanguages: [String: String]?
    public var readerLanguageLevel: String
    public var targetLanguage: String
    public var llmProvider: String?
    public var grokAuthentication: String?
    public var grokEndpoint: String?
    public var grokModel: String?
    public var grokEffort: String?
    public var qwenEndpoint: String?
    public var qwenModel: String?
    public var qwenThinking: Bool?
    public var qwenEffort: String?
    public var qwenEffortPolicyVersion: Int?
    public var openAIAuthentication: String?
    public var openAIEndpoint: String?
    public var openAIModel: String?
    public var openAIEffort: String?
    public var sentenceContextCount: Int
    public var chapterTranslationBlockSize: Int
    public var chatContextCount: Int
    public var autoTranslate: Bool
    public var playOnSelect: Bool
    public var deepReadingMode: Bool
    public var readAndPauseMode: Bool?
    public var showStudyOverlay: Bool
    public var vocabReviewPrompt: String
    public var appearance: String
    public var preferredDictionary: String
    public var lookupPanelWidth: Double
    public var readerFontScale: Double
    public var readerFont: String
    public var readerBold: Bool
    public var readerLineSpacing: Double
    public var readerWordSpacing: Double
    public var readerMargin: Double

    public init(
        libraryPath: String = "",
        playbackRate: Double = 1.0,
        textSource: String = "Spoken",
        skipSeconds: Double = 5,
        transcriptionLanguage: String = "en-US",
        bookTranscriptionLanguages: [String: String]? = nil,
        readerLanguageLevel: String = "intermediate",
        targetLanguage: String = "zh-Hans",
        llmProvider: String? = nil,
        grokAuthentication: String? = nil,
        grokEndpoint: String? = nil,
        grokModel: String? = nil,
        grokEffort: String? = nil,
        qwenEndpoint: String? = nil,
        qwenModel: String? = nil,
        qwenThinking: Bool? = nil,
        qwenEffort: String? = nil,
        qwenEffortPolicyVersion: Int? = nil,
        openAIAuthentication: String? = nil,
        openAIEndpoint: String? = nil,
        openAIModel: String? = nil,
        openAIEffort: String? = nil,
        sentenceContextCount: Int = 2,
        chapterTranslationBlockSize: Int = 5,
        chatContextCount: Int = 3,
        autoTranslate: Bool = false,
        playOnSelect: Bool = true,
        deepReadingMode: Bool = false,
        readAndPauseMode: Bool? = nil,
        showStudyOverlay: Bool = false,
        vocabReviewPrompt: String = "recognition",
        appearance: String = "system",
        preferredDictionary: String = "牛津英汉汉英词典",
        lookupPanelWidth: Double = 420,
        readerFontScale: Double = 1.0,
        readerFont: String = "New York",
        readerBold: Bool = false,
        readerLineSpacing: Double = 1.0,
        readerWordSpacing: Double = 2.0,
        readerMargin: Double = 32
    ) {
        self.libraryPath = libraryPath
        self.playbackRate = playbackRate
        self.textSource = textSource
        self.skipSeconds = skipSeconds
        self.transcriptionLanguage = transcriptionLanguage
        self.bookTranscriptionLanguages = bookTranscriptionLanguages
        self.readerLanguageLevel = readerLanguageLevel
        self.targetLanguage = targetLanguage
        self.llmProvider = llmProvider
        self.grokAuthentication = grokAuthentication
        self.grokEndpoint = grokEndpoint
        self.grokModel = grokModel
        self.grokEffort = grokEffort
        self.qwenEndpoint = qwenEndpoint
        self.qwenModel = qwenModel
        self.qwenThinking = qwenThinking
        self.qwenEffort = qwenEffort
        self.qwenEffortPolicyVersion = qwenEffortPolicyVersion
        self.openAIAuthentication = openAIAuthentication
        self.openAIEndpoint = openAIEndpoint
        self.openAIModel = openAIModel
        self.openAIEffort = openAIEffort
        self.sentenceContextCount = sentenceContextCount
        self.chapterTranslationBlockSize = chapterTranslationBlockSize
        self.chatContextCount = chatContextCount
        self.autoTranslate = autoTranslate
        self.playOnSelect = playOnSelect
        self.deepReadingMode = deepReadingMode
        self.readAndPauseMode = readAndPauseMode
        self.showStudyOverlay = showStudyOverlay
        self.vocabReviewPrompt = vocabReviewPrompt
        self.appearance = appearance
        self.preferredDictionary = preferredDictionary
        self.lookupPanelWidth = lookupPanelWidth
        self.readerFontScale = readerFontScale
        self.readerFont = readerFont
        self.readerBold = readerBold
        self.readerLineSpacing = readerLineSpacing
        self.readerWordSpacing = readerWordSpacing
        self.readerMargin = readerMargin
    }

    public static let `default` = StoredSettings()
}

public struct StoredBook: Codable, Equatable, Sendable {
    public var id: BookID
    public var title: String
    public var author: String?
    public var source: String
    public var chapters: [StoredChapter]

    public init(
        id: BookID,
        title: String,
        author: String? = nil,
        source: String,
        chapters: [StoredChapter]
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.source = source
        self.chapters = chapters
    }
}

public struct StoredChapter: Codable, Equatable, Sendable {
    public var id: ChapterID
    public var index: Int
    public var title: String
    public var duration: TimeInterval?
    public var startTime: TimeInterval?
    /// Identifies the published EPUB section independently of audio chapter order.
    public var ebookSectionIndex: Int?

    public init(
        id: ChapterID,
        index: Int,
        title: String,
        duration: TimeInterval? = nil,
        startTime: TimeInterval? = nil,
        ebookSectionIndex: Int? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.duration = duration
        self.startTime = startTime
        self.ebookSectionIndex = ebookSectionIndex
    }
}

/// Device-local media reference. Paths and fingerprints never enter the cloud
/// book payload, but remain typed and durable across local launches.
public struct StoredLocalAsset: Codable, Equatable, Sendable {
    public var id: AssetID
    public var bookID: BookID
    public var kind: String
    public var localMediaKey: String
    public var contentHash: String?
    public var byteCount: Int64?
    public var metadata: [String: String]

    public init(
        id: AssetID,
        bookID: BookID,
        kind: String,
        localMediaKey: String,
        contentHash: String? = nil,
        byteCount: Int64? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.bookID = bookID
        self.kind = kind
        self.localMediaKey = localMediaKey
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.metadata = metadata
    }
}

/// A verified v2 immutable object installed on this device. The manifest is compact; bytes stay
/// at `localObjectPath` and are never copied into SQLite.
public struct StoredSyncAssetManifest: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var revisionID: String?
    public var bookID: String?
    public var chapterID: String?
    public var contentType: String
    public var encoding: String
    public var sha256: String
    public var compressedBytes: Int64
    public var originalBytes: Int64
    public var segmentCount: Int?
    public var localObjectPath: String

    public init(
        id: String, kind: String, revisionID: String? = nil, bookID: String? = nil,
        chapterID: String? = nil, contentType: String, encoding: String, sha256: String,
        compressedBytes: Int64, originalBytes: Int64, segmentCount: Int? = nil,
        localObjectPath: String
    ) {
        self.id = id; self.kind = kind; self.revisionID = revisionID; self.bookID = bookID
        self.chapterID = chapterID; self.contentType = contentType; self.encoding = encoding
        self.sha256 = sha256; self.compressedBytes = compressedBytes
        self.originalBytes = originalBytes; self.segmentCount = segmentCount
        self.localObjectPath = localObjectPath
    }
}

public struct StoredTranscriptWord: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Double?

    public init(
        id: String,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct StoredTranscriptSegment: Codable, Equatable, Sendable {
    public var id: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var words: [StoredTranscriptWord]
    public var ebookText: String?
    public var alignmentScore: Double?
    public var individualEbookMatchTrusted: Bool?
    public var documentEbookUseAllowed: Bool?

    public init(
        id: String,
        start: TimeInterval,
        end: TimeInterval,
        words: [StoredTranscriptWord],
        ebookText: String? = nil,
        alignmentScore: Double? = nil,
        individualEbookMatchTrusted: Bool? = nil,
        documentEbookUseAllowed: Bool? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.words = words
        self.ebookText = ebookText
        self.alignmentScore = alignmentScore
        self.individualEbookMatchTrusted = individualEbookMatchTrusted
        self.documentEbookUseAllowed = documentEbookUseAllowed
    }
}

public struct StoredEPUBAlignmentMetrics: Codable, Equatable, Sendable {
    public var extractedWordCount: Int
    public var extractedSentenceCount: Int
    public var sampledAnchorCount: Int
    public var matchedAnchorCount: Int
    public var matchedCoverage: Double
    public var medianScore: Double
    public var lowerPercentileScore: Double
    public var backwardJumps: Int
    public var longestUnmatchedPassage: Int
    public var titleSimilarity: Double?
    public var authorSimilarity: Double?
    public var candidateComparisons: Int
    public var detailedAlignmentPerformed: Bool

    public init(
        extractedWordCount: Int = 0,
        extractedSentenceCount: Int = 0,
        sampledAnchorCount: Int = 0,
        matchedAnchorCount: Int = 0,
        matchedCoverage: Double = 0,
        medianScore: Double = 0,
        lowerPercentileScore: Double = 0,
        backwardJumps: Int = 0,
        longestUnmatchedPassage: Int = 0,
        titleSimilarity: Double? = nil,
        authorSimilarity: Double? = nil,
        candidateComparisons: Int = 0,
        detailedAlignmentPerformed: Bool = false
    ) {
        self.extractedWordCount = extractedWordCount
        self.extractedSentenceCount = extractedSentenceCount
        self.sampledAnchorCount = sampledAnchorCount
        self.matchedAnchorCount = matchedAnchorCount
        self.matchedCoverage = matchedCoverage
        self.medianScore = medianScore
        self.lowerPercentileScore = lowerPercentileScore
        self.backwardJumps = backwardJumps
        self.longestUnmatchedPassage = longestUnmatchedPassage
        self.titleSimilarity = titleSimilarity
        self.authorSimilarity = authorSimilarity
        self.candidateComparisons = candidateComparisons
        self.detailedAlignmentPerformed = detailedAlignmentPerformed
    }

    public static let empty = StoredEPUBAlignmentMetrics()
}

public struct StoredEPUBAlignment: Codable, Equatable, Sendable {
    public var status: String
    public var reason: String
    public var metrics: StoredEPUBAlignmentMetrics

    public init(
        status: String,
        reason: String,
        metrics: StoredEPUBAlignmentMetrics = .empty
    ) {
        self.status = status
        self.reason = reason
        self.metrics = metrics
    }
}

public struct StoredTranscript: Codable, Equatable, Sendable {
    public var chapterID: ChapterID
    public var localMediaKey: String
    public var chapterStart: TimeInterval?
    public var createdAt: Date
    public var locale: String
    public var source: String
    public var ebookAligned: Bool
    public var ebookAlignment: StoredEPUBAlignment?
    public var ebookUseOverride: Bool?
    public var segments: [StoredTranscriptSegment]

    public init(
        chapterID: ChapterID,
        localMediaKey: String,
        chapterStart: TimeInterval? = nil,
        createdAt: Date,
        locale: String,
        source: String,
        ebookAligned: Bool,
        ebookAlignment: StoredEPUBAlignment? = nil,
        ebookUseOverride: Bool? = nil,
        segments: [StoredTranscriptSegment]
    ) {
        self.chapterID = chapterID
        self.localMediaKey = localMediaKey
        self.chapterStart = chapterStart
        self.createdAt = createdAt
        self.locale = locale
        self.source = source
        self.ebookAligned = ebookAligned
        self.ebookAlignment = ebookAlignment
        self.ebookUseOverride = ebookUseOverride
        self.segments = segments
    }
}

public enum VocabularyPartOfSpeech: String, Codable, CaseIterable, Sendable {
    case noun, verb, adjective, adverb, pronoun, determiner, preposition, conjunction, interjection
    case phrase, sentence, unknown
}

public enum VocabularyCanonicalizationSource: String, Codable, Sendable {
    case normalized
    case appleNaturalLanguage
    case irregularRule
    case userEdited
    case llmFallback
    case cachedLLM
}

public enum VocabularyCanonicalizationStatus: String, Codable, Sendable {
    case confirmed
    case needsReview
}

public enum VocabularyCaptureSource: String, Codable, Sendable {
    case explicitWord
    case explicitPhrase
    case explicitSentence
    case acceptedSentenceTranslation
    case automaticPhraseSuggestion
}

public struct StoredVocabularyOccurrence: Codable, Equatable, Sendable {
    public var id: VocabularyOccurrenceID
    public var surface: String
    public var canonicalForm: String
    public var partOfSpeech: String
    public var senseID: String?
    public var canonicalizationSource: String
    public var canonicalizationConfidence: Double
    public var canonicalizationStatus: String
    public var canonicalizationTraceID: String?
    public var captureSource: String
    public var reviewEligible: Bool
    public var category: String
    public var definition: String?
    public var dictionaryName: String?
    public var dictionaryHTML: String?
    public var translation: String?
    public var translationLanguage: String?
    public var translationModel: String?
    public var sourceLanguage: String?
    public var context: String
    public var spokenText: String?
    public var ebookText: String?
    public var bookID: BookID
    public var bookTitle: String
    public var chapterID: ChapterID
    public var chapterTitle: String
    public var segmentID: String?
    public var wordID: String?
    public var timestamp: TimeInterval
    public var addedAt: Date
    public var reviewCount: Int
    public var nextReview: Date?
    public var lastReviewedAt: Date?
    public var lastReviewQuality: String?
    public var reviewIntervalDays: Double
    public var reviewEaseFactor: Double
    public var isInLearnList: Bool

    public init(
        id: VocabularyOccurrenceID,
        surface: String,
        canonicalForm: String? = nil,
        partOfSpeech: String = VocabularyPartOfSpeech.unknown.rawValue,
        senseID: String? = nil,
        canonicalizationSource: String = VocabularyCanonicalizationSource.normalized.rawValue,
        canonicalizationConfidence: Double = 0.4,
        canonicalizationStatus: String = VocabularyCanonicalizationStatus.needsReview.rawValue,
        canonicalizationTraceID: String? = nil,
        captureSource: String = VocabularyCaptureSource.explicitWord.rawValue,
        reviewEligible: Bool = true,
        category: String,
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
        bookID: BookID,
        bookTitle: String,
        chapterID: ChapterID,
        chapterTitle: String,
        segmentID: String? = nil,
        wordID: String? = nil,
        timestamp: TimeInterval,
        addedAt: Date,
        reviewCount: Int = 0,
        nextReview: Date? = nil,
        lastReviewedAt: Date? = nil,
        lastReviewQuality: String? = nil,
        reviewIntervalDays: Double = 0,
        reviewEaseFactor: Double = 2.5,
        isInLearnList: Bool = false
    ) {
        self.id = id
        self.surface = surface
        self.canonicalForm = canonicalForm ?? surface
        self.partOfSpeech = partOfSpeech
        self.senseID = senseID
        self.canonicalizationSource = canonicalizationSource
        self.canonicalizationConfidence = canonicalizationConfidence
        self.canonicalizationStatus = canonicalizationStatus
        self.canonicalizationTraceID = canonicalizationTraceID
        self.captureSource = captureSource
        self.reviewEligible = reviewEligible
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

    private enum CodingKeys: String, CodingKey {
        case id, surface, canonicalForm, partOfSpeech, senseID
        case canonicalizationSource, canonicalizationConfidence, canonicalizationStatus, canonicalizationTraceID
        case captureSource, reviewEligible, category, definition, dictionaryName, dictionaryHTML
        case translation, translationLanguage, translationModel, sourceLanguage, context, spokenText, ebookText
        case bookID, bookTitle, chapterID, chapterTitle, segmentID, wordID, timestamp, addedAt
        case reviewCount, nextReview, lastReviewedAt, lastReviewQuality, reviewIntervalDays, reviewEaseFactor
        case isInLearnList
    }

    /// Additive decoding keeps current vNext stores readable while the later
    /// persistence cutover introduces separate occurrence and study-card rows.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let surface = try values.decode(String.self, forKey: .surface)
        let category = try values.decode(String.self, forKey: .category)
        let reviewCount = try values.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        let isInLearnList = try values.decodeIfPresent(Bool.self, forKey: .isInLearnList) ?? false
        let storedCaptureSource = try values.decodeIfPresent(String.self, forKey: .captureSource)
        let captureSource = storedCaptureSource
            ?? Self.defaultCaptureSource(for: category, reviewed: reviewCount > 0, saved: isInLearnList).rawValue
        let reviewEligible = (try values.decodeIfPresent(Bool.self, forKey: .reviewEligible))
            ?? (VocabularyCaptureSource(rawValue: captureSource)?.defaultStoredReviewEligibility ?? true)
        self.init(
            id: try values.decode(VocabularyOccurrenceID.self, forKey: .id),
            surface: surface,
            canonicalForm: try values.decodeIfPresent(String.self, forKey: .canonicalForm),
            partOfSpeech: try values.decodeIfPresent(String.self, forKey: .partOfSpeech)
                ?? VocabularyPartOfSpeech.unknown.rawValue,
            senseID: try values.decodeIfPresent(String.self, forKey: .senseID),
            canonicalizationSource: try values.decodeIfPresent(String.self, forKey: .canonicalizationSource)
                ?? VocabularyCanonicalizationSource.normalized.rawValue,
            canonicalizationConfidence: try values.decodeIfPresent(Double.self, forKey: .canonicalizationConfidence) ?? 0.4,
            canonicalizationStatus: try values.decodeIfPresent(String.self, forKey: .canonicalizationStatus)
                ?? VocabularyCanonicalizationStatus.needsReview.rawValue,
            canonicalizationTraceID: try values.decodeIfPresent(String.self, forKey: .canonicalizationTraceID),
            captureSource: captureSource,
            reviewEligible: reviewCount > 0 ? true : reviewEligible,
            category: category,
            definition: try values.decodeIfPresent(String.self, forKey: .definition),
            dictionaryName: try values.decodeIfPresent(String.self, forKey: .dictionaryName),
            dictionaryHTML: try values.decodeIfPresent(String.self, forKey: .dictionaryHTML),
            translation: try values.decodeIfPresent(String.self, forKey: .translation),
            translationLanguage: try values.decodeIfPresent(String.self, forKey: .translationLanguage),
            translationModel: try values.decodeIfPresent(String.self, forKey: .translationModel),
            sourceLanguage: try values.decodeIfPresent(String.self, forKey: .sourceLanguage),
            context: try values.decode(String.self, forKey: .context),
            spokenText: try values.decodeIfPresent(String.self, forKey: .spokenText),
            ebookText: try values.decodeIfPresent(String.self, forKey: .ebookText),
            bookID: try values.decode(BookID.self, forKey: .bookID),
            bookTitle: try values.decode(String.self, forKey: .bookTitle),
            chapterID: try values.decode(ChapterID.self, forKey: .chapterID),
            chapterTitle: try values.decode(String.self, forKey: .chapterTitle),
            segmentID: try values.decodeIfPresent(String.self, forKey: .segmentID),
            wordID: try values.decodeIfPresent(String.self, forKey: .wordID),
            timestamp: try values.decode(TimeInterval.self, forKey: .timestamp),
            addedAt: try values.decode(Date.self, forKey: .addedAt),
            reviewCount: reviewCount,
            nextReview: try values.decodeIfPresent(Date.self, forKey: .nextReview),
            lastReviewedAt: try values.decodeIfPresent(Date.self, forKey: .lastReviewedAt),
            lastReviewQuality: try values.decodeIfPresent(String.self, forKey: .lastReviewQuality),
            reviewIntervalDays: try values.decodeIfPresent(Double.self, forKey: .reviewIntervalDays) ?? 0,
            reviewEaseFactor: try values.decodeIfPresent(Double.self, forKey: .reviewEaseFactor) ?? 2.5,
            isInLearnList: isInLearnList
        )
    }

    private static func defaultCaptureSource(
        for category: String,
        reviewed: Bool,
        saved: Bool
    ) -> VocabularyCaptureSource {
        switch category {
        case "phrase": reviewed || saved ? .explicitPhrase : .automaticPhraseSuggestion
        case "sentence": reviewed || saved ? .explicitSentence : .acceptedSentenceTranslation
        default: .explicitWord
        }
    }
}

private extension VocabularyCaptureSource {
    var defaultStoredReviewEligibility: Bool {
        switch self {
        case .explicitWord, .explicitPhrase, .explicitSentence: true
        case .acceptedSentenceTranslation, .automaticPhraseSuggestion: false
        }
    }
}

/// The scheduler-owned subset of a vocabulary occurrence. Review persistence
/// must not replace user-controlled or sync-updated vocabulary fields.
public struct StoredVocabularyReviewSchedule: Equatable, Sendable {
    public var vocabularyID: VocabularyOccurrenceID
    public var reviewCount: Int
    public var nextReview: Date?
    public var lastReviewedAt: Date?
    public var lastReviewQuality: String?
    public var reviewIntervalDays: Double
    public var reviewEaseFactor: Double

    public init(
        vocabularyID: VocabularyOccurrenceID,
        reviewCount: Int,
        nextReview: Date?,
        lastReviewedAt: Date?,
        lastReviewQuality: String?,
        reviewIntervalDays: Double,
        reviewEaseFactor: Double
    ) {
        self.vocabularyID = vocabularyID
        self.reviewCount = reviewCount
        self.nextReview = nextReview
        self.lastReviewedAt = lastReviewedAt
        self.lastReviewQuality = lastReviewQuality
        self.reviewIntervalDays = reviewIntervalDays
        self.reviewEaseFactor = reviewEaseFactor
    }

    public init(_ occurrence: StoredVocabularyOccurrence) {
        self.init(
            vocabularyID: occurrence.id,
            reviewCount: occurrence.reviewCount,
            nextReview: occurrence.nextReview,
            lastReviewedAt: occurrence.lastReviewedAt,
            lastReviewQuality: occurrence.lastReviewQuality,
            reviewIntervalDays: occurrence.reviewIntervalDays,
            reviewEaseFactor: occurrence.reviewEaseFactor
        )
    }

    public func merging(into occurrence: StoredVocabularyOccurrence) -> StoredVocabularyOccurrence {
        var merged = occurrence
        merged.reviewCount = reviewCount
        merged.nextReview = nextReview
        merged.lastReviewedAt = lastReviewedAt
        merged.lastReviewQuality = lastReviewQuality
        merged.reviewIntervalDays = reviewIntervalDays
        merged.reviewEaseFactor = reviewEaseFactor
        return merged
    }
}

/// Exact reader resume position is chapter-relative so M4B chapter offsets can
/// change without moving the user's logical place in the chapter.
public struct StoredReaderProgress: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var bookID: BookID
    public var chapterID: ChapterID
    public var relativeSeconds: TimeInterval
    public var updatedAt: Date
    public var deviceID: String
    public var revision: Int64

    public init(
        id: String,
        bookID: BookID,
        chapterID: ChapterID,
        relativeSeconds: TimeInterval,
        updatedAt: Date,
        deviceID: String,
        revision: Int64 = 0
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.relativeSeconds = relativeSeconds
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.revision = revision
    }
}

public struct StoredReaderProgressState: Equatable, Sendable {
    public var current: StoredReaderProgress
    public var conflicts: [StoredReaderProgress]

    public init(current: StoredReaderProgress, conflicts: [StoredReaderProgress]) {
        self.current = current
        self.conflicts = conflicts
    }
}

public enum ReaderProgressMergeOutcome: Equatable, Sendable {
    case inserted
    case replacedCurrent
    case conflictRetained
    case unchanged
}

public struct StoredKnownLemma: Codable, Equatable, Sendable {
    public var language: String
    public var form: String
    public var updatedAt: Date

    public init(language: String, form: String, updatedAt: Date) {
        self.language = language
        self.form = form
        self.updatedAt = updatedAt
    }
}

public struct StoredReviewEvent: Codable, Equatable, Sendable {
    public var id: ReviewEventID
    public var vocabularyID: VocabularyOccurrenceID
    public var cardID: String?
    public var face: String
    public var rating: String
    public var reviewedAt: Date

    public init(
        id: ReviewEventID,
        vocabularyID: VocabularyOccurrenceID,
        cardID: String? = nil,
        face: String,
        rating: String,
        reviewedAt: Date
    ) {
        self.id = id
        self.vocabularyID = vocabularyID
        self.cardID = cardID
        self.face = face
        self.rating = rating
        self.reviewedAt = reviewedAt
    }
}

public enum AssistantResultKind: String, Codable, Sendable {
    case sentenceGloss
    case wordGloss
    case chapterSummary
    case chapterTranslation
}

public enum AssistantResultStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
    case stale
    case edited
    case replaced
}

public struct StoredAssistantResultHistory: Codable, Equatable, Sendable {
    public var resultID: String
    public var sequence: Int64
    public var status: AssistantResultStatus
    public var text: String
    public var model: String
    public var promptVersion: String
    public var modelPolicyHash: String
    public var recordedAt: Date
    public var sharedCacheEntryID: String?

    public init(
        resultID: String,
        sequence: Int64,
        status: AssistantResultStatus,
        text: String,
        model: String,
        promptVersion: String,
        modelPolicyHash: String,
        recordedAt: Date,
        sharedCacheEntryID: String? = nil
    ) {
        self.resultID = resultID
        self.sequence = sequence
        self.status = status
        self.text = text
        self.model = model
        self.promptVersion = promptVersion
        self.modelPolicyHash = modelPolicyHash
        self.recordedAt = recordedAt
        self.sharedCacheEntryID = sharedCacheEntryID
    }
}

public struct StoredAssistantResult: Codable, Equatable, Sendable {
    public var id: String
    public var kind: AssistantResultKind
    public var status: AssistantResultStatus
    public var language: String
    public var model: String
    public var promptVersion: String
    public var modelPolicyHash: String
    public var bookID: BookID?
    public var bookTitle: String?
    public var chapterID: ChapterID?
    public var chapterTitle: String?
    public var source: String
    public var text: String
    public var context: String?
    public var timestamp: TimeInterval?
    public var createdAt: Date
    public var decidedAt: Date?
    public var replacedText: String?
    public var replacedModel: String?
    /// Optional provenance only. Durable private text never reads through this shared cache row.
    public var sharedCacheEntryID: String?

    public init(
        id: String,
        kind: AssistantResultKind,
        status: AssistantResultStatus,
        language: String,
        model: String,
        promptVersion: String = "local",
        modelPolicyHash: String = "local",
        bookID: BookID? = nil,
        bookTitle: String? = nil,
        chapterID: ChapterID? = nil,
        chapterTitle: String? = nil,
        source: String,
        text: String,
        context: String? = nil,
        timestamp: TimeInterval? = nil,
        createdAt: Date,
        decidedAt: Date? = nil,
        replacedText: String? = nil,
        replacedModel: String? = nil,
        sharedCacheEntryID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.language = language
        self.model = model
        self.promptVersion = promptVersion
        self.modelPolicyHash = modelPolicyHash
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.source = source
        self.text = text
        self.context = context
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.replacedText = replacedText
        self.replacedModel = replacedModel
        self.sharedCacheEntryID = sharedCacheEntryID
    }
}

/// Portable accepted/rejected decision payload. Derived vocabulary travels
/// with the decision so another device restores the same learning state.
public struct StoredAssistantDecisionPayload: Codable, Equatable, Sendable {
    public var result: StoredAssistantResult
    public var vocabulary: [StoredVocabularyOccurrence]
    public var removedVocabularyIDs: [VocabularyOccurrenceID]?

    public init(
        result: StoredAssistantResult,
        vocabulary: [StoredVocabularyOccurrence],
        removedVocabularyIDs: [VocabularyOccurrenceID]? = nil
    ) {
        self.result = result
        self.vocabulary = vocabulary
        self.removedVocabularyIDs = removedVocabularyIDs
    }
}

/// Checkpoints are operational resume state, not generated prose, so their
/// lifecycle remains independent from durable assistant results.
public struct StoredTranslationCheckpoint: Codable, Equatable, Sendable {
    public var chapterID: ChapterID
    public var language: String
    public var mode: String
    public var completedSegmentCount: Int
    public var totalSegmentCount: Int
    public var status: String
    public var updatedAt: Date

    public init(
        chapterID: ChapterID,
        language: String,
        mode: String = "continueFromCheckpoint",
        completedSegmentCount: Int,
        totalSegmentCount: Int = 0,
        status: String = "inProgress",
        updatedAt: Date
    ) {
        self.chapterID = chapterID
        self.language = language
        self.mode = mode
        self.completedSegmentCount = completedSegmentCount
        self.totalSegmentCount = totalSegmentCount
        self.status = status
        self.updatedAt = updatedAt
    }
}

public enum OutboxEntityType: String, Codable, Sendable {
    case settings
    case book
    case chapter
    case progress
    case vocabulary
    case lexemeState = "lexeme_state"
    case reviewEvent = "review_event"
    case transcript
    case asset
    case transcriptOverlay = "transcript_overlay"
    case assistantResult = "assistant_result"
    case chatMessage = "chat_message"
    case studyActivity = "study_activity"
}

public enum OutboxOperation: String, Codable, Sendable {
    case upsert
    case delete
    case append
}

public enum OutboxMutationStatus: String, Codable, Sendable {
    case pending
    case acknowledged
}

public struct OutboxMutation: Codable, Equatable, Sendable, Identifiable {
    public var id: MutationID
    public var entityType: OutboxEntityType
    public var entityID: String
    public var operation: OutboxOperation
    public var baseRevision: ServerVersion
    public var occurredAt: Date
    public var payload: Data
    public var status: OutboxMutationStatus

    public init(
        id: MutationID,
        entityType: OutboxEntityType,
        entityID: String,
        operation: OutboxOperation,
        baseRevision: ServerVersion,
        occurredAt: Date,
        payload: Data,
        status: OutboxMutationStatus = .pending
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.baseRevision = baseRevision
        self.occurredAt = occurredAt
        self.payload = payload
        self.status = status
    }
}

/// Last applied server revision and payload for an entity. Source of truth for
/// `baseRevision` and for skipping unchanged snapshot rows.
public struct SyncEntityVersion: Equatable, Sendable {
    public var entityType: String
    public var entityID: String
    public var serverVersion: Int64
    public var payload: Data
    public var lastMutationID: String?

    public init(
        entityType: String,
        entityID: String,
        serverVersion: Int64,
        payload: Data,
        lastMutationID: String? = nil
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.serverVersion = serverVersion
        self.payload = payload
        self.lastMutationID = lastMutationID
    }
}
