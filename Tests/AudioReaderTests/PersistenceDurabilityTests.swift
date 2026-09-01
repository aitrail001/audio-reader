import Foundation
import SQLite3
import Testing
@testable import AudioReader

@Suite("Persistence failure reporting")
struct PersistenceDurabilityTests {
    @MainActor
    @Test("Bare AppState transcript saves stay in memory")
    func bareAppStateTranscriptSaveIsIsolated() {
        let chapterID = "isolated-\(UUID().uuidString)"
        let chapter = Chapter(
            id: chapterID,
            index: 0,
            title: "Chapter",
            audioPath: "/tmp/isolated.m4b"
        )
        var segment = TranscriptSegment(
            id: "segment",
            start: 0,
            end: 1,
            words: [.init(id: "word", text: "Source.", start: 0, end: 1, confidence: 1)],
            ebookText: "Source.",
            alignmentScore: 1,
            individualEbookMatchTrusted: true,
            documentEbookUseAllowed: false
        )
        segment.documentEbookUseAllowed = false
        let state = AppState()
        state.books = [Book(
            id: "isolated-book",
            title: "Book",
            folderPath: "/tmp",
            ebookPath: "/tmp/isolated.epub",
            chapters: [chapter]
        )]
        state.selectedBookID = "isolated-book"
        state.selectedChapterID = chapterID
        state.transcript = Transcript(
            chapterID: chapterID,
            audioPath: chapter.audioPath,
            createdAt: Date(timeIntervalSince1970: 1),
            locale: "en-AU",
            segments: [segment],
            source: "test",
            ebookAligned: false,
            ebookAlignment: .init(status: .uncertain, reason: "test", metrics: .empty)
        )

        state.useCurrentEbookAnyway()

        #expect(state.errorMessage == nil)
        #expect(state.transcript?.ebookUseOverride == true)
    }

    @Test("Transcript survives reopening an injected SQLite store")
    func transcriptSurvivesRelaunch() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let transcript = sampleTranscript()

        try fixture.store.saveBook(StoredBook(
            id: BookID(rawValue: "durability-book"),
            title: "Book",
            source: BookSource.files.rawValue,
            chapters: [StoredChapter(
                id: ChapterID(rawValue: transcript.chapterID),
                index: 0,
                title: "Chapter"
            )]
        ))
        try Persistence.saveTranscript(transcript, database: fixture.store)
        let relaunched = LocalSQLiteStore(fileURL: fixture.databaseURL)

