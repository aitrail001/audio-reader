import Foundation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

struct LegacyTranscriptJSON: Decodable, Sendable {
    var chapterID: String
    var audioPath: String
    var chapterStart: TimeInterval?
    var createdAt: Date
    var locale: String
    var segments: [LegacySegmentJSON]
    var source: String
    var ebookAligned: Bool?
    var ebookAlignment: LegacyEPUBAlignmentJSON?
    var ebookUseOverride: Bool?

    func stored() -> StoredTranscript {
        let segments = self.segments.map { $0.stored() }
        let alignment = ebookAlignment?.stored()
        return StoredTranscript(
            chapterID: ChapterID(rawValue: chapterID),
            localMediaKey: audioPath,
            chapterStart: chapterStart,
            createdAt: createdAt,
            locale: locale,
            source: source,
            ebookAligned: ebookAligned ?? false,
            ebookAlignment: alignment,
            ebookUseOverride: ebookUseOverride,
            segments: segments
        )
    }
}

struct LegacySegmentJSON: Decodable, Sendable {
    var id: String
    var start: TimeInterval
    var end: TimeInterval
    var words: [LegacyWordJSON]
    var ebookText: String?
    var alignmentScore: Double?
    var individualEbookMatchTrusted: Bool?
    var documentEbookUseAllowed: Bool?

    func stored() -> StoredTranscriptSegment {
        StoredTranscriptSegment(
            id: id,
            start: start,
            end: end,
            words: words.map { $0.stored() },
            ebookText: ebookText,
            alignmentScore: alignmentScore,
            individualEbookMatchTrusted: individualEbookMatchTrusted,
            documentEbookUseAllowed: documentEbookUseAllowed
        )
    }
}

struct LegacyWordJSON: Decodable, Sendable {
    var id: String
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Double?

    func stored() -> StoredTranscriptWord {
        StoredTranscriptWord(id: id, text: text, start: start, end: end, confidence: confidence)
    }
}

struct LegacyEPUBAlignmentJSON: Codable, Sendable {
    var status: String
    var reason: String
    var metrics: LegacyEPUBMetricsJSON

    func stored() -> StoredEPUBAlignment {
        StoredEPUBAlignment(status: status, reason: reason, metrics: metrics.stored())
    }
}

struct LegacyEPUBMetricsJSON: Codable, Sendable {
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

    func stored() -> StoredEPUBAlignmentMetrics {
        StoredEPUBAlignmentMetrics(
            extractedWordCount: extractedWordCount,
            extractedSentenceCount: extractedSentenceCount,
            sampledAnchorCount: sampledAnchorCount,
            matchedAnchorCount: matchedAnchorCount,
            matchedCoverage: matchedCoverage,
            medianScore: medianScore,
            lowerPercentileScore: lowerPercentileScore,
            backwardJumps: backwardJumps,
            longestUnmatchedPassage: longestUnmatchedPassage,
            titleSimilarity: titleSimilarity,
            authorSimilarity: authorSimilarity,
            candidateComparisons: candidateComparisons,
            detailedAlignmentPerformed: detailedAlignmentPerformed
        )
    }
}

struct LegacyVocabJSON: Decodable, Sendable {
    var id: String
    var word: String
    var category: String?
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
    var reviewCount: Int?
    var nextReview: Date?
    var lastReviewedAt: Date?
    var lastReviewQuality: String?
    var reviewIntervalDays: Double?
    var reviewEaseFactor: Double?
    var isInLearnList: Bool?

    func stored() -> StoredVocabularyOccurrence {
        StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: id),
            surface: word,
            category: category ?? "word",
            definition: definition,
            dictionaryName: dictionaryName,
            dictionaryHTML: dictionaryHTML,
            translation: translation,
            translationLanguage: translationLanguage,
            translationModel: translationModel,
            sourceLanguage: sourceLanguage,
            context: context,
            spokenText: spokenText,
            ebookText: ebookText,
            bookID: BookID(rawValue: bookID),
            bookTitle: bookTitle,
            chapterID: ChapterID(rawValue: chapterID),
            chapterTitle: chapterTitle,
            segmentID: segmentID,
            wordID: wordID,
            timestamp: timestamp,
            addedAt: addedAt,
            reviewCount: reviewCount ?? 0,
            nextReview: nextReview,
            lastReviewedAt: lastReviewedAt,
            lastReviewQuality: lastReviewQuality,
            reviewIntervalDays: reviewIntervalDays ?? 0,
            reviewEaseFactor: reviewEaseFactor ?? 2.5,
            isInLearnList: isInLearnList ?? false
        )
    }
}

struct LegacyGlossJSON: Decodable, Sendable {
    var id: String
    var kind: String
    var language: String
    var source: String
    var context: String?
    var text: String
    var status: String
    var model: String
    var bookID: String?
    var bookTitle: String?
    var chapterID: String?
    var chapterTitle: String?
    var timestamp: TimeInterval?
    var createdAt: Date
    var decidedAt: Date?
    var replacedText: String?
    var replacedModel: String?

    func stored() -> StoredAssistantResult? {
        let mappedKind: AssistantResultKind
        switch kind {
        case "word": mappedKind = .wordGloss
        case "sentence": mappedKind = .sentenceGloss
        default: return nil
        }
        return StoredAssistantResult(
            id: id,
            kind: mappedKind,
            status: AssistantResultStatus(rawValue: status) ?? .pending,
            language: language,
            model: model,
            bookID: bookID.map(BookID.init(rawValue:)),
            bookTitle: bookTitle,
            chapterID: chapterID.map(ChapterID.init(rawValue:)),
            chapterTitle: chapterTitle,
            source: source,
            text: text,
            context: context,
            timestamp: timestamp,
            createdAt: createdAt,
            decidedAt: decidedAt,
            replacedText: replacedText,
            replacedModel: replacedModel
        )
    }
}

