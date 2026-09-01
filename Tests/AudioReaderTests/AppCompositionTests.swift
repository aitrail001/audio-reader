import Foundation
import Testing
@testable import AudioReader

@Suite("App composition injects learning repositories")
struct AppCompositionTests {
    private let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Live composition uses the single vNext SQLite store and no network")
    func liveCompositionUsesVNextStoreWithoutNetwork() throws {
        let compositionSource = try source("Sources/AudioReader/AppComposition.swift")
        let app = try source("Sources/AudioReader/AudioReaderApp.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")

        #expect(compositionSource.components(separatedBy: "Persistence.store").count - 1 == 1)
        #expect(!compositionSource.contains("LibraryStore"))
        #expect(!compositionSource.contains("RepositoryAdapter"))
        #expect(compositionSource.contains("var usesLivePersistence: Bool { synchronizedStore != nil }"))
        #expect(compositionSource.contains("transcripts: InMemoryTranscriptRepository"))
        #expect(!compositionSource.contains("#if os("))
        #expect(!compositionSource.contains("URLSession"))
        #expect(!compositionSource.contains("http"))
        #expect(app.contains("AppState(composition: .live)"))
        #expect(!app.contains("AppState()"))
        #expect(appState.contains("init(composition: AppComposition"))
        #expect(appState.contains("init(composition: AppComposition = .inMemory()"))
        #expect(!appState.contains("?? Persistence.store"))
        #expect(!appState.contains("Persistence.store"))
        #expect(!appState.contains("Persistence.loadVocab"))
        #expect(!appState.contains("Persistence.saveVocab"))
        #expect(!appState.contains("Persistence.loadKnownLemmas"))
        #expect(!appState.contains("Persistence.saveKnownLemmas"))

        let persistence = try source("Sources/AudioReader/Persistence.swift")
        let defaultPath = try section(
            in: persistence,
            from: "    private static var defaultLibraryPath: String {",
            to: "\n    init("
        )
        #expect(defaultPath.contains("Persistence.defaultImportedBooksURL.path"))
        #expect(!AppSettings.default.libraryPath.isEmpty)
        #expect(AppSettings.default.libraryPath.contains("ImportedBooks-vNext"))
        #expect(AppSettings.default.libraryPath.hasPrefix("/"))
        #expect(AppSettings.default.libraryPath != FileManager.default.currentDirectoryPath)
    }

    private func section(in source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    @MainActor
    @Test("In-memory composition does not load live Persistence or LibraryStore")
    func inMemoryCompositionDoesNotLoadLiveStore() throws {
        let state = AppState()

        #expect(state.glosses.isEmpty)
        #expect(state.vocab.isEmpty)
        #expect(state.knownLemmas.isEmpty)
        #expect(state.studyActivityLog == .empty)
        #expect(state.settings.playbackRate == AppSettings.default.playbackRate)
        #expect(state.settings.libraryPath == AppSettings.default.libraryPath)
        #expect(!state.settings.showStudyOverlay)
    }

    @MainActor
    @Test("sync publication refreshes catalog decisions and checkpoints without relaunch")
    func syncPublicationRefreshesStructuredStateImmediately() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        try store.saveBook(StoredBook(
            id: BookID(rawValue: "cloud-book"),
            title: "Cloud metadata",
            source: BookSource.files.rawValue,
            chapters: [StoredChapter(id: ChapterID(rawValue: "cloud-chapter"), index: 0, title: "One")]
        ))
        for (id, status) in [("accepted-result", AssistantResultStatus.accepted), ("rejected-result", .rejected)] {
            try store.saveAssistantResult(StoredAssistantResult(
                id: id,
                kind: .sentenceGloss,
                status: status,
                language: "zh-Hans",
                model: "managed",
                bookID: BookID(rawValue: "cloud-book"),
                chapterID: ChapterID(rawValue: "cloud-chapter"),
                source: "Source \(id)",
                text: "Result \(id)",
                createdAt: occurredAt,
                decidedAt: occurredAt
            ))
        }
        try store.saveTranslationCheckpoint(StoredTranslationCheckpoint(
            chapterID: ChapterID(rawValue: "cloud-chapter"),
            language: "zh-Hans",
            mode: ChapterTranslationMode.untranslatedOnly.rawValue,
            completedSegmentCount: 3,
            totalSegmentCount: 9,
            status: ChapterTranslationStatus.awaitingReview.rawValue,
            updatedAt: occurredAt
        ))
        let state = AppState(
            composition: AppComposition(liveStore: store),
            account: AccountSession.isolated()
        )

        state.account.onLearningDataApplied?()

        #expect(state.books.map { $0.id } == ["cloud-book"])
        #expect(state.books.first?.mediaAvailability == .metadataOnly)
        #expect(Set(state.glosses.map { $0.status }) == Set([GlossStatus.accepted, .rejected]))
        #expect(state.chapterTranslationCheckpoints.first?.totalSentences == 9)
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

        #expect(state.vocab.map(\.id) == [token])
        #expect(state.vocab.map(\.word) == [token])
        #expect(state.knownLemmas.map(\.form) == [token])
        #expect(state.glosses.isEmpty)
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
    func vocabularyMutationsPersistThroughInjectedRepository() async throws {
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
        await state.reviewVocabulary(token, quality: .remember, at: now)

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
        state.settings.libraryPath = token
        state.persistSettings()
        state.recordStudyActivity(now: occurredAt)
        let word = TranscriptWord(id: "w-isolated", text: token, start: 0, end: 0.4, confidence: nil)
        state.markKnown(word, known: true)
        state.setVocabularyLearnList(token, included: true)
        state.removeVocab(try #require(state.vocab.first { $0.id == token }))

        #expect(try knownLemmas.loadKnownLemmas().map(\.form) == [token])
        #expect(try vocabulary.loadVocabulary().isEmpty)
        #expect(state.glosses.isEmpty)
        #expect(!applicationSupportContains(token))
    }

    private func applicationSupportContains(_ token: String) -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioReader", isDirectory: true)
        guard FileManager.default.fileExists(atPath: support.path) else { return false }
        let needle = Data(token.utf8)
        let names = [
            "vocab.json",
            "lexicon.json",
            "glosses.json",
            "settings.json",
            "study-activity.json",
            "library.sqlite"
        ]
        for name in names {
            let url = support.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { continue }
            if data.range(of: needle) != nil { return true }
        }
        return false
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
