import CryptoKit
import Foundation
import Testing
@testable import AudioReaderLocalStore
@testable import AudioReaderNetworking

@Suite("Product sync client")
struct SyncClientTests {
    @Test("pulled transcript overlays apply after their immutable base transcript")
    func transcriptOverlayOrdering() {
        let overlay = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.transcriptOverlay.rawValue,
            entityId: "overlay",
            operation: "upsert",
            revision: 1,
            changedAt: "2026-08-29T00:00:00Z",
            payload: [:]
        )
        let transcript = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.transcript.rawValue,
            entityId: "transcript",
            operation: "upsert",
            revision: 1,
            changedAt: "2026-08-29T00:00:00Z",
            payload: [:]
        )

        #expect(SyncPulledChange.applying([overlay, transcript]).map(\.entityType) == [
            OutboxEntityType.transcript.rawValue,
            OutboxEntityType.transcriptOverlay.rawValue,
        ])
    }
    @Test("push encodes the outbox batch and pull reads the change page")
    func pushAndPullRoundTrip() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 200,
            json: """
            {"batchId":"7c9e6679-7425-40de-944b-e07fc1f90ae7","results":[{"mutationId":"9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d","status":"applied","entityRevision":1,"problem":null}],"cursor":"1"}
            """
        )
        http.enqueue(
            status: 200,
            json: """
            {"changes":[{"sequence":1,"entityType":"settings","entityId":"00000000-0000-4000-8000-00000000000a","operation":"upsert","revision":1,"changedAt":"2026-08-26T09:12:04Z","payload":{"targetLanguage":"zh"}}],"cursor":"1","hasMore":false}
            """
        )
        let client = ProductSyncClient(http: http)
        let pushed = try await client.push(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            request: SyncPushRequest(
                deviceId: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                batchId: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
                mutations: [
                    SyncPushMutation(
                        mutationId: "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
                        entityType: "settings",
                        entityId: "00000000-0000-4000-8000-00000000000a",
                        operation: "upsert",
                        baseRevision: 0,
                        occurredAt: "2026-08-26T09:12:04Z",
                        payload: ["targetLanguage": .string("zh")]
                    )
                ]
            )
        )
        #expect(pushed.cursor == "1")
        #expect(pushed.results.first?.status == "applied")
        #expect(http.requests.first?.path == "/v1/sync/push")
        let pushBody = try #require(http.requests.first?.body)
        let expectedDigest = SHA256.hash(data: pushBody).map { String(format: "%02x", $0) }.joined()
        #expect(http.requests.first?.headers["X-Content-SHA256"] == expectedDigest)

        let pulled = try await client.pull(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            cursor: "0",
            limit: 100
        )
        #expect(pulled.changes.count == 1)
        #expect(pulled.changes.first?.payload["targetLanguage"]?.stringValue == "zh")
        #expect(http.requests.last?.path.contains("/v1/sync/pull") == true)
    }

    @Test("pulled changes apply vocabulary before progress and reviews")
    func pulledChangesApplyVocabularyBeforeProgress() {
        let progress = SyncPulledChange(
            sequence: 1,
            entityType: "progress",
            entityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            operation: "upsert",
            revision: 1,
            changedAt: "2026-08-26T09:12:04Z",
            payload: [:]
        )
        let vocab = SyncPulledChange(
            sequence: 2,
            entityType: "vocabulary",
            entityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            operation: "upsert",
            revision: 1,
            changedAt: "2026-08-26T09:12:04Z",
            payload: [:]
        )
        let review = SyncPulledChange(
            sequence: 3,
            entityType: "review_event",
            entityId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            operation: "append",
            revision: 1,
            changedAt: "2026-08-26T09:12:04Z",
            payload: [:]
        )
        #expect(SyncPulledChange.applying([progress, review, vocab]).map(\.entityType) == [
            "vocabulary", "progress", "review_event"
        ])
    }
}

