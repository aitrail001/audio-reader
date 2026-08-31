import CryptoKit
import Foundation
import NaturalLanguage

struct VocabularyCanonicalization: Equatable, Sendable {
    var surfaceForm: String
    var canonicalForm: String
    var partOfSpeech: VocabularyPartOfSpeech
    var senseID: String?
    var source: VocabularyCanonicalizationSource
    var confidence: Double
    var status: VocabularyCanonicalizationStatus
    var traceID: String?

    func studyKey(language: String, occurrenceID: String? = nil) -> VocabularyStudyIdentity {
        VocabularyStudyIdentity(
            language: VocabularyCanonicalizer.normalizedLanguage(language),
            canonicalForm: canonicalForm,
            partOfSpeech: partOfSpeech,
            senseID: senseID,
            canonicalizationStatus: status,
            canonicalizationSource: source,
            canonicalizationConfidence: confidence,
            occurrenceID: senseID == nil ? occurrenceID : nil
        )
    }
}

struct VocabularyStudyIdentity: Hashable, Sendable {
    var language: String
    var canonicalForm: String
    var partOfSpeech: VocabularyPartOfSpeech
    var senseID: String?
    var canonicalizationStatus: VocabularyCanonicalizationStatus
    var canonicalizationSource: VocabularyCanonicalizationSource
    var canonicalizationConfidence: Double
    var occurrenceID: String?
}

struct VocabularyOccurrenceLocation: Equatable, Sendable {
    let occurrenceID: String
    let bookID: String
    let bookTitle: String
    let chapterID: String
    let chapterTitle: String
    let segmentID: String?
    let wordID: String?
    let timestamp: TimeInterval
}

struct VocabularyStudySchedule: Equatable, Sendable {
    let reviewCount: Int
    let nextReview: Date?
    let lastReviewedAt: Date?
    let lastReviewQuality: VocabReviewQuality?
    let reviewIntervalDays: Double
    let reviewEaseFactor: Double

    init(_ entry: VocabEntry) {
        reviewCount = entry.reviewCount
        nextReview = entry.nextReview
        lastReviewedAt = entry.lastReviewedAt
        lastReviewQuality = entry.lastReviewQuality
        reviewIntervalDays = entry.reviewIntervalDays
        reviewEaseFactor = entry.reviewEaseFactor
    }
}

/// A study card owns one schedule while retaining every exact source occurrence.
/// It is an explicit vNext projection until the persistence-cutover task moves it to its own table.
struct VocabularyStudyCard: Identifiable, Equatable, Sendable {
    let id: String
    let identity: VocabularyStudyIdentity
    let schedule: VocabularyStudySchedule
    let occurrences: [VocabEntry]

    var studyEntry: VocabEntry {
        occurrences[0].applyingStudySchedule(schedule)
    }

    var occurrenceIDs: Set<String> { Set(occurrences.map(\.id)) }
    var locations: [VocabularyOccurrenceLocation] {
        occurrences.map {
            VocabularyOccurrenceLocation(
                occurrenceID: $0.id,
                bookID: $0.bookID,
                bookTitle: $0.bookTitle,
                chapterID: $0.chapterID,
                chapterTitle: $0.chapterTitle,
                segmentID: $0.segmentID,
                wordID: $0.wordID,
                timestamp: $0.timestamp
            )
        }
    }

    var word: String { occurrences[0].studyForm }
    var addedAt: Date { occurrences.map(\.addedAt).min() ?? .distantPast }
    var reviewCount: Int { schedule.reviewCount }
    var nextReview: Date? { schedule.nextReview }
    var reviewIntervalDays: Double { schedule.reviewIntervalDays }
    var category: VocabCategory { occurrences[0].category }
    var canonicalForm: String { occurrences[0].canonicalForm }
    var bookTitle: String { occurrences[0].bookTitle }
    var chapterTitle: String { occurrences[0].chapterTitle }
    var isInLearnList: Bool { occurrences.contains(where: \.isInLearnList) }

    func occurrence(id: String) -> VocabEntry? {
        occurrences.first { $0.id == id }
    }

    func occurrence(inBook bookID: String) -> VocabEntry? {
        occurrences.first { $0.bookID == bookID }
    }
}

