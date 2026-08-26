import Foundation
import Testing
@testable import AudioReaderLocalStore

@Suite("Local schema v2 migration")
struct LocalSchemaV2MigrationTests {
    @Test("creates every required schema v2 table")
    func createsRequiredTables() throws {
        let fixture = try IsolatedLocalStoreFixture()
        defer { fixture.remove() }

        let store = LocalSQLiteStore(fileURL: fixture.sqliteURL)
        let receipt = try store.migrateLegacyData(from: fixture.sources)

        let tables = Set(try store.tableNames())
        for name in LocalSchemaV2.requiredTables {
            #expect(tables.contains(name), "missing table \(name)")
        }
        #expect(receipt.schemaVersion == LocalSchemaV2.version)
        #expect(try store.loadReceipt()?.schemaVersion == LocalSchemaV2.version)
        #expect(receipt.bookCount == 0)
        #expect(receipt.vocabularyCount == 0)
    }

    @Test("imports JSON-only known lemmas and study activity")
    func importsJSONKnownLemmasAndActivityLog() throws {
        let fixture = try IsolatedLocalStoreFixture()
        defer { fixture.remove() }
        try fixture.writeJSON(
            "lexicon.json",
            [
                ["language": "en", "form": "forest", "updatedAt": "2023-11-14T22:13:20Z"],
                ["language": "en", "form": "whale", "updatedAt": "2023-11-15T22:13:20Z"]
            ]
        )
        try fixture.writeJSON("study-activity.json", ["days": ["2023-11-14", "2023-11-15"]])

        let store = LocalSQLiteStore(fileURL: fixture.sqliteURL)
        let receipt = try store.migrateLegacyData(from: fixture.sources)

        #expect(receipt.knownLemmaCount == 2)
        #expect(try store.loadKnownLemmas().map(\.form).sorted() == ["forest", "whale"])
        #expect(try store.loadStudyActivityDays() == ["2023-11-14", "2023-11-15"])
        #expect(try store.rowCount("entity_versions") >= 1)
        #expect(try store.rowCount("sync_state") == 1)
        #expect(try store.rowCount("sync_outbox") == 0)
    }

    @Test("interrupted migration rolls back and leaves no receipt")
    func interruptedMigrationRollsBack() throws {
        let fixture = try IsolatedLocalStoreFixture()
        defer { fixture.remove() }
        try seedLegacyV1(
            at: fixture.sqliteURL,
            transcripts: [Self.transcriptJSON],
            vocab: [Self.vocabJSON],
            glosses: [Self.pendingGlossJSON, Self.acceptedGlossJSON]
        )

        let store = LocalSQLiteStore(fileURL: fixture.sqliteURL)
        store.interruptAfterTable = "local_vocabulary_occurrences"
        #expect(throws: LocalMigrationError.interrupted(table: "local_vocabulary_occurrences")) {
            try store.migrateLegacyData(from: fixture.sources)
        }

        #expect(try store.loadReceipt() == nil)
        for name in LocalSchemaV2.requiredTables {
            #expect(try store.rowCount(name) == 0, "partial rows left in \(name)")
        }

