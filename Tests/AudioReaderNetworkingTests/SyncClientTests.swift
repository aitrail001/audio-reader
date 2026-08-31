import CryptoKit
import Foundation
import Testing
@testable import AudioReaderLocalStore
@testable import AudioReaderNetworking

private func syncAssetFile(_ bytes: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioReaderSyncTest-\(UUID().uuidString).object")
    try bytes.write(to: url)
    return url
}

@Suite("Product sync client")
struct SyncClientTests {
    @MainActor
    @Test("Native refuses a new sync request when bootstrap says effective sync is unavailable")
    func unavailableBootstrapPreventsEnablingSync() async {
        let auth = FakeAuthClient()
        auth.bootstrapReadiness = AccountSyncReadiness(
            schemaReady: true,
            provider: "r2",
            bucket: "ASSETS",
            credentialStatus: "failed",
            ready: false,
            requested: false,
            effective: false,
            reason: "storage_credentials_invalid",
            retryAfterSeconds: 5
        )
        let session = AccountSession.isolated(client: auth)
        await session.requestEmailCode("unavailable-sync@example.com")
        await session.verifyEmailCode("123456")

        session.setSyncEnabled(true)

        #expect(session.mode == .signedInSyncOff)
        #expect(session.errorMessage?.contains("storage credentials") == true)
    }

    @MainActor
    @Test("A storage outage pauses without local mutation and automatically resumes after recovery")
    func storageOutagePausesWithoutMutationAndLaterResumes() async throws {
        let auth = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        let outbox = InMemorySyncOutboxRepository()
        let cursor = InMemorySyncCursorStore(cursor: "7")
        let mutation = OutboxMutation(
            id: MutationID(rawValue: "00000000-0000-4000-8000-000000000101"),
            entityType: .vocabulary,
            entityID: "10000000-0000-4000-8000-000000000101",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
            payload: Data(#"{"surface":"pause"}"#.utf8)
        )
        try outbox.enqueue(mutation)
        let session = AccountSession(
            client: auth,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(client: sync, outbox: outbox, cursor: cursor)
        )
        await session.requestEmailCode("paused-sync@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        try cursor.saveCursor("7")
        auth.bootstrapReadiness = AccountSyncReadiness(
            schemaReady: true,
            provider: "gcs",
            bucket: "private-sync",
            credentialStatus: "failed",
            uploadStatus: "not_checked",
            downloadStatus: "not_checked",
            checksumStatus: "not_checked",
            deleteStatus: "not_checked",
            notFoundStatus: "not_checked",
            ready: false,
            requested: true,
            effective: false,
            reason: "storage_credentials_invalid",
            retryAfterSeconds: 1,
            lastFailureAt: "2026-08-31T00:00:00Z",
            lastFailureCode: "storage_credentials_invalid",
            lastFailureDetail: "Object storage credentials could not access the configured bucket."
        )

        await session.synchronize()

        #expect(session.mode == .signedInSyncOn)
        #expect(session.syncStatus.phase == .paused)
        #expect(session.syncStatus.detail.contains("storage credentials"))
        #expect(try outbox.pendingMutations().map(\.id) == [mutation.id])
        #expect(try cursor.loadCursor() == "7")
        #expect(sync.pushed.isEmpty)

        auth.bootstrapReadiness = AccountSyncReadiness()
        try await Task.sleep(for: .milliseconds(1_200))

        #expect(session.syncStatus.phase == .completed)
        #expect(try outbox.pendingMutations().isEmpty)
    }

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
        #expect(http.requests.first?.path == "/v2/sync/push")
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
        #expect(http.requests.last?.path.contains("/v2/sync/pull") == true)
    }

    @Test("bootstrap reads latest entity state, manifest hashes, and a consistent cursor")
    func bootstrapRoundTrip() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 200,
            json: """
            {"entities":[{"sequence":7,"entityType":"vocabulary","entityId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","operation":"upsert","revision":3,"changedAt":"2026-08-30T00:00:00Z","payload":{"surface":"loom"},"payloadHash":"5c35de2d8919d3cfad1fc83bf4857a41dbf9c45ca9ffbee8145ad3605617f436"}],"cursor":"9","nextOffset":1,"hasMore":false}
            """
        )
        let client = ProductSyncClient(http: http)

        let bootstrapped = try await client.bootstrap(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            cursor: nil,
            offset: 0,
            limit: 100
        )