@Suite("Account session sync")
struct AccountSessionSyncTests {
    @Test("sync status describes granular entity, batch, pending, and conflict progress")
    func syncStatusDescriptions() {
        let uploading = AccountSyncStatus.uploading(
            entityType: OutboxEntityType.book.rawValue,
            completedCount: 2,
            totalCount: 5,
            batchIndex: 1,
            batchCount: 3,
            pendingCount: 3,
            entityProgress: [
                AccountSyncEntityProgress(
                    entityType: OutboxEntityType.book.rawValue,
                    completedCount: 2,
                    totalCount: 5
                )
            ]
        )

        #expect(uploading.phase == .uploading)
        #expect(uploading.title == "Uploading books")
        #expect(uploading.detail.contains("2 of 5 changes"))
        #expect(uploading.detail.contains("batch 1 of 3"))
        #expect(uploading.detail.contains("3 pending"))
        #expect(uploading.accessibilityDescription.contains("Uploading books"))

        let conflicted = AccountSyncStatus.completed(
            uploadedCount: 4,
            appliedCount: 2,
            pendingCount: 1,
            conflictCount: 1,
            entityProgress: uploading.entityProgress
        )
        #expect(conflicted.title == "Sync conflicts need review")
        #expect(conflicted.detail.contains("1 conflict"))
        #expect(conflicted.detail.contains("1 pending"))
        #expect(conflicted.requiresAttention)
    }

    @MainActor
    @Test("push batches keep each real-world transcript below the Worker-safe request allowance")
    func pushBatchesRespectEncodedByteLimit() throws {
        let payload = Data("{\"text\":\"\(String(repeating: "a", count: 2_600_000))\"}".utf8)
        let pending = (0..<3).map { index in
            OutboxMutation(
                id: MutationID(rawValue: "00000000-0000-4000-8000-\(String(format: "%012d", index + 1))"),
                entityType: .transcript,
                entityID: "10000000-0000-4000-8000-\(String(format: "%012d", index + 1))",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000 + Double(index)),
                payload: payload
            )
        }

        let batches = try AccountSession.syncPushBatches(pending)