        let reloaded = try #require(Persistence.loadTranscript(
            chapterID: transcript.chapterID,
            database: relaunched
        ))
        #expect(reloaded.chapterID == transcript.chapterID)
        #expect(reloaded.locale == transcript.locale)
        #expect(reloaded.source == transcript.source)
        #expect(reloaded.segments.map(\.id) == transcript.segments.map(\.id))
        #expect(reloaded.segments.map(\.displayText) == transcript.segments.map(\.displayText))
    }

    @Test("Generated translation and checkpoint survive reopening an injected SQLite store")
    func translationSurvivesRelaunch() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let gloss = sampleGloss()
        let checkpoint = sampleCheckpoint()

        try Persistence.saveGlossUpdates([gloss], allItems: [gloss], database: fixture.store)
        try Persistence.saveChapterTranslationCheckpoint(checkpoint, database: fixture.store)
        let relaunched = LocalSQLiteStore(fileURL: fixture.databaseURL)

        #expect(Persistence.loadGlosses(database: relaunched) == [gloss])
        #expect(Persistence.loadChapterTranslationCheckpoints(database: relaunched) == [checkpoint])
    }

    @Test("Checkpoint upsert preserves unrelated synchronized checkpoints")
    func checkpointUpsertPreservesUnrelatedRows() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let unrelated = ChapterTranslationCheckpoint(
            chapterID: "other-chapter",
            language: "fr",
            mode: .retranslateAll,
            nextSegmentIndex: 2,
            totalSentences: 4,
            status: .awaitingReview,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        try Persistence.saveChapterTranslationCheckpoint(unrelated, database: fixture.store)

        try Persistence.saveChapterTranslationCheckpoint(sampleCheckpoint(), database: fixture.store)

        #expect(Set(Persistence.loadChapterTranslationCheckpoints(database: fixture.store).map(\.id)) == Set([
            unrelated.id,
            sampleCheckpoint().id,
        ]))
    }

    @MainActor
    @Test("Failed translation edit leaves published state unchanged")
    func failedTranslationEditDoesNotPublish() {
        let database = closedStore()
        let gloss = sampleGloss()
        let state = AppState(
            composition: AppComposition(liveStore: database),
            account: AccountSession.isolated()
        )
        state.glosses = [gloss]

        state.editGloss(gloss, text: "replacement")

        #expect(state.glosses == [gloss])
        #expect(state.errorMessage == "The translation edit could not be saved. Nothing was changed.")
    }

    @Test("Transcript writes report an injected SQLite failure")
    func transcriptWriteReportsFailure() throws {
        let database = closedStore()
        let transcript = sampleTranscript()
        #expect(throws: (any Error).self) {
            try Persistence.saveTranscript(transcript, database: database)
        }
    }

    @Test("Generated gloss writes report an injected SQLite failure")
    func generatedGlossWriteReportsFailure() throws {
        let database = closedStore()
        let gloss = sampleGloss()

        #expect(throws: (any Error).self) {
            try Persistence.saveGlossUpdates([gloss], allItems: [gloss], database: database)
        }
    }

    @Test("Translation checkpoint writes report an injected SQLite failure")
    func translationCheckpointWriteReportsFailure() throws {
        let database = closedStore()
        let checkpoint = sampleCheckpoint()

        #expect(throws: (any Error).self) {
            try Persistence.saveChapterTranslationCheckpoint(checkpoint, database: database)
        }
    }

    @Test("A checkpoint failure rolls back generated chapter drafts")
    func checkpointFailureRollsBackGeneratedDrafts() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        try installFailingCheckpointTrigger(at: fixture.databaseURL)
        let gloss = sampleGloss()

        #expect(throws: (any Error).self) {
            try Persistence.saveGeneratedTranslationDrafts(
                [gloss],
                checkpoint: sampleCheckpoint(),
                database: fixture.store
            )
        }
        #expect(try fixture.store.loadAssistantResults().isEmpty)
        #expect(try fixture.store.loadTranslationCheckpoints().isEmpty)
    }

    @MainActor
    @Test("A failed chapter draft transaction leaves published state unchanged")
    func failedChapterDraftTransactionDoesNotPublish() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        try installFailingCheckpointTrigger(at: fixture.databaseURL)
        let state = AppState(
            composition: AppComposition(liveStore: fixture.store),
            account: AccountSession.isolated()
        )
        let gloss = sampleGloss()

        #expect(throws: (any Error).self) {
            try state.saveGeneratedChapterDrafts(
                [gloss],
                chapterID: "chapter",
                language: "zh-Hans",
                mode: .untranslatedOnly,
                nextSegmentIndex: 1,
                total: 3
            )
        }
        #expect(state.glosses.isEmpty)
        #expect(state.chapterTranslationCheckpoints.isEmpty)
        #expect(try fixture.store.loadAssistantResults().isEmpty)
    }

    private func sampleTranscript() -> Transcript {
        Transcript(
            chapterID: "durability-chapter",
            audioPath: "/tmp/durability.m4b",
            createdAt: Date(timeIntervalSince1970: 1),
            locale: "en-AU",
            segments: [TranscriptSegment(
                id: "segment",
                start: 0,
                end: 1,
                words: [.init(id: "word", text: "Source.", start: 0, end: 1, confidence: 1)]
            )],
            source: "test",
            ebookAligned: false
        )
    }

    private func sampleGloss() -> GlossEntry {
        GlossEntry(
            id: "durability-gloss",
            kind: .sentence,
            language: "zh-Hans",
            source: "Source.",
            context: nil,
            text: "译文。",
            status: .pending,
            model: "test",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            decidedAt: nil
        )
    }

    private func sampleCheckpoint() -> ChapterTranslationCheckpoint {
        ChapterTranslationCheckpoint(
            chapterID: "chapter",
            language: "zh-Hans",
            mode: .untranslatedOnly,
            nextSegmentIndex: 1,
            totalSentences: 3,
            status: .inProgress,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func closedStore() -> LocalSQLiteStore {
        LocalSQLiteStore(fileURL: URL(fileURLWithPath: "/dev/null/library-vNext.sqlite"))
    }

    private func installFailingCheckpointTrigger(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TRIGGER fail_checkpoint
        BEFORE INSERT ON local_translation_checkpoints
        BEGIN
          SELECT RAISE(FAIL, 'checkpoint failure');
        END;
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private struct DatabaseFixture {
        let root: URL
        let databaseURL: URL
        let store: LocalSQLiteStore

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseURL = root.appendingPathComponent("library-vNext.sqlite")
            store = LocalSQLiteStore(fileURL: databaseURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