        #expect(bootstrapped.cursor == "9")
        #expect(bootstrapped.entities.first?.revision == 3)
        #expect(bootstrapped.entities.first?.payloadHash.count == 64)
        #expect(http.requests.first?.path.contains("/v2/sync/bootstrap?offset=0&limit=100") == true)
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
    @Test("pull work is applied off-main once per page and progress publishes at page boundaries")
    func syncAppliesOneOffMainTransactionPerPage() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        sync.pullPages = [
            SyncPullResponse(
                changes: (1...100).map { index in
                    SyncPulledChange(
                        sequence: index,
                        entityType: "vocabulary",
                        entityId: String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", index),
                        operation: "upsert",
                        revision: 1,
                        changedAt: "2026-08-30T00:00:00Z",
                        payload: ["surface": .string("word-\(index)")]
                    )
                },
                cursor: "100",
                hasMore: false
            )
        ]
        let pageCalls = LockingBox<[(Int, String, Bool)]>([])
        let preApplyStatus = LockingBox<AccountSyncStatus?>(nil)
        let sessionBox = LockingBox<AccountSession?>(nil)
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: InMemorySyncCursorStore(cursor: "1"),
                applyPage: { changes, _, cursor in
                    let recorded = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        preApplyStatus.value = sessionBox.value?.syncStatus
                        recorded.signal()
                    }
                    guard recorded.wait(timeout: .now() + 2) == .success else {
                        throw StatusObservationError.timedOut
                    }
                    pageCalls.value.append((changes.count, cursor, Thread.isMainThread))
                }
            )
        )
        sessionBox.value = session
        await session.requestEmailCode("page@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(pageCalls.value.count == 1)
        #expect(pageCalls.value.first?.0 == 100)
        #expect(pageCalls.value.first?.1 == "100")
        #expect(pageCalls.value.first?.2 == false)
        #expect(preApplyStatus.value?.phase == .applying)
        #expect(preApplyStatus.value?.completedCount == 0)
        #expect(preApplyStatus.value?.totalCount == 100)
        #expect(session.syncStatus.completedCount == 0)
        #expect(session.syncStatus.appliedCount == 100)
    }

    @MainActor
    @Test("a failed page never reports uncommitted records as completed")
    func failedPageDoesNotPublishCompletedProgress() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        sync.pullChanges = [
            SyncPulledChange(
                sequence: 1,
                entityType: OutboxEntityType.vocabulary.rawValue,
                entityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                operation: OutboxOperation.upsert.rawValue,
                revision: 1,
                changedAt: "2026-08-30T00:00:00Z",
                payload: ["surface": .string("loom")]
            )
        ]
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: InMemorySyncCursorStore(cursor: "1"),
                applyPage: { _, _, _ in throw StatusObservationError.applyFailed }
            )
        )
        await session.requestEmailCode("page-failure@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(session.syncStatus.phase == .failed)
        #expect(session.syncStatus.completedCount == 0)
        #expect(session.syncStatus.appliedCount == 0)
    }

    @MainActor
    @Test("a committed page reports completion before the next download begins")
    func committedPagePublishesCompletedProgress() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = TwoPageGatedSyncClient()
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: InMemorySyncCursorStore(cursor: "1"),
                applyPage: { _, _, _ in }
            )
        )
        await session.requestEmailCode("page-success@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        let syncTask = Task { await session.synchronize() }
        await sync.waitUntilSecondPullStarts()

        #expect(session.syncStatus.phase == .downloading)
        #expect(session.syncStatus.completedCount == 1)

        await sync.releaseSecondPull()
        await syncTask.value
        #expect(session.syncStatus.appliedCount == 1)
    }

    @MainActor
    @Test("bootstrap manifest prevents unchanged local uploads and the immediate second sync is empty")
    func bootstrapManifestSkipsIdenticalLocalRows() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6")
        let sync = FakeSyncClient()
        sync.pullCursor = "5"
        let payload = Data("{ \"surface\" : \"loom\", \"metadata\" : { \"level\" : 2, \"tags\" : [ { \"b\" : 2, \"a\" : 1 } ] } }".utf8)
        let serverPayload: [String: SyncJSONValue] = [
            "metadata": .object([
                "tags": .array([.object(["a": .number(1), "b": .number(2)])]),
                "level": .number(2)
            ]),
            "surface": .string("loom")
        ]
        let serverManifestBytes = Data("{\"metadata\":{\"level\":2,\"tags\":[{\"a\":1,\"b\":2}]},\"surface\":\"loom\"}".utf8)
        sync.bootstrapPages = [
            SyncBootstrapResponse(
                entities: [
                    SyncBootstrapEntity(
                        sequence: 5,
                        entityType: OutboxEntityType.vocabulary.rawValue,
                        entityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                        operation: OutboxOperation.upsert.rawValue,
                        revision: 3,
                        changedAt: "2026-08-30T00:00:00Z",
                        payload: serverPayload,
                        payloadHash: SyncJSONCoding.payloadHash(serverManifestBytes)
                    )
                ],
                cursor: "5",
                nextOffset: 1,
                hasMore: false
            )
        ]
        let outbox = InMemorySyncOutboxRepository()
        let cursor = InMemorySyncCursorStore()
        let versions = InMemorySyncEntityVersionStore()
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: outbox,
                cursor: cursor,
                versions: versions,
                snapshot: {
                    [
                        OutboxMutation(
                            id: MutationID.generate(),
                            entityType: .vocabulary,
                            entityID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                            operation: .upsert,
                            baseRevision: .zero,
                            occurredAt: Date(),
                            payload: payload
                        )
                    ]
                }
            )
        )
        await session.requestEmailCode("manifest@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()
        await session.synchronize()

        #expect(sync.pushed.isEmpty)
        #expect(sync.pulledCursors == ["5", "5"])
        #expect(try outbox.pendingMutations().isEmpty)
        #expect(try cursor.loadCursor() == "5")
        #expect(session.syncStatus.appliedCount == 0)
    }

    @MainActor
    @Test("a new device hydrates and verifies transcript manifests during bootstrap before committing its cursor")
    func bootstrapHydratesTranscriptManifestBeforeApply() async throws {
        let auth = FakeAuthClient()
        let sync = FakeSyncClient()
        let bytes = Data(#"{"chapterID":"local-chapter","segments":[]}"#.utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let assetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let revisionID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        sync.seedAssetBody(assetID: assetID, bytes: bytes)
        sync.pullCursor = "7"
        sync.bootstrapPages = [
            SyncBootstrapResponse(
                entities: [
                    SyncBootstrapEntity(
                        sequence: 7,
                        entityType: OutboxEntityType.transcript.rawValue,
                        entityId: revisionID,
                        operation: OutboxOperation.upsert.rawValue,
                        revision: 1,
                        changedAt: "2026-08-31T00:00:00Z",
                        payload: [
                            "assetId": .string(assetID),
                            "revisionId": .string(revisionID),
                            "chapterId": .string("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
                            "sha256": .string(sha),
                            "encoding": .string("identity-json-v1"),
                            "compressedBytes": .number(Double(bytes.count)),
                            "originalBytes": .number(Double(bytes.count)),
                            "segmentCount": .number(0),
                        ],
                        payloadHash: SyncJSONCoding.payloadHash(
                            SyncJSONCoding.data(from: ["assetId": .string(assetID)])
                        )
                    )
                ],
                cursor: "7",
                nextOffset: 1,
                hasMore: false
            )
        ]
        let cursor = InMemorySyncCursorStore()
        let hydrated = LockingBox<(bytes: Data?, path: String?)>((nil, nil))
        let session = AccountSession(
            client: auth,
            store: InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6"),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: cursor,
                snapshot: { [] },
                applyPage: { changes, _, committedCursor in
                    if let path = changes.first?.payload["localObjectPath"]?.stringValue {
                        hydrated.value = (try Data(contentsOf: URL(fileURLWithPath: path)), path)
                    }
                    try cursor.saveCursor(committedCursor)
                }
            )
        )
        await session.requestEmailCode("bootstrap-transcript@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(hydrated.value.bytes == bytes)
        #expect(try cursor.loadCursor() == "7")
        #expect(hydrated.value.path.map { !FileManager.default.fileExists(atPath: $0) } == true)
    }

    @MainActor
    @Test("a failed bootstrap download removes earlier transcript temp files and keeps the cursor")
    func bootstrapTranscriptDownloadFailureCleansTempsAndRollsBackCursor() async throws {
        let auth = FakeAuthClient()
        let sync = FakeSyncClient()
        let bytes = Data(#"{"chapterID":"local-chapter","segments":[]}"#.utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let presentAssetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        sync.seedAssetBody(assetID: presentAssetID, bytes: bytes)
        let manifest: (Int, String, String) -> SyncBootstrapEntity = { sequence, assetID, revisionID in
            SyncBootstrapEntity(
                sequence: sequence,
                entityType: OutboxEntityType.transcript.rawValue,
                entityId: revisionID,
                operation: OutboxOperation.upsert.rawValue,
                revision: 1,
                changedAt: "2026-08-31T00:00:00Z",
                payload: [
                    "assetId": .string(assetID),
                    "revisionId": .string(revisionID),
                    "chapterId": .string("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
                    "sha256": .string(sha),
                    "encoding": .string("identity-json-v1"),
                    "compressedBytes": .number(Double(bytes.count)),
                    "originalBytes": .number(Double(bytes.count)),
                    "segmentCount": .number(0),
                ],
                payloadHash: sha
            )
        }
        sync.bootstrapPages = [
            SyncBootstrapResponse(
                entities: [
                    manifest(1, presentAssetID, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1"),
                    manifest(
                        2,
                        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2",
                        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
                    ),
                ],
                cursor: "2",
                nextOffset: 2,
                hasMore: false
            )
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderSyncAssets-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        let cursor = InMemorySyncCursorStore()
        let applied = LockingBox(false)
        let session = AccountSession(
            client: auth,
            store: InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6"),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: cursor,
                snapshot: { [] },
                applyPage: { _, _, _ in applied.value = true }
            )
        )
        await session.requestEmailCode("bootstrap-transcript-failure@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(session.syncStatus.phase == .failed)
        #expect(!applied.value)
        #expect(try cursor.loadCursor() == "0")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == before)
    }

    @MainActor
    @Test("a new device discovers and hydrates every v2 immutable asset kind before cursor commit")
    func bootstrapHydratesEveryAssetKind() async throws {
        let auth = FakeAuthClient()
        let sync = FakeSyncClient()
        var expected: [String: Data] = [:]
        let entities = SyncAssetKind.allCases.enumerated().map { index, kind in
            let assetID = String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", index + 1)
            let entityID = String(format: "bbbbbbbb-bbbb-4bbb-8bbb-%012d", index + 1)
            let bytes = kind == .transcriptRevision
                ? Data(#"{"segments":[]}"#.utf8) : Data([UInt8(index + 1)])
            let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            sync.seedAssetBody(assetID: assetID, bytes: bytes, kind: kind)
            expected[kind.rawValue] = bytes
            return SyncBootstrapEntity(
                sequence: index + 1,
                entityType: kind == .transcriptRevision
                    ? OutboxEntityType.transcript.rawValue : OutboxEntityType.asset.rawValue,
                entityId: entityID, operation: OutboxOperation.upsert.rawValue,
                revision: 1, changedAt: "2026-08-31T00:00:00Z",
                payload: [
                    "assetId": .string(assetID), "kind": .string(kind.rawValue),
                    "revisionId": .string(entityID), "sha256": .string(sha),
                    "encoding": .string(kind == .transcriptRevision ? "identity-json-v1" : "identity"),
                    "compressedBytes": .number(Double(bytes.count)),
                    "originalBytes": .number(Double(bytes.count)),
                    "segmentCount": kind == .transcriptRevision ? .number(0) : .null,
                ],
                payloadHash: sha
            )
        }
        sync.bootstrapPages = [SyncBootstrapResponse(
            entities: entities, cursor: "11", nextOffset: 11, hasMore: false
        )]
        sync.pullCursor = "11"
        let cursor = InMemorySyncCursorStore()
        let hydrated = LockingBox<[String: Data]>([:])
        let session = AccountSession(
            client: auth, store: InMemoryAuthSessionStore(),
            oauth: ScriptedOAuthBrowserSession.passthrough(), environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync, outbox: InMemorySyncOutboxRepository(), cursor: cursor,
                snapshot: { [] },
                applyPage: { changes, _, committedCursor in
                    for change in changes {
                        guard let kind = change.payload["kind"]?.stringValue,
                              let path = change.payload["localObjectPath"]?.stringValue else { continue }
                        hydrated.value[kind] = try Data(contentsOf: URL(fileURLWithPath: path))
                    }
                    try cursor.saveCursor(committedCursor)
                }
            )
        )
        await session.requestEmailCode("bootstrap-all-assets@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        await session.synchronize()

        #expect(hydrated.value == expected)
        #expect(try cursor.loadCursor() == "11")
    }

    @MainActor
    @Test("native hydration resolves an announced 501st asset directly by ID")
    func hydrationResolvesAssetBeyondDiscoveryWindow() async throws {
        let auth = FakeAuthClient()
        let sync = FakeSyncClient()
        var targetID = ""
        var targetBytes = Data()
        for index in 0...500 {
            let assetID = String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", index + 1)
            let bytes = Data([UInt8(index % 251)])
            sync.seedAssetBody(assetID: assetID, bytes: bytes, kind: .cover)
            targetID = assetID
            targetBytes = bytes
        }
        let sha = SHA256.hash(data: targetBytes).map { String(format: "%02x", $0) }.joined()
        sync.bootstrapPages = [SyncBootstrapResponse(entities: [SyncBootstrapEntity(
            sequence: 1, entityType: OutboxEntityType.asset.rawValue,
            entityId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", operation: OutboxOperation.upsert.rawValue,
            revision: 1, changedAt: "2026-08-31T00:00:00Z",
            payload: [
                "assetId": .string(targetID), "kind": .string(SyncAssetKind.cover.rawValue),
                "sha256": .string(sha), "encoding": .string("identity"),
                "compressedBytes": .number(Double(targetBytes.count)),
                "originalBytes": .number(Double(targetBytes.count)),
            ], payloadHash: sha
        )], cursor: "1", nextOffset: 1, hasMore: false)]
        sync.pullCursor = "1"
        let cursor = InMemorySyncCursorStore()
        let hydrated = LockingBox<Data?>(nil)
        let session = AccountSession(
            client: auth, store: InMemoryAuthSessionStore(),
            oauth: ScriptedOAuthBrowserSession.passthrough(), environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync, outbox: InMemorySyncOutboxRepository(), cursor: cursor,
                snapshot: { [] },
                applyPage: { changes, _, committedCursor in
                    if let path = changes.first?.payload["localObjectPath"]?.stringValue {
                        hydrated.value = try Data(contentsOf: URL(fileURLWithPath: path))
                    }
                    try cursor.saveCursor(committedCursor)
                }
            )
        )
        await session.requestEmailCode("direct-asset@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()

        #expect(hydrated.value == targetBytes)
        #expect(sync.manifestLookups == [targetID])
        #expect(sync.discoveryQueryCount == 0)
        #expect(try cursor.loadCursor() == "1")
    }

    @Test("payload hashing canonicalizes JSON but preserves raw fallback semantics")
    func payloadHashCanonicalizesJSON() {
        let left = Data("{ \"z\": [ { \"b\": 2, \"a\": 1 } ], \"a\": { \"y\": true, \"x\": null } }".utf8)
        let right = Data("{\"a\":{\"x\":null,\"y\":true},\"z\":[{\"a\":1,\"b\":2}]}".utf8)
        #expect(SyncJSONCoding.payloadHash(left) == SyncJSONCoding.payloadHash(right))

        let malformed = Data("not-json".utf8)
        let expectedRawHash = SHA256.hash(data: malformed).map { String(format: "%02x", $0) }.joined()
        #expect(SyncJSONCoding.payloadHash(malformed) == expectedRawHash)
    }

    @Test("transcript revisions use the private v2 asset lifecycle")
    func transcriptRevisionPublishesAsPrivateAsset() async throws {
        let http = StubHTTPClient()
        let bytes = Data(#"{"chapterID":"chapter","segments":[]}"#.utf8)
        let fileURL = try syncAssetFile(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        http.enqueue(status: 200, json: #"{"uploadId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","url":"https://objects.example/private/v2/pending/upload"}"#)
        http.enqueue(status: 200, body: Data())
        http.enqueue(status: 200, json: #"{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","status":"ready"}"#)

        try await ProductSyncClient(http: http).publishAsset(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            asset: SyncAssetUpload(
                revisionID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                chapterID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                sha256: sha,
                originalBytes: bytes.count,
                segmentCount: 0,
                fileURL: fileURL,
                compressedBytes: bytes.count
            )
        )

        #expect(http.requests.map(\.path) == [
            "/v2/assets/uploads",
            "https://objects.example/private/v2/pending/upload",
            "/v2/assets/uploads/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/complete",
        ])
        #expect(http.requests[1].body == nil)
        #expect(http.uploadedFiles == [fileURL])
        #expect(http.requests[1].headers["Authorization"] == nil)
        let draft = try #require(http.requests.first?.body)
        #expect(!String(decoding: draft, as: UTF8.self).contains("transcriptJSON"))
    }

    @Test("a ready content-addressed revision skips duplicate object transfer")
    func readyTranscriptRevisionSkipsTransfer() async throws {
        let http = StubHTTPClient()
        let bytes = Data(#"{"segments":[]}"#.utf8)
        let fileURL = try syncAssetFile(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        http.enqueue(
            status: 200,
            json: #"{"uploadId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","url":"https://objects.example/private/v2/pending/upload","ready":true}"#
        )

        try await ProductSyncClient(http: http).publishAsset(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            asset: SyncAssetUpload(
                revisionID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                chapterID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                sha256: sha,
                originalBytes: bytes.count,
                segmentCount: 0,
                fileURL: fileURL,
                compressedBytes: bytes.count
            )
        )

        #expect(http.requests.map(\.path) == ["/v2/assets/uploads"])
    }

    @Test("asset download rejects bytes before local commit when checksum differs")
    func transcriptRevisionDownloadChecksIntegrity() async {
        let http = StubHTTPClient()
        http.enqueue(status: 200, json: #"{"url":"https://objects.example/private/v2/revision"}"#)
        http.enqueue(status: 200, body: Data("tampered".utf8))

        await #expect(throws: (any Error).self) {
            _ = try await ProductSyncClient(http: http).downloadAsset(
                accessToken: "access",
                deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                assetID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                sha256: String(repeating: "0", count: 64),
                compressedBytes: 8
            )
        }
        #expect(http.requests[1].path == "https://objects.example/private/v2/revision")
        #expect(http.requests[1].headers["Authorization"] == nil)
    }

    @Test("shared iPad asset hashing keeps large sparse files within the fixed chunk bound")
    func largeAssetHashingIsBounded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderSparse-\(UUID().uuidString).object")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 32 * 1024 * 1024)
        try handle.close()

        let digest = try SyncAssetFileIO.digest(fileURL: url)

        #expect(digest.byteCount == 32 * 1024 * 1024)
        #expect(digest.maximumChunkBytes <= SyncAssetFileIO.chunkBytes)
    }

    @MainActor
    @Test("producer failure cleans every partially generated asset temp")
    func assetProducerFailureCleansScopedTemps() async throws {
        let fixture = try AssetCleanupFixture()
        defer { fixture.remove() }
        let sync = CleanupAssetSyncClient(mode: .success)
        let staging = LockingBox<URL?>(nil)
        let session = await cleanupSession(client: sync) { directory in
            staging.value = directory
            try fixture.writeGeneratedFiles(in: directory)
            throw TestSyncError.localApplyFailed
        }

        await session.synchronize()

        #expect(fixture.contents == fixture.baseline)
        #expect(FileManager.default.fileExists(atPath: fixture.userOwnedFile.path))
        #expect(staging.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @MainActor
    @Test("early upload failure cleans later unattempted transcript and EPUB temps")
    func assetUploadFailureCleansAllScopedTemps() async throws {
        let fixture = try AssetCleanupFixture()
        defer { fixture.remove() }
        let sync = CleanupAssetSyncClient(mode: .failure)
        let staging = LockingBox<URL?>(nil)
        let session = await cleanupSession(client: sync) { directory in
            staging.value = directory
            return try fixture.generatedUploads(in: directory)
        }

        await session.synchronize()

        #expect(await sync.publishCount == 1)
        #expect(fixture.contents == fixture.baseline)
        #expect(FileManager.default.fileExists(atPath: fixture.userOwnedFile.path))
        #expect(staging.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @MainActor
    @Test("task cancellation cleans current and later generated asset temps")
    func assetUploadCancellationCleansAllScopedTemps() async throws {
        let fixture = try AssetCleanupFixture()
        defer { fixture.remove() }
        let sync = CleanupAssetSyncClient(mode: .suspend)
        let staging = LockingBox<URL?>(nil)
        let session = await cleanupSession(client: sync) { directory in
            staging.value = directory
            return try fixture.generatedUploads(in: directory)
        }
        let task = Task { await session.synchronize() }
        await sync.waitUntilPublishStarts()

        task.cancel()
        await task.value

        #expect(fixture.contents == fixture.baseline)
        #expect(FileManager.default.fileExists(atPath: fixture.userOwnedFile.path))
        #expect(staging.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @MainActor
    @Test("successful asset publication cleans generated temps but retains user files")
    func assetUploadSuccessCleansAllScopedTemps() async throws {
        let fixture = try AssetCleanupFixture()
        defer { fixture.remove() }
        let sync = CleanupAssetSyncClient(mode: .success)
        let staging = LockingBox<URL?>(nil)
        let session = await cleanupSession(client: sync) { directory in
            staging.value = directory
            return try fixture.generatedUploads(in: directory)
        }

        await session.synchronize()

        #expect(await sync.publishCount == 3)
        #expect(fixture.contents == fixture.baseline)
        #expect(FileManager.default.fileExists(atPath: fixture.userOwnedFile.path))
        #expect(staging.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @MainActor
    @Test(
        "generated paths cannot escape staging and external media survives",
        arguments: AssetEscapeKind.allCases
    )
    func escapedGeneratedAssetIsRejected(_ escape: AssetEscapeKind) async throws {
        let fixture = try AssetCleanupFixture()
        defer { fixture.remove() }
        let sync = CleanupAssetSyncClient(mode: .success)
        let staging = LockingBox<URL?>(nil)
        let session = await cleanupSession(client: sync) { directory in
            staging.value = directory
            return [try fixture.escapedUpload(in: directory, escape: escape)]
        }

        await session.synchronize()

        #expect(await sync.publishCount == 0)
        #expect(session.syncStatus.phase == .failed)
        #expect(FileManager.default.fileExists(atPath: fixture.userOwnedFile.path))
        #expect(try Data(contentsOf: fixture.userOwnedFile) == Data("user-owned".utf8))
        #expect(staging.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @MainActor
    @Test("cancelling a joining sync caller leaves the shared owner and staging intact until completion")
    func cancelledJoiningSyncDoesNotCancelOwner() async throws {
        let fixture = try AssetCleanupFixture()
        defer { fixture.remove() }
        let sync = SharedAssetSyncClient()
        let cursor = InMemorySyncCursorStore()
        let staging = LockingBox<URL?>(nil)
        let session = AccountSession(
            client: FakeAuthClient(),
            store: InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6"),
            oauth: ScriptedOAuthBrowserSession.passthrough(), environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync, outbox: InMemorySyncOutboxRepository(), cursor: cursor,
                snapshot: { [] },
                assetUploads: { directory in
                    staging.value = directory
                    return try fixture.generatedUploads(in: directory)
                }
            )
        )
        await session.requestEmailCode("shared-cleanup@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)
        let owner = Task { await session.synchronize() }
        await sync.waitUntilPublishStarts()
        let joining = Task {
            await session.synchronize()
            return Task.isCancelled
        }
        await Task.yield()

        joining.cancel()
        await Task.yield()
        let liveStaging = try #require(staging.value)
        #expect(FileManager.default.fileExists(atPath: liveStaging.path))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: liveStaging.path)) == Set([
            "transcript.json", "expanded-epub.reading-package.zip",
        ]))
        await sync.releasePublish()
        await owner.value
        let joiningWasCancelled = await joining.value

        #expect(joiningWasCancelled)
        #expect((await sync.ownerCancellationObserved) == false)
        #expect(await sync.publishCount == 3)
        #expect(await sync.pullCount == 1)
        #expect(try cursor.loadCursor() == "1")
        #expect(session.syncStatus.phase == .completed)
        #expect(FileManager.default.fileExists(atPath: fixture.userOwnedFile.path))
        #expect(staging.value.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @MainActor
    @Test("an immediate second sync transfers no transcript object or change")
    func immediateSecondSyncDoesNotRetransferTranscript() async throws {
        let auth = FakeAuthClient()
        let sync = FakeSyncClient()
        sync.echoPublishedAssets = true
        let bytes = Data(#"{"chapterID":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","segments":[]}"#.utf8)
        let fileURL = try syncAssetFile(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let upload = SyncAssetUpload(
            revisionID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            chapterID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            sha256: sha,
            originalBytes: bytes.count,
            segmentCount: 0,
            fileURL: fileURL,
            compressedBytes: bytes.count
        )
        let versions = InMemorySyncEntityVersionStore()
        let cursor = InMemorySyncCursorStore()
        let session = AccountSession(
            client: auth,
            store: InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6"),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: InMemorySyncOutboxRepository(),
                cursor: cursor,
                versions: versions,
                assetUploads: { _ in [upload] }
            )
        )
        await session.requestEmailCode("asset-second-sync@example.com")
        await session.verifyEmailCode("123456")
        session.setSyncEnabled(true)

        await session.synchronize()
        await session.synchronize()

        #expect(sync.publishedAssets == [upload])
        #expect(sync.pulledCursors == ["0", "1"])
        #expect(try cursor.loadCursor() == "1")
    }

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
    @Test("push batches keep large structured rows below the Worker-safe request allowance")
    func pushBatchesRespectEncodedByteLimit() throws {
        let payload = Data("{\"text\":\"\(String(repeating: "a", count: 2_600_000))\"}".utf8)
        let pending = (0..<3).map { index in
            OutboxMutation(
                id: MutationID(rawValue: "00000000-0000-4000-8000-\(String(format: "%012d", index + 1))"),
                entityType: .vocabulary,
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
    @Test("a structured mutation larger than the native batch budget is skipped without blocking later rows")
    func oversizedMutationDoesNotBlockLaterRows() throws {
        let payload = Data("{\"text\":\"\(String(repeating: "a", count: 3_200_000))\"}".utf8)
        let oversized = OutboxMutation(
            id: MutationID(rawValue: "00000000-0000-4000-8000-000000000001"),
            entityType: .vocabulary,
            entityID: "10000000-0000-4000-8000-000000000001",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_777_000_000),
            payload: payload
        )
        let valid = OutboxMutation(
            id: MutationID(rawValue: "00000000-0000-4000-8000-000000000002"),
            entityType: .vocabulary,
            entityID: "10000000-0000-4000-8000-000000000002",
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: Date(timeIntervalSince1970: 1_777_000_001),
            payload: Data(#"{"surface":"safe"}"#.utf8)
        )

        let plan = try AccountSession.syncPushPlan([oversized, valid])

        #expect(plan.batches.map { $0.map(\.id) } == [[valid.id]])
        #expect(plan.skipped.map(\.mutationID) == [oversized.id])
        #expect(plan.skipped.first?.encodedBytes ?? 0 > 2_752_512)
    }

    @MainActor
    @Test("mixed large rows split before the Worker resource threshold")
    func mixedLargeRowsSplitBeforeWorkerThreshold() throws {
        let sizes = [1_616_000, 1_350_000]
        let pending = sizes.enumerated().map { index, size in
            OutboxMutation(
                id: MutationID(rawValue: "00000000-0000-4000-8000-\(String(format: "%012d", index + 1))"),
                entityType: .vocabulary,
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

private final class AssetCleanupFixture: @unchecked Sendable {
    let root: URL
    let userOwnedFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderAssetCleanup-\(UUID().uuidString)", isDirectory: true)
        userOwnedFile = root.appendingPathComponent("user-owned.epub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("user-owned".utf8).write(to: userOwnedFile)
    }

    var baseline: Set<String> { [userOwnedFile.lastPathComponent] }

    var contents: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }

    func writeGeneratedFiles(in generatedDirectory: URL) throws {
        try Data(#"{"segments":[]}"#.utf8)
            .write(to: generatedDirectory.appendingPathComponent("transcript.json"))
        try Data("expanded-epub-package".utf8)
            .write(to: generatedDirectory.appendingPathComponent("expanded-epub.reading-package.zip"))
    }

    func generatedUploads(in generatedDirectory: URL) throws -> [SyncAssetUpload] {
        try writeGeneratedFiles(in: generatedDirectory)
        return try [
            upload(
                at: generatedDirectory.appendingPathComponent("transcript.json"),
                kind: .transcriptRevision,
                deleteAfterUpload: true
            ),
            upload(at: userOwnedFile, kind: .epub, deleteAfterUpload: false),
            upload(
                at: generatedDirectory.appendingPathComponent("expanded-epub.reading-package.zip"),
                kind: .epubReadingPackage,
                deleteAfterUpload: true
            ),
        ]
    }

    func escapedUpload(in stagingDirectory: URL, escape: AssetEscapeKind) throws -> SyncAssetUpload {
        let escaped: URL
        switch escape {
        case .symbolicLink:
            escaped = stagingDirectory.appendingPathComponent("escaped-user-owned.epub")
            try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: userOwnedFile)
        case .parentTraversal:
            escaped = stagingDirectory.appendingPathComponent(
                "../\(root.lastPathComponent)/\(userOwnedFile.lastPathComponent)"
            )
        }
        return try upload(at: escaped, kind: .epub, deleteAfterUpload: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func upload(
        at url: URL,
        kind: SyncAssetKind,
        deleteAfterUpload: Bool
    ) throws -> SyncAssetUpload {
        let digest = try SyncAssetFileIO.digest(fileURL: url)
        return SyncAssetUpload(
            kind: kind,
            revisionID: UUID().uuidString.lowercased(),
            chapterID: kind == .transcriptRevision ? UUID().uuidString.lowercased() : nil,
            contentType: kind == .transcriptRevision ? "application/json" : "application/octet-stream",
            encoding: kind == .transcriptRevision ? "identity-json-v1" : "identity",
            sha256: digest.sha256,
            originalBytes: digest.byteCount,
            segmentCount: kind == .transcriptRevision ? 0 : nil,
            fileURL: url,
            compressedBytes: digest.byteCount,
            deleteFileAfterUpload: deleteAfterUpload
        )
    }
}

enum AssetEscapeKind: CaseIterable, Sendable {
    case symbolicLink
    case parentTraversal
}

private enum CleanupPublishMode: Sendable {
    case success
    case failure
    case suspend
}

private actor CleanupAssetSyncClient: SyncClient {
    let mode: CleanupPublishMode
    private(set) var publishCount = 0
    private var publishStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(mode: CleanupPublishMode) {
        self.mode = mode
    }

    func publishAsset(accessToken: String, deviceID: String, asset: SyncAssetUpload) async throws {
        _ = accessToken; _ = deviceID; _ = asset
        publishCount += 1
        publishStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        switch mode {
        case .success:
            return
        case .failure:
            throw TestSyncError.unavailable
        case .suspend:
            try await Task.sleep(for: .seconds(60))
        }
    }

    func waitUntilPublishStarts() async {
        guard !publishStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        SyncPushResponse(batchId: request.batchId, results: [], cursor: request.baseCursor ?? "0")
    }

    func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        SyncPullResponse(changes: [], cursor: cursor, hasMore: false)
    }
}

private actor SharedAssetSyncClient: SyncClient {
    private(set) var publishCount = 0
    private(set) var pullCount = 0
    private(set) var ownerCancellationObserved = false
    private var firstPublishStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func publishAsset(accessToken: String, deviceID: String, asset: SyncAssetUpload) async throws {
        _ = accessToken; _ = deviceID; _ = asset
        publishCount += 1
        guard publishCount == 1 else { return }
        firstPublishStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
        if Task.isCancelled {
            ownerCancellationObserved = true
        }
        try Task.checkCancellation()
    }

    func waitUntilPublishStarts() async {
        guard !firstPublishStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releasePublish() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        SyncPushResponse(batchId: request.batchId, results: [], cursor: request.baseCursor ?? "0")
    }

    func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        pullCount += 1
        return SyncPullResponse(changes: [], cursor: "1", hasMore: false)
    }
}

@MainActor
private func cleanupSession(
    client: any SyncClient,
    assetUploads: @escaping @Sendable (URL) throws -> [SyncAssetUpload]
) async -> AccountSession {
    let session = AccountSession(
        client: FakeAuthClient(),
        store: InMemoryAuthSessionStore(deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6"),
        oauth: ScriptedOAuthBrowserSession.passthrough(),
        environment: .test,
        syncRuntime: AccountSyncRuntime(
            client: client,
            outbox: InMemorySyncOutboxRepository(),
            cursor: InMemorySyncCursorStore(),
            snapshot: { [] },
            assetUploads: assetUploads
        )
    )
    await session.requestEmailCode("asset-cleanup-\(UUID().uuidString)@example.com")
    await session.verifyEmailCode("123456")
    session.setSyncEnabled(true)
    return session
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

private enum StatusObservationError: Error {
    case timedOut
    case applyFailed
}

private actor TwoPageGatedSyncClient: SyncClient {
    private var pullCount = 0
    private var secondPullWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondPullRelease: CheckedContinuation<Void, Never>?

    func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        SyncPushResponse(batchId: request.batchId, results: [], cursor: "1")
    }

    func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        pullCount += 1
        if pullCount == 1 {
            return SyncPullResponse(
                changes: [
                    SyncPulledChange(
                        sequence: 2,
                        entityType: OutboxEntityType.vocabulary.rawValue,
                        entityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                        operation: OutboxOperation.upsert.rawValue,
                        revision: 1,
                        changedAt: "2026-08-30T00:00:00Z",
                        payload: ["surface": .string("loom")]
                    )
                ],
                cursor: "2",
                hasMore: true
            )
        }
        for waiter in secondPullWaiters { waiter.resume() }
        secondPullWaiters.removeAll()
        await withCheckedContinuation { secondPullRelease = $0 }
        return SyncPullResponse(changes: [], cursor: "2", hasMore: false)
    }

    func waitUntilSecondPullStarts() async {
        if pullCount >= 2 { return }
        await withCheckedContinuation { secondPullWaiters.append($0) }
    }

    func releaseSecondPull() {
        secondPullRelease?.resume()
        secondPullRelease = nil
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
@Test("sync readiness enforces the v2 minimum before sync UI can become effective")
func syncReadinessRejectsOldSemanticVersion() {
    let readiness = AccountSyncReadiness(minAppVersion: "2.0.0", effective: true)
        .enforcingAppVersion("1.9.9")
    #expect(readiness.effective == false)
    #expect(readiness.reason == "upgrade_required")
}
