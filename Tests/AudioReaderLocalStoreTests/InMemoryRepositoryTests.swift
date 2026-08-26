import Foundation
import Testing
@testable import AudioReaderLocalStore

@Suite("In-memory local repositories")
struct InMemoryRepositoryTests {
    private let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("settings save and load without a file URL")
    func settingsSaveAndLoad() throws {
        let repo: any SettingsRepository = InMemorySettingsRepository()
        #expect(try repo.loadSettings() == StoredSettings.default)

        var settings = try repo.loadSettings()
        settings.playbackRate = 1.5
        settings.appearance = "light"
        settings.targetLanguage = "ja"
        try repo.saveSettings(settings)

        let loaded = try repo.loadSettings()
        #expect(loaded.playbackRate == 1.5)
        #expect(loaded.appearance == "light")
        #expect(loaded.targetLanguage == "ja")
    }

    @Test("books upsert, load, and delete by typed ID")
    func booksUpsertLoadAndDelete() throws {
        let repo: any BookRepository = InMemoryBookRepository()
        #expect(try repo.loadBooks().isEmpty)

        let book = sampleBook(id: "book-1", title: "Moby-Dick")
        try repo.saveBook(book)
        try repo.saveBook(sampleBook(id: "book-2", title: "The Ride"))
        try repo.saveBook(StoredBook(
            id: book.id,
            title: "Moby-Dick (annotated)",
            author: book.author,
            source: book.source,
            chapters: book.chapters
        ))

        let loaded = try repo.loadBooks()
        #expect(loaded.map(\.id) == [BookID(rawValue: "book-1"), BookID(rawValue: "book-2")])
        #expect(loaded[0].title == "Moby-Dick (annotated)")
        #expect(loaded[0].chapters[0].id == ChapterID(rawValue: "chapter-1"))

        try repo.deleteBook(id: BookID(rawValue: "book-1"))
        try repo.deleteBook(id: BookID(rawValue: "missing"))
        #expect(try repo.loadBooks().map(\.title) == ["The Ride"])
    }

    @Test("transcripts overwrite by chapter ID like LibraryStore")
    func transcriptsOverwriteByChapterID() throws {
        let repo: any TranscriptRepository = InMemoryTranscriptRepository()
        let first = sampleTranscript(chapterID: "chapter-1", text: "Call", createdAt: occurredAt)
        let second = sampleTranscript(chapterID: "chapter-1", text: "Call me", createdAt: occurredAt.addingTimeInterval(10))
        let other = sampleTranscript(chapterID: "chapter-2", text: "Some years ago", createdAt: occurredAt)

        try repo.saveTranscript(first)
        try repo.saveTranscript(other)
        try repo.saveTranscript(second)

        let loaded = try #require(try repo.loadTranscript(chapterID: ChapterID(rawValue: "chapter-1")))
        #expect(loaded.segments[0].words[0].text == "Call me")
        #expect(loaded.localMediaKey == "chapter-1-audio")
        #expect(try repo.loadTranscript(chapterID: ChapterID(rawValue: "missing")) == nil)

        let all = try repo.loadAllTranscripts()
        #expect(all.map(\.chapterID.rawValue).sorted() == ["chapter-1", "chapter-2"])
    }

    @Test("vocabulary replace, upsert, delete, and newest-first load")
    func vocabularyReplaceUpsertDeleteAndOrder() throws {
        let repo: any VocabularyRepository = InMemoryVocabularyRepository()
        let older = sampleVocabulary(id: "vocab-1", surface: "forest", addedAt: occurredAt)
        let newer = sampleVocabulary(id: "vocab-2", surface: "whale", addedAt: occurredAt.addingTimeInterval(60))

        try repo.saveVocabulary([older, newer])
        #expect(try repo.loadVocabulary().map(\.surface) == ["whale", "forest"])

        var updated = older
        updated.translation = "树林"
        updated.isInLearnList = true
        try repo.upsertVocabulary([updated])
        try repo.upsertVocabulary([
            sampleVocabulary(id: "vocab-3", surface: "mast", addedAt: occurredAt.addingTimeInterval(120))
        ])

        let afterUpsert = try repo.loadVocabulary()
        #expect(afterUpsert.map(\.surface) == ["mast", "whale", "forest"])
        #expect(afterUpsert.first { $0.id.rawValue == "vocab-1" }?.translation == "树林")
        #expect(afterUpsert.first { $0.id.rawValue == "vocab-1" }?.isInLearnList == true)

        try repo.deleteVocabulary(id: VocabularyOccurrenceID(rawValue: "vocab-2"))
        try repo.deleteVocabulary(id: VocabularyOccurrenceID(rawValue: "missing"))
        #expect(try repo.loadVocabulary().map(\.surface) == ["mast", "forest"])

        try repo.saveVocabulary([newer])
        #expect(try repo.loadVocabulary().map(\.id.rawValue) == ["vocab-2"])

        let duplicate = sampleVocabulary(id: "vocab-dup", surface: "first", addedAt: occurredAt)
        var duplicateLast = duplicate
        duplicateLast.surface = "last"
        try repo.saveVocabulary([duplicate, duplicateLast])
        #expect(try repo.loadVocabulary().map(\.surface) == ["last"])
    }