        #expect(batches.map(\.count) == [1, 1, 1])
        for batch in batches {
            let request = SyncPushRequest(
                deviceId: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                batchId: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
                mutations: try batch.map { try $0.productMutation() }
            )
            #expect(try JSONEncoder().encode(request).count < 4 * 1_024 * 1_024)
        }
    }

    @MainActor
    @Test("a transcript larger than the native batch budget fails before upload")
    func oversizedTranscriptFailsBeforeUpload() {
        let payload = Data("{\"text\":\"\(String(repeating: "a", count: 3_200_000))\"}".utf8)
        let mutation = OutboxMutation(
            id: MutationID(rawValue: "00000000-0000-4000-8000-000000000001"),
            entityType: .transcript,
            entityID: "10000000-0000-4000-8000-000000000001",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
            payload: payload
        )

        #expect(throws: (any Error).self) {
            _ = try AccountSession.syncPushBatches([mutation])
        }
    }

    @MainActor
    @Test("mixed transcripts split before the Worker resource threshold")
    func mixedTranscriptsSplitBeforeWorkerThreshold() throws {
        let sizes = [1_616_000, 1_350_000]
        let pending = sizes.enumerated().map { index, size in
            OutboxMutation(
                id: MutationID(rawValue: "00000000-0000-4000-8000-\(String(format: "%012d", index + 1))"),
                entityType: .transcript,
                entityID: "10000000-0000-4000-8000-\(String(format: "%012d", index + 1))",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000 + Double(index)),
                payload: Data("{\"text\":\"\(String(repeating: "a", count: size))\"}".utf8)
            )
        }

        #expect(try AccountSession.syncPushBatches(pending).map(\.count) == [1, 1])
    }

    @MainActor
    @Test("small sync rows split before the Worker CPU threshold")
    func smallRowsRespectWorkerCPUCountLimit() throws {
        let pending = (0..<101).map { index in
            OutboxMutation(
                id: MutationID(rawValue: "00000000-0000-4000-8000-\(String(format: "%012d", index + 1))"),
                entityType: .vocabulary,
                entityID: "10000000-0000-4000-8000-\(String(format: "%012d", index + 1))",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000 + Double(index)),
                payload: Data("{\"surface\":\"word-\(index)\"}".utf8)
            )
        }

        #expect(try AccountSession.syncPushBatches(pending).map(\.count) == [100, 1])
    }

    @MainActor
    @Test("sync coalesces repeated pending rows for the same entity")
    func synchronizeCoalescesRepeatedPendingEntities() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        let outbox = InMemorySyncOutboxRepository()
        let entityID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        for index in 0..<3 {
            try outbox.enqueue(
                OutboxMutation(
                    id: MutationID(rawValue: "00000000-0000-4000-8000-\(String(format: "%012d", index + 1))"),
                    entityType: .vocabulary,
                    entityID: entityID,
                    operation: .upsert,
                    baseRevision: ServerVersion(Int64(index)),
                    occurredAt: Date(timeIntervalSince1970: 1_777_000_000 + Double(index)),
                    payload: Data("{\"surface\":\"version-\(index)\"}".utf8)
                )
            )
        }
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(client: sync, outbox: outbox, cursor: InMemorySyncCursorStore())
        )
        await session.requestEmailCode("coalesce@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(sync.pushed.flatMap(\.mutations).count == 1)
        #expect(sync.pushed.first?.mutations.first?.baseRevision == 2)
        #expect(sync.pushed.first?.mutations.first?.payload["surface"]?.stringValue == "version-2")
        #expect(try outbox.pendingMutations().isEmpty)
    }

    @MainActor
    @Test("a re-added entity replaces its pending delete intent")
    func synchronizeReplacesPendingDeleteWithReAdd() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        let outbox = InMemorySyncOutboxRepository()
        let entityID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        try outbox.enqueue(
            OutboxMutation(
                id: MutationID(rawValue: "00000000-0000-4000-8000-000000000001"),
                entityType: .vocabulary,
                entityID: entityID,
                operation: .delete,
                baseRevision: ServerVersion(3),
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
                payload: Data("{\"_deleted\":true}".utf8)
            )
        )
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: outbox,
                cursor: InMemorySyncCursorStore(),
                snapshot: {
                    [
                        OutboxMutation(
                            id: MutationID.generate(),
                            entityType: .vocabulary,
                            entityID: entityID,
                            operation: .upsert,
                            baseRevision: .zero,
                            occurredAt: Date(timeIntervalSince1970: 1_777_000_100),
                            payload: Data("{\"surface\":\"restored\"}".utf8)
                        )
                    ]
                }
            )
        )
        await session.requestEmailCode("restore@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        let pushed = try #require(sync.pushed.first?.mutations.first)
        #expect(pushed.operation == OutboxOperation.upsert.rawValue)
        #expect(pushed.baseRevision == 3)
        #expect(pushed.payload["surface"]?.stringValue == "restored")
    }

    @MainActor
    @Test("synchronize pushes pending outbox rows and applies pulled settings")
    func synchronizeDrainsOutboxAndAppliesPull() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        let outbox = InMemorySyncOutboxRepository()
        let cursor = InMemorySyncCursorStore()
        let applied = LockingBox<[SyncPulledChange]>([])
        sync.pullChanges = [
            SyncPulledChange(
                sequence: 1,
                entityType: "settings",
                entityId: "00000000-0000-4000-8000-00000000000a",
                operation: "upsert",
                revision: 1,
                changedAt: "2026-08-26T09:12:04Z",
                payload: ["targetLanguage": .string("ja")]
            )
        ]
        try outbox.enqueue(
            OutboxMutation(
                id: MutationID(rawValue: "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"),
                entityType: .settings,
                entityID: "00000000-0000-4000-8000-00000000000a",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
                payload: Data("{\"targetLanguage\":\"zh\"}".utf8)
            )
        )
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: outbox,
                cursor: cursor,
                applyChange: { change in
                    applied.value.append(change)
                }
            )
        )
        await session.requestEmailCode("sync@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        await session.synchronize()

        #expect(sync.pushed.count == 1)
        #expect(sync.pushed.first?.mutations.first?.entityType == "settings")
        #expect(try outbox.pendingMutations().isEmpty)
        #expect(applied.value.first?.payload["targetLanguage"]?.stringValue == "ja")
        #expect(try cursor.loadCursor() == sync.pullCursor)
        #expect(session.syncStatus.phase == .completed)
        #expect(session.syncStatus.completedCount == 1)
        #expect(session.syncStatus.appliedCount == 1)
        #expect(session.syncStatus.pendingCount == 0)
        #expect(session.syncStatus.entityProgress.first?.entityType == OutboxEntityType.settings.rawValue)
        #expect(session.syncStatus.entityProgress.first?.completedCount == 1)
        await Task.yield()
        let usage = client.recordedUsage.last { $0.name == "sync.completed" }
        #expect(usage?.properties["uploadedCount"] == "1")
        #expect(usage?.properties["appliedCount"] == "1")
        #expect(usage?.properties["pendingCount"] == "0")
    }

    @MainActor
    @Test("conflict leaves a pending retry at the server revision instead of acking success")
    func synchronizeDoesNotAckConflictAsSuccess() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        sync.pushStatus = "conflict"
        sync.conflictRevision = 4
        let outbox = InMemorySyncOutboxRepository()
        let originalID = MutationID(rawValue: "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d")
        try outbox.enqueue(
            OutboxMutation(
                id: originalID,
                entityType: .settings,
                entityID: "00000000-0000-4000-8000-00000000000a",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
                payload: Data("{\"targetLanguage\":\"zh\"}".utf8)
            )
        )
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(client: sync, outbox: outbox, cursor: InMemorySyncCursorStore())
        )
        await session.requestEmailCode("conflict@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        await session.synchronize()

        let pending = try outbox.pendingMutations()
        #expect(pending.count == 1)
        #expect(pending[0].id != originalID)
        #expect(pending[0].baseRevision.rawValue == 4)
        #expect(String(data: pending[0].payload, encoding: .utf8) == "{\"targetLanguage\":\"zh\"}")
        #expect(session.syncStatus.phase == .completed)
        #expect(session.syncStatus.conflictCount == 1)
        #expect(session.syncStatus.pendingCount == 1)
        #expect(session.syncStatus.requiresAttention)
    }

    @MainActor
    @Test("a dirty snapshot does not reset the server revision of a conflict retry")
    func synchronizePreservesConflictRetryRevision() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        sync.pushStatus = "conflict"
        sync.conflictRevision = 7
        let outbox = InMemorySyncOutboxRepository()
        let payload = Data("{\"targetLanguage\":\"zh\"}".utf8)
        let entityID = "00000000-0000-4000-8000-00000000000a"
        try outbox.enqueue(
            OutboxMutation(
                id: MutationID(rawValue: "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"),
                entityType: .settings,
                entityID: entityID,
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
                payload: payload
            )
        )
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: outbox,
                cursor: InMemorySyncCursorStore(),
                snapshot: {
                    [
                        OutboxMutation(
                            id: MutationID.generate(),
                            entityType: .settings,
                            entityID: entityID,
                            operation: .upsert,
                            baseRevision: .zero,
                            occurredAt: Date(timeIntervalSince1970: 1_777_000_100),
                            payload: payload
                        )
                    ]
                }
            )
        )
        await session.requestEmailCode("retry-revision@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        await session.synchronize()
        sync.pushStatus = "applied"

        await session.synchronize()

        #expect(sync.pushed.count == 2)
        #expect(sync.pushed[1].mutations.first?.baseRevision == 7)
        #expect(try outbox.pendingMutations().isEmpty)
    }

    @MainActor
    @Test("sync failure keeps pending work visible with the error")
    func synchronizePublishesFailureAndPendingCount() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let outbox = InMemorySyncOutboxRepository()
        try outbox.enqueue(
            OutboxMutation(
                id: MutationID(rawValue: "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"),
                entityType: .vocabulary,
                entityID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
                payload: Data("{\"surface\":\"ice\"}".utf8)
            )
        )
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: FailingSyncClient(),
                outbox: outbox,
                cursor: InMemorySyncCursorStore()
            )
        )
        await session.requestEmailCode("failure@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        await session.synchronize()

        #expect(session.syncStatus.phase == .failed)
        #expect(session.syncStatus.pendingCount == 1)
        #expect(session.syncStatus.errorMessage == "The sync service is unavailable.")
        await Task.yield()
        let usage = client.recordedUsage.last { $0.name == "sync.failed" }
        #expect(usage?.outcome == "failed")
        #expect(usage?.properties["pendingCount"] == "1")
        #expect(session.syncStatus.requiresAttention)
    }

    @MainActor
    @Test("overlay conflicts expose the server revision before the retry is queued")
    func overlayConflictInvokesRetentionHook() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        sync.pushStatus = "conflict"
        sync.conflictRevision = 9
        let outbox = InMemorySyncOutboxRepository()
        let handledType = LockingBox<String?>(nil)
        let handledRevision = LockingBox<Int64?>(nil)
        try outbox.enqueue(
            OutboxMutation(
                id: MutationID(rawValue: "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"),
                entityType: .transcriptOverlay,
                entityID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
                payload: Data("{\"segmentId\":\"segment\"}".utf8)
            )
        )
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: outbox,
                cursor: InMemorySyncCursorStore(),
                handleConflict: { mutation, revision in
                    handledType.value = mutation.entityType.rawValue
                    handledRevision.value = revision
                }
            )
        )
        await session.requestEmailCode("overlay-conflict@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        await session.synchronize()

        #expect(handledType.value == OutboxEntityType.transcriptOverlay.rawValue)
        #expect(handledRevision.value == 9)
        #expect(try outbox.pendingMutations().first?.baseRevision.rawValue == 9)
    }

    @MainActor
    @Test("pull continues while hasMore instead of treating the first page as complete")
    func synchronizeLoopsPullWhileHasMore() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        let applied = LockingBox<[SyncPulledChange]>([])
        sync.pullPages = [
            SyncPullResponse(
                changes: [
                    SyncPulledChange(
                        sequence: 1,
                        entityType: "settings",
                        entityId: "00000000-0000-4000-8000-00000000000a",
                        operation: "upsert",
                        revision: 1,
                        changedAt: "2026-08-26T09:12:04Z",
                        payload: ["targetLanguage": .string("ja")]
                    )
                ],
                cursor: "1",
                hasMore: true
            ),
            SyncPullResponse(
                changes: [
                    SyncPulledChange(
                        sequence: 2,
                        entityType: "vocabulary",
                        entityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                        operation: "upsert",
                        revision: 1,
                        changedAt: "2026-08-26T09:12:05Z",
                        payload: ["surface": .string("ice")]
                    )
                ],
                cursor: "2",
                hasMore: false
            )
        ]
        let cursor = InMemorySyncCursorStore()
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: cursor,
                applyChange: { change in
                    applied.value.append(change)
                }
            )
        )
        await session.requestEmailCode("pages@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        await session.synchronize()

        #expect(sync.pulledCursors == ["0", "1"])
        #expect(applied.value.map(\.sequence) == [1, 2])
        #expect(try cursor.loadCursor() == "2")
    }

    @MainActor
    @Test("a push does not skip an unseen change written by another device")
    func synchronizePullsFromLastAcknowledgedCursorAfterInterleavedPush() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = TwoDeviceInterleavingSyncClient()
        let outbox = InMemorySyncOutboxRepository()
        let cursor = InMemorySyncCursorStore()
        let applied = LockingBox<[SyncPulledChange]>([])
        try outbox.enqueue(
            OutboxMutation(
                id: MutationID(rawValue: "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"),
                entityType: .vocabulary,
                entityID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                operation: .upsert,
                baseRevision: .zero,
                occurredAt: Date(timeIntervalSince1970: 1_777_000_001),
                payload: Data("{\"surface\":\"ice\"}".utf8)
            )
        )
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: outbox,
                cursor: cursor,
                applyChange: { change in applied.value.append(change) }
            )
        )
        await session.requestEmailCode("interleaved@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(await sync.pushedBaseCursors() == ["0"])
        #expect(await sync.pulledCursors() == ["0"])
        #expect(applied.value.map(\.sequence).sorted() == [1, 2])
        #expect(try cursor.loadCursor() == "2")
        #expect(try outbox.pendingMutations().isEmpty)
    }

    @MainActor
    @Test("a failed local apply does not advance entity version or pull cursor")
    func synchronizeDoesNotAcknowledgeFailedApply() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        sync.pullCursor = "1"
        sync.pullChanges = [
            SyncPulledChange(
                sequence: 1,
                entityType: OutboxEntityType.vocabulary.rawValue,
                entityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                operation: OutboxOperation.upsert.rawValue,
                revision: 1,
                changedAt: "2026-08-30T00:00:00Z",
                payload: ["surface": .string("ice")]
            )
        ]
        let cursor = InMemorySyncCursorStore()
        let versions = InMemorySyncEntityVersionStore()
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: cursor,
                versions: versions,
                applyChange: { _ in throw TestSyncError.localApplyFailed }
            )
        )
        await session.requestEmailCode("apply-failure@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(session.syncStatus.phase == .failed)
        #expect(try cursor.loadCursor() == "0")
        #expect(try versions.loadVersion(
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        ) == nil)
    }

    @MainActor
    @Test("pulled deletes store an explicit tombstone marker and apply after dependent rows")
    func synchronizePersistsDeletionMarker() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        let vocabularyID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let deletion = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityId: vocabularyID,
            operation: OutboxOperation.delete.rawValue,
            revision: 2,
            changedAt: "2026-08-30T00:01:00Z",
            payload: [:]
        )
        let review = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.reviewEvent.rawValue,
            entityId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            operation: OutboxOperation.append.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: ["vocabularyId": .string(vocabularyID)]
        )
        sync.pullChanges = [deletion, review]
        sync.pullCursor = "2"
        let versions = InMemorySyncEntityVersionStore()
        let applied = LockingBox<[SyncPulledChange]>([])
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: InMemorySyncCursorStore(),
                versions: versions,
                applyChange: { applied.value.append($0) }
            )
        )
        await session.requestEmailCode("delete-marker@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(applied.value.map(\.entityType) == [review.entityType, deletion.entityType])
        let version = try #require(try versions.loadVersion(
            entityType: deletion.entityType,
            entityID: deletion.entityId
        ))
        #expect(
            try JSONDecoder().decode([String: SyncJSONValue].self, from: version.payload)["_deleted"]
                == .bool(true)
        )
    }

    @MainActor
    @Test("pull page cap remains an attention state while the server has more")
    func synchronizeDoesNotCompleteAtPullPageCap() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        sync.pullPages = (1...64).map { page in
            SyncPullResponse(changes: [], cursor: "\(page)", hasMore: true)
        }
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: InMemorySyncCursorStore()
            )
        )
        await session.requestEmailCode("page-cap@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(sync.pulledCursors.count == 64)
        #expect(session.syncStatus.phase == .failed)
        #expect(session.syncStatus.requiresAttention)
        #expect(session.syncStatus.errorMessage?.contains("More sync changes remain") == true)
    }

    @MainActor
    @Test("concurrent synchronize callers share one in-flight drain")
    func synchronizeIsSingleFlight() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = SuspendedSyncClient()
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: InMemorySyncCursorStore()
            )
        )
        await session.requestEmailCode("single-flight@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        let first = Task { await session.synchronize() }
        await sync.waitUntilPullStarts()
        let second = Task { await session.synchronize() }
        await Task.yield()

        #expect(await sync.pullCount == 1)
        await sync.releasePull()
        await first.value
        await second.value
        #expect(await sync.pullCount == 1)
        #expect(session.syncStatus.phase == .completed)
    }

    @MainActor
    @Test("reverting to the last applied payload cancels a stale pending mutation")
    func synchronizeCancelsRevertedSnapshotMutation() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        let outbox = InMemorySyncOutboxRepository()
        let versions = InMemorySyncEntityVersionStore()
        let entityID = "00000000-0000-4000-8000-00000000000a"
        let appliedPayload = Data("{\"targetLanguage\":\"zh\"}".utf8)
        try versions.saveVersion(
            SyncEntityVersion(
                entityType: OutboxEntityType.settings.rawValue,
                entityID: entityID,
                serverVersion: 4,
                payload: appliedPayload
            )
        )
        try outbox.enqueue(
            OutboxMutation(
                id: MutationID(rawValue: "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"),
                entityType: .settings,
                entityID: entityID,
                operation: .upsert,
                baseRevision: ServerVersion(4),
                occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
                payload: Data("{\"targetLanguage\":\"ja\"}".utf8)
            )
        )
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: outbox,
                cursor: InMemorySyncCursorStore(),
                versions: versions,
                snapshot: {
                    [
                        OutboxMutation(
                            id: MutationID.generate(),
                            entityType: .settings,
                            entityID: entityID,
                            operation: .upsert,
                            baseRevision: .zero,
                            occurredAt: Date(timeIntervalSince1970: 1_777_000_100),
                            payload: appliedPayload
                        )
                    ]
                }
            )
        )
        await session.requestEmailCode("reverted@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(sync.pushed.isEmpty)
        #expect(try outbox.pendingMutations().isEmpty)
        #expect(session.syncStatus.pendingCount == 0)
    }

    @MainActor
    @Test("unchanged snapshot payloads are not pushed again")
    func synchronizeSkipsUnchangedSnapshotRows() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        let outbox = InMemorySyncOutboxRepository()
        let versions = InMemorySyncEntityVersionStore()
        let payload = Data("{\"targetLanguage\":\"zh\"}".utf8)
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: outbox,
                cursor: InMemorySyncCursorStore(),
                versions: versions,
                snapshot: {
                    [
                        OutboxMutation(
                            id: MutationID.generate(),
                            entityType: .settings,
                            entityID: "00000000-0000-4000-8000-00000000000a",
                            operation: .upsert,
                            baseRevision: .zero,
                            occurredAt: Date(),
                            payload: payload
                        )
                    ]
                }
            )
        )
        await session.requestEmailCode("dirty@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        await session.synchronize()
        await session.synchronize()

        #expect(sync.pushed.count == 1)
        #expect(try outbox.pendingMutations().isEmpty)
        #expect(try versions.loadVersion(entityType: "settings", entityID: "00000000-0000-4000-8000-00000000000a")?.serverVersion == 1)
    }
}

