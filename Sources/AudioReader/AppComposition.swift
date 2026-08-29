struct AppComposition: Sendable {
    var vocabulary: any VocabularyRepository
    var knownLemmas: any KnownLemmaRepository
    var reviewEvents: any ReviewEventRepository
    /// When false, AppState skips live settings, gloss, checkpoint, summary, and study-activity I/O and does not open LibraryStore.shared during init.
    var usesLivePersistence: Bool

    init(
        vocabulary: any VocabularyRepository,
        knownLemmas: any KnownLemmaRepository,
        reviewEvents: any ReviewEventRepository = InMemoryReviewEventRepository(),
        usesLivePersistence: Bool = false
    ) {
        self.vocabulary = vocabulary
        self.knownLemmas = knownLemmas
        self.reviewEvents = reviewEvents
        self.usesLivePersistence = usesLivePersistence
    }

    static let live = AppComposition(
        vocabulary: LibraryStoreVocabularyRepository(store: .shared),
        knownLemmas: PersistenceKnownLemmaRepository(),
        reviewEvents: LocalSQLiteStore(
            fileURL: Persistence.root.appendingPathComponent("library.sqlite")
        ),
        usesLivePersistence: true
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
