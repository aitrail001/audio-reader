import Foundation
import SQLite3
import Testing
@testable import AudioReaderDomain
@testable import AudioReaderLocalStore

@Suite("Clean vNext local persistence")
struct LocalVNextPersistenceTests {
    @Test
    func priorV1SchemaMigratesWithoutLosingAssetsOrAssistantResults() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        try installPriorV1Schema(at: url)

        let store = LocalSQLiteStore(fileURL: url)

        #expect(try store.currentSchemaVersion() == 3)
        #expect(Set(try store.columnNames(in: "local_assets")).isSuperset(of: [
            "content_hash", "byte_count", "metadata_json",
        ]))
        #expect(Set(try store.columnNames(in: "local_assistant_results")).isSuperset(of: [
            "prompt_version", "model_policy_hash", "shared_cache_entry_id",
        ]))
        #expect(try store.loadAssets(bookID: BookID(rawValue: "legacy-book")) == [
            StoredLocalAsset(
                id: AssetID(rawValue: "legacy-asset"),
                bookID: BookID(rawValue: "legacy-book"),
                kind: "epub",
                localMediaKey: "/legacy/book.epub"
            ),
        ])
        let legacyResult = try #require(try store.loadAssistantResults().first {
            $0.id == "legacy-result"
        })
        #expect(legacyResult.promptVersion == "local")
        #expect(legacyResult.modelPolicyHash == "local")
        #expect(legacyResult.sharedCacheEntryID == nil)

        let currentAsset = StoredLocalAsset(
            id: AssetID(rawValue: "current-asset"),
            bookID: BookID(rawValue: "legacy-book"),
            kind: "audio",
            localMediaKey: "/current/chapter.m4b",
            contentHash: "sha256:current",
            byteCount: 42,
            metadata: ["chapterID": "legacy-chapter"]
        )
        try store.saveAssets([currentAsset], bookID: BookID(rawValue: "legacy-book"))
        let currentResult = StoredAssistantResult(
            id: "current-result",
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh-Hans",
            model: "qwen",
            promptVersion: "prompt-v2",
            modelPolicyHash: "policy-v2",
            source: "Source",
            text: "Translation",
            createdAt: Date(timeIntervalSince1970: 20),
            sharedCacheEntryID: "cache-v2"
        )
        try store.saveAssistantResult(currentResult)

        let reopened = LocalSQLiteStore(fileURL: url)
        #expect(try reopened.currentSchemaVersion() == 3)
        #expect(try reopened.loadAssets(bookID: BookID(rawValue: "legacy-book")) == [currentAsset])
        #expect(try reopened.loadAssistantResults().contains(currentResult))
        #expect(try reopened.rowCount("local_assets") == 1)
        #expect(try reopened.rowCount("local_assistant_results") == 2)
    }

    @Test
    func priorV2SchemaMigratesChapterEbookSectionIndexWithoutLosingRows() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        try installPriorV1Schema(at: url)
        try installVersion2Columns(at: url)
        try execute("PRAGMA user_version = 2", at: url)

        let store = LocalSQLiteStore(fileURL: url)

        #expect(try store.currentSchemaVersion() == 3)
        #expect(try store.columnNames(in: "local_chapters").contains("ebook_section_index"))
        let legacyChapter = try #require(try store.loadBooks().first?.chapters.first)
        #expect(legacyChapter.ebookSectionIndex == nil)

        var updated = legacyChapter
        updated.ebookSectionIndex = 4
        try store.saveBook(StoredBook(
            id: BookID(rawValue: "legacy-book"),
            title: "Legacy Book",
            source: "files",
            chapters: [updated]
        ))

        #expect(try LocalSQLiteStore(fileURL: url).loadBooks().first?.chapters.first?.ebookSectionIndex == 4)
    }

    @Test
    func storedChapterDecodesPayloadsWrittenBeforeEbookSectionIndex() throws {
        let data = Data(#"{"id":"legacy-chapter","index":2,"title":"Legacy"}"#.utf8)

        let chapter = try JSONDecoder().decode(StoredChapter.self, from: data)

        #expect(chapter.id == ChapterID(rawValue: "legacy-chapter"))
        #expect(chapter.index == 2)
        #expect(chapter.ebookSectionIndex == nil)
    }

    @Test
    func futureSchemaVersionIsRejectedWithoutModification() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        try installPriorV1Schema(at: url)
        try installVersion2Columns(at: url)
        try execute("PRAGMA user_version = 4", at: url)
        let schemaBeforeOpen = try schemaFingerprint(at: url)
        let assetsBeforeOpen = try rawRows("SELECT * FROM local_assets ORDER BY id", at: url)

        let store = LocalSQLiteStore(fileURL: url)

        #expect(throws: (any Error).self) {
            try store.currentSchemaVersion()
        }
        #expect(throws: (any Error).self) {
            try store.deleteAssets(bookID: BookID(rawValue: "legacy-book"))
        }
        #expect(try rawUserVersion(at: url) == 4)
        #expect(try schemaFingerprint(at: url) == schemaBeforeOpen)
        #expect(try rawRows("SELECT * FROM local_assets ORDER BY id", at: url) == assetsBeforeOpen)
    }

    @Test
    func failedV1MigrationRollsBackColumnsAndSchemaVersion() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        try installPriorV1Schema(at: url)
        try execute(
            """
            ALTER TABLE local_assistant_results RENAME TO local_assistant_results_v1;
            CREATE VIEW local_assistant_results AS SELECT * FROM local_assistant_results_v1;
            """,
            at: url
        )
        let schemaBeforeOpen = try schemaFingerprint(at: url)

        let store = LocalSQLiteStore(fileURL: url)

        #expect(throws: (any Error).self) {
            try store.currentSchemaVersion()
        }
        #expect(try rawUserVersion(at: url) == 1)
        #expect(Set(try rawColumnNames(in: "local_assets", at: url)).isDisjoint(with: [
            "content_hash", "byte_count", "metadata_json",
        ]))
        #expect(try schemaFingerprint(at: url) == schemaBeforeOpen)
    }

    @Test
    func schemaContainsOnlyCurrentTablesAndNormalizedTranscriptRows() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)

        let tables = Set(try store.tableNames())
        #expect(tables == Set(LocalSchemaVNext.requiredTables))
        #expect(!tables.contains("transcripts"))
        #expect(!tables.contains("vocab"))
        #expect(!tables.contains("glosses"))

        let revisionColumns = Set(try store.columnNames(in: "local_transcript_revisions"))
        #expect(!revisionColumns.contains("segments_json"))
        #expect(!revisionColumns.contains("ebook_alignment_json"))
        #expect(tables.contains("local_transcript_segments"))
        #expect(tables.contains("local_translation_checkpoints"))
        #expect(tables.contains("local_settings"))
        #expect(tables.contains("local_study_activity"))
        #expect(!tables.contains("sync_mirror_repairs"))
    }

    @Test
    func secondLaunchDoesNotReadOrMutateLegacyStore() throws {
        let directory = temporaryDirectory()
        let legacyURL = directory.appendingPathComponent("library.sqlite")
        let legacyBytes = Data("local-reader-owned".utf8)
        try legacyBytes.write(to: legacyURL)
        try Data("legacy".utf8).write(to: directory.appendingPathComponent("vocab.json"))

        let vNextURL = directory.appendingPathComponent("library-vNext.sqlite")
        _ = LocalSQLiteStore(fileURL: vNextURL)
        let firstTables = try LocalSQLiteStore(fileURL: vNextURL).tableNames()
        let second = LocalSQLiteStore(fileURL: vNextURL)

        #expect(try Data(contentsOf: legacyURL) == legacyBytes)
        #expect(try second.tableNames() == firstTables)
        #expect(try second.loadVocabulary().isEmpty)
        #expect(try second.loadAssistantResults().isEmpty)
    }

    @Test
    func transcriptRangeAndSingleSegmentUpdateAreRelational() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let transcript = sampleTranscript(segmentCount: 200)
        try saveCatalog(for: transcript, to: store)
        try store.saveTranscript(transcript)
        #expect(try store.journalMode() == "wal")

        let range = try store.loadTranscriptSegments(
            chapterID: transcript.chapterID,
            range: 50..<60
        )
        #expect(range.map(\.id) == (50..<60).map { "segment-\($0)" })
        #expect(store.lastTranscriptSegmentQueryCount == 10)
        let openingPage = try #require(try store.loadTranscript(
            chapterID: transcript.chapterID,
            range: 0..<25
        ))
        #expect(openingPage.segments.count == 25)
        #expect(store.lastTranscriptSegmentQueryCount == 25)
        let nextPage = try #require(try store.loadTranscript(
            chapterID: transcript.chapterID,
            range: 25..<50
        ))
        #expect(nextPage.segments.first?.id == "segment-25")
        #expect(try store.transcriptSegmentCount(chapterID: transcript.chapterID) == 200)

        var edited = transcript.segments[55]
        edited.words[0].text = "edited"
        let changesBeforeEdit = store.totalChangeCount
        try store.updateTranscriptSegment(chapterID: transcript.chapterID, segment: edited)
        #expect(store.totalChangeCount - changesBeforeEdit == 1)

        let relaunched = LocalSQLiteStore(fileURL: url)
        let aroundEdit = try relaunched.loadTranscriptSegments(
            chapterID: transcript.chapterID,
            range: 54..<57
        )
        #expect(aroundEdit[0] == transcript.segments[54])
        #expect(aroundEdit[1] == edited)
        #expect(aroundEdit[2] == transcript.segments[56])
    }

    @Test
    func completeTranscriptLoadsEverySegmentInBoundedPages() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let transcript = sampleTranscript(segmentCount: 451)
        try saveCatalog(for: transcript, to: store)
        try store.saveTranscript(transcript)

        let loaded = try #require(try store.loadCompleteTranscript(
            chapterID: transcript.chapterID,
            pageSize: 200
        ))

        #expect(loaded.segments.count == 451)
        #expect(loaded.segments.first?.id == "segment-0")
        #expect(loaded.segments.last?.id == "segment-450")
        #expect(store.maximumTranscriptSegmentQueryCount == 200)
    }

    @Test("sync transcript candidate hydration stays in its established WAL snapshot")
    func syncTranscriptCandidateHydrationStaysInEstablishedWALSnapshot() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let reader = LocalSQLiteStore(fileURL: url)
        let transcript = sampleTranscript(segmentCount: 1)
        try saveCatalog(for: transcript, to: reader)
        try reader.saveTranscript(transcript)
        #expect(try reader.journalMode() == "wal")

        let candidates = try reader.loadActiveSyncTranscriptCandidates {
            try execute(
                """
                UPDATE local_transcript_revisions
                SET is_active = 0, deleted_at = 1000
                WHERE chapter_id = '\(transcript.chapterID.rawValue)'
                """,
                at: url
            )
        }

        #expect(candidates.count == 1)
        #expect(candidates.first?.bookID == BookID(rawValue: "book-for-\(transcript.chapterID.rawValue)"))
        #expect(candidates.first?.transcript == transcript)
        #expect(try LocalSQLiteStore(fileURL: url).activeTranscriptChapterIDs().isEmpty)
    }

    @Test
    func assistantSummaryCheckpointSettingsAndActivitySurviveRelaunch() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let summary = StoredAssistantResult(
            id: "summary-1",
            kind: .chapterSummary,
            status: .accepted,
            language: "en",
            model: "test",
            chapterID: ChapterID(rawValue: "chapter-1"),
            source: "chapter",
            text: "summary",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let checkpoint = StoredTranslationCheckpoint(
            chapterID: ChapterID(rawValue: "chapter-1"),
            language: "zh",
            completedSegmentCount: 12,
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        var settings = StoredSettings.default
        settings.playbackRate = 1.25

        try store.saveAssistantResult(summary)
        try store.saveTranslationCheckpoint(checkpoint)
        try store.saveSettings(settings)
        try store.saveStudyActivityDays(["2026-08-30", "2026-08-31"])

        let relaunched = LocalSQLiteStore(fileURL: url)
        #expect(try relaunched.loadAssistantResults() == [summary])
        #expect(try relaunched.loadTranslationCheckpoints() == [checkpoint])
        #expect(try relaunched.loadSettings() == settings)
        #expect(try relaunched.loadStudyActivityDays() == ["2026-08-30", "2026-08-31"])
    }

    @Test
    func assistantDecisionHistoryAndCacheReferenceSurviveRelaunch() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let createdAt = Date(timeIntervalSince1970: 120)
        var pending = StoredAssistantResult(
            id: "sentence-history",
            kind: .sentenceGloss,
            status: .pending,
            language: "zh-Hans",
            model: "qwen-old",
            chapterID: ChapterID(rawValue: "chapter-1"),
            source: "Source sentence",
            text: "Draft",
            createdAt: createdAt,
            sharedCacheEntryID: "shared-cache-entry"
        )
        try store.saveAssistantResult(pending)

        pending.status = .accepted
        pending.text = "User accepted text"
        pending.model = "qwen-new"
        pending.decidedAt = Date(timeIntervalSince1970: 121)
        try store.saveAssistantResult(pending)

        let relaunched = LocalSQLiteStore(fileURL: url)
        let current = try #require(try relaunched.loadAssistantResults().first)
        #expect(current.status == .accepted)
        #expect(current.text == "User accepted text")
        #expect(current.sharedCacheEntryID == "shared-cache-entry")
        #expect(try relaunched.loadAssistantResultHistory(resultID: pending.id).map(\.status) == [
            .pending,
            .accepted,
        ])
        #expect(try relaunched.loadAssistantResultHistory(resultID: pending.id).map(\.model) == [
            "qwen-old",
            "qwen-new",
        ])
    }

    @Test
    func replacingAssistantOutputRetainsRejectedAndReplacedHistory() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let createdAt = Date(timeIntervalSince1970: 130)
        var result = StoredAssistantResult(
            id: "sentence-replacement",
            kind: .sentenceGloss,
            status: .rejected,
            language: "zh-Hans",
            model: "qwen-a",
            source: "Source sentence",
            text: "Rejected draft",
            createdAt: createdAt,
            decidedAt: createdAt
        )
        try store.saveAssistantResult(result)
        result.status = .replaced
        result.text = "Replacement draft"
        result.model = "qwen-b"
        result.decidedAt = createdAt.addingTimeInterval(1)
        try store.saveAssistantResult(result)

        let history = try LocalSQLiteStore(fileURL: url)
            .loadAssistantResultHistory(resultID: result.id)
        #expect(history.map(\.status) == [.rejected, .replaced])
        #expect(history.map(\.text) == ["Rejected draft", "Replacement draft"])
    }

    @Test
    func acceptingTranslationCommitsResultVocabularyAndOutboxTogether() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let decidedAt = Date(timeIntervalSince1970: 200)
        let result = StoredAssistantResult(
            id: "sentence-1",
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh",
            model: "test",
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Book",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Chapter",
            source: "Source sentence",
            text: "译文",
            createdAt: decidedAt,
            decidedAt: decidedAt
        )
        let vocabulary = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "vocab-1"),
            surface: "Source sentence",
            captureSource: VocabularyCaptureSource.acceptedSentenceTranslation.rawValue,
            reviewEligible: false,
            category: "sentence",
            context: "Source sentence",
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Book",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Chapter",
            timestamp: 10,
            addedAt: decidedAt
        )
        let mutation = OutboxMutation(
            id: MutationID(rawValue: "mutation-1"),
            entityType: .assistantResult,
            entityID: result.id,
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: decidedAt,
            payload: Data("{}".utf8)
        )

        try store.acceptAssistantResult(result, vocabulary: [vocabulary], mutation: mutation)

        let relaunched = LocalSQLiteStore(fileURL: url)
        #expect(try relaunched.loadAssistantResults() == [result])
        #expect(try relaunched.loadVocabulary() == [vocabulary])
        #expect(try relaunched.loadReviewCards().map(\.vocabularyID) == [vocabulary.id])
        #expect(try relaunched.pendingMutations() == [mutation])
    }

    @Test
    func invalidDecisionMutationRollsBackResultVocabularyAndOutbox() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let result = StoredAssistantResult(
            id: "sentence-rollback",
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh",
            model: "test",
            chapterID: ChapterID(rawValue: "chapter-rollback"),
            source: "Source",
            text: "译文",
            createdAt: Date(timeIntervalSince1970: 250)
        )
        let vocabulary = sampleVocabulary()
        let invalidMutation = OutboxMutation(
            id: MutationID(rawValue: "mutation-invalid-kind"),
            entityType: .book,
            entityID: result.id,
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: result.createdAt,
            payload: Data("{}".utf8)
        )

        #expect(throws: (any Error).self) {
            try store.acceptAssistantResult(result, vocabulary: [vocabulary], mutation: invalidMutation)
        }

        let relaunched = LocalSQLiteStore(fileURL: url)
        #expect(try relaunched.loadAssistantResults().isEmpty)
        #expect(try relaunched.loadVocabulary().isEmpty)
        #expect(try relaunched.loadReviewCards().isEmpty)
        #expect(try relaunched.pendingMutations().isEmpty)
    }

    @Test
    func localImportCommitsCatalogAndBookOutboxTogether() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let book = StoredBook(
            id: BookID(rawValue: "imported-book"),
            title: "Imported Book",
            source: "files",
            chapters: [StoredChapter(id: ChapterID(rawValue: "imported-chapter"), index: 0, title: "One")]
        )
        let mutation = OutboxMutation(
            id: MutationID(rawValue: "import-book-mutation"),
            entityType: .book,
            entityID: "remote-book",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 275),
            payload: Data("{}".utf8)
        )

        try store.saveBook(book, mutation: mutation)

        let relaunched = LocalSQLiteStore(fileURL: url)
        #expect(try relaunched.loadBooks() == [book])
        #expect(try relaunched.pendingMutations() == [mutation])
    }

    @Test
    func bookAssetsRelaunchAndDeleteWithCatalogTombstoneAtomically() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let book = StoredBook(
            id: BookID(rawValue: "asset-book"),
            title: "Asset Book",
            source: "files",
            chapters: [StoredChapter(id: ChapterID(rawValue: "asset-chapter"), index: 0, title: "One")]
        )
        let assets = [
            StoredLocalAsset(
                id: AssetID(rawValue: "audio-asset"),
                bookID: book.id,
                kind: "audio",
                localMediaKey: "/media/chapter.m4b",
                contentHash: "audio-hash",
                byteCount: 123,
                metadata: ["chapterID": "asset-chapter"]
            ),
            StoredLocalAsset(
                id: AssetID(rawValue: "epub-asset"),
                bookID: book.id,
                kind: "epub",
                localMediaKey: "/media/book.epub",
                contentHash: "epub-hash",
                byteCount: 456
            ),
            StoredLocalAsset(
                id: AssetID(rawValue: "cover-asset"),
                bookID: book.id,
                kind: "cover",
                localMediaKey: "/media/cover.jpg",
                contentHash: "cover-hash",
                byteCount: 789
            ),
        ]
        let upsert = OutboxMutation(
            id: MutationID(rawValue: "asset-book-upsert"),
            entityType: .book,
            entityID: "asset-book-entity",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_400),
            payload: Data("{}".utf8)
        )
        try store.saveBook(book, assets: assets, mutation: upsert)

        let relaunched = LocalSQLiteStore(fileURL: url)
        #expect(try relaunched.loadBooks() == [book])
        let sortedAssets = assets.sorted { $0.id.rawValue < $1.id.rawValue }
        #expect(try relaunched.loadAssets(bookID: book.id) == sortedAssets)

        let tombstone = OutboxMutation(
            id: MutationID(rawValue: "asset-book-delete"),
            entityType: .book,
            entityID: upsert.entityID,
            operation: .delete,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_401),
            payload: Data("{}".utf8)
        )
        let removed = try relaunched.deleteBook(id: book.id, mutation: tombstone)

        #expect(removed == sortedAssets)
        #expect(try relaunched.loadBooks().isEmpty)
        #expect(try relaunched.loadAssets(bookID: book.id).isEmpty)
        #expect(try relaunched.pendingMutations() == [tombstone])
        let afterDelete = LocalSQLiteStore(fileURL: url)
        #expect(try afterDelete.loadBooks().isEmpty)
        #expect(try afterDelete.loadAssets(bookID: book.id).isEmpty)
    }

    @Test
    func invalidBookDeleteRollsBackMetadataAndAssets() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDirectory().appendingPathComponent("library-vNext.sqlite"))
        let book = StoredBook(id: BookID(rawValue: "rollback-book"), title: "Book", source: "files", chapters: [])
        try store.saveBook(book)
        let asset = StoredLocalAsset(
            id: AssetID(rawValue: "rollback-asset"),
            bookID: book.id,
            kind: "cover",
            localMediaKey: "/media/cover.jpg"
        )
        try store.saveAssets([asset], bookID: book.id)
        let invalid = OutboxMutation(
            id: MutationID(rawValue: "invalid-book-delete"),
            entityType: .settings,
            entityID: "rollback-book",
            operation: .delete,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_500),
            payload: Data("{}".utf8)
        )

        #expect(throws: (any Error).self) {
            try store.deleteBook(id: book.id, mutation: invalid)
        }
        #expect(try store.loadBooks() == [book])
        #expect(try store.loadAssets(bookID: book.id) == [asset])
        #expect(try store.pendingMutations().isEmpty)
    }

    @Test
    func transcriptRevisionAndOverlayCommitAtomically() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        var transcript = sampleTranscript(segmentCount: 2)
        try saveCatalog(for: transcript, to: store)
        transcript.segments[1].id = transcript.segments[0].id
        let overlay = StoredTranscriptOverlay(
            id: "overlay-1",
            chapterID: transcript.chapterID,
            segmentID: transcript.segments[0].id,
            baseFingerprint: "fingerprint",
            correctedText: "corrected",
            correctedStart: 0,
            correctedEnd: 1,
            provenance: TranscriptOverlayProvenance(
                deviceID: "device-1",
                createdAt: Date(timeIntervalSince1970: 300)
            ),
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        #expect(throws: (any Error).self) {
            try store.saveTranscript(transcript, merging: overlay, revision: 1)
        }

        let relaunched = LocalSQLiteStore(fileURL: url)
        #expect(try relaunched.loadTranscript(chapterID: transcript.chapterID) == nil)
        #expect(try relaunched.loadTranscriptOverlays(chapterID: transcript.chapterID).isEmpty)
    }

    @Test
    func liveVocabularySavePreservesReviewHistoryAndSchedule() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        var reviewed = sampleVocabulary()
        reviewed.reviewCount = 4
        reviewed.nextReview = Date(timeIntervalSince1970: 800)
        reviewed.lastReviewedAt = Date(timeIntervalSince1970: 700)
        reviewed.lastReviewQuality = "remember"
        reviewed.reviewIntervalDays = 7
        reviewed.reviewEaseFactor = 2.7
        try store.upsertVocabulary(reviewed)
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-1"),
            vocabularyID: reviewed.id,
            face: "recognition",
            rating: "remember",
            reviewedAt: Date(timeIntervalSince1970: 700)
        )
        try store.appendReviewEvent(event, vocabulary: reviewed)

        var acceptedTranslation = reviewed
        acceptedTranslation.translation = "updated translation"
        acceptedTranslation.reviewCount = 0
        acceptedTranslation.nextReview = nil
        acceptedTranslation.lastReviewedAt = nil
        acceptedTranslation.lastReviewQuality = nil
        acceptedTranslation.reviewIntervalDays = 0
        acceptedTranslation.reviewEaseFactor = 2.5
        try store.saveVocabulary([acceptedTranslation])

        let relaunched = LocalSQLiteStore(fileURL: url)
        let persisted = try #require(try relaunched.loadVocabulary().first)
        #expect(persisted.translation == "updated translation")
        #expect(persisted.reviewCount == reviewed.reviewCount)
        #expect(persisted.nextReview == reviewed.nextReview)
        #expect(persisted.lastReviewedAt == reviewed.lastReviewedAt)
        #expect(persisted.lastReviewQuality == reviewed.lastReviewQuality)
        #expect(persisted.reviewIntervalDays == reviewed.reviewIntervalDays)
        #expect(persisted.reviewEaseFactor == reviewed.reviewEaseFactor)
        #expect(try relaunched.loadReviewEvents() == [event])
    }

    @Test
    func pulledDecisionPreservesNewerLocalReviewScheduleAndEvents() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        var local = sampleVocabulary()
        local.reviewCount = 6
        local.nextReview = Date(timeIntervalSince1970: 1_000)
        local.lastReviewedAt = Date(timeIntervalSince1970: 900)
        local.lastReviewQuality = "easy"
        local.reviewIntervalDays = 30
        local.reviewEaseFactor = 2.9
        try store.upsertVocabulary(local)
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-pull"),
            vocabularyID: local.id,
            face: "recognition",
            rating: "easy",
            reviewedAt: Date(timeIntervalSince1970: 900)
        )
        try store.appendReviewEvent(event, vocabulary: local)
        var pulled = local
        pulled.translation = "remote translation"
        pulled.reviewCount = 0
        pulled.nextReview = nil
        pulled.lastReviewedAt = nil
        pulled.lastReviewQuality = nil
        pulled.reviewIntervalDays = 0
        pulled.reviewEaseFactor = 2.5

        try store.applyAssistantResults([], vocabulary: [pulled])

        let persisted = try #require(try store.loadVocabulary().first)
        #expect(persisted.translation == "remote translation")
        #expect(persisted.reviewCount == 6)
        #expect(persisted.nextReview == local.nextReview)
        #expect(persisted.lastReviewedAt == local.lastReviewedAt)
        #expect(persisted.reviewIntervalDays == 30)
        #expect(try store.loadReviewCards().first?.reviewCount == 6)
        #expect(try store.loadReviewEvents() == [event])
    }

    @Test
    func knownLemmaUpsertIsIdempotentAndKeepsNewestTimestamp() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDirectory().appendingPathComponent("library-vNext.sqlite"))
        let older = StoredKnownLemma(language: "en", form: "read", updatedAt: Date(timeIntervalSince1970: 10))
        let newer = StoredKnownLemma(language: "en", form: "read", updatedAt: Date(timeIntervalSince1970: 20))

        try store.upsertKnownLemma(older)
        try store.upsertKnownLemma(newer)
        try store.upsertKnownLemma(older)

        #expect(try store.loadKnownLemmas() == [newer])
    }

    @Test
    func rejectingTranslationIsAtomicAndDoesNotResurrectDerivedVocabulary() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        var derived = sampleVocabulary()
        derived.captureSource = VocabularyCaptureSource.acceptedSentenceTranslation.rawValue
        try store.upsertVocabulary(derived)
        let rejected = StoredAssistantResult(
            id: "rejected-result",
            kind: .sentenceGloss,
            status: .rejected,
            language: "zh",
            model: "test",
            source: derived.context,
            text: "rejected",
            createdAt: Date(timeIntervalSince1970: 1_100),
            decidedAt: Date(timeIntervalSince1970: 1_101)
        )
        let mutation = OutboxMutation(
            id: MutationID(rawValue: "reject-mutation"),
            entityType: .assistantResult,
            entityID: rejected.id,
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: rejected.decidedAt!,
            payload: Data("{}".utf8)
        )

        try store.rejectAssistantResult(rejected, derivedVocabularyIDs: [derived.id], mutation: mutation)

        let relaunched = LocalSQLiteStore(fileURL: url)
        #expect(try relaunched.loadAssistantResults() == [rejected])
        #expect(try relaunched.loadVocabulary().isEmpty)
        #expect(try relaunched.loadReviewCards().isEmpty)
        #expect(try relaunched.pendingMutations() == [mutation])
    }

    @Test
    func invalidRejectMutationRollsBackStatusAndDerivedRemoval() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        var derived = sampleVocabulary()
        derived.captureSource = VocabularyCaptureSource.acceptedSentenceTranslation.rawValue
        try store.upsertVocabulary(derived)
        let rejected = StoredAssistantResult(
            id: "rollback-rejection",
            kind: .sentenceGloss,
            status: .rejected,
            language: "zh",
            model: "test",
            source: derived.context,
            text: "rejected",
            createdAt: Date(timeIntervalSince1970: 1_200)
        )
        let invalid = OutboxMutation(
            id: MutationID(rawValue: "invalid-reject"),
            entityType: .settings,
            entityID: rejected.id,
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: rejected.createdAt,
            payload: Data("{}".utf8)
        )

        #expect(throws: (any Error).self) {
            try store.rejectAssistantResult(rejected, derivedVocabularyIDs: [derived.id], mutation: invalid)
        }
        #expect(try store.loadAssistantResults().isEmpty)
        #expect(try store.loadVocabulary() == [derived])
        #expect(try store.pendingMutations().isEmpty)
    }

    @Test
    func overlayEditRestoreAndResolutionRollbackWithInvalidOutboxMutation() throws {
        let url = temporaryDirectory().appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let transcript = sampleTranscript(segmentCount: 1)
        try saveCatalog(for: transcript, to: store)
        try store.saveTranscript(transcript)
        let first = sampleOverlay(id: "overlay-first", deviceID: "device-a", text: "first")
        let invalid = OutboxMutation(
            id: MutationID(rawValue: "invalid-overlay-mutation"),
            entityType: .settings,
            entityID: "settings",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: first.updatedAt,
            payload: Data("{}".utf8)
        )

        #expect(throws: (any Error).self) {
            try store.mergeTranscriptOverlay(first, revision: 1, mutation: invalid)
        }
        #expect(try store.loadTranscriptOverlays(chapterID: transcript.chapterID).isEmpty)

        _ = try store.mergeTranscriptOverlay(first, revision: 1)
        #expect(throws: (any Error).self) {
            try store.deleteTranscriptOverlay(id: first.id, mutation: invalid)
        }
        #expect(try store.loadTranscriptOverlays(chapterID: transcript.chapterID) == [first])

        let conflict = sampleOverlay(id: "overlay-conflict", deviceID: "device-b", text: "second")
        _ = try store.mergeTranscriptOverlay(conflict, revision: 1)
        #expect(throws: (any Error).self) {
            try store.resolveTranscriptOverlay(
                chapterID: transcript.chapterID,
                segmentID: first.segmentID,
                choosing: conflict.id,
                mutation: invalid
            )
        }
        let state = try #require(try store.loadTranscriptOverlayState(
            chapterID: transcript.chapterID,
            segmentID: first.segmentID
        ))
        #expect(state.current.overlay == first)
        #expect(state.conflicts.map(\.overlay) == [conflict])
        #expect(try store.pendingMutations().isEmpty)
    }

    @Test
    func overlayRestoreSupersedesPendingEditWithStrictlyNewerTombstone() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDirectory().appendingPathComponent("library-vNext.sqlite"))
        let transcript = sampleTranscript(segmentCount: 1)
        try saveCatalog(for: transcript, to: store)
        try store.saveTranscript(transcript)
        let overlay = sampleOverlay(id: "overlay-coalesced", deviceID: "device-a", text: "edited")
        let entityID = "overlay-entity"
        let occurredAt = Date(timeIntervalSince1970: 1_300)
        let upsert = OutboxMutation(
            id: MutationID(rawValue: "overlay-upsert"),
            entityType: .transcriptOverlay,
            entityID: entityID,
            operation: .upsert,
            baseRevision: ServerVersion(2),
            occurredAt: occurredAt,
            payload: Data("{}".utf8)
        )
        let delete = OutboxMutation(
            id: MutationID(rawValue: "overlay-delete"),
            entityType: .transcriptOverlay,
            entityID: entityID,
            operation: .delete,
            baseRevision: ServerVersion(1),
            occurredAt: occurredAt,
            payload: Data("{}".utf8)
        )

        _ = try store.mergeTranscriptOverlay(overlay, revision: 2, mutation: upsert)
        try store.deleteTranscriptOverlay(id: overlay.id, mutation: delete)

        let pending = try store.pendingMutations()
        #expect(pending.count == 1)
        #expect(pending.first?.operation == .delete)
        #expect(pending.first?.baseRevision == ServerVersion(2))
        #expect((pending.first?.occurredAt ?? .distantPast) > occurredAt)
        #expect(try store.loadTranscriptOverlays(chapterID: transcript.chapterID).isEmpty)
    }

    private func sampleTranscript(segmentCount: Int) -> StoredTranscript {
        StoredTranscript(
            chapterID: ChapterID(rawValue: "chapter-1"),
            localMediaKey: "/media/book.m4b",
            chapterStart: 10,
            createdAt: Date(timeIntervalSince1970: 100),
            locale: "en",
            source: "test",
            ebookAligned: true,
            segments: (0..<segmentCount).map { index in
                StoredTranscriptSegment(
                    id: "segment-\(index)",
                    start: Double(index),
                    end: Double(index + 1),
                    words: [
                        StoredTranscriptWord(
                            id: "word-\(index)",
                            text: "word-\(index)",
                            start: Double(index),
                            end: Double(index) + 0.5,
                            confidence: 0.9
                        )
                    ],
                    ebookText: "ebook-\(index)",
                    alignmentScore: 0.8,
                    individualEbookMatchTrusted: true,
                    documentEbookUseAllowed: true
                )
            }
        )
    }

    private func saveCatalog(for transcript: StoredTranscript, to store: LocalSQLiteStore) throws {
        try store.saveBook(StoredBook(
            id: BookID(rawValue: "book-for-\(transcript.chapterID.rawValue)"),
            title: "Book",
            source: "test",
            chapters: [StoredChapter(
                id: transcript.chapterID,
                index: 0,
                title: "Chapter"
            )]
        ))
    }

    private func sampleVocabulary() -> StoredVocabularyOccurrence {
        StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "vocab-reviewed"),
            surface: "word",
            captureSource: VocabularyCaptureSource.explicitWord.rawValue,
            reviewEligible: true,
            category: "word",
            context: "A word in context.",
            bookID: BookID(rawValue: "book-reviewed"),
            bookTitle: "Book",
            chapterID: ChapterID(rawValue: "chapter-reviewed"),
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 600)
        )
    }

    private func sampleOverlay(id: String, deviceID: String, text: String) -> StoredTranscriptOverlay {
        StoredTranscriptOverlay(
            id: id,
            chapterID: ChapterID(rawValue: "chapter-1"),
            segmentID: "segment-0",
            baseFingerprint: "fingerprint",
            correctedText: text,
            correctedStart: 0,
            correctedEnd: 1,
            provenance: TranscriptOverlayProvenance(
                deviceID: deviceID,
                createdAt: Date(timeIntervalSince1970: 900)
            ),
            updatedAt: Date(timeIntervalSince1970: 900)
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-vnext-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func installPriorV1Schema(at url: URL) throws {
        try execute(PriorV1SchemaFixture.sql, at: url)
        try execute(
            """
            INSERT INTO local_books(id, title, source, created_at, updated_at)
              VALUES ('legacy-book', 'Legacy Book', 'files', 10, 10);
            INSERT INTO local_chapters(id, book_id, position, title, created_at, updated_at)
              VALUES ('legacy-chapter', 'legacy-book', 0, 'Legacy Chapter', 10, 10);
            INSERT INTO local_assets(id, book_id, kind, local_media_key, created_at, updated_at)
              VALUES ('legacy-asset', 'legacy-book', 'epub', '/legacy/book.epub', 10, 10);
            INSERT INTO local_assistant_results(
              id, kind, status, language, model, source, text, created_at, updated_at
            ) VALUES ('legacy-result', 'sentence_gloss', 'pending', 'zh-Hans', 'legacy', 'Source', 'Draft', 10, 10);
            """,
            at: url
        )

        #expect(Set(try rawTableNames(at: url)) == Set([
            "entity_versions", "local_assets", "local_sync_asset_manifests",
            "local_book_tombstones", "local_assistant_result_history", "local_assistant_results",
            "local_books", "local_chapters", "local_known_lemmas", "local_reader_progress",
            "local_review_cards", "local_review_events", "local_settings", "local_study_activity",
            "local_transcript_overlay_conflicts", "local_transcript_overlays",
            "local_transcript_revisions", "local_transcript_segments",
            "local_translation_checkpoints", "local_vocabulary_occurrences", "sync_outbox", "sync_state",
        ]))
        let currentURL = url.deletingLastPathComponent().appendingPathComponent("current-schema.sqlite")
        try execute(LocalSchemaVNext.createStatements.joined(separator: "\n"), at: currentURL)
        let priorColumns = try rawSchemaColumns(at: url)
        let currentColumns = try rawSchemaColumns(at: currentURL)
        let additions = Set(currentColumns.flatMap { table, columns in
            columns.subtracting(priorColumns[table] ?? []).map { "\(table).\($0)" }
        })
        #expect(additions == Set([
            "local_assets.content_hash", "local_assets.byte_count", "local_assets.metadata_json",
            "local_assistant_results.prompt_version", "local_assistant_results.model_policy_hash",
            "local_assistant_results.shared_cache_entry_id",
            "local_chapters.ebook_section_index",
        ]))
        #expect(priorColumns.allSatisfy { table, columns in
            columns.subtracting(currentColumns[table] ?? []).isEmpty
        })
    }

    private func installVersion2Columns(at url: URL) throws {
        try execute(LocalSchemaVNext.version2ColumnAdditions.map(\.sql).joined(separator: ";\n"), at: url)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func rawUserVersion(at url: URL) throws -> Int {
        try rawRows("PRAGMA user_version", at: url).first.flatMap { Int($0["user_version"] ?? "") } ?? 0
    }

    private func rawTableNames(at url: URL) throws -> [String] {
        try rawRows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", at: url)
            .compactMap { $0["name"] }
    }

    private func rawColumnNames(in table: String, at url: URL) throws -> [String] {
        try rawRows("PRAGMA table_info(\(table))", at: url).compactMap { $0["name"] }
    }

    private func rawSchemaColumns(at url: URL) throws -> [String: Set<String>] {
        try Dictionary(uniqueKeysWithValues: rawTableNames(at: url).map { table in
            (table, Set(try rawColumnNames(in: table, at: url)))
        })
    }

    private func schemaFingerprint(at url: URL) throws -> [String] {
        try rawRows(
            "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name",
            at: url
        ).map { row in
            ["type", "name", "tbl_name", "sql"].map { row[$0] ?? "NULL" }.joined(separator: "|")
        }
    }

    private func rawRows(_ sql: String, at url: URL) throws -> [[String: String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                if let value = sqlite3_column_text(statement, index) {
                    row[name] = String(cString: value)
                }
            }
            rows.append(row)
        }
        return rows
    }
}