enum VocabularyCanonicalizer {
    /// This compiled map is the complete deterministic English fallback contract,
    /// not a general dictionary. Both app targets use identical entries; unsupported
    /// forms preserve their surface until Apple or a reviewed fallback supplies a lemma.
    private static let bundledEnglishVerbInflections: [String: String] = [
        "called": "call",
        "calling": "call",
        "looked": "look",
        "looking": "look",
        "running": "run",
        "stopped": "stop",
        "stopping": "stop",
        "studied": "study",
        "studying": "study",
        "walked": "walk",
        "walking": "walk"
    ]
    private static let bundledEnglishNounInflections: [String: String] = [
        "books": "book",
        "boxes": "box",
        "boys": "boy",
        "cases": "case",
        "facts": "fact"
    ]

    /// Natural Language supplies contextual lemma/POS candidates offline. POS
    /// alone is never a sense boundary, so unsupported results remain editable.
    static func canonicalize(
        surfaceForm: String,
        context: String,
        language: String
    ) -> VocabularyCanonicalization {
        let surface = normalizedForm(surfaceForm)
        let language = normalizedLanguage(language)
        guard !surface.isEmpty else {
            return result(surface, surface, .unknown, nil, .normalized, 0, .needsReview)
        }

        if language == "en", let corrected = englishCorrection(surface: surface, context: context) {
            return corrected
        }
        if surface.contains(" ") {
            return result(surface, surface, .phrase, nil, .normalized, 0.6, .needsReview)
        }
        if let analysis = naturalLanguageAnalysis(surface: surface, context: context, language: language) {
            let lemma = analysis.lemma.flatMap { $0 == surface ? nil : $0 }
                ?? englishInflectionFallback(
                    surface: surface,
                    language: language,
                    partOfSpeech: analysis.partOfSpeech
                )
                ?? analysis.lemma
                ?? surface
            return result(
                surface,
                lemma,
                analysis.partOfSpeech,
                nil,
                .appleNaturalLanguage,
                analysis.partOfSpeech == .unknown ? 0.4 : 0.7,
                .needsReview
            )
        }
        return result(surface, surface, .unknown, nil, .normalized, 0.4, .needsReview)
    }

    /// A missing platform lemma must not make regular English study forms vary
    /// by OS NLP data. Exact vetted mappings run only for a known lexical class.
    static func englishInflectionFallback(
        surface: String,
        language: String,
        partOfSpeech: VocabularyPartOfSpeech
    ) -> String? {
        guard normalizedLanguage(language) == "en" else { return nil }
        let word = normalizedForm(surface)
        guard word.count >= 4,
              word.unicodeScalars.allSatisfy({ ("a"..."z").contains(Character($0)) })
        else { return nil }

        switch partOfSpeech {
        case .verb:
            return bundledEnglishVerbInflections[word]
        case .noun:
            return bundledEnglishNounInflections[word]
        default:
            return nil
        }
    }

    static func normalizedLanguage(_ language: String) -> String {
        let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
        return normalized.split(separator: "-").first.map(String.init) ?? "und"
    }

