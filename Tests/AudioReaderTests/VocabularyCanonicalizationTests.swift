import Foundation
import Testing
@testable import AudioReader

@Suite("Canonical vocabulary identity")
struct VocabularyCanonicalizationTests {
    @Test("Irregular word forms share one study identity without losing occurrences")
    func irregularFormsShareStudyIdentity() {
        let forms = [
            ("do", "I do the work."),
            ("did", "I did the work yesterday."),
            ("done", "The work is done.")
        ]
        let entries = forms.enumerated().map { index, value in
            entry(id: "occurrence-\(index)", surface: value.0, context: value.1)
        }

        #expect(entries.map(\.word) == ["do", "did", "done"])
        #expect(Set(entries.map(\.canonicalForm)) == ["do"])
        #expect(Set(entries.map(\.studyIdentity)) .count == 1)
        let card = VocabularyStudyCards.cards(entries).first
        #expect(VocabularyStudyCards.cards(entries).count == 1)
        #expect(card?.occurrenceIDs == Set(entries.map(\.id)))
    }

    @Test("Context keeps verbal better separate from adjectival good")
    func betterUsesPartOfSpeechContext() {
        let adjective = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "better",
            context: "This is a better outcome.",
            language: "en"
        )
        let verb = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "better",
            context: "We can better the situation.",
            language: "en"
        )
        let comparative = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "better",
            context: "The better the weather, the longer we stay.",
            language: "en"
        )

        #expect(adjective.canonicalForm == "good")
        #expect(adjective.partOfSpeech == .adjective)
        #expect(verb.canonicalForm == "better")
        #expect(verb.partOfSpeech == .verb)
        #expect(adjective.studyKey(language: "en") != verb.studyKey(language: "en"))
        #expect(comparative.status == .needsReview)
        #expect(comparative.senseID == nil)
    }

    @Test("Better canonicalization requires positive grammatical evidence")
    func betterRequiresContextualEvidence() {
        let bareVerb = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "better",
            context: "They better the situation.",
            language: "en"
        )
        let adverb = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "better",
            context: "It works better.",
            language: "en"
        )
        let adjective = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "better",
            context: "This is a better plan.",
            language: "en"
        )
        let unknown = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "better",
            context: "Better.",
            language: "en"
        )

        #expect(bareVerb.partOfSpeech == .verb)
        #expect(bareVerb.canonicalForm == "better")
        #expect(bareVerb.senseID == "better:improve")
        #expect(bareVerb.status == .confirmed)
        #expect(adverb.partOfSpeech == .adverb)
        #expect(adverb.canonicalForm == "better")
        #expect(adverb.status == .needsReview)
        #expect(adverb.senseID == nil)
        #expect(adjective.partOfSpeech == .adjective)
        #expect(adjective.canonicalForm == "good")
        #expect(adjective.status == .confirmed)
        #expect(unknown.canonicalForm == "better")
        #expect(unknown.status == .needsReview)
        #expect(unknown.senseID == nil)
    }

    @Test("Apple Natural Language lemmatizes a regular contextual verb offline")
    func appleNaturalLanguageCanonicalizesRegularVerb() {
        let result = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "walked",
            context: "They walked home together.",
            language: "en"
        )

        #expect(result.canonicalForm == "walk")
        #expect(result.partOfSpeech == .verb)
        #expect(result.source == .appleNaturalLanguage)
        #expect(result.status == .needsReview)
        #expect(result.senseID == nil)
    }

    @Test("Known lexical classes have a deterministic English fallback when Apple omits the lemma")
    func nilAppleLemmaUsesConservativeEnglishInflectionFallback() {
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "walked",
            language: "en",
            partOfSpeech: .verb
        ) == "walk")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "walking",
            language: "en",
            partOfSpeech: .verb
        ) == "walk")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "books",
            language: "en",
            partOfSpeech: .noun
        ) == "book")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "stopped",
            language: "en",
            partOfSpeech: .verb
        ) == "stop")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "running",
            language: "en",
            partOfSpeech: .verb
        ) == "run")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "boxes",
            language: "en",
            partOfSpeech: .noun
        ) == "box")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "looked",
            language: "en",
            partOfSpeech: .verb
        ) == "look")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "called",
            language: "en",
            partOfSpeech: .verb
        ) == "call")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "studied",
            language: "en",
            partOfSpeech: .verb
        ) == "study")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "boys",
            language: "en",
            partOfSpeech: .noun
        ) == "boy")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "cases",
            language: "en",
            partOfSpeech: .noun
        ) == "case")
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "facts",
            language: "en",
            partOfSpeech: .noun
        ) == "fact")
    }

    @Test("Deterministic inflection fallback stays inside conservative English word boundaries")
    func deterministicInflectionFallbackPreservesAmbiguousAndUnsupportedForms() {
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "went",
            language: "en",
            partOfSpeech: .verb
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "children",
            language: "en",
            partOfSpeech: .noun
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "axes",
            language: "en",
            partOfSpeech: .noun
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "giving up",
            language: "en",
            partOfSpeech: .verb
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "better",
            language: "en",
            partOfSpeech: .adjective
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "marches",
            language: "fr",
            partOfSpeech: .verb
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "walked",
            language: "en",
            partOfSpeech: .unknown
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "misled",
            language: "en",
            partOfSpeech: .verb
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "embed",
            language: "en",
            partOfSpeech: .verb
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "movies",
            language: "en",
            partOfSpeech: .noun
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "clothes",
            language: "en",
            partOfSpeech: .noun
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "means",
            language: "en",
            partOfSpeech: .noun
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "caches",
            language: "en",
            partOfSpeech: .noun
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "prizes",
            language: "en",
            partOfSpeech: .noun
        ) == nil)
        #expect(VocabularyCanonicalizer.englishInflectionFallback(
            surface: "mumps",
            language: "en",
            partOfSpeech: .noun
        ) == nil)
    }

    @Test("Inflected phrasal verbs share a canonical phrase")
    func phrasalVerbCanonicalization() {
        let past = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "gave up",
            context: "She gave up after midnight.",
            language: "en"
        )
        let progressive = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "giving up",
            context: "Giving up was never the plan.",
            language: "en"
        )
        let base = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "give up",
            context: "I will not give up.",
            language: "en"
        )

        #expect(past.canonicalForm == "give up")
        #expect(progressive.canonicalForm == "give up")
        #expect(past.partOfSpeech == .verb)
        #expect(past.studyKey(language: "en") == progressive.studyKey(language: "en"))
        #expect(base.studyKey(language: "en") == past.studyKey(language: "en"))
    }

    @Test("Low-confidence forms remain distinct until the user edits them")
    func lowConfidenceNeverSilentlyMerges() {
        var first = entry(
            id: "first",
            surface: "axes",
            context: "The axes crossed.",
            status: .needsReview,
            confidence: 0.35
        )
        let second = entry(
            id: "second",
            surface: "axes",
            context: "He axes the proposal.",
            status: .needsReview,
            confidence: 0.35
        )

        #expect(VocabularyStudyCards.cards([first, second]).count == 2)
        first.confirmCanonicalForm("axis", partOfSpeech: .noun, senseID: "axis:geometry")
        #expect(first.canonicalForm == "axis")
        #expect(first.canonicalizationStatus == .confirmed)
        #expect(first.canonicalizationSource == .userEdited)
        #expect(first.senseID == "axis:geometry")
    }

    @Test("Same-POS homonyms stay isolated without compatible validated senses")
    func bankSensesNeverMergeByLemmaAndPOSAlone() {
        let river = entry(id: "river-bank", surface: "bank", context: "We rested on the river bank.")
        let financial = entry(id: "financial-bank", surface: "bank", context: "The bank approved the loan.")

        #expect(river.canonicalizationStatus == .needsReview)
        #expect(financial.canonicalizationStatus == .needsReview)
        #expect(VocabularyStudyCards.cards([river, financial]).count == 2)

        var confirmedRiver = river
        var confirmedFinancial = financial
        confirmedRiver.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:river-edge")
        confirmedFinancial.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:financial-institution")
        #expect(VocabularyStudyCards.cards([confirmedRiver, confirmedFinancial]).count == 2)
    }

    @Test("Confirmed identity ignores provenance and confidence metadata")
    func confirmedIdentityIgnoresAuditMetadata() throws {
        var manual = entry(id: "manual", surface: "bank", context: "We rested on the river bank.")
        manual.definition = "the land beside a river"
        manual.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:river-edge")
        var managed = manual
        managed.id = "managed"
        managed.canonicalizationSource = .llmFallback
        managed.canonicalizationConfidence = 0.91
        managed.canonicalizationTraceID = "trace-managed"

        let card = try #require(VocabularyStudyCards.cards([manual, managed]).first)

        #expect(VocabularyStudyCards.cards([manual, managed]).count == 1)
        #expect(card.occurrenceIDs == ["manual", "managed"])
        #expect(manual.studyIdentity == managed.studyIdentity)
    }

    @Test("Hidden sense identifiers are deterministic and collision safe")
    func hiddenSenseIdentifiersAreDeterministicAndCollisionSafe() {
        let river = VocabularySenseConfirmation.stableSenseID(
            language: "en-AU",
            canonicalForm: "Bank",
            partOfSpeech: .noun,
            meaning: "The land beside a river"
        )
        let sameRiver = VocabularySenseConfirmation.stableSenseID(
            language: "en",
            canonicalForm: " bank ",
            partOfSpeech: .noun,
            meaning: "the land beside a river"
        )
        let finance = VocabularySenseConfirmation.stableSenseID(
            language: "en",
            canonicalForm: "bank",
            partOfSpeech: .noun,
            meaning: "a financial institution"
        )

        #expect(river == sameRiver)
        #expect(river != finance)
        #expect(!river.contains("land beside a river"))
    }

    @Test("Hidden sense identity keeps delimiter and empty tuple fields distinct")
    func hiddenSenseIdentitySeparatesAdversarialTupleComponents() {
        let delimiter = "\u{1f}"
        let delimiterInMeaning = VocabularySenseConfirmation.stableSenseID(
            language: "en",
            canonicalForm: "bank",
            partOfSpeech: .noun,
            meaning: "river\(delimiter)edge",
            disambiguator: ""
        )
        let shiftedDelimiter = VocabularySenseConfirmation.stableSenseID(
            language: "en",
            canonicalForm: "bank",
            partOfSpeech: .noun,
            meaning: "river",
            disambiguator: "edge\(delimiter)"
        )
        let emptyMeaning = VocabularySenseConfirmation.stableSenseID(
            language: "en",
            canonicalForm: "bank",
            partOfSpeech: .noun,
            meaning: "",
            disambiguator: "river"
        )
        let emptyDisambiguator = VocabularySenseConfirmation.stableSenseID(
            language: "en",
            canonicalForm: "bank",
            partOfSpeech: .noun,
            meaning: "river",
            disambiguator: ""
        )

        #expect(delimiterInMeaning != shiftedDelimiter)
        #expect(emptyMeaning != emptyDisambiguator)
    }

    @Test("Study card identity safely encodes confirmed tuples and keeps drafts occurrence scoped")
    func studyCardIdentityIsCollisionSafeAndDeterministic() throws {
        let delimiter = "\u{1f}"
        var embeddedDelimiter = entry(id: "embedded", surface: "bank", context: "First context.")
        embeddedDelimiter.confirmCanonicalForm(
            "bank\(delimiter)noun",
            partOfSpeech: .verb,
            senseID: "sense"
        )
        var shiftedDelimiter = entry(id: "shifted", surface: "bank", context: "Second context.")
        shiftedDelimiter.confirmCanonicalForm(
            "bank",
            partOfSpeech: .noun,
            senseID: "verb\(delimiter)sense"
        )

        let forward = VocabularyStudyCards.cards([embeddedDelimiter, shiftedDelimiter])
        let reversed = VocabularyStudyCards.cards([shiftedDelimiter, embeddedDelimiter])

        #expect(forward.count == 2)
        #expect(Set(forward.map(\.id)).count == 2)
        #expect(Set(forward.map(\.id)) == Set(reversed.map(\.id)))
        #expect(forward.allSatisfy { $0.id.hasPrefix("study:") })

        let firstDraft = entry(id: "draft-a", surface: "bank", context: "Draft A.")
        let secondDraft = entry(id: "draft-b", surface: "bank", context: "Draft B.")
        let draftCards = VocabularyStudyCards.cards([firstDraft, secondDraft])

        #expect(Set(draftCards.map(\.id)) == ["draft-a", "draft-b"])
    }

    @Test("Meaning choices are readable while internal identifiers stay hidden")
    func meaningChoicesUseReadableVocabularyEvidence() throws {
        var river = entry(id: "river", surface: "bank", context: "We rested on the river bank.")
        river.definition = "the land beside a river"
        river.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:river-edge")
        var financial = entry(id: "finance", surface: "bank", context: "The bank approved the loan.")
        financial.translation = "financial institution"
        financial.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:financial-institution")
        var unresolved = entry(id: "new", surface: "bank", context: "The boat reached the bank.")
        unresolved.definition = "the land beside a river"

        let choices = VocabularySenseConfirmation.choices(for: unresolved, among: [river, financial])

        #expect(choices.map(\.title).contains("the land beside a river"))
        #expect(choices.map(\.title).contains("financial institution"))
        #expect(choices.allSatisfy { !$0.title.contains($0.id) })
        #expect(choices.allSatisfy { !$0.title.contains(":river-edge") })
    }

    @Test("Only exact contextual evidence automatically reuses a confirmed sense")
    func contextualRecurrenceReusesOnlyAnUnambiguousConfirmedSense() {
        var river = entry(id: "river", surface: "bank", context: "We rested on the river bank.")
        river.translation = "river edge"
        river.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:river-edge")
        var financial = entry(id: "finance", surface: "bank", context: "The bank approved the loan.")
        financial.translation = "financial institution"
        financial.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:financial-institution")
        var recurring = entry(id: "recurring", surface: "bank", context: "They sat on the bank.")
        recurring.translation = "river edge"
        let ambiguous = entry(id: "ambiguous", surface: "bank", context: "They approached the bank.")

        #expect(VocabularySenseConfirmation.recurringSenseID(for: recurring, among: [river, financial]) == "bank:river-edge")
        #expect(VocabularySenseConfirmation.recurringSenseID(for: ambiguous, among: [river, financial]) == nil)
    }

    @Test("Legacy occurrence senses reconcile without losing schedule or locations")
    func legacySenseReconciliationPreservesState() throws {
        var first = entry(id: "legacy-a", surface: "bank", context: "We rested on the river bank.")
        first.translation = "river edge"
        first.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: first.id)
        first.reviewCount = 7
        first.reviewIntervalDays = 18
        first.nextReview = Date(timeIntervalSince1970: 90_000)
        first.lastReviewedAt = Date(timeIntervalSince1970: 80_000)
        first.lastReviewQuality = .remember
        var second = entry(id: "legacy-b", surface: "bank", context: "The path followed the bank.")
        second.translation = "river edge"
        second.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "occurrence:\(second.id)")
        second.bookID = "other-book"

        let reconciled = VocabularySenseConfirmation.reconcile([first, second])
        let card = try #require(VocabularyStudyCards.cards(reconciled).first)

        #expect(VocabularyStudyCards.cards(reconciled).count == 1)
        #expect(Set(reconciled.compactMap(\.senseID)).count == 1)
        #expect(card.occurrenceIDs == ["legacy-a", "legacy-b"])
        #expect(card.locations.map(\.bookID).sorted() == ["book", "other-book"])
        #expect(reconciled.allSatisfy { $0.reviewCount == 7 })
        #expect(reconciled.allSatisfy { $0.nextReview == Date(timeIntervalSince1970: 90_000) })
    }

    @Test("Reconciliation does not merge delimiter-shifted base and evidence tuples")
    func reconciliationKeyKeepsAdversarialTuplesDistinct() {
        let delimiter = "\u{1f}"
        var embeddedBase = entry(id: "embedded-base", surface: "bank", context: "First context.")
        embeddedBase.translation = "edge"
        embeddedBase.confirmCanonicalForm(
            "bank\(delimiter)noun\(delimiter)translation:river",
            partOfSpeech: .verb,
            senseID: "sense:embedded-base"
        )
        var shiftedEvidence = entry(id: "shifted-evidence", surface: "bank", context: "Second context.")
        shiftedEvidence.translation = "river\(delimiter)verb\(delimiter)translation:edge"
        shiftedEvidence.confirmCanonicalForm(
            "bank",
            partOfSpeech: .noun,
            senseID: "sense:shifted-evidence"
        )

        let reconciled = VocabularySenseConfirmation.reconcile([embeddedBase, shiftedEvidence])

        #expect(Set(reconciled.compactMap(\.senseID)) == ["sense:embedded-base", "sense:shifted-evidence"])
    }

    @Test("Contextual recurrence does not reuse a delimiter-colliding base identity")
    func contextualRecurrenceKeepsAdversarialBaseIdentitiesDistinct() {
        let delimiter = "\u{1f}"
        var confirmed = entry(id: "confirmed", surface: "noun", context: "First context.")
        confirmed.sourceLanguage = "en\(delimiter)bank"
        confirmed.translation = "shared meaning"
        confirmed.confirmCanonicalForm("noun", partOfSpeech: .verb, senseID: "sense:confirmed")
        var candidate = entry(id: "candidate", surface: "bank", context: "Second context.")
        candidate.sourceLanguage = "en"
        candidate.translation = "shared meaning"
        candidate.confirmCanonicalForm(
            "bank\(delimiter)noun",
            partOfSpeech: .verb,
            senseID: nil
        )

        #expect(VocabularySenseConfirmation.recurringSenseID(for: candidate, among: [confirmed]) == nil)
    }

    @Test("Ordinary matching reconciliation still merges schedules and senses")
    func structuredReconciliationKeyStillMergesOrdinaryEvidence() {
        var first = entry(id: "ordinary-a", surface: "bank", context: "First context.")
        first.translation = "river edge"
        first.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "sense:provider-a")
        first.reviewCount = 6
        var second = entry(id: "ordinary-b", surface: "bank", context: "Second context.")
        second.translation = "river edge"
        second.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "sense:provider-b")

        let reconciled = VocabularySenseConfirmation.reconcile([first, second])

        #expect(Set(reconciled.compactMap(\.senseID)).count == 1)
        #expect(reconciled.allSatisfy { $0.reviewCount == 6 })
    }

    @Test("App launch persists deterministic reconciliation and retains legacy review history")
    @MainActor
    func appLaunchPersistsReconciliationWithoutRewritingHistory() throws {
        let vocabulary = InMemoryVocabularyRepository()
        let reviews = InMemoryReviewEventRepository()
        var first = entry(id: "persist-a", surface: "bank", context: "We rested on the river bank.")
        first.translation = "river edge"
        first.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: first.id)
        first.reviewCount = 4
        first.lastReviewedAt = Date(timeIntervalSince1970: 5_000)
        var second = entry(id: "persist-b", surface: "bank", context: "The path followed the bank.")
        second.translation = "river edge"
        second.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "occurrence:\(second.id)")
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "legacy-review"),
            vocabularyID: VocabularyOccurrenceID(rawValue: first.id),
            cardID: "legacy-occurrence-card",
            face: VocabReviewPrompt.recognition.rawValue,
            rating: VocabReviewQuality.remember.rawValue,
            reviewedAt: Date(timeIntervalSince1970: 1_000)
        )
        try vocabulary.saveVocabulary([first, second].map(StoredVocabularyOccurrence.init))
        try reviews.appendReviewEvent(event)

        let state = AppState(composition: AppComposition(
            vocabulary: vocabulary,
            knownLemmas: InMemoryKnownLemmaRepository(),
            reviewEvents: reviews
        ))
        let persisted = try vocabulary.loadVocabulary()

        #expect(VocabularyStudyCards.cards(state.vocab).count == 1)
        #expect(Set(persisted.compactMap(\.senseID)).count == 1)
        #expect(persisted.allSatisfy { $0.reviewCount == 4 })
        #expect(try reviews.loadReviewEvents() == [event])
        #expect(state.vocabReviewEvents == [event])
    }

    @Test("Merge and separate recovery preserve schedules and immutable review history")
    @MainActor
    func mergeAndSeparateRecoveryPreservesReviewStateAndHistory() throws {
        let vocabulary = InMemoryVocabularyRepository()
        let reviews = InMemoryReviewEventRepository()
        var river = entry(id: "river", surface: "bank", context: "We rested on the river bank.")
        river.translation = "river edge"
        river.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:river-edge")
        river.reviewCount = 5
        river.reviewIntervalDays = 14
        river.lastReviewedAt = Date(timeIntervalSince1970: 5_000)
        var duplicate = entry(id: "duplicate", surface: "bank", context: "The path followed the bank.")
        duplicate.translation = "land beside the water"
        duplicate.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "legacy-fallback-river")
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-history"),
            vocabularyID: VocabularyOccurrenceID(rawValue: river.id),
            cardID: "legacy-card-id",
            face: VocabReviewPrompt.recognition.rawValue,
            rating: VocabReviewQuality.remember.rawValue,
            reviewedAt: Date(timeIntervalSince1970: 5_000)
        )
        try vocabulary.saveVocabulary([river, duplicate].map(StoredVocabularyOccurrence.init))
        try reviews.appendReviewEvent(event)
        let state = AppState(composition: AppComposition(
            vocabulary: vocabulary,
            knownLemmas: InMemoryKnownLemmaRepository(),
            reviewEvents: reviews
        ))
        let target = try #require(VocabularySenseConfirmation.choices(
            for: state.vocab.first { $0.id == duplicate.id }!,
            among: state.vocab
        ).first { $0.occurrenceIDs.contains(river.id) })

        state.confirmVocabularyMeaning(
            duplicate.id,
            canonicalForm: "banking",
            partOfSpeech: .verb,
            choice: target
        )
        let merged = try #require(state.vocab.first { $0.id == duplicate.id })
        #expect(merged.senseID == river.senseID)
        #expect(merged.canonicalForm == "bank")
        #expect(merged.partOfSpeech == .noun)
        #expect(merged.reviewCount == 5)
        #expect(try reviews.loadReviewEvents() == [event])

        state.separateVocabularyMeaning(duplicate.id)
        let separated = try #require(state.vocab.first { $0.id == duplicate.id })
        #expect(separated.senseID != river.senseID)
        #expect(separated.reviewCount == 5)
        #expect(try reviews.loadReviewEvents() == [event])
        #expect(try vocabulary.loadVocabulary().first { $0.id.rawValue == duplicate.id }?.senseID == separated.senseID)
    }

    @Test("Compatible occurrences keep the strongest reviewed schedule")
    func canonicalMergePreservesReviewedSchedule() {
        var earlier = entry(id: "did", surface: "did", context: "I did it.")
        earlier.reviewCount = 8
        earlier.reviewIntervalDays = 21
        earlier.nextReview = Date(timeIntervalSince1970: 9_000)
        earlier.lastReviewedAt = Date(timeIntervalSince1970: 8_000)
        earlier.lastReviewQuality = .remember
        let later = entry(id: "done", surface: "done", context: "It is done.")

        let card = VocabularyStudyCards.cards([later, earlier]).first

        #expect(card?.schedule.reviewCount == 8)
        #expect(card?.schedule.reviewIntervalDays == 21)
        #expect(card?.schedule.nextReview == Date(timeIntervalSince1970: 9_000))
        #expect(card?.occurrenceIDs == Set([earlier.id, later.id]))
    }

    @Test("One canonical card retains occurrence locations in every source book")
    func canonicalCardRetainsMultiBookOccurrences() throws {
        var first = entry(id: "book-a-did", surface: "did", context: "I did it.")
        first.bookID = "book-a"
        first.bookTitle = "Book A"
        var second = entry(id: "book-b-done", surface: "done", context: "It is done.")
        second.bookID = "book-b"
        second.bookTitle = "Book B"

        let card = try #require(VocabularyStudyCards.cards([first, second]).first)
        #expect(card.occurrences.count == 2)
        #expect(Set(card.locations.map(\.bookID)) == ["book-a", "book-b"])
        #expect(card.occurrence(id: first.id)?.context == "I did it.")
        #expect(card.occurrence(id: second.id)?.context == "It is done.")

        let bookA = VocabularyReviewSetupProjection.make(entries: [first, second], at: .now)
            .summary(for: .book("book-a"))
        let bookB = VocabularyReviewSetupProjection.make(entries: [first, second], at: .now)
            .summary(for: .book("book-b"))
        #expect(bookA.sessionIDs == [card.id])
        #expect(bookB.sessionIDs == [card.id])
    }

    @Test("New contains only eligible canonical study concepts")
    func newQueueFiltersEligibilityAndCanonicalDuplicates() {
        let did = entry(id: "did", surface: "did", context: "I did it.")
        let done = entry(id: "done", surface: "done", context: "It is done.")
        var suggestion = VocabEntry(
            id: "suggestion",
            word: "gave up",
            canonicalForm: "give up",
            partOfSpeech: .verb,
            captureSource: .automaticPhraseSuggestion,
            reviewEligible: false,
            category: .phrase,
            context: "She gave up.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )
        suggestion.isInLearnList = true

        let queue = VocabularyLearningAnalytics.queue(entries: [did, done, suggestion], at: .now)

        #expect(queue.new.count == 1)
        #expect(queue.new.first?.canonicalForm == "do")
        #expect(suggestion.isInLearnList)
        #expect(!suggestion.reviewEligible)
    }

    @MainActor
    @Test("Suggestions and sentence annotations require explicit acceptance")
    func explicitAcceptanceControlsEligibility() {
        let state = AppState(composition: .inMemory())
        state.vocab = [
            VocabEntry(
                id: "phrase",
                word: "gave up",
                canonicalForm: "give up",
                partOfSpeech: .verb,
                captureSource: .automaticPhraseSuggestion,
                reviewEligible: false,
                category: .phrase,
                context: "She gave up.",
                bookID: "book",
                bookTitle: "Book",
                chapterID: "chapter",
                chapterTitle: "Chapter",
                timestamp: 1,
                addedAt: Date(timeIntervalSince1970: 1)
            ),
            VocabEntry(
                id: "sentence",
                word: "She gave up.",
                canonicalForm: "She gave up.",
                partOfSpeech: .sentence,
                captureSource: .acceptedSentenceTranslation,
                reviewEligible: false,
                category: .sentence,
                context: "She gave up.",
                bookID: "book",
                bookTitle: "Book",
                chapterID: "chapter",
                chapterTitle: "Chapter",
                timestamp: 1,
                addedAt: Date(timeIntervalSince1970: 1)
            )
        ]
        #expect(VocabularyLearningAnalytics.queue(entries: state.vocab, at: .now).new.isEmpty)

        state.acceptVocabularyForReview("phrase")
        state.acceptVocabularyForReview("sentence")

        #expect(state.vocab.first { $0.id == "phrase" }?.captureSource == .explicitPhrase)
        #expect(state.vocab.first { $0.id == "sentence" }?.captureSource == .explicitSentence)
        #expect(VocabularyLearningAnalytics.queue(entries: state.vocab, at: .now).new.count == 2)
    }

    @Test("Canonical metadata survives local persistence serialization")
    func canonicalMetadataRoundTrips() throws {
        let original = entry(id: "did", surface: "did", context: "I did it.")
        let stored = StoredVocabularyOccurrence(original)
        let decoded = try JSONDecoder().decode(
            StoredVocabularyOccurrence.self,
            from: JSONEncoder().encode(stored)
        )

        #expect(decoded.surface == "did")
        #expect(decoded.canonicalForm == "do")
        #expect(decoded.partOfSpeech == VocabularyPartOfSpeech.verb.rawValue)
        #expect(decoded.captureSource == VocabularyCaptureSource.explicitWord.rawValue)
        #expect(decoded.reviewEligible)
        #expect(VocabEntry(decoded).studyIdentity == original.studyIdentity)
    }

    @Test("Pre-canonicalization reviewed data decodes safely without losing its schedule")
    func additiveSchemaDecodingPreservesReviewedData() throws {
        let json = """
        {
          "id":"legacy-reviewed","word":"axes","category":"word","context":"The axes crossed.",
          "bookID":"book","bookTitle":"Book","chapterID":"chapter","chapterTitle":"Chapter",
          "timestamp":1,"addedAt":"1970-01-01T00:00:01Z","reviewCount":4,
          "nextReview":"1970-01-01T02:46:40Z","lastReviewedAt":"1970-01-01T02:30:00Z",
          "lastReviewQuality":"remember","reviewIntervalDays":14,"reviewEaseFactor":2.7,
          "isInLearnList":false
        }
        """
        let entry = try JSONDecoder.iso.decode(VocabEntry.self, from: Data(json.utf8))

        #expect(entry.word == "axes")
        #expect(entry.canonicalForm == "axes")
        #expect(entry.canonicalizationStatus == .needsReview)
        #expect(entry.reviewEligible)
        #expect(entry.reviewCount == 4)
        #expect(entry.reviewIntervalDays == 14)
        #expect(entry.lastReviewQuality == .remember)
    }

    @Test("Cached structured fallback is reused with traceable provenance")
    func cachedFallbackIsBoundedAndTraceable() async throws {
        let client = RecordingCanonicalizationFallbackClient(result: .init(
            canonicalForm: "bank",
            partOfSpeech: .noun,
            senseID: "bank:river-edge",
            confidence: 0.94,
            traceID: "trace-river-bank"
        ))
        let resolver = VocabularyCanonicalizationFallbackResolver(client: client, capacity: 4)
        let offline = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "bank",
            context: "We rested on the river bank.",
            language: "en"
        )
        let longContext = String(repeating: "Before. ", count: 100) + "We rested on the river bank."

        let first = await resolver.resolve(
            offline: offline,
            surfaceForm: "bank",
            context: longContext,
            language: "en"
        )
        let second = await resolver.resolve(
            offline: offline,
            surfaceForm: "bank",
            context: longContext,
            language: "en"
        )

        let callCount = await client.callCount
        let lastContextCount = await client.lastContextCount
        #expect(callCount == 1)
        #expect(lastContextCount <= VocabularyCanonicalizationFallbackRequest.maximumContextLength)
        #expect(first == second)
        #expect(first.source == .cachedLLM)
        #expect(first.traceID == "trace-river-bank")
        #expect(first.status == .confirmed)
    }

    @Test("Managed fallback uses provider message provenance instead of model-authored trace")
    func managedFallbackUsesProviderTrace() async throws {
        let recorder = RecordingManagedCanonicalizationCompletion()
        let client = ManagedVocabularyCanonicalizationFallbackClient(completion: recorder.complete)
        let resolver = VocabularyCanonicalizationFallbackResolver(client: client)
        let offline = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "bank",
            context: "We rested on the river bank.",
            language: "en"
        )
        let result = await resolver.resolve(
            offline: offline,
            surfaceForm: "bank",
            context: "We rested on the river bank.",
            language: "en"
        )
        let cached = await resolver.resolve(
            offline: offline,
            surfaceForm: "bank",
            context: "We rested on the river bank.",
            language: "en"
        )

        #expect(result.traceID == "provider-message-17")
        #expect(result.senseID == "bank:river-edge")
        #expect(cached == result)
        #expect(await recorder.callCount == 1)
        let system = await recorder.system
        #expect(!system.contains("traceID"))
        #expect(!system.contains("traceId"))
    }

    @Test("Unavailable or invalid fallback fails closed without a mergeable sense")
    func fallbackFailsClosed() async {
        let offline = VocabularyCanonicalizer.canonicalize(
            surfaceForm: "axes",
            context: "The axes crossed.",
            language: "en"
        )
        let invalid = RecordingCanonicalizationFallbackClient(result: .init(
            canonicalForm: "axis",
            partOfSpeech: .noun,
            senseID: nil,
            confidence: 0.99,
            traceID: "invalid"
        ))
        let unavailable = RecordingCanonicalizationFallbackClient(result: nil)

        let invalidResult = await VocabularyCanonicalizationFallbackResolver(client: invalid)
            .resolve(offline: offline, surfaceForm: "axes", context: "The axes crossed.", language: "en")
        let unavailableResult = await VocabularyCanonicalizationFallbackResolver(client: unavailable)
            .resolve(offline: offline, surfaceForm: "axes", context: "The axes crossed.", language: "en")

        #expect(invalidResult.status == .needsReview)
        #expect(invalidResult.senseID == nil)
        #expect(unavailableResult == offline)
    }

    private func entry(
        id: String,
        surface: String,
        context: String,
        status: VocabularyCanonicalizationStatus? = nil,
        confidence: Double? = nil
    ) -> VocabEntry {
        let canonicalization = VocabularyCanonicalizer.canonicalize(
            surfaceForm: surface,
            context: context,
            language: "en"
        )
        return VocabEntry(
            id: id,
            word: surface,
            canonicalForm: canonicalization.canonicalForm,
            partOfSpeech: canonicalization.partOfSpeech,
            senseID: canonicalization.senseID,
            canonicalizationSource: canonicalization.source,
            canonicalizationConfidence: confidence ?? canonicalization.confidence,
            canonicalizationStatus: status ?? canonicalization.status,
            canonicalizationTraceID: canonicalization.traceID,
            captureSource: .explicitWord,
            reviewEligible: true,
            category: .word,
            sourceLanguage: "en",
            context: context,
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            segmentID: "segment-\(id)",
            wordID: "word-\(id)",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private actor RecordingCanonicalizationFallbackClient: VocabularyCanonicalizationFallbackClient {
    private(set) var callCount = 0
    private(set) var lastContextCount = 0
    let result: VocabularyCanonicalizationFallbackResult?

    init(result: VocabularyCanonicalizationFallbackResult?) {
        self.result = result
    }

    func canonicalize(_ request: VocabularyCanonicalizationFallbackRequest) async throws
        -> VocabularyCanonicalizationFallbackResult? {
        callCount += 1
        lastContextCount = request.context.count
        return result
    }
}

private actor RecordingManagedCanonicalizationCompletion {
    private(set) var system = ""
    private(set) var callCount = 0

    func complete(system: String, user: String, language: String) async throws -> ProductAICompletion {
        self.system = system
        callCount += 1
        return ProductAICompletion(
            text: """
            {"canonicalForm":"bank","partOfSpeech":"noun","senseID":"bank:river-edge","confidence":0.94}
            """,
            traceID: "provider-message-17"
        )
    }
}