    @Test("known lemmas replace and load")
    func knownLemmasReplaceAndLoad() throws {
        let repo: any KnownLemmaRepository = InMemoryKnownLemmaRepository()
        #expect(try repo.loadKnownLemmas().isEmpty)

        try repo.saveKnownLemmas([
            StoredKnownLemma(language: "en", form: "forest", updatedAt: occurredAt),
            StoredKnownLemma(language: "en", form: "whale", updatedAt: occurredAt)
        ])
        #expect(try repo.loadKnownLemmas().map(\.form) == ["forest", "whale"])

        try repo.saveKnownLemmas([
            StoredKnownLemma(language: "en", form: "mast", updatedAt: occurredAt.addingTimeInterval(1))
        ])
        #expect(try repo.loadKnownLemmas().map(\.form) == ["mast"])
    }

    @Test("review events append immutably")
    func reviewEventsAppendImmutably() throws {
        let repo: any ReviewEventRepository = InMemoryReviewEventRepository()
        let first = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-1"),
            vocabularyID: VocabularyOccurrenceID(rawValue: "vocab-1"),
            face: "recognition",
            rating: "forgot",
            reviewedAt: occurredAt
        )
        var duplicate = first
        duplicate.rating = "remember"
        let second = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-2"),
            vocabularyID: VocabularyOccurrenceID(rawValue: "vocab-1"),
            face: "cloze",
            rating: "remember",
            reviewedAt: occurredAt.addingTimeInterval(30)
        )

        try repo.appendReviewEvent(first)
        try repo.appendReviewEvent(duplicate)
        try repo.appendReviewEvent(second)

        let loaded = try repo.loadReviewEvents()
        #expect(loaded.map(\.id.rawValue) == ["review-1", "review-2"])
        #expect(loaded[0].rating == "forgot")
    }

    @Test("assistant results upsert, replace, and newest-first load")
    func assistantResultsUpsertReplaceAndOrder() throws {
        let repo: any AssistantResultRepository = InMemoryAssistantResultRepository()
        let older = sampleAssistantResult(id: "gloss-1", text: "旧", createdAt: occurredAt)
        let newer = sampleAssistantResult(id: "gloss-2", text: "新", createdAt: occurredAt.addingTimeInterval(5))

        try repo.saveAssistantResult(older)
        try repo.saveAssistantResult(newer)
        var accepted = older
        accepted.status = .accepted
        accepted.text = "已接受"
        accepted.decidedAt = occurredAt.addingTimeInterval(8)
        try repo.saveAssistantResult(accepted)

        let loaded = try repo.loadAssistantResults()
        #expect(loaded.map(\.id) == ["gloss-2", "gloss-1"])
        #expect(loaded[1].status == .accepted)
        #expect(loaded[1].text == "已接受")

        try repo.replaceAssistantResults([newer])
        #expect(try repo.loadAssistantResults().map(\.id) == ["gloss-2"])

        try repo.replaceAssistantResults([
            sampleAssistantResult(id: "gloss-dup", text: "first", createdAt: occurredAt),
            sampleAssistantResult(id: "gloss-dup", text: "last", createdAt: occurredAt)
        ])
        #expect(try repo.loadAssistantResults().map(\.text) == ["last"])
    }

    @Test("outbox enqueues pending mutations and acknowledges without rewriting payload")
    func outboxEnqueueAndAcknowledge() throws {
        let repo: any SyncOutboxRepository = InMemorySyncOutboxRepository()
        let first = OutboxMutation(
            id: MutationID(rawValue: "mutation-1"),
            entityType: .vocabulary,
            entityID: "vocab-1",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: occurredAt,
            payload: Data("{\"surface\":\"forest\"}".utf8),
            status: .acknowledged
        )
        var rewritten = first
        rewritten.payload = Data("{\"surface\":\"changed\"}".utf8)
        let second = OutboxMutation(
            id: MutationID(rawValue: "mutation-2"),
            entityType: .reviewEvent,
            entityID: "review-1",
            operation: .append,
            baseRevision: ServerVersion(1),
            occurredAt: occurredAt.addingTimeInterval(1),
            payload: Data("{}".utf8),
            status: .pending
        )

        try repo.enqueue(first)
        try repo.enqueue(rewritten)
        try repo.enqueue(second)

        let pending = try repo.pendingMutations()
        #expect(pending.map(\.id.rawValue) == ["mutation-1", "mutation-2"])
        #expect(pending[0].status == .pending)
        #expect(String(data: pending[0].payload, encoding: .utf8) == "{\"surface\":\"forest\"}")

        try repo.markAcknowledged(id: MutationID(rawValue: "mutation-1"))
        try repo.markAcknowledged(id: MutationID(rawValue: "missing"))
        #expect(try repo.pendingMutations().map(\.id.rawValue) == ["mutation-2"])
    }

    @Test("in-memory repositories do not write Application Support files")
    func inMemoryRepositoriesDoNotWriteApplicationSupport() throws {
        let token = "in-memory-only-\(UUID().uuidString)"
        let store = InMemoryLocalStore()
        let book = sampleBook(id: token, title: "Probe")
        try store.books.saveBook(book)
        try store.settings.saveSettings({
            var settings = StoredSettings.default
            settings.libraryPath = token
            return settings
        }())
        try store.transcripts.saveTranscript(sampleTranscript(chapterID: token, text: token, createdAt: occurredAt))
        try store.vocabulary.saveVocabulary([
            sampleVocabulary(id: token, surface: token, addedAt: occurredAt)
        ])
        try store.knownLemmas.saveKnownLemmas([
            StoredKnownLemma(language: "en", form: token, updatedAt: occurredAt)
        ])
        try store.reviewEvents.appendReviewEvent(
            StoredReviewEvent(
                id: ReviewEventID(rawValue: token),
                vocabularyID: VocabularyOccurrenceID(rawValue: token),
                face: "recognition",
                rating: "remember",
                reviewedAt: occurredAt
            )
        )
        try store.assistantResults.saveAssistantResult(
            sampleAssistantResult(id: token, text: token, createdAt: occurredAt)
        )
        try store.outbox.enqueue(
            OutboxMutation(
                id: MutationID(rawValue: token),
                entityType: .book,
                entityID: token,
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: occurredAt,
                payload: Data(token.utf8),
                status: .pending
            )
        )

        assertApplicationSupportWasNotUsed(for: token)
    }

    private func assertApplicationSupportWasNotUsed(for token: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioReader", isDirectory: true)
        guard FileManager.default.fileExists(atPath: support.path) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        #expect(!names.contains(where: { $0.contains(token) }))
        let transcriptNames = (try? FileManager.default.contentsOfDirectory(
            atPath: support.appendingPathComponent("transcripts").path
        )) ?? []
        #expect(!transcriptNames.contains(where: { $0.contains(token) }))
        let needle = Data(token.utf8)
        for name in ["settings.json", "lexicon.json", "vocab.json", "glosses.json"] {
            let url = support.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { continue }
            #expect(data.range(of: needle) == nil)
        }
    }

    private func sampleBook(id: String, title: String) -> StoredBook {
        StoredBook(
            id: BookID(rawValue: id),
            title: title,
            author: "Herman Melville",
            source: "localFolder",
            chapters: [
                StoredChapter(
                    id: ChapterID(rawValue: "chapter-1"),
                    index: 0,
                    title: "Loomings",
                    duration: 321.5,
                    startTime: nil
                )
            ]
        )
    }

    private func sampleTranscript(chapterID: String, text: String, createdAt: Date) -> StoredTranscript {
        StoredTranscript(
            chapterID: ChapterID(rawValue: chapterID),
            localMediaKey: "\(chapterID)-audio",
            chapterStart: nil,
            createdAt: createdAt,
            locale: "en-US",
            source: "apple-speech",
            ebookAligned: false,
            ebookAlignment: nil,
            ebookUseOverride: nil,
            segments: [
                StoredTranscriptSegment(
                    id: "seg-1",
                    start: 0,
                    end: 1,
                    words: [
                        StoredTranscriptWord(id: "w-1", text: text, start: 0, end: 1, confidence: nil)
                    ],
                    ebookText: nil,
                    alignmentScore: nil,
                    individualEbookMatchTrusted: nil,
                    documentEbookUseAllowed: nil
                )
            ]
        )
    }

    private func sampleVocabulary(id: String, surface: String, addedAt: Date) -> StoredVocabularyOccurrence {
        StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: id),
            surface: surface,
            category: "word",
            definition: nil,
            dictionaryName: nil,
            dictionaryHTML: nil,
            translation: nil,
            translationLanguage: nil,
            translationModel: nil,
            sourceLanguage: "en",
            context: "\(surface) context",
            spokenText: nil,
            ebookText: nil,
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Loomings",
            segmentID: nil,
            wordID: nil,
            timestamp: 0,
            addedAt: addedAt,
            reviewCount: 0,
            nextReview: nil,
            lastReviewedAt: nil,
            lastReviewQuality: nil,
            reviewIntervalDays: 0,
            reviewEaseFactor: 2.5,
            isInLearnList: false
        )
    }

    private func sampleAssistantResult(id: String, text: String, createdAt: Date) -> StoredAssistantResult {
        StoredAssistantResult(
            id: id,
            kind: .sentenceGloss,
            status: .pending,
            language: "zh-Hans",
            model: "test-model",
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Loomings",
            source: "Call me Ishmael.",
            text: text,
            context: nil,
            timestamp: nil,
            createdAt: createdAt,
            decidedAt: nil,
            replacedText: nil,
            replacedModel: nil
        )
    }
}