    static func normalizedForm(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func englishCorrection(
        surface: String,
        context: String
    ) -> VocabularyCanonicalization? {
        switch surface {
        case "do", "does", "did", "done", "doing":
            return result(surface, "do", .verb, "do:verb", .irregularRule, 0.99, .confirmed)
        case "better", "best":
            if isComparativeCorrelative(context) {
                return result(surface, surface, .adjective, nil, .irregularRule, 0.4, .needsReview)
            }
            if isVerbalBetter(surface: surface, context: context) {
                return result(surface, "better", .verb, "better:improve", .irregularRule, 0.97, .confirmed)
            }
            if isAdjectivalBetter(surface: surface, context: context) {
                return result(surface, "good", .adjective, "good:quality", .irregularRule, 0.97, .confirmed)
            }
            let unresolvedPartOfSpeech = isAdverbialBetter(surface: surface, context: context)
                ? VocabularyPartOfSpeech.adverb
                : .unknown
            return result(surface, surface, unresolvedPartOfSpeech, nil, .irregularRule, 0.4, .needsReview)
        case "worse", "worst":
            return result(surface, "bad", .adjective, "bad:quality", .irregularRule, 0.97, .confirmed)
        case "give up", "gave up", "giving up", "given up", "gives up":
            return result(surface, "give up", .verb, "give-up:stop", .irregularRule, 0.99, .confirmed)
        case "look forward to", "was looking forward to", "were looking forward to", "looked forward to", "looking forward to":
            return result(surface, "look forward to", .verb, "look-forward-to:anticipate", .irregularRule, 0.99, .confirmed)
        case "in charge of":
            return result(surface, surface, .phrase, "in-charge-of:responsible", .irregularRule, 0.99, .confirmed)
        default:
            return nil
        }
    }

    private static func isComparativeCorrelative(_ context: String) -> Bool {
        let normalized = " \(normalizedForm(context)) "
        return normalized.contains(" the better the ")
    }

    private static func isVerbalBetter(surface: String, context: String) -> Bool {
        guard surface == "better" else { return false }
        let normalized = " \(normalizedForm(context)) "
        if normalized.contains(" to better ")
            || normalized.contains(" can better ")
            || normalized.contains(" could better ")
            || normalized.contains(" should better ")
            || normalized.contains(" will better ")
        { return true }
        let words = normalizedForm(context).split(separator: " ").map(String.init)
        guard let index = words.firstIndex(of: surface), index > 0, words.indices.contains(index + 1) else {
            return false
        }
        let subjects: Set<String> = ["i", "we", "you", "they", "he", "she", "it"]
        let objectIntroducers: Set<String> = ["a", "an", "the", "this", "that", "my", "our", "your", "his", "her", "its", "their"]
        return subjects.contains(words[index - 1]) && objectIntroducers.contains(words[index + 1])
    }

    private static func isAdjectivalBetter(surface: String, context: String) -> Bool {
        guard surface == "better" || surface == "best" else { return false }
        let normalized = " \(normalizedForm(context)) "
        return normalized.contains(" a \(surface) ")
            || normalized.contains(" an \(surface) ")
            || normalized.contains(" the \(surface) ")
            || normalized.contains(" this \(surface) ")
            || normalized.contains(" that \(surface) ")
    }

    private static func isAdverbialBetter(surface: String, context: String) -> Bool {
        guard surface == "better" else { return false }
        let normalizedContext = normalizedForm(context)
        let words = normalizedContext.split(separator: " ").map(String.init)
        guard let index = words.firstIndex(of: surface), index > 0 else { return false }
        let previous = words[index - 1]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = normalizedContext
        var previousIsVerb = false
        tagger.enumerateTags(
            in: normalizedContext.startIndex..<normalizedContext.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, range in
            guard normalizedForm(String(normalizedContext[range])) == previous else { return true }
            previousIsVerb = tag == .verb
            return false
        }
        return previousIsVerb
    }

    private static func naturalLanguageAnalysis(
        surface: String,
        context: String,
        language: String
    ) -> (lemma: String?, partOfSpeech: VocabularyPartOfSpeech)? {
        guard !context.isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = context
        let fullRange = context.startIndex..<context.endIndex
        tagger.setLanguage(NLLanguage(rawValue: language), range: fullRange)
        var match: (String?, VocabularyPartOfSpeech)?
        tagger.enumerateTags(
            in: fullRange,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, tokenRange in
            guard normalizedForm(String(context[tokenRange])) == surface else { return true }
            let lemma = tagger.tag(at: tokenRange.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let normalizedLemma = lemma.map(normalizedForm).flatMap { $0.isEmpty ? nil : $0 }
            match = (normalizedLemma, partOfSpeech(for: tag))
            return false
        }
        return match
    }

    private static func partOfSpeech(for tag: NLTag?) -> VocabularyPartOfSpeech {
        switch tag {
        case .noun: .noun
        case .verb: .verb
        case .adjective: .adjective
        case .adverb: .adverb
        case .pronoun: .pronoun
        case .determiner: .determiner
        case .preposition: .preposition
        case .conjunction: .conjunction
        case .interjection: .interjection
        default: .unknown
        }
    }

    private static func result(
        _ surface: String,
        _ canonical: String,
        _ partOfSpeech: VocabularyPartOfSpeech,
        _ senseID: String?,
        _ source: VocabularyCanonicalizationSource,
        _ confidence: Double,
        _ status: VocabularyCanonicalizationStatus,
        traceID: String? = nil
    ) -> VocabularyCanonicalization {
        VocabularyCanonicalization(
            surfaceForm: surface,
            canonicalForm: canonical,
            partOfSpeech: partOfSpeech,
            senseID: senseID,
            source: source,
            confidence: confidence,
            status: status,
            traceID: traceID
        )
    }
}

extension VocabEntry {
    var studyIdentity: VocabularyStudyIdentity {
        let normalizedSense = senseID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidatedSense = canonicalizationStatus == .confirmed && normalizedSense?.isEmpty == false
        return VocabularyStudyIdentity(
            language: VocabularyCanonicalizer.normalizedLanguage(sourceLanguage ?? "und"),
            canonicalForm: VocabularyCanonicalizer.normalizedForm(canonicalForm),
            partOfSpeech: partOfSpeech,
            senseID: hasValidatedSense ? normalizedSense : nil,
            canonicalizationStatus: hasValidatedSense ? .confirmed : .needsReview,
            canonicalizationSource: canonicalizationSource,
            canonicalizationConfidence: canonicalizationConfidence,
            occurrenceID: hasValidatedSense ? nil : id
        )
    }

    var studyForm: String { canonicalForm.isEmpty ? word : canonicalForm }

    mutating func confirmCanonicalForm(
        _ form: String,
        partOfSpeech: VocabularyPartOfSpeech,
        senseID: String?
    ) {
        canonicalForm = VocabularyCanonicalizer.normalizedForm(form)
        self.partOfSpeech = partOfSpeech
        let normalizedSense = senseID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senseID = normalizedSense?.isEmpty == false ? normalizedSense : nil
        canonicalizationSource = .userEdited
        canonicalizationTraceID = nil
        canonicalizationConfidence = self.senseID == nil ? 0.5 : 1
        canonicalizationStatus = self.senseID == nil ? .needsReview : .confirmed
    }

    func applyingStudySchedule(from owner: VocabEntry) -> VocabEntry {
        var updated = self
        updated.reviewCount = owner.reviewCount
        updated.nextReview = owner.nextReview
        updated.lastReviewedAt = owner.lastReviewedAt
        updated.lastReviewQuality = owner.lastReviewQuality
        updated.reviewIntervalDays = owner.reviewIntervalDays
        updated.reviewEaseFactor = owner.reviewEaseFactor
        return updated
    }

    func applyingStudySchedule(_ schedule: VocabularyStudySchedule) -> VocabEntry {
        var updated = self
        updated.reviewCount = schedule.reviewCount
        updated.nextReview = schedule.nextReview
        updated.lastReviewedAt = schedule.lastReviewedAt
        updated.lastReviewQuality = schedule.lastReviewQuality
        updated.reviewIntervalDays = schedule.reviewIntervalDays
        updated.reviewEaseFactor = schedule.reviewEaseFactor
        return updated
    }
}

enum VocabularyStudyCards {
    static func cards(_ entries: [VocabEntry]) -> [VocabularyStudyCard] {
        var order: [VocabularyStudyIdentity] = []
        var grouped: [VocabularyStudyIdentity: [VocabEntry]] = [:]
        for entry in entries where entry.reviewEligible {
            let identity = entry.studyIdentity
            if grouped[identity] == nil { order.append(identity) }
            grouped[identity, default: []].append(entry)
        }
        return order.compactMap { identity in
            guard let occurrences = grouped[identity],
                  let schedule = occurrences.sorted(by: scheduleBefore).first
            else { return nil }
            return VocabularyStudyCard(
                id: cardID(for: identity),
                identity: identity,
                schedule: VocabularyStudySchedule(schedule),
                occurrences: occurrences
            )
        }
    }

    static func card(containing id: String, in entries: [VocabEntry]) -> VocabularyStudyCard? {
        cards(entries).first { $0.id == id || $0.occurrenceIDs.contains(id) }
    }

    private static func cardID(for identity: VocabularyStudyIdentity) -> String {
        if let occurrenceID = identity.occurrenceID { return occurrenceID }
        let components = [
            identity.language,
            identity.canonicalForm,
            identity.partOfSpeech.rawValue,
            identity.senseID ?? "",
            identity.canonicalizationStatus.rawValue,
            identity.canonicalizationSource.rawValue,
            String(identity.canonicalizationConfidence)
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(components.utf8))
        return "study:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func scheduleBefore(_ lhs: VocabEntry, _ rhs: VocabEntry) -> Bool {
        if lhs.reviewCount != rhs.reviewCount { return lhs.reviewCount > rhs.reviewCount }
        let lhsReview = lhs.lastReviewedAt ?? .distantPast
        let rhsReview = rhs.lastReviewedAt ?? .distantPast
        if lhsReview != rhsReview { return lhsReview > rhsReview }
        return lhs.addedAt < rhs.addedAt
    }
}

struct VocabularyCanonicalizationFallbackRequest: Hashable, Sendable {
    static let maximumContextLength = 320
    let surfaceForm: String
    let context: String
    let language: String

    init(surfaceForm: String, context: String, language: String) {
        self.surfaceForm = VocabularyCanonicalizer.normalizedForm(surfaceForm)
        self.context = Self.boundedContext(context, around: surfaceForm)
        self.language = VocabularyCanonicalizer.normalizedLanguage(language)
    }

    private static func boundedContext(_ context: String, around surface: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumContextLength else { return trimmed }
        guard let range = trimmed.range(of: surface, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(trimmed.prefix(maximumContextLength))
        }
        let center = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
        let startOffset = max(0, min(trimmed.count - maximumContextLength, center - maximumContextLength / 2))
        let start = trimmed.index(trimmed.startIndex, offsetBy: startOffset)
        let end = trimmed.index(start, offsetBy: maximumContextLength)
        return String(trimmed[start..<end])
    }
}

struct VocabularyCanonicalizationFallbackResult: Codable, Equatable, Sendable {
    let canonicalForm: String
    let partOfSpeech: VocabularyPartOfSpeech
    let senseID: String?
    let confidence: Double
    let traceID: String
}

protocol VocabularyCanonicalizationFallbackClient: Sendable {
    func canonicalize(_ request: VocabularyCanonicalizationFallbackRequest) async throws
        -> VocabularyCanonicalizationFallbackResult?
}

struct ManagedVocabularyCanonicalizationFallbackClient: VocabularyCanonicalizationFallbackClient {
    typealias Completion = @Sendable (String, String, String) async throws -> ProductAICompletion

    private struct Payload: Codable {
        let canonicalForm: String
        let partOfSpeech: VocabularyPartOfSpeech
        let senseID: String?
        let confidence: Double
    }

    private let completion: Completion

    init() {
        completion = { system, user, language in
            try await ManagedProductLLM.completeWithTrace(
                system: system,
                user: user,
                sourceLanguage: language
            )
        }
    }

    init(completion: @escaping Completion) {
        self.completion = completion
    }

    /// Sends only the selected surface and its bounded sentence context to the
    /// existing managed provider; book, chapter, and surrounding text stay local.
    func canonicalize(
        _ request: VocabularyCanonicalizationFallbackRequest
    ) async throws -> VocabularyCanonicalizationFallbackResult? {
        let requestData = try JSONSerialization.data(withJSONObject: [
            "surfaceForm": request.surfaceForm,
            "sentenceContext": request.context,
            "language": request.language
        ], options: [.sortedKeys])
        guard let user = String(data: requestData, encoding: .utf8) else { return nil }
        let response = try await completion(
            """
            Canonicalize one study term using only the supplied sentence. Return JSON only with canonicalForm, partOfSpeech, senseID, and confidence. Use a stable, concise senseID that distinguishes homonyms. If the sense is ambiguous, use null senseID and confidence below 0.85. partOfSpeech must be one of unknown, noun, verb, adjective, adverb, pronoun, determiner, preposition, conjunction, interjection, phrase.
            """,
            user,
            request.language
        )
        let json = response.text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        return VocabularyCanonicalizationFallbackResult(
            canonicalForm: payload.canonicalForm,
            partOfSpeech: payload.partOfSpeech,
            senseID: payload.senseID,
            confidence: payload.confidence,
            traceID: response.traceID
        )
    }
}

actor VocabularyCanonicalizationFallbackResolver {
    private let client: any VocabularyCanonicalizationFallbackClient
    private let capacity: Int
    private var cache: [VocabularyCanonicalizationFallbackRequest: VocabularyCanonicalization] = [:]
    private var order: [VocabularyCanonicalizationFallbackRequest] = []

    init(client: any VocabularyCanonicalizationFallbackClient, capacity: Int = 128) {
        self.client = client
        self.capacity = max(1, capacity)
    }

    /// Only a validated structured sense may leave needsReview. Provider and
    /// decoding failures deliberately return the offline proposal unchanged.
    func resolve(
        offline: VocabularyCanonicalization,
        surfaceForm: String,
        context: String,
        language: String
    ) async -> VocabularyCanonicalization {
        guard offline.status == .needsReview else { return offline }
        let request = VocabularyCanonicalizationFallbackRequest(
            surfaceForm: surfaceForm,
            context: context,
            language: language
        )
        if let cached = cache[request] { return cached }
        do {
            guard let response = try await client.canonicalize(request),
                  !VocabularyCanonicalizer.normalizedForm(response.canonicalForm).isEmpty,
                  let senseID = response.senseID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !senseID.isEmpty,
                  (0.85...1).contains(response.confidence),
                  !response.traceID.isEmpty
            else { return offline }
            let resolved = VocabularyCanonicalization(
                surfaceForm: offline.surfaceForm,
                canonicalForm: VocabularyCanonicalizer.normalizedForm(response.canonicalForm),
                partOfSpeech: response.partOfSpeech,
                senseID: senseID,
                source: .cachedLLM,
                confidence: response.confidence,
                status: .confirmed,
                traceID: response.traceID
            )
            cache[request] = resolved
            order.append(request)
            if order.count > capacity, let oldest = order.first {
                order.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            return resolved
        } catch {
            return offline
        }
    }
}