struct LegacyLemmaJSON: Decodable, Sendable {
    var language: String
    var form: String
    var updatedAt: Date

    func stored() -> StoredKnownLemma {
        StoredKnownLemma(language: language, form: form, updatedAt: updatedAt)
    }
}

struct LegacyActivityJSON: Codable, Sendable {
    var days: [String]
}

struct LegacySettingsJSON: Decodable, Sendable {
    var libraryPath: String?
    var playbackRate: Double?
    var textSource: String?
    var skipSeconds: Double?
    var transcriptionLanguage: String?
    var readerLanguageLevel: String?
    var targetLanguage: String?
    var sentenceContextCount: Int?
    var chapterTranslationBlockSize: Int?
    var chatContextCount: Int?
    var autoTranslate: Bool?
    var playOnSelect: Bool?
    var deepReadingMode: Bool?
    var showStudyOverlay: Bool?
    var vocabReviewPrompt: String?
    var appearance: String?
    var preferredDictionary: String?
    var lookupPanelWidth: Double?
    var readerFontScale: Double?
    var readerFont: String?
    var readerBold: Bool?
    var readerLineSpacing: Double?
    var readerWordSpacing: Double?
    var readerMargin: Double?

    func stored() -> StoredSettings {
        let defaults = StoredSettings.default
        return StoredSettings(
            libraryPath: libraryPath ?? defaults.libraryPath,
            playbackRate: playbackRate ?? defaults.playbackRate,
            textSource: textSource ?? defaults.textSource,
            skipSeconds: skipSeconds ?? defaults.skipSeconds,
            transcriptionLanguage: transcriptionLanguage ?? defaults.transcriptionLanguage,
            readerLanguageLevel: readerLanguageLevel ?? defaults.readerLanguageLevel,
            targetLanguage: targetLanguage ?? defaults.targetLanguage,
            sentenceContextCount: sentenceContextCount ?? defaults.sentenceContextCount,
            chapterTranslationBlockSize: chapterTranslationBlockSize ?? defaults.chapterTranslationBlockSize,
            chatContextCount: chatContextCount ?? defaults.chatContextCount,
            autoTranslate: autoTranslate ?? defaults.autoTranslate,
            playOnSelect: playOnSelect ?? defaults.playOnSelect,
            deepReadingMode: deepReadingMode ?? defaults.deepReadingMode,
            showStudyOverlay: showStudyOverlay ?? defaults.showStudyOverlay,
            vocabReviewPrompt: vocabReviewPrompt ?? defaults.vocabReviewPrompt,
            appearance: appearance ?? defaults.appearance,
            preferredDictionary: preferredDictionary ?? defaults.preferredDictionary,
            lookupPanelWidth: lookupPanelWidth ?? defaults.lookupPanelWidth,
            readerFontScale: readerFontScale ?? defaults.readerFontScale,
            readerFont: readerFont ?? defaults.readerFont,
            readerBold: readerBold ?? defaults.readerBold,
            readerLineSpacing: readerLineSpacing ?? defaults.readerLineSpacing,
            readerWordSpacing: readerWordSpacing ?? defaults.readerWordSpacing,
            readerMargin: readerMargin ?? defaults.readerMargin
        )
    }
}

struct LegacySummaryJSON: Decodable, Sendable {
    var id: String
    var summary: LegacySummaryPresentationJSON
    var language: String
    var status: String
    var model: String
    var bookID: String?
    var bookTitle: String
    var chapterID: String
    var chapterTitle: String
    var createdAt: Date
    var decidedAt: Date?
    var replacedSummary: LegacySummaryPresentationJSON?
    var replacedModel: String?

    func stored() throws -> StoredAssistantResult {
        StoredAssistantResult(
            id: id,
            kind: .chapterSummary,
            status: AssistantResultStatus(rawValue: status) ?? .pending,
            language: language,
            model: model,
            bookID: bookID.map(BookID.init(rawValue:)),
            bookTitle: bookTitle,
            chapterID: ChapterID(rawValue: chapterID),
            chapterTitle: chapterTitle,
            source: chapterTitle,
            text: try LocalJSON.encode(summary),
            createdAt: createdAt,
            decidedAt: decidedAt,
            replacedText: try replacedSummary.map(LocalJSON.encode),
            replacedModel: replacedModel
        )
    }
}

struct LegacySummaryPresentationJSON: Codable, Sendable {
    var overview: String
    var keyPoints: [String]
    var charactersOrIdeas: [String]
    var keyConcepts: [Concept]
    var themes: [String]

    struct Concept: Codable, Sendable {
        var name: String
        var explanation: String
    }
}

struct LegacyCheckpointJSON: Codable, Sendable {
    var chapterID: String
    var language: String
    var mode: String?
    var nextSegmentIndex: Int
    var totalSentences: Int
    var status: String
    var updatedAt: Date

    func stored() throws -> StoredAssistantResult {
        let mapped: AssistantResultStatus
        switch status {
        case "allAccepted": mapped = .accepted
        case "rejected": mapped = .rejected
        default: mapped = .pending
        }
        return StoredAssistantResult(
            id: "checkpoint:\(chapterID)|\(language)",
            kind: .chapterTranslation,
            status: mapped,
            language: language,
            model: mode ?? "checkpoint",
            chapterID: ChapterID(rawValue: chapterID),
            source: "checkpoint",
            text: try LocalJSON.encode(self),
            createdAt: updatedAt
        )
    }
}
