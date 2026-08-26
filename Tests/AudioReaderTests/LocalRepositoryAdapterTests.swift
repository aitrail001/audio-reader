import Foundation
import Testing
@testable import AudioReader

@Suite("Persistence and LibraryStore repository adapters")
struct LocalRepositoryAdapterTests {
    private let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("settings adapter preserves current JSON load and save")
    func settingsAdapterPreservesJSONLoadAndSave() throws {
        let fixture = try IsolatedStoreFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("settings.json")
        let repo: any SettingsRepository = PersistenceSettingsRepository(url: url)

        #expect(try repo.loadSettings().playbackRate == AppSettings.default.playbackRate)
        #expect(try repo.loadSettings().vocabReviewPrompt == VocabReviewPrompt.recognition.rawValue)

        var settings = try repo.loadSettings()
        settings.playbackRate = 1.25
        settings.appearance = AppAppearance.light.rawValue
        settings.showStudyOverlay = true
        try repo.saveSettings(settings)

        let loaded = Persistence.loadSettings(from: url)
        #expect(loaded.playbackRate == 1.25)
        #expect(loaded.appearance == AppAppearance.light.rawValue)
        #expect(loaded.showStudyOverlay)
        #expect(try repo.loadSettings().playbackRate == 1.25)
    }

    @Test("transcript adapter preserves LibraryStore load and save")
    func transcriptAdapterPreservesLibraryStoreLoadAndSave() throws {
        let fixture = try IsolatedStoreFixture()
        defer { fixture.remove() }
        let store = LibraryStore(fileURL: fixture.sqliteURL)
        let repo: any TranscriptRepository = LibraryStoreTranscriptRepository(store: store)
        let stored = StoredTranscript(
            chapterID: ChapterID(rawValue: "chapter-adapter-1"),
            localMediaKey: "/tmp/adapter-chapter.m4b",
            chapterStart: 1.5,
            createdAt: occurredAt,
            locale: "en-US",
            source: "apple-speech",
            ebookAligned: false,
            ebookAlignment: StoredEPUBAlignment(status: "uncertain", reason: "test"),
            ebookUseOverride: nil,
            segments: [
                StoredTranscriptSegment(
                    id: "seg-1",
                    start: 0,
                    end: 1.2,
                    words: [
                        StoredTranscriptWord(id: "w-1", text: "Call", start: 0, end: 0.4, confidence: 0.9)
                    ]
                )
            ]
        )

        try repo.saveTranscript(stored)
        let fromStore = try #require(store.loadTranscript(chapterID: stored.chapterID.rawValue))
        #expect(fromStore.chapterID == stored.chapterID.rawValue)
        #expect(fromStore.audioPath == stored.localMediaKey)
        #expect(fromStore.locale == "en-US")
        #expect(fromStore.segments[0].words[0].text == "Call")
        #expect(fromStore.ebookAlignment?.status == .uncertain)

        let fromRepo = try #require(try repo.loadTranscript(chapterID: stored.chapterID))
        #expect(fromRepo.chapterID == stored.chapterID)
        #expect(fromRepo.localMediaKey == stored.localMediaKey)
        #expect(fromRepo.segments[0].words[0].text == "Call")
        #expect(fromRepo.ebookAlignment?.status == "uncertain")
    }

    @Test("vocabulary adapter preserves LibraryStore replace and upsert")
    func vocabularyAdapterPreservesLibraryStoreReplaceAndUpsert() throws {
        let fixture = try IsolatedStoreFixture()
        defer { fixture.remove() }
        let store = LibraryStore(fileURL: fixture.sqliteURL)
        let repo: any VocabularyRepository = LibraryStoreVocabularyRepository(store: store)
        let first = sampleVocabulary(id: "vocab-1", surface: "forest", addedAt: occurredAt)
        let second = sampleVocabulary(id: "vocab-2", surface: "whale", addedAt: occurredAt.addingTimeInterval(30))

        try repo.saveVocabulary([first, second])
        #expect(store.loadVocab().map(\.word) == ["whale", "forest"])
        #expect(try repo.loadVocabulary().map(\.surface) == ["whale", "forest"])

        var updated = first
        updated.translation = "森林"
        updated.lastReviewQuality = "remember"
        try repo.upsertVocabulary([updated])
        let fromStore = store.loadVocab()
        #expect(fromStore.first { $0.id == "vocab-1" }?.translation == "森林")
        #expect(fromStore.first { $0.id == "vocab-1" }?.lastReviewQuality == .remember)
        #expect(fromStore.count == 2)

        try repo.deleteVocabulary(id: VocabularyOccurrenceID(rawValue: "vocab-2"))
        #expect(try repo.loadVocabulary().map(\.surface) == ["forest"])
    }

    @Test("known lemma adapter preserves current JSON load and save")
    func knownLemmaAdapterPreservesJSONLoadAndSave() throws {
        let fixture = try IsolatedStoreFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("lexicon.json")
        let repo: any KnownLemmaRepository = PersistenceKnownLemmaRepository(url: url)
        let lemmas = [
            StoredKnownLemma(language: "en", form: "forest", updatedAt: occurredAt),
            StoredKnownLemma(language: "en", form: "whale", updatedAt: occurredAt)
        ]

        try repo.saveKnownLemmas(lemmas)
        let loaded = Persistence.loadKnownLemmas(from: url)
        #expect(loaded.map(\.form) == ["forest", "whale"])
        #expect(loaded.first?.language == "en")
        #expect(try repo.loadKnownLemmas().map(\.form) == ["forest", "whale"])
    }

    @Test("isolated adapters do not write Application Support files")
    func isolatedAdaptersDoNotWriteApplicationSupport() throws {
        let token = "adapter-isolated-\(UUID().uuidString)"
        let fixture = try IsolatedStoreFixture()
        defer { fixture.remove() }
        let store = LibraryStore(fileURL: fixture.sqliteURL)
        let transcripts: any TranscriptRepository = LibraryStoreTranscriptRepository(store: store)
        let vocabulary: any VocabularyRepository = LibraryStoreVocabularyRepository(store: store)
        let lemmas: any KnownLemmaRepository = PersistenceKnownLemmaRepository(
            url: fixture.root.appendingPathComponent("lexicon.json")
        )

        try transcripts.saveTranscript(
            StoredTranscript(
                chapterID: ChapterID(rawValue: token),
                localMediaKey: token,
                createdAt: occurredAt,
                locale: "en-US",
                source: "test",
                ebookAligned: false,
                segments: [
                    StoredTranscriptSegment(
                        id: "seg",
                        start: 0,
                        end: 1,
                        words: [StoredTranscriptWord(id: "w", text: token, start: 0, end: 1)]
                    )
                ]
            )
        )
        try vocabulary.saveVocabulary([sampleVocabulary(id: token, surface: token, addedAt: occurredAt)])
        try lemmas.saveKnownLemmas([StoredKnownLemma(language: "en", form: token, updatedAt: occurredAt)])

        let support = Persistence.root
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        #expect(!names.contains(where: { $0.contains(token) }))
        #expect(FileManager.default.fileExists(atPath: fixture.sqliteURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("lexicon.json").path))
    }

    private func sampleVocabulary(id: String, surface: String, addedAt: Date) -> StoredVocabularyOccurrence {
        StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: id),
            surface: surface,
            category: VocabCategory.word.rawValue,
            context: "\(surface) context",
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Loomings",
            timestamp: 0,
            addedAt: addedAt
        )
    }
}

private struct IsolatedStoreFixture {
    let root: URL

    var sqliteURL: URL { root.appendingPathComponent("library.sqlite") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-local-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
