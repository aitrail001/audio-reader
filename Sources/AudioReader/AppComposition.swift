struct AppComposition: Sendable {
    var vocabulary: any VocabularyRepository
    var knownLemmas: any KnownLemmaRepository

    static let live = AppComposition(
        vocabulary: LibraryStoreVocabularyRepository(store: .shared),
        knownLemmas: PersistenceKnownLemmaRepository()
    )

    static func inMemory(
        vocabulary: InMemoryVocabularyRepository = InMemoryVocabularyRepository(),
        knownLemmas: InMemoryKnownLemmaRepository = InMemoryKnownLemmaRepository()
    ) -> AppComposition {
        AppComposition(vocabulary: vocabulary, knownLemmas: knownLemmas)
    }
}
