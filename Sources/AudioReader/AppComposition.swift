struct AppComposition: Sendable {
    var vocabulary: any VocabularyRepository
    var knownLemmas: any KnownLemmaRepository
    var reviewEvents: any ReviewEventRepository
    var canonicalizationFallback: VocabularyCanonicalizationFallbackResolver?
    /// When false, AppState skips all disk-backed learning and assistant state.
    var usesLivePersistence: Bool
    /// Canonical structured state published after a sync page commits.
    var synchronizedStore: LocalSQLiteStore?

    init(
        vocabulary: any VocabularyRepository,
        knownLemmas: any KnownLemmaRepository,
        reviewEvents: any ReviewEventRepository = InMemoryReviewEventRepository(),
        canonicalizationFallback: VocabularyCanonicalizationFallbackResolver? = nil,
        usesLivePersistence: Bool = false,
        synchronizedStore: LocalSQLiteStore? = nil
    ) {
        self.vocabulary = vocabulary
        self.knownLemmas = knownLemmas
        self.reviewEvents = reviewEvents
        self.canonicalizationFallback = canonicalizationFallback
        self.usesLivePersistence = usesLivePersistence
        self.synchronizedStore = synchronizedStore
    }

    static let live = AppComposition(
        vocabulary: Persistence.store,
        knownLemmas: Persistence.store,
        reviewEvents: Persistence.store,
        canonicalizationFallback: VocabularyCanonicalizationFallbackResolver(
            client: ManagedVocabularyCanonicalizationFallbackClient()
        ),
        usesLivePersistence: true,
        synchronizedStore: Persistence.store
    )

    static func inMemory(
        vocabulary: InMemoryVocabularyRepository = InMemoryVocabularyRepository(),
        knownLemmas: InMemoryKnownLemmaRepository = InMemoryKnownLemmaRepository(),
        reviewEvents: InMemoryReviewEventRepository = InMemoryReviewEventRepository()
    ) -> AppComposition {
        AppComposition(
            vocabulary: vocabulary,
            knownLemmas: knownLemmas,
            reviewEvents: reviewEvents
        )
    }
}
