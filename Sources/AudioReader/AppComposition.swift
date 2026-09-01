struct AppComposition: Sendable {
    var vocabulary: any VocabularyRepository
    var knownLemmas: any KnownLemmaRepository
    var reviewEvents: any ReviewEventRepository
    var transcripts: any TranscriptRepository
    var canonicalizationFallback: VocabularyCanonicalizationFallbackResolver?
    /// A live composition has one canonical owner for every local repository.
    var synchronizedStore: LocalSQLiteStore?

    var usesLivePersistence: Bool { synchronizedStore != nil }

    init(
        vocabulary: any VocabularyRepository,
        knownLemmas: any KnownLemmaRepository,
        reviewEvents: any ReviewEventRepository = InMemoryReviewEventRepository(),
        transcripts: any TranscriptRepository = InMemoryTranscriptRepository(),
        canonicalizationFallback: VocabularyCanonicalizationFallbackResolver? = nil
    ) {
        self.vocabulary = vocabulary
        self.knownLemmas = knownLemmas
        self.reviewEvents = reviewEvents
        self.transcripts = transcripts
        self.canonicalizationFallback = canonicalizationFallback
        synchronizedStore = nil
    }

    /// Live construction derives every repository from the same SQLite store,
    /// preventing transcript and learning state from diverging.
    init(
        liveStore: LocalSQLiteStore,
        canonicalizationFallback: VocabularyCanonicalizationFallbackResolver? = nil
    ) {
        vocabulary = liveStore
        knownLemmas = liveStore
        reviewEvents = liveStore
        transcripts = liveStore
        self.canonicalizationFallback = canonicalizationFallback
        synchronizedStore = liveStore
    }

    static let live = AppComposition(
        liveStore: Persistence.store,
        canonicalizationFallback: VocabularyCanonicalizationFallbackResolver(
            client: ManagedVocabularyCanonicalizationFallbackClient()
        )
    )

    static func inMemory(
        vocabulary: InMemoryVocabularyRepository = InMemoryVocabularyRepository(),
        knownLemmas: InMemoryKnownLemmaRepository = InMemoryKnownLemmaRepository(),
        reviewEvents: InMemoryReviewEventRepository = InMemoryReviewEventRepository(),
        transcripts: InMemoryTranscriptRepository = InMemoryTranscriptRepository()
    ) -> AppComposition {
        AppComposition(
            vocabulary: vocabulary,
            knownLemmas: knownLemmas,
            reviewEvents: reviewEvents,
            transcripts: transcripts
        )
    }
}
