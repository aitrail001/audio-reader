import Foundation

public struct StoredSettings: Codable, Equatable, Sendable {
    public var libraryPath: String
    public var playbackRate: Double
    public var textSource: String
    public var skipSeconds: Double
    public var transcriptionLanguage: String
    public var readerLanguageLevel: String
    public var targetLanguage: String
    public var sentenceContextCount: Int
    public var chapterTranslationBlockSize: Int
    public var chatContextCount: Int
    public var autoTranslate: Bool
    public var playOnSelect: Bool
    public var deepReadingMode: Bool
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
        readerLanguageLevel: String = "intermediate",
        targetLanguage: String = "zh-Hans",
        sentenceContextCount: Int = 2,
        chapterTranslationBlockSize: Int = 5,
        chatContextCount: Int = 3,
        autoTranslate: Bool = false,
        playOnSelect: Bool = true,
        deepReadingMode: Bool = false,
        showStudyOverlay: Bool = false,
        vocabReviewPrompt: String = "recognition",
        appearance: String = "dark",
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
        self.readerLanguageLevel = readerLanguageLevel
        self.targetLanguage = targetLanguage
        self.sentenceContextCount = sentenceContextCount
        self.chapterTranslationBlockSize = chapterTranslationBlockSize
        self.chatContextCount = chatContextCount
        self.autoTranslate = autoTranslate
        self.playOnSelect = playOnSelect
        self.deepReadingMode = deepReadingMode
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

    public init(
        id: ChapterID,
        index: Int,
        title: String,
        duration: TimeInterval? = nil,
        startTime: TimeInterval? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.duration = duration
        self.startTime = startTime
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

public struct StoredEPUBAlignment: Codable, Equatable, Sendable {
    public var status: String
    public var reason: String

    public init(status: String, reason: String) {
        self.status = status
        self.reason = reason
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

public struct StoredVocabularyOccurrence: Codable, Equatable, Sendable {
    public var id: VocabularyOccurrenceID
    public var surface: String
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
    public var face: String
    public var rating: String
    public var reviewedAt: Date

    public init(
        id: ReviewEventID,
        vocabularyID: VocabularyOccurrenceID,
        face: String,
        rating: String,
        reviewedAt: Date
    ) {
        self.id = id
        self.vocabularyID = vocabularyID
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
}

public struct StoredAssistantResult: Codable, Equatable, Sendable {
    public var id: String
    public var kind: AssistantResultKind
    public var status: AssistantResultStatus
    public var language: String
    public var model: String
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

    public init(
        id: String,
        kind: AssistantResultKind,
        status: AssistantResultStatus,
        language: String,
        model: String,
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
        replacedModel: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.language = language
        self.model = model
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
    case transcriptOverlay = "transcript_overlay"
    case translationDecision = "translation_decision"
    case summaryDecision = "summary_decision"
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
