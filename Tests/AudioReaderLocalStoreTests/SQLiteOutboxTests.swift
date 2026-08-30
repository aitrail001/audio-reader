import Foundation
import Testing
@testable import AudioReaderLocalStore

@Suite("SQLite sync outbox")
struct SQLiteOutboxTests {
    @Test("enqueues pending mutations, ignores duplicate IDs, and stores the cursor")
    func enqueueAcknowledgeAndCursor() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-outbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let mutation = OutboxMutation(
            id: MutationID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            entityType: .settings,
            entityID: "00000000-0000-4000-8000-00000000000a",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
            payload: Data("{\"targetLanguage\":\"zh\"}".utf8)
        )
        try store.enqueue(mutation)
        var duplicate = mutation
        duplicate.payload = Data("{\"targetLanguage\":\"ja\"}".utf8)
        try store.enqueue(duplicate)

        let pending = try store.pendingMutations()
        #expect(pending.map(\.id.rawValue) == [mutation.id.rawValue])
        #expect(String(data: pending[0].payload, encoding: .utf8) == "{\"targetLanguage\":\"zh\"}")

        try store.markAcknowledged(id: mutation.id)
        #expect(try store.pendingMutations().isEmpty)
        #expect(try store.loadCursor() == "0")
        try store.saveCursor("12")
        #expect(try store.loadCursor() == "12")
    }

    @Test("bulk acknowledgement crosses SQLite parameter chunks atomically")
    func bulkAcknowledgement() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-outbox-bulk-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let mutations = (0..<1_001).map { index in
            OutboxMutation(
                id: MutationID(rawValue: "mutation-\(index)"),
                entityType: .vocabulary,
                entityID: "vocabulary-\(index)",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000 + Double(index)),
                payload: Data("{}".utf8)
            )
        }
        for mutation in mutations {
            try store.enqueue(mutation)
        }

        try store.markAcknowledged(ids: mutations.prefix(750).map(\.id))

        let pending = try store.pendingMutations()
        #expect(pending.count == 251)
        #expect(pending.first?.id == mutations[750].id)
        #expect(pending.last?.id == mutations[1_000].id)
    }

    @Test("updates pending payload and stores entity revisions")
    func updatePendingAndEntityVersion() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-outbox-version-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        var mutation = OutboxMutation(
            id: MutationID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            entityType: .settings,
            entityID: "00000000-0000-4000-8000-00000000000a",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
            payload: Data("{\"targetLanguage\":\"zh\"}".utf8)
        )
        try store.enqueue(mutation)
        mutation.payload = Data("{\"targetLanguage\":\"ja\"}".utf8)
        mutation.baseRevision = ServerVersion(3)
        try store.updatePending(mutation)
        let pending = try store.pendingMutations()
        #expect(String(data: pending[0].payload, encoding: .utf8) == "{\"targetLanguage\":\"ja\"}")
        #expect(pending[0].baseRevision.rawValue == 3)

        try store.saveVersion(
            SyncEntityVersion(
                entityType: mutation.entityType.rawValue,
                entityID: mutation.entityID,
                serverVersion: 3,
                payload: mutation.payload,
                lastMutationID: mutation.id.rawValue
            )
        )
        let version = try store.loadVersion(entityType: mutation.entityType.rawValue, entityID: mutation.entityID)
        #expect(version?.serverVersion == 3)
        #expect(version?.payload == mutation.payload)
    }

    @Test("only an explicit vocabulary deletion marker is treated as a tombstone")
    func vocabularyTombstoneRequiresExplicitMarker() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-outbox-tombstone-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let entityID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        try store.saveVersion(
            SyncEntityVersion(
                entityType: OutboxEntityType.vocabulary.rawValue,
                entityID: entityID,
                serverVersion: 0,
                payload: Data("{}".utf8)
            )
        )
        #expect(try !store.isVocabularyTombstoned(entityID: entityID))

        try store.saveVersion(
            SyncEntityVersion(
                entityType: OutboxEntityType.vocabulary.rawValue,
                entityID: entityID,
                serverVersion: 1,
                payload: Data("{\"_deleted\":true}".utf8)
            )
        )
        #expect(try store.isVocabularyTombstoned(entityID: entityID))
    }
}