private struct FailingSyncClient: SyncClient {
    func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        throw TestSyncError.unavailable
    }

    func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        throw TestSyncError.unavailable
    }
}

private enum TestSyncError: LocalizedError {
    case unavailable
    case localApplyFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "The sync service is unavailable."
        case .localApplyFailed: "The local sync change could not be saved."
        }
    }
}

private actor SuspendedSyncClient: SyncClient {
    private(set) var pullCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        SyncPushResponse(batchId: request.batchId, results: [], cursor: "0")
    }

    func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        pullCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return SyncPullResponse(changes: [], cursor: cursor, hasMore: false)
    }

    func waitUntilPullStarts() async {
        guard pullCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releasePull() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Models device B writing sequence 1 before device A pushes sequence 2. The push cursor is
/// the server high-water mark, not proof that device A has applied either sequence locally.
private actor TwoDeviceInterleavingSyncClient: SyncClient {
    private var changes = [
        SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.settings.rawValue,
            entityId: "00000000-0000-4000-8000-00000000000a",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: ["targetLanguage": .string("ja")]
        )
    ]
    private var baseCursors: [String] = []
    private var pullHistory: [String] = []

    func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        _ = accessToken
        _ = deviceID
        baseCursors.append(request.baseCursor ?? "")
        let mutation = try #require(request.mutations.first)
        changes.append(
            SyncPulledChange(
                sequence: 2,
                entityType: mutation.entityType,
                entityId: mutation.entityId,
                operation: mutation.operation,
                revision: 1,
                changedAt: mutation.occurredAt,
                payload: mutation.payload
            )
        )
        return SyncPushResponse(
            batchId: request.batchId,
            results: [
                SyncMutationResult(
                    mutationId: mutation.mutationId,
                    status: "applied",
                    entityRevision: 1
                )
            ],
            cursor: "2"
        )
    }

    func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        _ = accessToken
        _ = deviceID
        pullHistory.append(cursor)
        let after = Int(cursor) ?? 0
        let page = Array(changes.filter { $0.sequence > after }.prefix(limit))
        let nextCursor = page.last.map { String($0.sequence) } ?? cursor
        return SyncPullResponse(
            changes: page,
            cursor: nextCursor,
            hasMore: changes.contains { $0.sequence > (Int(nextCursor) ?? after) }
        )
    }

    func pushedBaseCursors() -> [String] {
        baseCursors
    }

    func pulledCursors() -> [String] {
        pullHistory
    }
}

private final class LockingBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}
