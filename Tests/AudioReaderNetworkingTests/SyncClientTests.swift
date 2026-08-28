import Foundation
import Testing
@testable import AudioReaderLocalStore
@testable import AudioReaderNetworking

@Suite("Product sync client")
struct SyncClientTests {
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
