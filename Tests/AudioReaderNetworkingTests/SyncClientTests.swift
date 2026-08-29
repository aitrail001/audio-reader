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