        store.interruptAfterTable = nil
        let receipt = try store.migrateLegacyData(from: fixture.sources)
        #expect(receipt.vocabularyCount == 1)
        #expect(receipt.transcriptRevisionCount == 1)
        #expect(try store.loadReceipt() != nil)
        #expect(try store.loadVocabulary().map(\.surface) == ["Ishmael"])
    }

    @Test("repeated launch does not duplicate rows")
    func repeatedLaunchDoesNotDuplicateRows() throws {
        let fixture = try IsolatedLocalStoreFixture()
        defer { fixture.remove() }
        try seedLegacyV1(
            at: fixture.sqliteURL,
            transcripts: [Self.transcriptJSON],
            vocab: [Self.vocabJSON],
            glosses: [Self.pendingGlossJSON, Self.acceptedGlossJSON]
        )
        try fixture.writeJSON(
            "lexicon.json",
            [["language": "en", "form": "forest", "updatedAt": "2023-11-14T22:13:20Z"]]
        )

        let store = LocalSQLiteStore(fileURL: fixture.sqliteURL)
        let first = try store.migrateLegacyData(from: fixture.sources)
        let counts = try store.requiredTableCounts()
        let second = try store.migrateLegacyData(from: fixture.sources)

        #expect(first == second)
        #expect(try store.requiredTableCounts() == counts)
        #expect(first.vocabularyCount == 1)
        #expect(try store.rowCount("local_vocabulary_occurrences") == 1)
        #expect(try store.rowCount("local_transcript_revisions") == 1)
        #expect(try store.rowCount("local_known_lemmas") == 1)
    }

    @Test("isolated migration does not read Persistence.root")
    func isolatedMigrationDoesNotReadPersistenceRoot() throws {
        let token = "v2-isolation-\(UUID().uuidString)"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioReader", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let plantedLexicon = support.appendingPathComponent("lexicon.json")
        let existing = try? Data(contentsOf: plantedLexicon)
        try JSONSerialization.data(withJSONObject: [
            ["language": "en", "form": token, "updatedAt": "2023-11-14T22:13:20Z"]
        ]).write(to: plantedLexicon, options: .atomic)
        defer {
            if let existing {
                try? existing.write(to: plantedLexicon, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: plantedLexicon)
            }
        }

        let fixture = try IsolatedLocalStoreFixture()
        defer { fixture.remove() }
        let store = LocalSQLiteStore(fileURL: fixture.sqliteURL)
        _ = try store.migrateLegacyData(from: fixture.sources)

        #expect(try store.loadKnownLemmas().isEmpty)
        let sqliteData = try Data(contentsOf: fixture.sqliteURL)
        #expect(sqliteData.range(of: Data(token.utf8)) == nil)
        #expect(store.url.path.contains(fixture.root.path))
        #expect(store.url != support.appendingPathComponent("library.sqlite"))
    }

    private static let transcriptJSON = """
        {
          "chapterID": "chapter-loomings",
          "audioPath": "/Books/Moby-Dick/chapter-01.m4b",
          "chapterStart": 0,
          "createdAt": "2023-11-14T22:13:20Z",
          "locale": "en-US",
          "source": "apple-speech",
          "ebookAligned": true,
          "ebookUseOverride": null,
          "ebookAlignment": {
            "status": "trusted",
            "reason": "anchors matched across sampled sentences",
            "metrics": {
              "extractedWordCount": 12840,
              "extractedSentenceCount": 612,
              "sampledAnchorCount": 48,
              "matchedAnchorCount": 45,
              "matchedCoverage": 0.9375,
              "medianScore": 0.91,
              "lowerPercentileScore": 0.74,
              "backwardJumps": 1,
              "longestUnmatchedPassage": 18,
              "titleSimilarity": 0.99,
              "authorSimilarity": 0.88,
              "candidateComparisons": 3,
              "detailedAlignmentPerformed": true
            }
          },
          "segments": [
            {
              "id": "seg-1",
              "start": 0,
              "end": 2.4,
              "words": [
                {"id": "w-1", "text": "Call", "start": 0, "end": 0.4, "confidence": 0.96},
                {"id": "w-2", "text": " me", "start": 0.4, "end": 0.7, "confidence": 0.99},
                {"id": "w-3", "text": " Ishmael", "start": 0.7, "end": 1.4, "confidence": 0.98}
              ],
              "ebookText": "Call me Ishmael.",
              "alignmentScore": 0.94,
              "individualEbookMatchTrusted": true,
              "documentEbookUseAllowed": true
            }
          ]
        }
        """

    private static let vocabJSON = """
        {
          "id": "vocab-ishmael",
          "word": "Ishmael",
          "category": "word",
          "definition": "a biblical wanderer",
          "dictionaryName": "牛津英汉汉英词典",
          "dictionaryHTML": "<html><body><b>Ishmael</b> n. 以实玛利</body></html>",
          "translation": "以实玛利",
          "translationLanguage": "zh-Hans",
          "translationModel": "grok-4.6",
          "sourceLanguage": "en",
          "context": "Call me Ishmael.",
          "spokenText": "Call me Ishmael.",
          "ebookText": "Call me Ishmael.",
          "bookID": "book-moby-dick",
          "bookTitle": "Moby-Dick",
          "chapterID": "chapter-loomings",
          "chapterTitle": "Loomings",
          "segmentID": "seg-1",
          "wordID": "w-3",
          "timestamp": 1.2,
          "addedAt": "2023-11-14T22:13:20Z",
          "reviewCount": 3,
          "nextReview": "2023-11-21T22:13:20Z",
          "lastReviewedAt": "2023-11-18T22:13:20Z",
          "lastReviewQuality": "remember",
          "reviewIntervalDays": 7,
          "reviewEaseFactor": 2.6,
          "isInLearnList": true
        }
        """

    private static let pendingGlossJSON = """
        {
          "id": "gloss-pending",
          "kind": "sentence",
          "language": "zh-Hans",
          "source": "Call me Ishmael.",
          "context": null,
          "text": "叫我以实玛利。",
          "status": "pending",
          "model": "grok-4.6",
          "bookID": "book-moby-dick",
          "bookTitle": "Moby-Dick",
          "chapterID": "chapter-loomings",
          "chapterTitle": "Loomings",
          "timestamp": 0,
          "createdAt": "2023-11-14T22:13:20Z"
        }
        """

    private static let acceptedGlossJSON = """
        {
          "id": "gloss-accepted",
          "kind": "word",
          "language": "zh-Hans",
          "source": "Ishmael",
          "context": "Call me Ishmael.",
          "text": "以实玛利",
          "status": "accepted",
          "model": "grok-4.6",
          "bookID": "book-moby-dick",
          "bookTitle": "Moby-Dick",
          "chapterID": "chapter-loomings",
          "chapterTitle": "Loomings",
          "timestamp": 1.2,
          "createdAt": "2023-11-14T22:13:20Z",
          "decidedAt": "2023-11-14T22:20:00Z"
        }
        """
}

private struct IsolatedLocalStoreFixture {
    let root: URL

    var sqliteURL: URL { root.appendingPathComponent("library.sqlite") }

    var sources: LegacyLocalDataSources {
        LegacyLocalDataSources(sqliteURL: sqliteURL, persistenceRoot: root)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-schema-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeJSON(_ name: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent(name), options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension LocalSQLiteStore {
    func requiredTableCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for name in LocalSchemaV2.requiredTables {
            counts[name] = try rowCount(name)
        }
        return counts
    }
}
