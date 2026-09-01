import Foundation
import CryptoKit
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif
#if canImport(AudioReaderLocalStore)
import AudioReaderLocalStore
#endif

extension StoredBook {
    init(_ book: Book) {
        self.init(
            id: BookID(rawValue: book.id),
            title: book.title,
            author: book.author,
            source: book.source.rawValue,
            chapters: book.chapters.map {
                StoredChapter(
                    id: ChapterID(rawValue: $0.id),
                    index: $0.index,
                    title: $0.title,
                    duration: $0.duration,
                    startTime: $0.startTime,
                    ebookSectionIndex: $0.ebookSectionIndex
                )
            }
        )
    }
}

extension StoredLocalAsset {
    static func snapshots(
        for book: Book,
        reusing existing: [StoredLocalAsset] = []
    ) -> [StoredLocalAsset] {
        var assets = book.chapters.compactMap { chapter -> StoredLocalAsset? in
            guard !chapter.audioPath.isEmpty else { return nil }
            return snapshot(
                bookID: book.bookID,
                kind: "audio",
                path: chapter.audioPath,
                discriminator: chapter.id,
                metadata: ["chapterID": chapter.id],
                existing: existing
            )
        }
        if let path = book.ebookPath {
            assets.append(snapshot(
                bookID: book.bookID,
                kind: "epub",
                path: path,
                discriminator: "epub",
                existing: existing
            ))
        }
        if let path = book.coverPath {
            assets.append(snapshot(
                bookID: book.bookID,
                kind: "cover",
                path: path,
                discriminator: "cover",
                existing: existing
            ))
        }
        return assets.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func snapshot(
        bookID: BookID,
        kind: String,
        path: String,
        discriminator: String,
        metadata: [String: String] = [:],
        existing: [StoredLocalAsset]
    ) -> StoredLocalAsset {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        let rawID = SHA256.hash(data: Data("\(bookID.rawValue)|\(kind)|\(discriminator)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        var storedMetadata = metadata
        if let modified { storedMetadata["modifiedAt"] = String(modified) }
        let matching = existing.first { $0.id.rawValue == rawID }
        let isDirectory = (attributes?[.type] as? FileAttributeType) == .typeDirectory
        let digest: AudiobookImportService.AssetDigest?
        if !isDirectory,
           let byteCount = (attributes?[.size] as? NSNumber)?.int64Value,
           matching?.byteCount == byteCount,
           matching?.metadata["modifiedAt"] == storedMetadata["modifiedAt"] {
            digest = matching?.contentHash.map {
                AudiobookImportService.AssetDigest(
                    contentHash: $0,
                    byteCount: byteCount,
                    regularFileCount: 1,
                    isDirectory: false
                )
            }
        } else {
            digest = try? AudiobookImportService.assetDigest(URL(fileURLWithPath: path))
        }
        storedMetadata["representation"] = digest?.isDirectory == true ? "directory" : "file"
        if let count = digest?.regularFileCount { storedMetadata["regularFileCount"] = String(count) }
        return StoredLocalAsset(
            id: AssetID(rawValue: rawID),
            bookID: bookID,
            kind: kind,
            localMediaKey: path,
            contentHash: digest?.contentHash,
            byteCount: digest?.byteCount,
            metadata: storedMetadata
        )
    }
}

extension Book {
    /// Cloud catalog rows intentionally contain metadata only; media paths stay
    /// empty until this device imports the matching audio or EPUB files.
    init(_ stored: StoredBook) {
        self.init(stored, assets: [])
    }

    /// Local asset rows restore media paths without depending on a fresh scan;
    /// absent rows intentionally produce a metadata-only cloud catalog entry.
    init(_ stored: StoredBook, assets: [StoredLocalAsset]) {
        let audioPairs: [(String, String)] = assets.compactMap { asset in
            guard asset.kind == "audio", let chapterID = asset.metadata["chapterID"] else { return nil }
            return (chapterID, asset.localMediaKey)
        }
        let audioByChapter = Dictionary(uniqueKeysWithValues: audioPairs)
        let ebookPath = assets.first(where: { $0.kind == "epub" })?.localMediaKey
        let coverPath = assets.first(where: { $0.kind == "cover" })?.localMediaKey
        let firstMediaPath = audioByChapter.values.first ?? ebookPath ?? coverPath
        self.init(
            id: stored.id.rawValue,
            title: stored.title,
            author: stored.author,
            folderPath: firstMediaPath.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().path
            } ?? "",
            coverPath: coverPath,
            ebookPath: ebookPath,
            chapters: stored.chapters.map {
                Chapter(
                    id: $0.id.rawValue,
                    index: $0.index,
                    title: $0.title,
                    audioPath: audioByChapter[$0.id.rawValue] ?? "",
                    duration: $0.duration,
                    startTime: $0.startTime,
                    ebookSectionIndex: $0.ebookSectionIndex
                )
            },
            source: BookSource(rawValue: stored.source) ?? .files
        )
    }
}

extension StoredTranscript {
    init(_ transcript: Transcript) {
        self.init(
            chapterID: ChapterID(rawValue: transcript.chapterID),
            localMediaKey: transcript.audioPath,
            chapterStart: transcript.chapterStart,
            createdAt: transcript.createdAt,
            locale: transcript.locale,
            source: transcript.source,
            ebookAligned: transcript.ebookAligned,
            ebookAlignment: transcript.ebookAlignment.map(StoredEPUBAlignment.init),
            ebookUseOverride: transcript.ebookUseOverride,
            segments: transcript.segments.map(StoredTranscriptSegment.init)
        )
    }
}

extension StoredTranscriptSegment {
    init(_ segment: TranscriptSegment) {
        self.init(
            id: segment.id,
            start: segment.start,
            end: segment.end,
            words: segment.words.map(StoredTranscriptWord.init),
            ebookText: segment.ebookText,
            alignmentScore: segment.alignmentScore,
            individualEbookMatchTrusted: segment.individualEbookMatchTrusted,
            documentEbookUseAllowed: segment.documentEbookUseAllowed
        )
    }
}

extension StoredTranscriptWord {
    init(_ word: TranscriptWord) {
        self.init(id: word.id, text: word.text, start: word.start, end: word.end, confidence: word.confidence)
    }
}

extension Transcript {
    init(_ stored: StoredTranscript) {
        self.init(
            chapterID: stored.chapterID.rawValue,
            audioPath: stored.localMediaKey,
            chapterStart: stored.chapterStart,
            createdAt: stored.createdAt,
            locale: stored.locale,
            segments: stored.segments.map(TranscriptSegment.init),
            source: stored.source,
            ebookAligned: stored.ebookAligned,
            ebookAlignment: stored.ebookAlignment.map(EPUBAlignmentAssessment.init),
            ebookUseOverride: stored.ebookUseOverride
        )
    }

    /// Resolved overlay text is presentation state; the immutable base remains
    /// the persisted revision used for future conflict checks.
    init(_ resolved: ResolvedTranscript) {
        let stored = resolved.base
        self.init(
            chapterID: stored.chapterID.rawValue,
            audioPath: stored.localMediaKey,
            chapterStart: stored.chapterStart,
            createdAt: stored.createdAt,
            locale: stored.locale,
            segments: resolved.segments.map(TranscriptSegment.init),
            source: stored.source,
            ebookAligned: stored.ebookAligned,
            ebookAlignment: stored.ebookAlignment.map(EPUBAlignmentAssessment.init),
            ebookUseOverride: stored.ebookUseOverride
        )
    }
}

extension TranscriptSegment {
    init(_ resolved: ResolvedTranscriptSegment) {
        let base = resolved.base
        self.init(
            id: base.id,
            start: resolved.start,
            end: resolved.end,
            words: base.words.map(TranscriptWord.init),
            ebookText: base.ebookText,
            alignmentScore: base.alignmentScore,
            individualEbookMatchTrusted: base.individualEbookMatchTrusted,
            documentEbookUseAllowed: base.documentEbookUseAllowed,
            resolvedOverlayText: resolved.appliedOverlayID == nil ? nil : resolved.displayText
        )
    }

    init(_ stored: StoredTranscriptSegment) {
        self.init(
            id: stored.id,
            start: stored.start,
            end: stored.end,
            words: stored.words.map(TranscriptWord.init),
            ebookText: stored.ebookText,
            alignmentScore: stored.alignmentScore,
            individualEbookMatchTrusted: stored.individualEbookMatchTrusted,
            documentEbookUseAllowed: stored.documentEbookUseAllowed
        )
    }
}

extension TranscriptWord {
    init(_ stored: StoredTranscriptWord) {
        self.init(id: stored.id, text: stored.text, start: stored.start, end: stored.end, confidence: stored.confidence)
    }
}

extension StoredVocabularyOccurrence {
    init(_ entry: VocabEntry) {
        self.init(
            id: VocabularyOccurrenceID(rawValue: entry.id),
            surface: entry.word,
            canonicalForm: entry.canonicalForm,
            partOfSpeech: entry.partOfSpeech.rawValue,
            senseID: entry.senseID,
            canonicalizationSource: entry.canonicalizationSource.rawValue,
            canonicalizationConfidence: entry.canonicalizationConfidence,
            canonicalizationStatus: entry.canonicalizationStatus.rawValue,
            canonicalizationTraceID: entry.canonicalizationTraceID,
            captureSource: entry.captureSource.rawValue,
            reviewEligible: entry.reviewEligible,
            category: entry.category.rawValue,
            definition: entry.definition,
            dictionaryName: entry.dictionaryName,
            dictionaryHTML: entry.dictionaryHTML,
            translation: entry.translation,
            translationLanguage: entry.translationLanguage,
            translationModel: entry.translationModel,
            sourceLanguage: entry.sourceLanguage,
            context: entry.context,
            spokenText: entry.spokenText,
            ebookText: entry.ebookText,
            bookID: BookID(rawValue: entry.bookID),
            bookTitle: entry.bookTitle,
            chapterID: ChapterID(rawValue: entry.chapterID),
            chapterTitle: entry.chapterTitle,
            segmentID: entry.segmentID,
            wordID: entry.wordID,
            timestamp: entry.timestamp,
            addedAt: entry.addedAt,
            reviewCount: entry.reviewCount,
            nextReview: entry.nextReview,
            lastReviewedAt: entry.lastReviewedAt,
            lastReviewQuality: entry.lastReviewQuality?.rawValue,
            reviewIntervalDays: entry.reviewIntervalDays,
            reviewEaseFactor: entry.reviewEaseFactor,
            isInLearnList: entry.isInLearnList
        )
    }
}

extension VocabEntry {
    init(_ stored: StoredVocabularyOccurrence) {
        self.init(
            id: stored.id.rawValue,
            word: stored.surface,
            canonicalForm: stored.canonicalForm,
            partOfSpeech: VocabularyPartOfSpeech(rawValue: stored.partOfSpeech) ?? .unknown,
            senseID: stored.senseID,
            canonicalizationSource: VocabularyCanonicalizationSource(rawValue: stored.canonicalizationSource) ?? .normalized,
            canonicalizationConfidence: stored.canonicalizationConfidence,
            canonicalizationStatus: VocabularyCanonicalizationStatus(rawValue: stored.canonicalizationStatus) ?? .needsReview,
            canonicalizationTraceID: stored.canonicalizationTraceID,
            captureSource: VocabularyCaptureSource(rawValue: stored.captureSource),
            reviewEligible: stored.reviewEligible,
            category: VocabCategory(rawValue: stored.category) ?? .word,
            definition: stored.definition,
            dictionaryName: stored.dictionaryName,
            dictionaryHTML: stored.dictionaryHTML,
            translation: stored.translation,
            translationLanguage: stored.translationLanguage,
            translationModel: stored.translationModel,
            sourceLanguage: stored.sourceLanguage,
            context: stored.context,
            spokenText: stored.spokenText,
            ebookText: stored.ebookText,
            bookID: stored.bookID.rawValue,
            bookTitle: stored.bookTitle,
            chapterID: stored.chapterID.rawValue,
            chapterTitle: stored.chapterTitle,
            segmentID: stored.segmentID,
            wordID: stored.wordID,
            timestamp: stored.timestamp,
            addedAt: stored.addedAt,
            reviewCount: stored.reviewCount,
            nextReview: stored.nextReview,
            lastReviewedAt: stored.lastReviewedAt,
            lastReviewQuality: stored.lastReviewQuality.flatMap(VocabReviewQuality.init(rawValue:)),
            reviewIntervalDays: stored.reviewIntervalDays,
            reviewEaseFactor: stored.reviewEaseFactor,
            isInLearnList: stored.isInLearnList
        )
    }
}

extension StoredAssistantResult {
    init(_ gloss: GlossEntry) {
        self.init(
            id: gloss.id,
            kind: gloss.kind == .word ? .wordGloss : .sentenceGloss,
            status: AssistantResultStatus(gloss.status),
            language: gloss.language,
            model: gloss.model,
            promptVersion: gloss.promptVersion,
            modelPolicyHash: gloss.modelPolicyHash,
            bookID: gloss.bookID.map(BookID.init(rawValue:)),
            bookTitle: gloss.bookTitle,
            chapterID: gloss.chapterID.map(ChapterID.init(rawValue:)),
            chapterTitle: gloss.chapterTitle,
            source: gloss.source,
            text: gloss.text,
            context: gloss.context,
            timestamp: gloss.timestamp,
            createdAt: gloss.createdAt,
            decidedAt: gloss.decidedAt,
            replacedText: gloss.replacedText,
            replacedModel: gloss.replacedModel,
            sharedCacheEntryID: gloss.sharedCacheEntryID
        )
    }
}

extension GlossEntry {
    init(_ stored: StoredAssistantResult) throws {
        let kind: GlossKind
        switch stored.kind {
        case .wordGloss: kind = .word
        case .sentenceGloss: kind = .sentence
        case .chapterSummary, .chapterTranslation: throw LocalStoreError.unsupportedAssistantResultKind
        }
        self.init(
            id: stored.id,
            kind: kind,
            language: stored.language,
            source: stored.source,
            context: stored.context,
            text: stored.text,
            status: GlossStatus(stored.status),
            model: stored.model,
            promptVersion: stored.promptVersion,
            modelPolicyHash: stored.modelPolicyHash,
            sharedCacheEntryID: stored.sharedCacheEntryID,
            bookID: stored.bookID?.rawValue,
            bookTitle: stored.bookTitle,
            chapterID: stored.chapterID?.rawValue,
            chapterTitle: stored.chapterTitle,
            timestamp: stored.timestamp,
            createdAt: stored.createdAt,
            decidedAt: stored.decidedAt,
            replacedText: stored.replacedText,
            replacedModel: stored.replacedModel
        )
    }
}

extension StoredEPUBAlignment {
    init(_ assessment: EPUBAlignmentAssessment) {
        self.init(
            status: assessment.status.rawValue,
            reason: assessment.reason,
            metrics: StoredEPUBAlignmentMetrics(assessment.metrics)
        )
    }
}

extension StoredEPUBAlignmentMetrics {
    init(_ metrics: EPUBAlignmentMetrics) {
        self.init(
            extractedWordCount: metrics.extractedWordCount,
            extractedSentenceCount: metrics.extractedSentenceCount,
            sampledAnchorCount: metrics.sampledAnchorCount,
            matchedAnchorCount: metrics.matchedAnchorCount,
            matchedCoverage: metrics.matchedCoverage,
            medianScore: metrics.medianScore,
            lowerPercentileScore: metrics.lowerPercentileScore,
            backwardJumps: metrics.backwardJumps,
            longestUnmatchedPassage: metrics.longestUnmatchedPassage,
            titleSimilarity: metrics.titleSimilarity,
            authorSimilarity: metrics.authorSimilarity,
            candidateComparisons: metrics.candidateComparisons,
            detailedAlignmentPerformed: metrics.detailedAlignmentPerformed
        )
    }
}

extension EPUBAlignmentAssessment {
    init(_ stored: StoredEPUBAlignment) {
        self.init(
            status: EPUBAlignmentStatus(rawValue: stored.status) ?? .uncertain,
            reason: stored.reason,
            metrics: EPUBAlignmentMetrics(stored.metrics)
        )
    }
}

extension EPUBAlignmentMetrics {
    init(_ stored: StoredEPUBAlignmentMetrics) {
        self.init(
            extractedWordCount: stored.extractedWordCount,
            extractedSentenceCount: stored.extractedSentenceCount,
            sampledAnchorCount: stored.sampledAnchorCount,
            matchedAnchorCount: stored.matchedAnchorCount,
            matchedCoverage: stored.matchedCoverage,
            medianScore: stored.medianScore,
            lowerPercentileScore: stored.lowerPercentileScore,
            backwardJumps: stored.backwardJumps,
            longestUnmatchedPassage: stored.longestUnmatchedPassage,
            titleSimilarity: stored.titleSimilarity,
            authorSimilarity: stored.authorSimilarity,
            candidateComparisons: stored.candidateComparisons,
            detailedAlignmentPerformed: stored.detailedAlignmentPerformed
        )
    }
}

private extension AssistantResultStatus {
    init(_ status: GlossStatus) {
        self = AssistantResultStatus(rawValue: status.rawValue) ?? .pending
    }
}

private extension GlossStatus {
    init(_ status: AssistantResultStatus) {
        self = GlossStatus(rawValue: status.rawValue) ?? .pending
    }
}

enum GlossPhrases {
    static func extract(from grokText: String) -> [(phrase: String, meaning: String)] {
        var results: [(String, String)] = []
        var inSection = false
        for raw in grokText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let uppercased = line.uppercased()
            if line.hasPrefix("短语")
                || uppercased.hasPrefix(GlossTextFormat.phrasesHeading)
                || uppercased.hasPrefix(GlossTextFormat.learningNotesHeading) {
                inSection = true
                let rest = line
                    .replacingOccurrences(of: #"^短语[：:\s]*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)^PHRASAL VERBS AND PHRASES[:\s]*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)^LANGUAGE AND CONTEXT NOTES[:\s]*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty || rest.hasPrefix("无") || rest.caseInsensitiveCompare("None") == .orderedSame { continue }
                if let pair = parseLine(rest) { results.append(pair) }
                continue
            }
            if GlossTextFormat.isHeading(line) {
                inSection = false
                continue
            }
            guard !line.isEmpty else { continue }
            let isBullet = line.hasPrefix("•") || line.hasPrefix("·") || line.hasPrefix("- ") || line.hasPrefix("* ")
            if inSection || isBullet {
                if line == "无" || line.hasPrefix("无") || line.caseInsensitiveCompare("None") == .orderedSame { continue }
                if let pair = parseLine(line) { results.append(pair) }
            }
        }
        return results
    }

    private static func parseLine(_ line: String) -> (String, String)? {
        var body = line
        while let first = body.first, "•·-–—*".contains(first) {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for separator in [" — ", " – ", "——", " —", "– ", " - ", "：", ": "] {
            if let range = body.range(of: separator) {
                let phrase = String(body[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
                let meaning = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if phrase.count >= 2, !meaning.isEmpty, phrase.count < 80 { return (phrase, meaning) }
            }
        }
        return nil
    }
}
