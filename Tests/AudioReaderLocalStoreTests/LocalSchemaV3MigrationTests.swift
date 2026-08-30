import Foundation
import Testing
import AudioReaderDomain
@testable import AudioReaderLocalStore

@Suite("Local schema v3 transcript overlays")
struct LocalSchemaV3MigrationTests {
    @Test("opening a v2 database adds v3 overlay storage without removing data")
    func migratesV2Database() throws {
        let url = temporaryDatabaseURL()
        let store = LocalSQLiteStore(fileURL: url)
        #expect(try store.currentSchemaVersion() == LocalSchemaV4.version)
        #expect(try store.tableNames().contains("sync_mirror_repairs"))
        #expect(try store.tableNames().contains("local_transcript_overlays"))
        #expect(try store.tableNames().contains("local_transcript_overlay_conflicts"))
    }

    @Test("repository keeps one current overlay and supports restore")
    func savesReplacesAndDeletesOverlay() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDatabaseURL())
        let first = overlay(text: "First", updatedAt: Date(timeIntervalSince1970: 1))
        let replacement = overlay(text: "Replacement", updatedAt: Date(timeIntervalSince1970: 2))

        try store.saveTranscriptOverlay(first)
        try store.saveTranscriptOverlay(replacement)

        #expect(try store.loadTranscriptOverlays(chapterID: first.chapterID) == [replacement])
        try store.deleteTranscriptOverlay(id: replacement.id)
        #expect(try store.loadTranscriptOverlays(chapterID: first.chapterID).isEmpty)
    }

    @Test("stale overlays round trip unchanged for provenance")
    func staleOverlayRoundTrip() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDatabaseURL())
        let value = overlay(text: "Stale", updatedAt: Date(timeIntervalSince1970: 3), fingerprint: "old")
        try store.saveTranscriptOverlay(value)
        #expect(try store.loadAllTranscriptOverlays() == [value])
    }

    @Test("same-revision overlay edits from two devices require explicit resolution")
    func overlayConflictRetention() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDatabaseURL())
        let mac = overlay(
            text: "Mac correction",
            updatedAt: Date(timeIntervalSince1970: 3),
            deviceID: "mac"
        )
        let iPad = overlay(
            text: "iPad correction",
            updatedAt: Date(timeIntervalSince1970: 4),
            fingerprint: "stale-but-retained",
            deviceID: "ipad"
        )

        #expect(try store.mergeTranscriptOverlay(mac, revision: 7) == .inserted)
        #expect(try store.mergeTranscriptOverlay(iPad, revision: 7) == .conflictRetained)
        var state = try #require(try store.loadTranscriptOverlayState(
            chapterID: mac.chapterID,
            segmentID: mac.segmentID
        ))

        #expect(state.current.overlay == mac)
        #expect(state.current.revision == 7)
        #expect(state.conflicts.map(\.overlay) == [iPad])
        #expect(state.current.id != state.conflicts[0].id)

        try store.resolveTranscriptOverlay(
            chapterID: mac.chapterID,
            segmentID: mac.segmentID,
            choosing: state.conflicts[0].id
        )
        state = try #require(try store.loadTranscriptOverlayState(
            chapterID: mac.chapterID,
            segmentID: mac.segmentID
        ))
        #expect(state.current.overlay == iPad)
        #expect(state.conflicts.isEmpty)
    }

    @Test("reader resume stores exact relative seconds")
    func readerProgressRoundTrip() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDatabaseURL())
        let progress = readerProgress(id: "mac-1", deviceID: "mac", seconds: 42.125, revision: 4)

        #expect(try store.mergeReaderProgress(progress) == .inserted)
        let state = try #require(try store.loadReaderProgress(bookID: progress.bookID))

        #expect(state.current == progress)
        #expect(state.current.relativeSeconds == 42.125)
        #expect(state.conflicts.isEmpty)
    }

    @Test("a first review persists its vocabulary, card schedule, and additive event together")
    func firstReviewPersistsLearningHistory() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDatabaseURL())
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let vocabulary = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "vocab-1"),
            surface: "whale",
            category: "word",
            sourceLanguage: "en",
            context: "Call me Ishmael.",
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Loomings",
            timestamp: 12,
            addedAt: reviewedAt.addingTimeInterval(-60),
            reviewCount: 1,
            nextReview: reviewedAt.addingTimeInterval(3 * 86_400),
            lastReviewedAt: reviewedAt,
            lastReviewQuality: "vague",
            reviewIntervalDays: 3,
            reviewEaseFactor: 2.5,
            isInLearnList: true
        )
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-1"),
            vocabularyID: vocabulary.id,
            face: "cloze",
            rating: "vague",
            reviewedAt: reviewedAt
        )

        try store.appendReviewEvent(event, vocabulary: vocabulary)
        try store.appendReviewEvent(event, vocabulary: vocabulary)

        #expect(try store.loadVocabulary() == [vocabulary])
        #expect(try store.loadReviewEvents() == [event])
    }

    @Test("Review writes reuse the schema established when the store opens")
    func reviewWriteDoesNotReapplySchema() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDatabaseURL())
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let vocabulary = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "vocab-schema"),
            surface: "whale",
            category: "word",
            sourceLanguage: "en",
            context: "Call me Ishmael.",
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Loomings",
            timestamp: 12,
            addedAt: reviewedAt,
            reviewCount: 1,
            nextReview: reviewedAt.addingTimeInterval(86_400),
            lastReviewedAt: reviewedAt,
            lastReviewQuality: "remember",
            reviewIntervalDays: 1,
            reviewEaseFactor: 2.5,
            isInLearnList: false
        )
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-schema"),
            vocabularyID: vocabulary.id,
            face: "recognition",
            rating: "remember",
            reviewedAt: reviewedAt
        )
        let applicationsAfterOpen = store.schemaApplicationCount

        try store.appendReviewEvent(event, vocabulary: vocabulary)

        #expect(applicationsAfterOpen == 1)
        #expect(store.schemaApplicationCount == applicationsAfterOpen)
    }

    @Test("Review writes update only schedule fields on an existing vocabulary row")
    func reviewWritePreservesConcurrentVocabularyFields() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDatabaseURL())
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var latest = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "vocab-review-merge"),
            surface: "whale",
            category: "word",
            context: "Call me Ishmael.",
            bookID: BookID(rawValue: "book-1"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter-1"),
            chapterTitle: "Loomings",
            timestamp: 12,
            addedAt: reviewedAt.addingTimeInterval(-60)
        )
        latest.translation = "latest translation"
        latest.isInLearnList = true
        try store.upsertVocabulary(latest)

        var staleReviewed = latest
        staleReviewed.translation = "stale translation"
        staleReviewed.isInLearnList = false
        staleReviewed.reviewCount = 1
        staleReviewed.nextReview = reviewedAt.addingTimeInterval(7 * 86_400)
        staleReviewed.lastReviewedAt = reviewedAt
        staleReviewed.lastReviewQuality = "remember"
        staleReviewed.reviewIntervalDays = 7
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-merge"),
            vocabularyID: staleReviewed.id,
            face: "recognition",
            rating: "remember",
            reviewedAt: reviewedAt
        )

        try store.appendReviewEvent(event, vocabulary: staleReviewed)

        let stored = try #require(store.loadVocabulary().first)
        #expect(stored.translation == "latest translation")
        #expect(stored.isInLearnList)
        #expect(stored.reviewCount == 1)
        #expect(stored.lastReviewedAt == reviewedAt)
    }

    @Test("same-revision progress from another device is retained for explicit resolution")
    func readerProgressConflictRetention() throws {
        let store = LocalSQLiteStore(fileURL: temporaryDatabaseURL())
        let mac = readerProgress(id: "mac-1", deviceID: "mac", seconds: 42.125, revision: 4)
        let iPad = readerProgress(id: "ipad-1", deviceID: "ipad", seconds: 90.75, revision: 4)

        _ = try store.mergeReaderProgress(mac)
        #expect(try store.mergeReaderProgress(iPad) == .conflictRetained)
        var state = try #require(try store.loadReaderProgress(bookID: mac.bookID))
        #expect(state.current == mac)
        #expect(state.conflicts == [iPad])

        try store.resolveReaderProgress(bookID: mac.bookID, choosing: iPad.id)
        state = try #require(try store.loadReaderProgress(bookID: mac.bookID))
        #expect(state.current == iPad)
        #expect(state.conflicts.isEmpty)
    }

    private func overlay(
        text: String,
        updatedAt: Date,
        fingerprint: String = "base",
        deviceID: String = "mac"
    ) -> StoredTranscriptOverlay {
        StoredTranscriptOverlay(
            id: "chapter:segment",
            chapterID: ChapterID(rawValue: "chapter"),
            segmentID: "segment",
            baseFingerprint: fingerprint,
            correctedText: text,
            correctedStart: 1,
            correctedEnd: 2,
            provenance: .init(deviceID: deviceID, actorID: "person", createdAt: updatedAt),
            updatedAt: updatedAt
        )
    }

    private func readerProgress(
        id: String,
        deviceID: String,
        seconds: Double,
        revision: Int64
    ) -> StoredReaderProgress {
        StoredReaderProgress(
            id: id,
            bookID: BookID(rawValue: "book"),
            chapterID: ChapterID(rawValue: "chapter"),
            relativeSeconds: seconds,
            updatedAt: Date(timeIntervalSince1970: 100),
            deviceID: deviceID,
            revision: revision
        )
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-v3-\(UUID().uuidString).sqlite")
    }
}
