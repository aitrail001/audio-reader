import Foundation
import Testing
@testable import AudioReader

@Suite("App composition injects learning repositories")
struct AppCompositionTests {
    private let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Live composition uses local adapters and no network")
    func liveCompositionUsesLocalAdaptersWithoutNetwork() throws {
        let composition = AppComposition.live
        #expect(composition.vocabulary is LibraryStoreVocabularyRepository)
        #expect(composition.knownLemmas is PersistenceKnownLemmaRepository)

        let compositionSource = try source("Sources/AudioReader/AppComposition.swift")
        let app = try source("Sources/AudioReader/AudioReaderApp.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")

        #expect(!compositionSource.contains("#if os("))
        #expect(!compositionSource.contains("URLSession"))
        #expect(!compositionSource.contains("http"))
        #expect(app.contains("AppState(composition: .live)"))
        #expect(!app.contains("AppState()"))
        #expect(appState.contains("init(composition: AppComposition"))
        #expect(!appState.contains("Persistence.loadVocab"))
        #expect(!appState.contains("Persistence.saveVocab"))
        #expect(!appState.contains("Persistence.loadKnownLemmas"))
        #expect(!appState.contains("Persistence.saveKnownLemmas"))
    }

    @MainActor
    @Test("AppState loads known lemmas and vocabulary from injected repositories")
    func loadsLearningStateFromInjectedRepositories() throws {
        let vocabulary = InMemoryVocabularyRepository()
        let knownLemmas = InMemoryKnownLemmaRepository()
        let token = "inject-\(UUID().uuidString)"
        try vocabulary.saveVocabulary([
            sampleVocabulary(id: token, surface: token, addedAt: occurredAt)
        ])
        try knownLemmas.saveKnownLemmas([
            StoredKnownLemma(language: "en", form: token, updatedAt: occurredAt)
        ])

        let state = AppState(
            composition: AppComposition(vocabulary: vocabulary, knownLemmas: knownLemmas)
        )

        #expect(state.vocab.contains { $0.id == token && $0.word == token })
        #expect(state.knownLemmas.contains { $0.form == token && $0.language == "en" })
    }

    @MainActor
    @Test("Mark known persists through the injected lemma repository")
    func markKnownPersistsThroughInjectedRepository() throws {
        let vocabulary = InMemoryVocabularyRepository()
        let knownLemmas = InMemoryKnownLemmaRepository()
        let state = AppState(
            composition: AppComposition(vocabulary: vocabulary, knownLemmas: knownLemmas)
        )
        state.settings.transcriptionLanguage = TranscriptionLanguage.englishUS.rawValue
        state.vocab = []
        state.knownLemmas = []
        let word = TranscriptWord(id: "w1", text: "Forest.", start: 0.2, end: 0.6, confidence: nil)

        state.markKnown(word, known: true)

        #expect(state.knownLemmas.contains { $0.form == "forest" && $0.language == "en" })
        #expect(try knownLemmas.loadKnownLemmas().map(\.form) == ["forest"])

        state.markKnown(word, known: false)
        #expect(state.knownLemmas.isEmpty)
        #expect(try knownLemmas.loadKnownLemmas().isEmpty)
    }

    @MainActor
    @Test("Vocabulary review and learn-list updates persist through the injected repository")
    func vocabularyMutationsPersistThroughInjectedRepository() throws {
        let vocabulary = InMemoryVocabularyRepository()
        let knownLemmas = InMemoryKnownLemmaRepository()
        let token = "review-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 2_000_000)
        var entry = sampleVocabEntry(id: token, surface: "forest", addedAt: occurredAt)
        entry.isInLearnList = true
        try vocabulary.saveVocabulary([StoredVocabularyOccurrence(entry)])

        let state = AppState(
            composition: AppComposition(vocabulary: vocabulary, knownLemmas: knownLemmas)
        )
        state.setVocabularyLearnList(token, included: false)
        state.reviewVocabulary(token, quality: .remember, at: now)

        let stored = try #require(try vocabulary.loadVocabulary().first { $0.id.rawValue == token })
        #expect(stored.isInLearnList == false)
        #expect(stored.lastReviewQuality == VocabReviewQuality.remember.rawValue)
        #expect(stored.reviewCount == 1)
        #expect(state.vocab.first { $0.id == token }?.isInLearnList == false)
        #expect(state.vocab.first { $0.id == token }?.lastReviewQuality == .remember)
    }

    @MainActor
    @Test("Injected learning persistence does not write Application Support files")
    func injectedPersistenceDoesNotWriteApplicationSupport() throws {
        let token = "compositionisolated\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let vocabulary = InMemoryVocabularyRepository()
        let knownLemmas = InMemoryKnownLemmaRepository()
        try vocabulary.saveVocabulary([
            sampleVocabulary(id: token, surface: token, addedAt: occurredAt)
        ])

        let state = AppState(
            composition: AppComposition(vocabulary: vocabulary, knownLemmas: knownLemmas)
        )
        state.settings.transcriptionLanguage = TranscriptionLanguage.englishUS.rawValue
        state.knownLemmas = []
        let word = TranscriptWord(id: "w-isolated", text: token, start: 0, end: 0.4, confidence: nil)
        state.markKnown(word, known: true)
        state.setVocabularyLearnList(token, included: true)
        state.removeVocab(try #require(state.vocab.first { $0.id == token }))

        #expect(try knownLemmas.loadKnownLemmas().map(\.form) == [token])
        #expect(try vocabulary.loadVocabulary().allSatisfy { $0.id.rawValue != token })

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioReader", isDirectory: true)
        let needle = Data(token.utf8)
        for name in ["vocab.json", "lexicon.json"] {
            let url = support.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { continue }
            #expect(data.range(of: needle) == nil)
        }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sampleVocabEntry(id: String, surface: String, addedAt: Date) -> VocabEntry {
        VocabEntry(
            id: id,
            word: surface,
            category: .word,
            context: "\(surface) context",
            bookID: "book-1",
            bookTitle: "Moby-Dick",
            chapterID: "chapter-1",
            chapterTitle: "Loomings",
            timestamp: 0,
            addedAt: addedAt
        )
    }

    private func sampleVocabulary(id: String, surface: String, addedAt: Date) -> StoredVocabularyOccurrence {
        StoredVocabularyOccurrence(sampleVocabEntry(id: id, surface: surface, addedAt: addedAt))
    }
}
