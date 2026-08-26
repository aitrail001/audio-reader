struct AppComposition: Sendable {
    var vocabulary: any VocabularyRepository
    var knownLemmas: any KnownLemmaRepository
    /// When false, AppState must not read or write Persistence.root / LibraryStore.shared.
    var usesLivePersistence: Bool

    init(
        vocabulary: any VocabularyRepository,
        knownLemmas: any KnownLemmaRepository,
        usesLivePersistence: Bool = false
    ) {
        self.vocabulary = vocabulary
        self.knownLemmas = knownLemmas
        self.usesLivePersistence = usesLivePersistence
    }

    static let live = AppComposition(
        vocabulary: LibraryStoreVocabularyRepository(store: .shared),
        knownLemmas: PersistenceKnownLemmaRepository(),
        usesLivePersistence: true
    )

    static func inMemory(
        vocabulary: InMemoryVocabularyRepository = InMemoryVocabularyRepository(),
        knownLemmas: InMemoryKnownLemmaRepository = InMemoryKnownLemmaRepository()
    ) -> AppComposition {
        AppComposition(vocabulary: vocabulary, knownLemmas: knownLemmas)
    }
}
