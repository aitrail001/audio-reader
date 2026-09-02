import Foundation
import Testing
@testable import AudioReader
@testable import AudioReaderLocalStore
@testable import AudioReaderNetworking

@Suite("Native account session flow")
struct AccountSessionFlowTests {
    @Test("asset publication fails closed when its catalog database cannot be read")
    func assetPublicationFailsClosedOnCatalogReadError() throws {
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-upload-read-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let unreadable = LocalSQLiteStore(
            fileURL: URL(fileURLWithPath: "/dev/null/library-vNext.sqlite")
        )

        #expect(throws: (any Error).self) {
            try AccountSyncApplicator.assetUploads(
                database: unreadable,
                stagingDirectory: stagingDirectory
            )
        }
    }

    @Test("asset publication excludes transcript rows below catalog tombstones")
    func assetPublicationExcludesDeletedCatalogDescendants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-upload-filter-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("library-vNext.sqlite")
        let stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LocalSQLiteStore(fileURL: databaseURL)
        let liveBookID = BookID(rawValue: "live-book")
        let deletedBookID = BookID(rawValue: "deleted-book")
        let liveChapterID = ChapterID(rawValue: "live-chapter")
        let deletedChapterID = ChapterID(rawValue: "deleted-chapter")
        let deletedBookChapterID = ChapterID(rawValue: "deleted-book-chapter")
        let liveBook = StoredBook(
            id: liveBookID,
            title: "Live Book",
            source: "test",
            chapters: [
                StoredChapter(id: liveChapterID, index: 0, title: "Live Chapter"),
                StoredChapter(id: deletedChapterID, index: 1, title: "Deleted Chapter"),
            ]
        )
        try store.saveBook(liveBook)
        try store.saveBook(StoredBook(
            id: deletedBookID,
            title: "Deleted Book",
            source: "test",
            chapters: [StoredChapter(id: deletedBookChapterID, index: 0, title: "Chapter")]
        ))

        for (index, chapterID) in [liveChapterID, deletedChapterID, deletedBookChapterID].enumerated() {
            try store.saveTranscript(Self.syncTranscript(chapterID: chapterID, index: index))
        }

        let liveAudioURL = root.appendingPathComponent("live.m4a")
        let deletedChapterAudioURL = root.appendingPathComponent("deleted-chapter.m4a")
        let liveEPUBURL = root.appendingPathComponent("live.epub")
        let liveCoverURL = root.appendingPathComponent("cover.jpg")
        let deletedBookEPUBURL = root.appendingPathComponent("deleted-book.epub")
        try Data([1]).write(to: liveAudioURL)
        try Data([2]).write(to: deletedChapterAudioURL)
        try Data([3]).write(to: liveEPUBURL)
        try Data([4]).write(to: liveCoverURL)
        try Data([5]).write(to: deletedBookEPUBURL)
        try store.saveAssets([
            StoredLocalAsset(
                id: AssetID(rawValue: "live-audio"), bookID: liveBookID, kind: "audio",
                localMediaKey: liveAudioURL.path, metadata: ["chapterID": liveChapterID.rawValue]
            ),
            StoredLocalAsset(
                id: AssetID(rawValue: "deleted-chapter-audio"), bookID: liveBookID, kind: "audio",
                localMediaKey: deletedChapterAudioURL.path,
                metadata: ["chapterID": deletedChapterID.rawValue]
            ),
            StoredLocalAsset(
                id: AssetID(rawValue: "live-epub"), bookID: liveBookID, kind: "epub",
                localMediaKey: liveEPUBURL.path
            ),
            StoredLocalAsset(
                id: AssetID(rawValue: "live-cover"), bookID: liveBookID, kind: "cover",
                localMediaKey: liveCoverURL.path
            ),
        ], bookID: liveBookID)

        try store.saveBook(StoredBook(
            id: liveBookID,
            title: liveBook.title,
            source: liveBook.source,
            chapters: [StoredChapter(id: liveChapterID, index: 0, title: "Live Chapter")]
        ))
        try store.deleteBook(id: deletedBookID)
        try store.saveAssets([
            StoredLocalAsset(
                id: AssetID(rawValue: "deleted-book-epub"), bookID: deletedBookID, kind: "epub",
                localMediaKey: deletedBookEPUBURL.path
            ),
        ], bookID: deletedBookID)

        let uploads = try AccountSyncApplicator.assetUploads(
            database: store,
            stagingDirectory: stagingDirectory
        )
        let liveBookSyncID = AccountSyncApplicator.syncEntityID(liveBookID.rawValue, kind: "book")
        let liveChapterSyncID = AccountSyncApplicator.syncEntityID(liveChapterID.rawValue, kind: "chapter")

        #expect(uploads.count == 1)
        #expect(uploads.allSatisfy { $0.bookID == liveBookSyncID })
        #expect(uploads.filter { $0.kind == .transcriptRevision }.map(\.chapterID) == [liveChapterSyncID])
        #expect(uploads.allSatisfy { $0.kind == .transcriptRevision })
    }

    @Test("operator cloud-media capability does not opt the user into book uploads")
    func operatorCapabilityDoesNotAuthorizeBookMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-media-consent-\(UUID().uuidString)", isDirectory: true)
        let stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bookID = BookID(rawValue: "local-media-book")
        let chapterID = ChapterID(rawValue: "local-media-chapter")
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        try store.saveBook(StoredBook(
            id: bookID,
            title: "Local Media",
            source: "files",
            chapters: [StoredChapter(id: chapterID, index: 0, title: "Chapter")]
        ))
        let media = [("audio", "book.m4b"), ("epub", "book.epub"), ("cover", "cover.jpg")]
        let assets = try media.map { kind, name in
            let url = root.appendingPathComponent(name)
            try Data(kind.utf8).write(to: url)
            return StoredLocalAsset(
                id: AssetID(rawValue: "local-\(kind)"), bookID: bookID, kind: kind,
                localMediaKey: url.path,
                metadata: kind == "audio" ? ["chapterID": chapterID.rawValue] : [:]
            )
        }
        try store.saveAssets(assets, bookID: bookID)

        let uploads = try AccountSyncApplicator.assetUploads(
            database: store,
            stagingDirectory: stagingDirectory
        )

        #expect(uploads.isEmpty)
    }

    @Test("verified audio manifest installs atomically and associates its chapter before cursor commit")
    func installsAudioManifestWithChapterAssociation() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-audio-\(UUID().uuidString).sqlite")
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-audio-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        defer { try? FileManager.default.removeItem(at: source) }
        try Data([1, 2, 3]).write(to: source)
        let store = LocalSQLiteStore(fileURL: databaseURL)
        let bookID = BookID(rawValue: "local-book")
        let chapterID = ChapterID(rawValue: "local-chapter")
        try store.saveBook(StoredBook(
            id: bookID, title: "Book", author: "Author", source: "files",
            chapters: [StoredChapter(id: chapterID, index: 0, title: "Chapter")]
        ))
        let assetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let sha = String(repeating: "e", count: 64)
        let change = SyncPulledChange(
            sequence: 1, entityType: OutboxEntityType.asset.rawValue, entityId: assetID,
            operation: OutboxOperation.upsert.rawValue, revision: 1,
            changedAt: "2026-08-31T00:00:00Z",
            payload: [
                "assetId": .string(assetID), "kind": .string(SyncAssetKind.audio.rawValue),
                "bookId": .string(AccountSyncApplicator.syncEntityID(bookID.rawValue, kind: "book")),
                "chapterId": .string(AccountSyncApplicator.syncEntityID(chapterID.rawValue, kind: "chapter")),
                "contentType": .string("audio/mpeg"), "encoding": .string("identity"),
                "sha256": .string(sha), "compressedBytes": .number(3),
                "originalBytes": .number(3), "localObjectPath": .string(source.path),
            ]
        )
        try AccountSyncApplicator.applyPage([change], versions: [], cursor: "1", to: store)
        let manifest = try #require(try store.loadSyncAssetManifests().first)
        defer { try? FileManager.default.removeItem(atPath: manifest.localObjectPath) }
        #expect(FileManager.default.fileExists(atPath: manifest.localObjectPath))
        #expect(try store.loadAssets(bookID: bookID).first?.metadata["chapterID"] == chapterID.rawValue)
        #expect(try store.loadCursor() == "1")
    }

    private static func syncTranscript(chapterID: ChapterID, index: Int) -> StoredTranscript {
        StoredTranscript(
            chapterID: chapterID,
            localMediaKey: "/media/\(chapterID.rawValue).m4a",
            createdAt: Date(timeIntervalSince1970: Double(index + 1)),
            locale: "en",
            source: "test",
            ebookAligned: false,
            segments: [
                StoredTranscriptSegment(
                    id: "segment-\(index)",
                    start: 0,
                    end: 1,
                    words: [StoredTranscriptWord(
                        id: "word-\(index)", text: "word", start: 0, end: 1
                    )]
                ),
            ]
        )
    }

    private static func hydratedTranscriptChange(
        sequence: Int,
        entityID: String,
        sourceChapterID: ChapterID,
        announcedChapterID: String,
        directory: URL
    ) throws -> SyncPulledChange {
        let transcript = syncTranscript(chapterID: sourceChapterID, index: sequence)
        let data = try JSONEncoder.iso.encode(Transcript(transcript))
        let source = directory.appendingPathComponent("\(entityID).transcript.json")
        try data.write(to: source, options: .atomic)
        return SyncPulledChange(
            sequence: sequence,
            entityType: OutboxEntityType.transcript.rawValue,
            entityId: entityID,
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-09-01T00:00:00Z",
            payload: [
                "assetId": .string(entityID),
                "chapterId": .string(announcedChapterID),
                "contentType": .string("application/json"),
                "encoding": .string("identity-json-v1"),
                "kind": .string(SyncAssetKind.transcriptRevision.rawValue),
                "revisionId": .string(entityID),
                "sha256": .string(String(repeating: String(sequence), count: 64)),
                "compressedBytes": .number(Double(data.count)),
                "originalBytes": .number(Double(data.count)),
                "segmentCount": .number(Double(transcript.segments.count)),
                "localObjectPath": .string(source.path),
            ]
        )
    }

    @MainActor
    @Test("Shared account UI explains paused and never-enabled storage readiness while sync is idle")
    func sharedAccountUIExplainsIdleStorageReadiness() async throws {
        let client = FakeAuthClient()
        client.bootstrapReadiness = AccountSyncReadiness(
            schemaReady: true,
            provider: "gcs",
            bucket: "private-sync",
            credentialStatus: "failed",
            ready: false,
            requested: true,
            effective: false,
            reason: "storage_credentials_invalid"
        )
        let account = AccountSession.isolated(client: client)
        await account.requestEmailCode("paused-ui@example.com")
        await account.verifyEmailCode("123456")
        #expect(account.mode == .signedInSyncOff)
        #expect(account.syncStatus.phase == .idle)
        #expect(account.syncReadinessMessage?.contains("Sync paused") == true)
        #expect(account.syncReadinessMessage?.contains("storage credentials") == true)

        client.bootstrapReadiness.requested = false
        await account.refreshSession()
        #expect(account.syncReadinessMessage?.contains("Sync unavailable") == true)
        #expect(account.syncReadinessMessage?.contains("Turn on sync after") == true)

        client.bootstrapReadiness = AccountSyncReadiness(
            schemaReady: true,
            provider: "gcs",
            bucket: "private-sync",
            credentialStatus: "ok",
            ready: true,
            requested: false,
            effective: false,
            reason: nil
        )
        await account.refreshSession()
        #expect(account.syncReadinessMessage == "Sync unavailable — the service operator has not enabled cross-device sync.")
        #expect(account.syncAvailabilityManagedByOperator)

        let view = try source("Sources/AudioReader/AccountSessionView.swift")
        #expect(view.contains("session.syncReadinessMessage"))
        #expect(view.contains("accessibilityLabel(\"Account sync readiness\")"))
        #expect(view.contains("session.syncAvailabilityManagedByOperator"))
        #expect(view.contains("Button(\"Refresh sync availability\")"))
    }

    @MainActor
    @Test("Signing out does not silently delete local books")
    func signingOutDoesNotSilentlyDeleteLocalBooks() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "00000000-0000-4000-8000-000000000099")
        let account = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        let state = AppState(composition: .inMemory(), account: account)
        state.books = [
            Book(
                id: "book-keep-1",
                title: "Moby-Dick",
                author: "Herman Melville",
                folderPath: "/tmp/audio-reader-keep/moby",
                chapters: [
                    Chapter(id: "ch-1", index: 0, title: "Loomings", audioPath: "/tmp/audio-reader-keep/moby/01.m4b")
                ]
            )
        ]

        await account.requestEmailCode("keeper@example.com")
        await account.verifyEmailCode("123456")
        #expect(account.mode == .signedInSyncOff)
        #expect(state.books.map(\.id) == ["book-keep-1"])

        await account.signOut()

        #expect(account.mode == .local)
        #expect(state.books.map(\.title) == ["Moby-Dick"])
        #expect(state.books.first?.chapters.first?.title == "Loomings")
        #expect(try store.load() == nil)
    }

    @MainActor
    @Test("Signed-in sync on is persisted and does not drop local books")
    func signedInSyncOnPersistsWithoutDroppingBooks() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: "00000000-0000-4000-8000-000000000097")
        let account = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        let state = AppState(composition: .inMemory(), account: account)
        state.books = [
            Book(
                id: "book-keep-3",
                title: "Moby-Dick",
                author: nil,
                folderPath: "/tmp/audio-reader-keep/sync",
                chapters: [
                    Chapter(id: "ch-3", index: 0, title: "Loomings", audioPath: "/tmp/audio-reader-keep/sync/01.m4b")
                ]
            )
        ]
        await account.requestEmailCode("sync@example.com")
        await account.verifyEmailCode("123456")
        account.setSyncEnabled(true)

        #expect(account.mode == .signedInSyncOn)
        #expect(try store.load()?.mode == .signedInSyncOn)
        #expect(state.books.map(\.id) == ["book-keep-3"])

        let restored = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        await restored.restore()
        #expect(restored.mode == .signedInSyncOn)
        #expect(state.books.map(\.id) == ["book-keep-3"])
    }

    @MainActor
    @Test("Revoked device recovery leaves local books in place")
    func revokedDeviceRecoveryLeavesLocalBooks() async throws {
        let deviceID = "00000000-0000-4000-8000-000000000098"
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: deviceID)
        let account = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        let state = AppState(composition: .inMemory(), account: account)
        state.books = [
            Book(
                id: "book-keep-2",
                title: "The Ride",
                author: nil,
                folderPath: "/tmp/audio-reader-keep/ride",
                chapters: [
                    Chapter(id: "ch-2", index: 0, title: "One", audioPath: "/tmp/audio-reader-keep/ride/01.m4b")
                ]
            )
        ]
        await account.requestEmailCode("device@example.com")
        await account.verifyEmailCode("123456")
        client.revokeDeviceLocally(deviceID)
        await account.refreshSession()

        #expect(account.mode == .local)
        #expect(account.recoveryMessage != nil)
        #expect(state.books.map(\.id) == ["book-keep-2"])
        #expect(state.books.count == 1)
    }

    @Test("Account screens expose VoiceOver labels and Dynamic Type")
    func accountScreensExposeVoiceOverAndDynamicType() throws {
        let view = try source("Sources/AudioReader/AccountSessionView.swift")
        let settings = try source("Sources/AudioReader/SettingsView.swift")

        #expect(settings.contains("AccountSessionView(session: state.account)"))
        #expect(view.contains("@ScaledMetric(relativeTo: .body)"))
        #expect(view.contains("dynamicTypeSize"))
        #expect(view.contains(".font(.body)"))
        #expect(view.contains(".accessibilityLabel(\"Sign in with Google\")"))
        #expect(view.contains(".accessibilityLabel(\"Sign in with Microsoft\")"))
        #expect(view.contains(".accessibilityLabel(\"Email address for sign-in code\")"))
        #expect(view.contains(".accessibilityLabel(\"Send email sign-in code\")"))
        #expect(view.contains(".accessibilityLabel(\"Email sign-in code\")"))
        #expect(view.contains(".accessibilityLabel(\"Verify email sign-in code\")"))
        #expect(view.contains(".accessibilityLabel(\"Sign out of AudioReader account\")"))
        #expect(view.contains("\"Export account data\""))
        #expect(view.contains(".fileExporter("))
        #expect(view.contains("Save export"))
        #expect(view.contains("AccountExportDocument"))
        #expect(view.contains(".accessibilityLabel(\"Delete AudioReader account\")"))
        #expect(view.contains(".accessibilityLabel(\"Sync learning data across devices\")"))
        #expect(view.contains("session.accountSyncReadiness.effective"))
        #expect(view.contains("session.mode.isSyncEnabled"))
        #expect(view.contains("Share aggregate learning progress with Operator support"))
        #expect(view.contains("Reading text, transcripts, saved words, translations, notes, and prompts are never shared"))
        #expect(view.contains("setOperatorLearningAnalyticsEnabled"))
        #expect(view.contains("AccountSyncStatusView(session: session)"))
        #expect(view.contains(".accessibilityLabel(\"Sync status\")"))
        #expect(view.contains(".accessibilityValue(session.syncStatusAccessibilityDescription)"))
        #expect(view.contains(".accessibilityLabel(\"Account session recovery\")"))
        #expect(view.contains(".accessibilityLabel(\"Account connection issue\")"))
        #expect(!view.contains(".foregroundStyle(.red)"))
        #expect(view.contains("Revoke"))
        #expect(view.contains("Books on this device stay here"))
        #expect(view.contains("minHeight: 44"))
        #expect(!view.contains("func deleteBook"))
        #expect(!view.contains("books = []"))
    }

    @Test("Account session is shared across macOS, iPadOS, and iPhone layout")
    func accountSessionIsSharedAcrossPlatforms() throws {
        let view = try source("Sources/AudioReader/AccountSessionView.swift")
        let macRoot = try source("Sources/AudioReader/RootView.swift")
        let iPadRoot = try source("Sources/AudioReader/IPadRootView.swift")
        let settings = try source("Sources/AudioReader/SettingsView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")
        let live = try source("Sources/AudioReader/AccountSession+Live.swift")

        #expect(macRoot.contains("SettingsView(state: state)"))
        #expect(iPadRoot.contains("SettingsView(state: state)"))
        #expect(macRoot.contains("AccountSyncStatusView(session: state.account, compact: true)"))
        #expect(iPadRoot.contains("AccountSyncStatusView(session: state.account, compact: true)"))
        #expect(macRoot.contains("WorkStatusBanner("))
        #expect(iPadRoot.contains("WorkStatusBanner("))
        #expect(!iPadRoot.contains("if state.isScanning, let progress = state.libraryScanProgress"))
        #expect(!macRoot.contains(".sheet(isPresented: $state.showSettings)"))
        #expect(!iPadRoot.contains(".sheet(isPresented: $state.showSettings)"))
        #expect(macRoot.contains("case .settings:"))
        #expect(iPadRoot.contains("case .settings:"))
        #expect(settings.contains("accountSection"))
        #expect(appState.contains("account.restore()"))
        #expect(!appState.contains("async let accountRestore"))
        #expect(appState.contains("await account.restore()"))
        #expect(appState.contains("reloadSyncedLearningData()"))
        #expect(appState.contains("ManagedProductLLM.translateBatch"))
        #expect(appState.contains("ManagedProductLLM.lookupSummary"))
        #expect(appState.contains("ManagedProductLLM.summarize"))
        #expect(appState.contains("ManagedProductLLM.translate"))
        #expect(appState.contains("lookupOnly: true"))
        #expect(appState.contains("contextPrevious"))
        #expect(appState.contains("contextNext"))
        #expect(appState.contains("contextBefore:"))
        #expect(appState.contains("wordMeaningText"))
        #expect(appState.contains("bookTitle: book?.title"))
        #expect(try source("Sources/AudioReader/ManagedProductLLM.swift").contains("sentenceMeaningHeading"))
        #expect(try source("Sources/AudioReader/ManagedProductLLM.swift").contains("examplesHeading"))
        #expect(view.contains("activityMessage"))
        #expect(view.contains("Account activity"))
        #expect(settings.contains("Loading installed dictionaries"))
        #expect(settings.contains("installedNamesOffMain"))
        #expect(view.contains("refreshDevices"))
        #expect(view.contains(".dynamicTypeSize(.xSmall ... .accessibility5)\n        .onChange(of: session.pendingExport"))
        #expect(appState.contains("init(composition: AppComposition"))
        #expect(live.contains("ASWebAuthenticationSession"))
        #expect(live.contains("callbackURLScheme"))
        #expect(live.contains("nonisolated static func makeSession"))
        #expect(live.contains("nonisolated static func finish"))
        #expect(live.contains("enum WebAuthCallbacks"))
        #expect(live.contains("/v1/auth/oauth/local-complete"))
        #expect(live.contains("@concurrent"))
        #expect(live.contains("OnceResume"))
        #expect(view.contains("Sign in with Google"))
        #expect(view.contains("Sign in with Microsoft"))
        #expect(!view.contains("#if os(macOS)"))
        #expect(!settings.contains("#if os(macOS)\n                    accountSection"))
    }

    @Test("macOS activity banner does not invalidate NavigationSplitView safe areas")
    func macActivityBannerAvoidsSplitViewSafeAreaFeedback() throws {
        let macRoot = try source("Sources/AudioReader/RootView.swift")
        let iPadRoot = try source("Sources/AudioReader/IPadRootView.swift")

        #expect(macRoot.contains("VStack(spacing: 0)"))
        #expect(macRoot.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        #expect(macRoot.contains(".layoutPriority(1)"))
        #expect(!macRoot.contains(".safeAreaInset(edge: .top"))
        #expect(iPadRoot.contains(".safeAreaInset(edge: .top"))
    }

    @Test("Product account auth stays separate from OpenAI API-key and ChatGPT-plan paths")
    func productAccountAuthIsSeparateFromLLMProviders() throws {
        let settings = try source("Sources/AudioReader/SettingsView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")
        let live = try source("Sources/AudioReader/AccountSession+Live.swift")

        #expect(settings.contains("ForEach(OpenAIAuthentication.allCases)"))
        #expect(settings.contains("draft.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue"))
        #expect(appState.contains("settings.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue"))
        #expect(live.contains("ProductAuthClient"))
        #expect(live.contains("EncryptedFileAuthSessionStore"))
        #expect(live.contains("legacy: nil"))
        #expect(!live.contains("KeychainAuthSessionStore()"))
        let sessionStore = try source("Sources/AudioReaderNetworking/AuthSessionStore.swift")
        #expect(sessionStore.contains("legacy: KeychainAuthSessionStore? = nil"))
        #expect(!live.contains("OpenAIAPIKeyStore"))
        #expect(!live.contains("codex login"))
    }

    @Test("Local OAuth complete URLs are recognized without Safari")
    func localOAuthCompleteURLsAreRecognizedWithoutSafari() throws {
        let local = URL(string: "http://127.0.0.1:8787/v1/auth/oauth/local-complete?code=abc&state=xyz")!
        let hosted = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        #expect(LocalOAuthRedirect.isLocalComplete(local))
        #expect(!LocalOAuthRedirect.isLocalComplete(hosted))
    }

    @Test("Local OAuth complete follows the native callback redirect when the API is running")
    func localOAuthCompleteFollowsNativeCallbackWhenAPIRunning() async throws {
        guard let healthURL = URL(string: "http://127.0.0.1:8787/healthz") else {
            return
        }
        var healthRequest = URLRequest(url: healthURL)
        healthRequest.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: healthRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        } catch {
            return
        }

        var authorize = URLRequest(url: URL(string: "http://127.0.0.1:8787/v1/auth/oauth/authorize")!)
        authorize.httpMethod = "POST"
        authorize.setValue("application/json", forHTTPHeaderField: "content-type")
        let pkce = PKCEPair.generate()
        authorize.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "google",
            "redirectUri": ProductAPI.callbackURL.absoluteString,
            "codeChallenge": pkce.challenge,
            "codeChallengeMethod": "S256",
            "state": "oauth-live-follow",
        ])
        let (body, response) = try await URLSession.shared.data(for: authorize)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let authorization = try #require(payload?["authorizationUrl"] as? String)
        let authorizationURL = try #require(URL(string: authorization))
        #expect(LocalOAuthRedirect.isLocalComplete(authorizationURL))
        let callback = try await LocalOAuthRedirect.follow(authorizationURL)
        #expect(callback.scheme == "audioreader")
        #expect(callback.path == "/callback" || callback.host == "auth")
        #expect(callback.query?.contains("code=") == true)
        #expect(callback.query?.contains("state=oauth-live-follow") == true)
    }

    @Test("OAuth callback scheme is registered for packaged macOS and iPad apps")
    func oauthCallbackSchemeIsRegistered() throws {
        let mac = try source("Info.plist")
        let iPad = try source("Info-iPad.plist")
        let xcodeMac = try source("Xcode/Info-macOS.plist")
        let xcodeiOS = try source("Xcode/Info-iOS.plist")

        for plist in [mac, iPad, xcodeMac, xcodeiOS] {
            #expect(plist.contains("<key>CFBundleURLSchemes</key>"))
            #expect(plist.contains("<string>audioreader</string>"))
        }
    }

    @Test("Xcode compiles AudioReaderNetworking sources into both apps without an SPM product link")
    func networkingSourcesAreSynchronizedNotLinked() throws {
        let project = try source("AudioReader.xcodeproj/project.pbxproj")
        let models = try source("Sources/AudioReader/Models.swift")
        let package = try source("Package.swift")

        #expect(project.components(separatedBy: "100000000000000000000027 /* Sources/AudioReaderNetworking */,").count - 1 == 3)
        #expect(!project.contains("/* AudioReaderNetworking in Frameworks */"))
        #expect(models.contains("#if canImport(AudioReaderNetworking)"))
        #expect(models.contains("@_exported import AudioReaderNetworking"))
        #expect(package.contains("name: \"AudioReaderNetworking\""))
        #expect(package.contains("AudioReaderNetworkingTests"))
        #expect(package.contains(".linkedFramework(\"AuthenticationServices\")"))
    }

    @Test("Account session controller never clears the local library")
    func accountSessionControllerDoesNotClearLibrary() throws {
        let session = try source("Sources/AudioReaderNetworking/AccountSession.swift")
        #expect(session.contains("func signOut()"))
        #expect(session.contains("Books on this device were kept"))
        #expect(!session.contains("deleteBook"))
        #expect(!session.contains("LibraryStore"))
        #expect(!session.contains("books = []"))
    }

    @Test("Sync snapshot enqueues UUID vocabulary and known lemmas")
    func syncSnapshotEnqueuesVocabularyAndLemmas() throws {
        let vocabID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let mutations = try AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: [
                VocabEntry(
                    id: vocabID,
                    word: "loom",
                    context: "Call me Ishmael",
                    bookID: "book-1",
                    bookTitle: "Moby-Dick",
                    chapterID: "ch-1",
                    chapterTitle: "Loomings",
                    timestamp: 4,
                    addedAt: Date(timeIntervalSince1970: 1_777_000_000),
                    isInLearnList: true
                )
            ],
            lemmas: [
                KnownLemmaRecord(language: "en", form: "whale", updatedAt: Date(timeIntervalSince1970: 1_777_000_000))
            ],
            deletedLemmas: [
                StoredKnownLemma(language: "en", form: "forest", updatedAt: Date(timeIntervalSince1970: 1_777_000_100))
            ]
        )
        #expect(mutations.contains(where: { $0.entityType == .settings }))
        #expect(mutations.contains(where: { $0.entityType == .vocabulary && $0.entityID == vocabID }))
        #expect(mutations.contains(where: { $0.entityType == .lexemeState }))
        #expect(mutations.contains(where: { $0.entityType == .lexemeState && $0.operation == .delete }))
        #expect(AccountSyncApplicator.isUUID(AccountSyncApplicator.uuidForLemma(language: "en", form: "whale")))
    }

    @Test("Sync snapshot enqueues books, transcripts, reviews, and progress")
    func syncSnapshotEnqueuesLibraryLearningData() throws {
        let bookID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let chapterID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let vocabID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let mutations = try AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: [
                VocabEntry(
                    id: vocabID,
                    word: "ice",
                    context: "the ice",
                    bookID: bookID,
                    bookTitle: "Moby-Dick",
                    chapterID: chapterID,
                    chapterTitle: "Loomings",
                    timestamp: 1,
                    addedAt: Date(timeIntervalSince1970: 1_777_000_000),
                    reviewCount: 2,
                    nextReview: Date(timeIntervalSince1970: 1_777_086_400),
                    lastReviewedAt: Date(timeIntervalSince1970: 1_777_000_100),
                    lastReviewQuality: .remember,
                    reviewIntervalDays: 12,
                    reviewEaseFactor: 2.8,
                    isInLearnList: true
                )
            ],
            lemmas: [],
            books: [
                StoredBook(
                    id: BookID(rawValue: bookID),
                    title: "Moby-Dick",
                    author: "Herman Melville",
                    source: "local_folder",
                    chapters: [
                        StoredChapter(id: ChapterID(rawValue: chapterID), index: 0, title: "Loomings")
                    ]
                )
            ],
            transcripts: [
                StoredTranscript(
                    chapterID: ChapterID(rawValue: chapterID),
                    localMediaKey: "audio",
                    createdAt: Date(timeIntervalSince1970: 1_777_000_000),
                    locale: "en-US",
                    source: "spoken",
                    ebookAligned: false,
                    segments: []
                )
            ],
            overlays: [
                StoredTranscriptOverlay(
                    id: "overlay-1",
                    chapterID: ChapterID(rawValue: chapterID),
                    segmentID: "segment-1",
                    baseFingerprint: "base",
                    correctedText: "Corrected",
                    correctedStart: 1,
                    correctedEnd: 2,
                    provenance: .init(deviceID: "mac", createdAt: Date(timeIntervalSince1970: 1_777_000_010)),
                    updatedAt: Date(timeIntervalSince1970: 1_777_000_010)
                )
            ],
            readerProgress: [
                StoredReaderProgress(
                    id: "reader-progress",
                    bookID: BookID(rawValue: bookID),
                    chapterID: ChapterID(rawValue: chapterID),
                    relativeSeconds: 12.875,
                    updatedAt: Date(timeIntervalSince1970: 1_777_000_020),
                    deviceID: "mac",
                    revision: 3
                )
            ],
            reviews: [
                StoredReviewEvent(
                    id: ReviewEventID(rawValue: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
                    vocabularyID: VocabularyOccurrenceID(rawValue: vocabID),
                    cardID: "study:give-up",
                    face: "recognition",
                    rating: "remember",
                    reviewedAt: Date(timeIntervalSince1970: 1_777_000_100)
                )
            ]
        )
        #expect(mutations.contains(where: { $0.entityType == .book && $0.entityID == bookID }))
        #expect(!mutations.contains(where: { $0.entityType == .transcript }))
        let overlay = try #require(mutations.first(where: { $0.entityType == .transcriptOverlay }))
        let overlayPayload = try JSONDecoder().decode([String: SyncJSONValue].self, from: overlay.payload)
        #expect(overlayPayload["localChapterId"]?.stringValue == chapterID)
        #expect(overlayPayload["overlayJSON"]?.stringValue?.contains("Corrected") == true)
        let reviewMutation = try #require(mutations.first(where: { $0.entityType == .reviewEvent }))
        let reviewPayload = try JSONDecoder().decode([String: SyncJSONValue].self, from: reviewMutation.payload)
        #expect(reviewPayload["cardId"]?.stringValue == "study:give-up")
        let vocabularyProgress = try #require(mutations.first(where: {
            $0.entityType == .progress && $0.entityID == vocabID
        }))
        let vocabularyProgressPayload = try JSONDecoder().decode(
            [String: SyncJSONValue].self,
            from: vocabularyProgress.payload
        )
        #expect(vocabularyProgressPayload["reviewIntervalDays"]?.numberValue == 12)
        #expect(vocabularyProgressPayload["reviewEaseFactor"]?.numberValue == 2.8)
        let readerProgress = try #require(mutations.first(where: {
            guard $0.entityType == .progress,
                  let payload = try? JSONDecoder().decode([String: SyncJSONValue].self, from: $0.payload)
            else { return false }
            return payload["progressKind"]?.stringValue == "reader"
        }))
        let progressPayload = try JSONDecoder().decode([String: SyncJSONValue].self, from: readerProgress.payload)
        #expect(progressPayload["relativeSeconds"]?.numberValue == 12.875)
        #expect(progressPayload["localChapterId"]?.stringValue == chapterID)
    }

    @Test("Sync snapshot keeps transcript bytes out of structured records")
    func syncSnapshotExcludesTranscriptBytes() throws {
        let chapterID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let sentence = "Listening changes us and careful repeated practice builds durable understanding. "
            + "Listening changes us and careful repeated practice builds durable understanding. "
        let template = StoredTranscriptSegment(
            id: "segment",
            start: 0,
            end: 1,
            words: [
                StoredTranscriptWord(id: "word-1", text: sentence, start: 0, end: 0.5, confidence: 0.98),
                StoredTranscriptWord(id: "word-2", text: sentence, start: 0.5, end: 1, confidence: 0.97)
            ],
            ebookText: sentence,
            alignmentScore: 0.99,
            individualEbookMatchTrusted: true,
            documentEbookUseAllowed: true
        )
        let segments = Array(repeating: template, count: 8_914)
        let stored = StoredTranscript(
            chapterID: ChapterID(rawValue: chapterID),
            localMediaKey: "",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            locale: "en-US",
            source: "spoken",
            ebookAligned: true,
            segments: segments
        )

        let mutations = try AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: [],
            lemmas: [],
            transcripts: [stored]
        )
        #expect(!mutations.contains { $0.entityType == OutboxEntityType.transcript })
    }

    @Test("Pulled vocabulary, SRS progress, and review history share durable parents")
    func pulledLearningStateRoundTripsThroughLocalStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-learning-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let vocabularyID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let vocabulary = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityId: vocabularyID,
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T02:00:00Z",
            payload: [
                "bookId": .string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
                "chapterId": .string("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
                "bookTitle": .string("Moby-Dick"),
                "chapterTitle": .string("Loomings"),
                "surface": .string("gave up"),
                "lemma": .string("give up"),
                "partOfSpeech": .string("verb"),
                "senseId": .string("give-up:stop"),
                "canonicalizationSource": .string("irregularRule"),
                "canonicalizationConfidence": .number(0.99),
                "canonicalizationStatus": .string("confirmed"),
                "canonicalizationTraceId": .string("trace-pulled"),
                "captureSource": .string("explicitPhrase"),
                "reviewEligible": .bool(true),
                "category": .string("phrase"),
                "context": .string("The ice closed over."),
                "timestampSeconds": .number(3),
                "state": .string("learning")
            ]
        )
        let progress = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.progress.rawValue,
            entityId: vocabularyID,
            operation: OutboxOperation.upsert.rawValue,
            revision: 2,
            changedAt: "2026-08-30T02:10:00Z",
            payload: [
                "vocabularyId": .string(vocabularyID),
                "reviewCount": .number(4),
                "nextReview": .string("2026-09-11T02:10:00Z"),
                "lastReviewedAt": .string("2026-08-30T02:10:00Z"),
                "lastReviewQuality": .string(VocabReviewQuality.remember.rawValue),
                "reviewIntervalDays": .number(12),
                "reviewEaseFactor": .number(2.8)
            ]
        )
        let review = SyncPulledChange(
            sequence: 3,
            entityType: OutboxEntityType.reviewEvent.rawValue,
            entityId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            operation: OutboxOperation.append.rawValue,
            revision: 1,
            changedAt: "2026-08-30T02:10:00Z",
            payload: [
                "vocabularyId": .string(vocabularyID),
                "cardId": .string("study:give-up"),
                "face": .string("recognition"),
                "rating": .string(VocabReviewQuality.remember.rawValue),
                "reviewedAt": .string("2026-08-30T02:10:00Z")
            ]
        )

        _ = try AccountSyncApplicator.applyLearning(vocabulary, to: store)
        _ = try AccountSyncApplicator.applyLearning(progress, to: store)
        _ = try AccountSyncApplicator.applyLearning(review, to: store)

        var stored = try #require(try store.loadVocabulary().first)
        #expect(stored.reviewCount == 4)
        #expect(stored.reviewIntervalDays == 12)
        #expect(stored.reviewEaseFactor == 2.8)
        #expect(stored.surface == "gave up")
        #expect(stored.senseID == "give-up:stop")
        #expect(stored.canonicalizationTraceID == "trace-pulled")
        #expect(stored.canonicalForm == "give up")
        #expect(stored.partOfSpeech == "verb")
        #expect(stored.captureSource == "explicitPhrase")
        #expect(stored.reviewEligible)
        #expect(try store.loadReviewEvents().map(\.id.rawValue) == [review.entityId])

        var newerProgress = progress
        newerProgress.sequence = 4
        newerProgress.payload["lastReviewedAt"] = .string("2026-08-31T02:10:00Z")
        _ = try AccountSyncApplicator.applyLearning(newerProgress, to: store)
        _ = try AccountSyncApplicator.applyLearning(review, to: store)

        stored = try #require(try store.loadVocabulary().first)
        #expect(stored.lastReviewedAt == ISO8601DateFormatter().date(from: "2026-08-31T02:10:00Z"))
        #expect(try store.loadReviewEvents().count == 1)
    }

    @Test("Vocabulary deletion enqueues a tombstone and removes the durable learning graph")
    func vocabularyDeletionIsDurableAndSyncable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library-vNext.sqlite")
        let relational = LocalSQLiteStore(fileURL: url)
        let repository: any VocabularyRepository = relational
        let vocabularyID = VocabularyOccurrenceID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let item = StoredVocabularyOccurrence(
            id: vocabularyID,
            surface: "ice",
            category: VocabCategory.word.rawValue,
            context: "The ice closed over.",
            bookID: BookID(rawValue: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
            chapterTitle: "Loomings",
            timestamp: 3,
            addedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        try repository.saveVocabulary([item])
        try relational.appendReviewEvent(
            StoredReviewEvent(
                id: ReviewEventID(rawValue: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
                vocabularyID: vocabularyID,
                face: "recognition",
                rating: VocabReviewQuality.remember.rawValue,
                reviewedAt: Date(timeIntervalSince1970: 1_777_000_100)
            ),
            vocabulary: item
        )

        try repository.deleteVocabulary(id: vocabularyID)

        let tombstone = try #require(try relational.pendingMutations().first)
        #expect(tombstone.entityType == .vocabulary)
        #expect(tombstone.entityID == vocabularyID.rawValue)
        #expect(tombstone.operation == .delete)
        #expect(
            try JSONDecoder().decode([String: SyncJSONValue].self, from: tombstone.payload)["_deleted"]
                == .bool(true)
        )
        #expect(
            try JSONDecoder().decode([String: SyncJSONValue].self, from: tombstone.payload)["localId"]
                == .string(vocabularyID.rawValue)
        )
        #expect(try repository.loadVocabulary().isEmpty)
        #expect(try relational.loadVocabulary().isEmpty)
        #expect(try relational.loadReviewCards().isEmpty)
        #expect(try relational.loadReviewEvents().isEmpty)
    }

    @Test("A vocabulary tombstone deletes the second device and blocks dependent resurrection")
    func vocabularyDeletionRoundTripsAcrossDevices() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-delete-device-b-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let vocabularyID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let item = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: vocabularyID),
            surface: "ice",
            category: VocabCategory.word.rawValue,
            context: "The ice closed over.",
            bookID: BookID(rawValue: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
            chapterTitle: "Loomings",
            timestamp: 3,
            addedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        try store.upsertVocabulary(item)
        let deletion = SyncPulledChange(
            sequence: 8,
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityId: vocabularyID,
            operation: OutboxOperation.delete.rawValue,
            revision: 2,
            changedAt: "2026-08-30T03:00:00Z",
            payload: [:]
        )

        _ = try AccountSyncApplicator.applyLearning(deletion, to: store)
        try store.saveVersion(
            SyncEntityVersion(
                entityType: deletion.entityType,
                entityID: deletion.entityId,
                serverVersion: Int64(deletion.revision),
                payload: Data("{\"_deleted\":true}".utf8)
            )
        )
        let staleReview = SyncPulledChange(
            sequence: 9,
            entityType: OutboxEntityType.reviewEvent.rawValue,
            entityId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            operation: OutboxOperation.append.rawValue,
            revision: 1,
            changedAt: "2026-08-30T03:01:00Z",
            payload: [
                "vocabularyId": .string(vocabularyID),
                "face": .string("recognition"),
                "rating": .string(VocabReviewQuality.remember.rawValue),
                "reviewedAt": .string("2026-08-30T03:01:00Z")
            ]
        )

        _ = try AccountSyncApplicator.applyLearning(staleReview, to: store)

        #expect(try store.loadVocabulary().isEmpty)
        #expect(try store.loadReviewEvents().isEmpty)
        #expect(try !AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: try store.loadVocabulary().map(VocabEntry.init),
            lemmas: []
        ).contains(where: { $0.entityType == .vocabulary && $0.entityID == vocabularyID }))
    }

    @Test("A non-UUID vocabulary tombstone deletes the original local identifier on another device")
    func legacyVocabularyDeletionRoundTripsAcrossDevices() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-delete-legacy-device-b-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let localID = "legacy-vocabulary-ice"
        let entityID = AccountSyncApplicator.syncEntityID(localID, kind: "vocab")
        let item = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: localID),
            surface: "ice",
            category: VocabCategory.word.rawValue,
            context: "The ice closed over.",
            bookID: BookID(rawValue: "book"),
            bookTitle: "Moby-Dick",
            chapterID: ChapterID(rawValue: "chapter"),
            chapterTitle: "Loomings",
            timestamp: 3,
            addedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        try store.upsertVocabulary(item)
        let deletion = SyncPulledChange(
            sequence: 8,
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityId: entityID,
            operation: OutboxOperation.delete.rawValue,
            revision: 2,
            changedAt: "2026-08-30T03:00:00Z",
            payload: [
                "_deleted": .bool(true),
                "localId": .string(localID)
            ]
        )

        var mismatchedDeletion = deletion
        mismatchedDeletion.payload["localId"] = .string("another-local-vocabulary")
        _ = try AccountSyncApplicator.applyLearning(mismatchedDeletion, to: store)
        #expect(try store.loadVocabulary().map(\.id.rawValue) == [localID])

        _ = try AccountSyncApplicator.applyLearning(deletion, to: store)

        #expect(try store.loadVocabulary().isEmpty)
    }

    @Test("A review without its durable vocabulary parent remains retriable")
    func pulledReviewRequiresDurableVocabularyParent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-review-parent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let review = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.reviewEvent.rawValue,
            entityId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            operation: OutboxOperation.append.rawValue,
            revision: 1,
            changedAt: "2026-08-30T02:10:00Z",
            payload: [
                "vocabularyId": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                "cardId": .string("study:give-up"),
                "face": .string("recognition"),
                "rating": .string(VocabReviewQuality.remember.rawValue),
                "reviewedAt": .string("2026-08-30T02:10:00Z")
            ]
        )

        #expect(throws: (any Error).self) {
            _ = try AccountSyncApplicator.applyLearning(review, to: store)
        }
        #expect(try store.loadReviewEvents().isEmpty)
    }

    @Test("Review events append immutable history for learning statistics")
    func reviewRepositoryAppendsHistory() throws {
        let repository = InMemoryReviewEventRepository()
        let reviewedAt = try #require(ISO8601DateFormatter().date(from: "2026-08-30T02:14:30Z"))
        let stored = StoredReviewEvent(
            id: ReviewEventID(rawValue: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
            vocabularyID: VocabularyOccurrenceID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            cardID: "study:give-up",
            face: "recognition",
            rating: VocabReviewQuality.remember.rawValue,
            reviewedAt: reviewedAt
        )

        try repository.appendReviewEvent(stored)
        try repository.appendReviewEvent(stored)

        let events = try repository.loadReviewEvents()
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.id.rawValue == "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
        #expect(event.vocabularyID.rawValue == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        #expect(event.cardID == "study:give-up")
        #expect(event.face == "recognition")
        #expect(event.rating == VocabReviewQuality.remember.rawValue)
        #expect(event.reviewedAt == reviewedAt)
    }

    @Test("Vocabulary sync carries local sentence and translation provenance additively")
    func vocabularySyncCarriesPortableFields() throws {
        let item = VocabEntry(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            word: "gave up",
            canonicalForm: "give up",
            partOfSpeech: .verb,
            senseID: "give-up:stop",
            canonicalizationSource: .irregularRule,
            canonicalizationConfidence: 0.99,
            canonicalizationStatus: .confirmed,
            canonicalizationTraceID: "trace-123",
            captureSource: .explicitPhrase,
            reviewEligible: true,
            category: .phrase,
            definition: "frozen water",
            translation: "冰",
            translationLanguage: "zh-Hans",
            translationModel: "qwen",
            sourceLanguage: "en-US",
            context: "The ice closed over.",
            spokenText: "The ice closed over.",
            ebookText: "The ice had closed over.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            segmentID: "segment",
            wordID: "word",
            timestamp: 3,
            addedAt: Date(timeIntervalSince1970: 1)
        )
        let mutation = try #require(AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: [item],
            lemmas: []
        ).first(where: { $0.entityType == .vocabulary }))
        let payload = try JSONDecoder().decode([String: SyncJSONValue].self, from: mutation.payload)

        #expect(payload["segmentId"]?.stringValue == "segment")
        #expect(payload["wordId"]?.stringValue == "word")
        #expect(payload["spokenText"]?.stringValue == "The ice closed over.")
        #expect(payload["surface"]?.stringValue == "gave up")
        #expect(payload["lemma"]?.stringValue == "give up")
        #expect(payload["partOfSpeech"]?.stringValue == "verb")
        #expect(payload["canonicalizationSource"]?.stringValue == "irregularRule")
        #expect(payload["canonicalizationStatus"]?.stringValue == "confirmed")
        #expect(payload["senseId"]?.stringValue == "give-up:stop")
        #expect(payload["canonicalizationTraceId"]?.stringValue == "trace-123")
        #expect(payload["captureSource"]?.stringValue == "explicitPhrase")
        #expect(payload["reviewEligible"] == .bool(true))
        #expect(payload["ebookText"]?.stringValue == "The ice had closed over.")
        #expect(payload["translationLanguage"]?.stringValue == "zh-Hans")
        #expect(payload["translationModel"]?.stringValue == "qwen")
        #expect(payload["sourceLanguage"]?.stringValue == "en-US")
    }

    @Test("Sync snapshot hashes non-UUID book and chapter IDs instead of the settings sentinel")
    func syncSnapshotHashesBookAndChapterIDs() throws {
        let vocabID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let mutations = try AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: [
                VocabEntry(
                    id: vocabID,
                    word: "loom",
                    context: "Call me Ishmael",
                    bookID: "moby-folder",
                    bookTitle: "Moby-Dick",
                    chapterID: "loomings",
                    chapterTitle: "Loomings",
                    timestamp: 4,
                    addedAt: Date(timeIntervalSince1970: 1_777_000_000),
                    isInLearnList: true
                )
            ],
            lemmas: [],
            books: [
                StoredBook(
                    id: BookID(rawValue: "moby-folder"),
                    title: "Moby-Dick",
                    author: nil,
                    source: "local_folder",
                    chapters: [
                        StoredChapter(id: ChapterID(rawValue: "loomings"), index: 0, title: "Loomings")
                    ]
                )
            ]
        )
        let vocab = try #require(mutations.first { $0.entityType == .vocabulary })
        let payload = try JSONDecoder().decode([String: SyncJSONValue].self, from: vocab.payload)
        let bookID = AccountSyncApplicator.syncEntityID("moby-folder", kind: "book")
        let chapterID = AccountSyncApplicator.syncEntityID("loomings", kind: "chapter")
        #expect(payload["bookId"]?.stringValue == bookID)
        #expect(payload["chapterId"]?.stringValue == chapterID)
        #expect(payload["localBookId"]?.stringValue == "moby-folder")
        #expect(payload["localChapterId"]?.stringValue == "loomings")
        #expect(payload["bookId"]?.stringValue != AccountSyncApplicator.settingsEntityID)
        #expect(mutations.contains(where: { $0.entityType == .book && $0.entityID == bookID }))
    }

    @Test("Vocabulary apply keeps existing SRS fields when the pull omits them")
    func applyVocabularyPreservesReviewState() {
        let existing = VocabEntry(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            word: "loom",
            context: "Call me Ishmael",
            bookID: "book-1",
            bookTitle: "Moby-Dick",
            chapterID: "ch-1",
            chapterTitle: "Loomings",
            timestamp: 4,
            addedAt: Date(timeIntervalSince1970: 1_777_000_000),
            reviewCount: 4,
            nextReview: Date(timeIntervalSince1970: 1_777_100_000),
            lastReviewedAt: Date(timeIntervalSince1970: 1_777_000_100),
            lastReviewQuality: .remember,
            reviewIntervalDays: 6,
            reviewEaseFactor: 2.8,
            isInLearnList: true
        )
        let incoming = VocabEntry(
            id: existing.id,
            word: "loom",
            context: "Call me Ishmael",
            bookID: "book-1",
            bookTitle: "Moby-Dick",
            chapterID: "ch-1",
            chapterTitle: "Loomings",
            timestamp: 4,
            addedAt: Date(timeIntervalSince1970: 1_777_000_000),
            isInLearnList: true
        )
        let merged = AccountSyncApplicator.mergingVocabulary(existing: existing, incoming: incoming)
        #expect(merged.reviewCount == 4)
        #expect(merged.lastReviewQuality == .remember)
        #expect(merged.reviewIntervalDays == 6)
        #expect(merged.reviewEaseFactor == 2.8)
        #expect(merged.nextReview == existing.nextReview)
    }

    @Test("Legacy bootstrap vocabulary never resurrects automatic material into New")
    func legacyBootstrapInfersAutomaticCaptureEligibility() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-legacy-bootstrap-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let sentence = legacyVocabularyChange(id: "legacy-sentence", category: .sentence, state: "unknown")
        let phrase = legacyVocabularyChange(id: "legacy-phrase", category: .phrase, state: "unknown")
        let savedPhrase = legacyVocabularyChange(id: "saved-phrase", category: .phrase, state: "learning")

        try AccountSyncApplicator.applyPage(
            [sentence, phrase, savedPhrase],
            cursor: "3",
            to: store
        )

        let entries = try store.loadVocabulary().map(VocabEntry.init)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        #expect(byID["legacy-sentence"]?.captureSource == .acceptedSentenceTranslation)
        #expect(byID["legacy-sentence"]?.reviewEligible == false)
        #expect(byID["legacy-phrase"]?.captureSource == .automaticPhraseSuggestion)
        #expect(byID["legacy-phrase"]?.reviewEligible == false)
        #expect(byID["saved-phrase"]?.captureSource == .explicitPhrase)
        #expect(byID["saved-phrase"]?.reviewEligible == true)
        #expect(VocabularyLearningAnalytics.queue(entries: entries, at: .now).new.map(\.id) == ["saved-phrase"])
    }

    @Test("Legacy reviewed progress makes an automatic capture eligible without changing provenance")
    func legacyReviewedProgressRestoresEligibility() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-legacy-reviewed-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let sentence = legacyVocabularyChange(id: "reviewed-sentence", category: .sentence, state: "unknown")
        let progress = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.progress.rawValue,
            entityId: "reviewed-sentence-progress",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: [
                "vocabularyId": .string("reviewed-sentence"),
                "reviewCount": .number(2),
                "lastReviewedAt": .string("2026-08-30T00:00:00Z")
            ]
        )

        try AccountSyncApplicator.applyPage(
            [sentence, progress],
            cursor: "2",
            to: store
        )

        let entry = try #require(try store.loadVocabulary().first.map(VocabEntry.init))
        #expect(entry.reviewCount == 2)
        #expect(entry.captureSource == .acceptedSentenceTranslation)
        #expect(entry.reviewEligible)
    }

    @Test("Incremental legacy vocabulary preserves local canonical and eligibility metadata")
    func legacyIncrementalMergePreservesLocalMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-legacy-incremental-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let existing = VocabEntry(
            id: "legacy-phrase",
            word: "axes",
            canonicalForm: "axis",
            partOfSpeech: .noun,
            senseID: "axis:geometry",
            canonicalizationSource: .userEdited,
            canonicalizationConfidence: 1,
            canonicalizationStatus: .confirmed,
            captureSource: .automaticPhraseSuggestion,
            reviewEligible: false,
            category: .phrase,
            context: "The axes crossed.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )
        try store.upsertVocabulary(StoredVocabularyOccurrence(existing))

        _ = try AccountSyncApplicator.applyLearning(
            legacyVocabularyChange(id: existing.id, category: .phrase, state: "unknown"),
            to: store
        )
        let merged = try #require(try store.loadVocabulary().first.map(VocabEntry.init))

        #expect(merged.canonicalForm == "axis")
        #expect(merged.partOfSpeech == .noun)
        #expect(merged.senseID == "axis:geometry")
        #expect(merged.canonicalizationSource == .userEdited)
        #expect(merged.canonicalizationStatus == .confirmed)
        #expect(merged.captureSource == .automaticPhraseSuggestion)
        #expect(merged.reviewEligible == false)
    }

    @Test("Explicit new-format sync metadata replaces local canonical metadata")
    func newFormatIncrementalMergeUsesExplicitFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-new-format-incremental-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        var existing = VocabEntry(
            id: "new-format",
            word: "bank",
            context: "A bank.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )
        existing.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: "bank:river-edge")
        try store.upsertVocabulary(StoredVocabularyOccurrence(existing))
        var change = legacyVocabularyChange(id: existing.id, category: .word, state: "unknown")
        change.payload["lemma"] = .string("bank")
        change.payload["partOfSpeech"] = .string("noun")
        change.payload["senseId"] = .string("bank:financial-institution")
        change.payload["canonicalizationSource"] = .string("cachedLLM")
        change.payload["canonicalizationConfidence"] = .number(0.94)
        change.payload["canonicalizationStatus"] = .string("confirmed")
        change.payload["canonicalizationTraceId"] = .string("provider-message-17")
        change.payload["captureSource"] = .string("explicitWord")
        change.payload["reviewEligible"] = .bool(true)

        _ = try AccountSyncApplicator.applyLearning(change, to: store)
        let merged = try #require(try store.loadVocabulary().first.map(VocabEntry.init))

        #expect(merged.senseID == "bank:financial-institution")
        #expect(merged.canonicalizationSource == .cachedLLM)
        #expect(merged.canonicalizationTraceID == "provider-message-17")
        #expect(merged.reviewEligible)
    }

    @Test("Versioned vocabulary snapshot bootstraps intentional nil canonical fields")
    func versionedVocabularyBootstrapRoundTripsNilCanonicalFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-versioned-bootstrap-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let entry = VocabEntry(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            word: "bank",
            canonicalForm: "bank",
            partOfSpeech: .noun,
            senseID: nil,
            canonicalizationSource: .userEdited,
            canonicalizationConfidence: 0.5,
            canonicalizationStatus: .needsReview,
            canonicalizationTraceID: nil,
            context: "Bank.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )
        let mutation = try #require(AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: [entry],
            lemmas: []
        ).first { $0.entityType == .vocabulary })
        let payload = try JSONDecoder().decode([String: SyncJSONValue].self, from: mutation.payload)
        #expect(payload["vocabularySchemaVersion"] == .number(1))

        try AccountSyncApplicator.applyPage(
            [pulledVocabularyChange(from: mutation, payload: payload)],
            cursor: "1",
            to: store
        )

        let restored = try #require(try store.loadVocabulary().first.map(VocabEntry.init))
        #expect(restored.canonicalizationSource == .userEdited)
        #expect(restored.senseID == nil)
        #expect(restored.canonicalizationTraceID == nil)
    }

    @Test("Versioned incremental vocabulary clears an old provider sense and trace")
    func versionedVocabularyIncrementalRoundTripsNilCanonicalFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-versioned-incremental-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let existing = VocabEntry(
            id: id,
            word: "bank",
            canonicalForm: "bank",
            partOfSpeech: .noun,
            senseID: "bank:financial-institution",
            canonicalizationSource: .cachedLLM,
            canonicalizationConfidence: 0.94,
            canonicalizationStatus: .confirmed,
            canonicalizationTraceID: "provider-message-old",
            context: "Bank.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )
        try store.upsertVocabulary(StoredVocabularyOccurrence(existing))
        var edited = existing
        edited.confirmCanonicalForm("bank", partOfSpeech: .noun, senseID: nil)
        let mutation = try #require(AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: [edited],
            lemmas: []
        ).first { $0.entityType == .vocabulary })
        let payload = try JSONDecoder().decode([String: SyncJSONValue].self, from: mutation.payload)

        _ = try AccountSyncApplicator.applyLearning(
            pulledVocabularyChange(from: mutation, payload: payload),
            to: store
        )
        let merged = try #require(try store.loadVocabulary().first.map(VocabEntry.init))

        #expect(merged.canonicalizationSource == .userEdited)
        #expect(merged.senseID == nil)
        #expect(merged.canonicalizationTraceID == nil)
    }

    @Test("Unversioned legacy absence preserves a cached provider sense and trace")
    func legacyAbsentOptionalCanonicalFieldsPreserveLocalValues() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-legacy-optional-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let existing = VocabEntry(
            id: "legacy-provider",
            word: "bank",
            canonicalForm: "bank",
            partOfSpeech: .noun,
            senseID: "bank:financial-institution",
            canonicalizationSource: .cachedLLM,
            canonicalizationConfidence: 0.94,
            canonicalizationStatus: .confirmed,
            canonicalizationTraceID: "provider-message-17",
            context: "The bank approved it.",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1)
        )
        try store.upsertVocabulary(StoredVocabularyOccurrence(existing))

        _ = try AccountSyncApplicator.applyLearning(
            legacyVocabularyChange(id: existing.id, category: .word, state: "unknown"),
            to: store
        )
        let merged = try #require(try store.loadVocabulary().first.map(VocabEntry.init))

        #expect(merged.senseID == "bank:financial-institution")
        #expect(merged.canonicalizationSource == .cachedLLM)
        #expect(merged.canonicalizationTraceID == "provider-message-17")
    }

    @Test("A failed sync page rolls back rows, entity versions, and cursor")
    func failedSyncPageIsAtomic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-page-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let vocabulary = syncVocabularyChange(index: 1)
        let invalidProgress = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.progress.rawValue,
            entityId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: ["vocabularyId": .string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")]
        )

        #expect(throws: (any Error).self) {
            try AccountSyncApplicator.applyPage(
                [vocabulary, invalidProgress],
                cursor: "2",
                to: store
            )
        }

        #expect(try store.loadVocabulary().isEmpty)
        #expect(try store.loadVersion(entityType: vocabulary.entityType, entityID: vocabulary.entityId) == nil)
        #expect(try store.loadCursor() == "0")
    }

    @Test("Case-variant vocabulary IDs merge without losing review state or page atomicity")
    func caseVariantVocabularyIDsMergeDuringPageApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-vocabulary-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library-vNext.sqlite")
        let lowercaseID = "40a95295-1975-49c9-8efc-4aabf78bfd76"
        let uppercaseID = lowercaseID.uppercased()
        let bookID = BookID(rawValue: "case-book")
        let chapterID = ChapterID(rawValue: "case-chapter")

        do {
            let setup = LocalSQLiteStore(fileURL: databaseURL)
            let uppercase = StoredVocabularyOccurrence(
                id: VocabularyOccurrenceID(rawValue: uppercaseID),
                surface: "bank",
                category: VocabCategory.word.rawValue,
                definition: "a financial institution",
                context: "The bank approved it.",
                bookID: bookID,
                bookTitle: "Book",
                chapterID: chapterID,
                chapterTitle: "Chapter",
                timestamp: 1,
                addedAt: Date(timeIntervalSince1970: 10),
                reviewCount: 3,
                nextReview: Date(timeIntervalSince1970: 300),
                lastReviewedAt: Date(timeIntervalSince1970: 30),
                lastReviewQuality: VocabReviewQuality.remember.rawValue,
                reviewIntervalDays: 3,
                reviewEaseFactor: 2.6,
                isInLearnList: true
            )
            try setup.upsertVocabulary(uppercase)
            try setup.appendReviewEvent(
                StoredReviewEvent(
                    id: ReviewEventID(rawValue: "case-review-uppercase"),
                    vocabularyID: uppercase.id,
                    cardID: "case-card-uppercase",
                    face: "recognition",
                    rating: VocabReviewQuality.remember.rawValue,
                    reviewedAt: Date(timeIntervalSince1970: 30)
                ),
                vocabulary: uppercase
            )
        }

        // Reproduce the legacy on-disk invariant directly, bypassing current write-path guards.
        let legacy = SQLiteConnection(fileURL: databaseURL)
        try legacy.run(
            """
            INSERT INTO local_vocabulary_occurrences(
              id, surface, canonical_form, part_of_speech, sense_id,
              canonicalization_source, canonicalization_confidence, canonicalization_status,
              canonicalization_trace_id, capture_source, review_eligible, category, definition,
              dictionary_name, dictionary_html, translation, translation_language, translation_model,
              source_language, context, spoken_text, ebook_text, book_id, book_title, chapter_id,
              chapter_title, segment_id, word_id, timestamp, added_at, review_count, next_review,
              last_reviewed_at, last_review_quality, review_interval_days, review_ease_factor,
              is_in_learn_list, created_at, updated_at, server_version
            )
            SELECT ?, surface, canonical_form, part_of_speech, sense_id,
              canonicalization_source, canonicalization_confidence, canonicalization_status,
              canonicalization_trace_id, capture_source, review_eligible, category, NULL,
              dictionary_name, dictionary_html, ?, ?, translation_model,
              source_language, context, spoken_text, ebook_text, book_id, book_title, chapter_id,
              chapter_title, segment_id, word_id, timestamp, 20, 5, 500,
              50, ?, 5, 2.8, 0, 20, 50, server_version
            FROM local_vocabulary_occurrences WHERE id = ?
            """
        ) { statement in
            legacy.bind(statement, 1, lowercaseID)
            legacy.bind(statement, 2, "\u{94f6}\u{884c}")
            legacy.bind(statement, 3, "zh-Hans")
            legacy.bind(statement, 4, VocabReviewQuality.remember.rawValue)
            legacy.bind(statement, 5, uppercaseID)
        }
        try legacy.run(
            """
            INSERT INTO local_review_cards(
              id, vocabulary_id, face, review_count, next_review, last_reviewed_at,
              last_review_quality, review_interval_days, review_ease_factor,
              created_at, updated_at, server_version
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,0)
            """
        ) { statement in
            legacy.bind(statement, 1, "case-card-lowercase")
            legacy.bind(statement, 2, lowercaseID)
            legacy.bind(statement, 3, "recognition")
            legacy.bind(statement, 4, 5)
            legacy.bind(statement, 5, 500.0)
            legacy.bind(statement, 6, 50.0)
            legacy.bind(statement, 7, VocabReviewQuality.remember.rawValue)
            legacy.bind(statement, 8, 5.0)
            legacy.bind(statement, 9, 2.8)
            legacy.bind(statement, 10, 20.0)
            legacy.bind(statement, 11, 50.0)
        }
        try legacy.run(
            """
            INSERT INTO local_review_events(
              id, vocabulary_id, card_id, face, rating, reviewed_at, created_at, server_version
            ) VALUES (?,?,?,?,?,?,?,0)
            """
        ) { statement in
            legacy.bind(statement, 1, "case-review-lowercase")
            legacy.bind(statement, 2, lowercaseID)
            legacy.bind(statement, 3, "case-card-lowercase")
            legacy.bind(statement, 4, "recognition")
            legacy.bind(statement, 5, VocabReviewQuality.remember.rawValue)
            legacy.bind(statement, 6, 50.0)
            legacy.bind(statement, 7, 50.0)
        }
        #expect(try legacy.query("SELECT id FROM local_vocabulary_occurrences").count == 2)

        let store = LocalSQLiteStore(fileURL: databaseURL)
        let cardPlan = try legacy.query(
            "EXPLAIN QUERY PLAN SELECT * FROM local_review_cards WHERE lower(vocabulary_id) = ?"
        ) { statement in legacy.bind(statement, 1, lowercaseID) }
            .compactMap { $0["detail"] }
            .joined(separator: " ")
        let eventPlan = try legacy.query(
            "EXPLAIN QUERY PLAN UPDATE local_review_events SET vocabulary_id = ? WHERE lower(vocabulary_id) = ?"
        ) { statement in
            legacy.bind(statement, 1, lowercaseID)
            legacy.bind(statement, 2, lowercaseID)
        }
            .compactMap { $0["detail"] }
            .joined(separator: " ")
        let cardReferencePlan = try legacy.query(
            "EXPLAIN QUERY PLAN UPDATE local_review_events SET card_id = ? WHERE card_id = ?"
        ) { statement in
            legacy.bind(statement, 1, "case-card-lowercase")
            legacy.bind(statement, 2, "case-card-uppercase")
        }
            .compactMap { $0["detail"] }
            .joined(separator: " ")
        #expect(cardPlan.contains("SEARCH local_review_cards USING INDEX idx_local_review_cards_canonical_vocab"))
        #expect(eventPlan.contains("SEARCH local_review_events USING INDEX idx_local_review_events_canonical_vocab"))
        #expect(cardReferencePlan.contains("SEARCH local_review_events"))
        #expect(cardReferencePlan.contains("idx_local_review_events_card"))
        let incoming = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityId: lowercaseID,
            operation: OutboxOperation.upsert.rawValue,
            revision: 2,
            changedAt: "2026-09-01T05:00:00Z",
            payload: [
                "bookId": .string(bookID.rawValue),
                "chapterId": .string(chapterID.rawValue),
                "bookTitle": .string("Book"),
                "chapterTitle": .string("Chapter"),
                "surface": .string("bank"),
                "definition": .string("a financial institution"),
                "note": .string("\u{94f6}\u{884c}"),
                "translationLanguage": .string("zh-Hans"),
                "context": .string("The bank approved it."),
                "state": .string("learning")
            ]
        )
        let invalidProgress = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.progress.rawValue,
            entityId: lowercaseID,
            operation: OutboxOperation.upsert.rawValue,
            revision: 2,
            changedAt: "2026-09-01T05:00:01Z",
            payload: ["vocabularyId": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")]
        )

        #expect(throws: (any Error).self) {
            try AccountSyncApplicator.applyPage(
                [incoming, invalidProgress],
                cursor: "201",
                to: store
            )
        }
        #expect(try store.loadCursor() == "0")
        #expect(try store.loadVersion(
            entityType: incoming.entityType,
            entityID: incoming.entityId
        ) == nil)

        try AccountSyncApplicator.applyPage([incoming], cursor: "202", to: store)

        let merged = try #require(try store.loadVocabulary().first)
        #expect(try store.loadVocabulary().count == 1)
        #expect(merged.id.rawValue == lowercaseID)
        #expect(merged.addedAt == Date(timeIntervalSince1970: 10))
        #expect(merged.definition == "a financial institution")
        #expect(merged.translation == "\u{94f6}\u{884c}")
        #expect(merged.reviewCount == 5)
        #expect(merged.lastReviewedAt == Date(timeIntervalSince1970: 50))
        #expect(merged.isInLearnList)
        #expect(Set(try store.loadReviewEvents().map(\.id.rawValue)) == [
            "case-review-uppercase", "case-review-lowercase",
        ])
        #expect(try store.loadReviewEvents().allSatisfy { $0.vocabularyID.rawValue == lowercaseID })
        #expect(try store.loadReviewCards().count == 1)
        #expect(try store.loadReviewCards().first?.vocabularyID.rawValue == lowercaseID)
        #expect(try store.loadCursor() == "202")
        #expect(try store.loadVersion(
            entityType: incoming.entityType,
            entityID: incoming.entityId
        )?.serverVersion == 2)

        let recurrenceID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        try store.upsertVocabulary(StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: recurrenceID.uppercased()),
            surface: "harbor",
            category: VocabCategory.word.rawValue,
            context: "The ship entered the harbor.",
            bookID: bookID,
            bookTitle: "Book",
            chapterID: chapterID,
            chapterTitle: "Chapter",
            timestamp: 2,
            addedAt: Date(timeIntervalSince1970: 60)
        ))
        var recurrence = incoming
        recurrence.sequence = 3
        recurrence.entityId = recurrenceID
        recurrence.revision = 1
        recurrence.payload["surface"] = .string("harbor")
        recurrence.payload["context"] = .string("The ship entered the harbor.")

        try AccountSyncApplicator.applyPage([recurrence], cursor: "203", to: store)
        #expect(try store.loadVocabulary().filter {
            $0.id.rawValue.lowercased() == recurrenceID
        }.map(\.id.rawValue) == [recurrenceID])
        try AccountSyncApplicator.applyPage([], cursor: "204", to: store)
        #expect(try store.loadCursor() == "204")
        #expect(try legacy.query("PRAGMA foreign_key_check").isEmpty)
    }

    @Test("Every vocabulary insertion path enforces canonical UUID identity")
    func everyVocabularyInsertionPathRepairsCaseAliases() throws {
        for index in 1...3 {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("audio-reader-vocabulary-insert-path-\(index)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("library-vNext.sqlite")
            let store = LocalSQLiteStore(fileURL: databaseURL)
            let lowercaseID = "aaaaaaaa-bbbb-4ccc-8ddd-\(String(format: "%012d", index))"
            let bookID = BookID(rawValue: "insert-path-book-\(index)")
            let chapterID = ChapterID(rawValue: "insert-path-chapter-\(index)")
            var uppercase = StoredVocabularyOccurrence(
                id: VocabularyOccurrenceID(rawValue: lowercaseID.uppercased()),
                surface: "harbor",
                category: VocabCategory.word.rawValue,
                definition: "a sheltered place for ships",
                context: "The ship entered the harbor.",
                bookID: bookID,
                bookTitle: "Book",
                chapterID: chapterID,
                chapterTitle: "Chapter",
                timestamp: 1,
                addedAt: Date(timeIntervalSince1970: 10),
                isInLearnList: true
            )
            try store.upsertVocabulary(uppercase)
            uppercase.id = VocabularyOccurrenceID(rawValue: lowercaseID)
            uppercase.translation = "\u{6e2f}\u{53e3}"
            uppercase.translationLanguage = "zh-Hans"
            uppercase.addedAt = Date(timeIntervalSince1970: 20)

            switch index {
            case 1:
                try store.applyAssistantResults([], vocabulary: [uppercase])
            case 2:
                let result = StoredAssistantResult(
                    id: "insert-path-result-\(index)",
                    kind: .sentenceGloss,
                    status: .accepted,
                    language: "zh-Hans",
                    model: "test",
                    source: uppercase.context,
                    text: "accepted",
                    createdAt: Date(timeIntervalSince1970: 20)
                )
                try store.acceptAssistantResult(
                    result,
                    vocabulary: [uppercase],
                    mutation: OutboxMutation(
                        id: MutationID(rawValue: "insert-path-mutation-\(index)"),
                        entityType: .assistantResult,
                        entityID: result.id,
                        operation: .upsert,
                        baseRevision: .zero,
                        occurredAt: result.createdAt,
                        payload: Data("{}".utf8)
                    )
                )
            default:
                uppercase.reviewCount = 1
                uppercase.lastReviewedAt = Date(timeIntervalSince1970: 30)
                try store.appendReviewEvent(
                    StoredReviewEvent(
                        id: ReviewEventID(rawValue: "insert-path-review"),
                        vocabularyID: uppercase.id,
                        face: "recognition",
                        rating: VocabReviewQuality.remember.rawValue,
                        reviewedAt: Date(timeIntervalSince1970: 30)
                    ),
                    vocabulary: uppercase
                )
            }

            let aliases = try store.loadVocabulary().filter {
                $0.id.rawValue.lowercased() == lowercaseID
            }
            #expect(aliases.count == 1)
            #expect(aliases.first?.id.rawValue == lowercaseID)
            #expect(aliases.first?.addedAt == Date(timeIntervalSince1970: 10))
            if aliases.count == 1 {
                try AccountSyncApplicator.applyPage([], cursor: "insert-path-\(index)", to: store)
                #expect(try store.loadCursor() == "insert-path-\(index)")
            }
            let raw = SQLiteConnection(fileURL: databaseURL)
            #expect(try raw.query("PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test("Vocabulary child writes use the surviving canonical ID for reverse-case aliases")
    func vocabularyChildWritesCanonicalizeReverseCaseAliases() throws {
        for index in 1...3 {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("audio-reader-vocabulary-child-path-\(index)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("library-vNext.sqlite")
            let store = LocalSQLiteStore(fileURL: databaseURL)
            let lowercaseID = "bbbbbbbb-cccc-4ddd-8eee-\(String(format: "%012d", index))"
            let uppercaseID = lowercaseID.uppercased()
            let bookID = BookID(rawValue: "reverse-path-book-\(index)")
            let chapterID = ChapterID(rawValue: "reverse-path-chapter-\(index)")
            var incoming = StoredVocabularyOccurrence(
                id: VocabularyOccurrenceID(rawValue: lowercaseID),
                surface: "harbor",
                category: VocabCategory.word.rawValue,
                definition: "a sheltered place for ships",
                context: "The ship entered the harbor.",
                bookID: bookID,
                bookTitle: "Book",
                chapterID: chapterID,
                chapterTitle: "Chapter",
                timestamp: 1,
                addedAt: Date(timeIntervalSince1970: 10),
                isInLearnList: true
            )
            try store.upsertVocabulary(incoming)
            incoming.id = VocabularyOccurrenceID(rawValue: uppercaseID)
            incoming.translation = "\u{6e2f}\u{53e3}"
            incoming.translationLanguage = "zh-Hans"
            incoming.addedAt = Date(timeIntervalSince1970: 20)

            let result = StoredAssistantResult(
                id: "reverse-path-result-\(index)",
                kind: .sentenceGloss,
                status: .accepted,
                language: "zh-Hans",
                model: "test",
                source: incoming.context,
                text: "accepted",
                createdAt: Date(timeIntervalSince1970: 20)
            )
            var operationError: (any Error)?
            do {
                switch index {
                case 1:
                    try store.applyAssistantResults([result], vocabulary: [incoming])
                case 2:
                    try store.acceptAssistantResult(
                        result,
                        vocabulary: [incoming],
                        mutation: OutboxMutation(
                            id: MutationID(rawValue: "reverse-path-mutation-\(index)"),
                            entityType: .assistantResult,
                            entityID: result.id,
                            operation: .upsert,
                            baseRevision: .zero,
                            occurredAt: result.createdAt,
                            payload: Data("{}".utf8)
                        )
                    )
                default:
                    incoming.reviewCount = 1
                    incoming.lastReviewedAt = Date(timeIntervalSince1970: 30)
                    try store.appendReviewEvent(
                        StoredReviewEvent(
                            id: ReviewEventID(rawValue: "reverse-path-review"),
                            vocabularyID: incoming.id,
                            cardID: "reverse-path-card",
                            face: "recognition",
                            rating: VocabReviewQuality.remember.rawValue,
                            reviewedAt: Date(timeIntervalSince1970: 30)
                        ),
                        vocabulary: incoming
                    )
                }
            } catch {
                operationError = error
            }
            #expect(operationError == nil)
            guard operationError == nil else { continue }

            let aliases = try store.loadVocabulary().filter {
                $0.id.rawValue.lowercased() == lowercaseID
            }
            #expect(aliases.map(\.id.rawValue) == [lowercaseID])
            #expect(aliases.first?.addedAt == Date(timeIntervalSince1970: 10))
            let cards = try store.loadReviewCards().filter {
                $0.vocabularyID.rawValue.lowercased() == lowercaseID
            }
            #expect(!cards.isEmpty)
            #expect(cards.allSatisfy { $0.vocabularyID.rawValue == lowercaseID })
            if index < 3 {
                #expect(try store.loadAssistantResults().contains { $0.id == result.id })
            } else {
                let events = try store.loadReviewEvents().filter {
                    $0.id.rawValue == "reverse-path-review"
                }
                #expect(events.count == 1)
                #expect(events.first?.vocabularyID.rawValue == lowercaseID)
                #expect(events.first?.cardID == cards.first?.id)
            }
            try AccountSyncApplicator.applyPage([], cursor: "reverse-path-\(index)", to: store)
            #expect(try store.loadCursor() == "reverse-path-\(index)")
            let raw = SQLiteConnection(fileURL: databaseURL)
            #expect(try raw.query("PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test("Assistant case aliases reuse one canonical review card without reducing its state")
    func assistantCaseAliasesReuseCanonicalReviewCard() throws {
        for usesLocalAcceptance in [false, true] {
            let path = usesLocalAcceptance ? "accept" : "pull"
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("audio-reader-vocabulary-card-\(path)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("library-vNext.sqlite")
            let store = LocalSQLiteStore(fileURL: databaseURL)
            let lowercaseID = "cccccccc-dddd-4eee-8fff-000000000001"
            let canonicalCardID = "card:\(lowercaseID):recognition"
            let bookID = BookID(rawValue: "card-path-book-\(path)")
            let chapterID = ChapterID(rawValue: "card-path-chapter-\(path)")
            var reviewed = StoredVocabularyOccurrence(
                id: VocabularyOccurrenceID(rawValue: lowercaseID),
                surface: "harbor",
                category: VocabCategory.word.rawValue,
                context: "The ship entered the harbor.",
                bookID: bookID,
                bookTitle: "Book",
                chapterID: chapterID,
                chapterTitle: "Chapter",
                timestamp: 1,
                addedAt: Date(timeIntervalSince1970: 10),
                reviewCount: 4,
                nextReview: Date(timeIntervalSince1970: 400),
                lastReviewedAt: Date(timeIntervalSince1970: 40),
                lastReviewQuality: VocabReviewQuality.remember.rawValue,
                reviewIntervalDays: 4,
                reviewEaseFactor: 2.7,
                isInLearnList: true
            )
            try store.upsertVocabulary(reviewed)
            try store.appendReviewEvent(
                StoredReviewEvent(
                    id: ReviewEventID(rawValue: "card-path-review-\(path)"),
                    vocabularyID: reviewed.id,
                    cardID: canonicalCardID,
                    face: "recognition",
                    rating: VocabReviewQuality.remember.rawValue,
                    reviewedAt: Date(timeIntervalSince1970: 40)
                ),
                vocabulary: reviewed
            )

            reviewed.id = VocabularyOccurrenceID(rawValue: lowercaseID.uppercased())
            reviewed.reviewCount = 0
            reviewed.nextReview = nil
            reviewed.lastReviewedAt = nil
            reviewed.lastReviewQuality = nil
            reviewed.reviewIntervalDays = 0
            reviewed.reviewEaseFactor = 2.5
            reviewed.addedAt = Date(timeIntervalSince1970: 20)
            let firstResult = StoredAssistantResult(
                id: "card-path-first-\(path)",
                kind: .sentenceGloss,
                status: .accepted,
                language: "zh-Hans",
                model: "test",
                source: reviewed.context,
                text: "accepted",
                createdAt: Date(timeIntervalSince1970: 20)
            )
            if usesLocalAcceptance {
                try store.acceptAssistantResult(
                    firstResult,
                    vocabulary: [reviewed],
                    mutation: OutboxMutation(
                        id: MutationID(rawValue: "card-path-mutation"),
                        entityType: .assistantResult,
                        entityID: firstResult.id,
                        operation: .upsert,
                        baseRevision: .zero,
                        occurredAt: firstResult.createdAt,
                        payload: Data("{}".utf8)
                    )
                )
            } else {
                try store.applyAssistantResults([firstResult], vocabulary: [reviewed])
            }

            let cardsAfterAlias = try store.loadReviewCards().filter {
                $0.vocabularyID.rawValue == lowercaseID && $0.face == "recognition"
            }
            #expect(cardsAfterAlias.count == 1)
            #expect(cardsAfterAlias.first?.id == canonicalCardID)
            #expect(cardsAfterAlias.first?.reviewCount == 4)

            var canonical = try #require(try store.loadVocabulary().first {
                $0.id.rawValue == lowercaseID
            })
            canonical.translation = "\u{6e2f}\u{53e3}"
            let secondResult = StoredAssistantResult(
                id: "card-path-second-\(path)",
                kind: .sentenceGloss,
                status: .accepted,
                language: "zh-Hans",
                model: "test",
                source: canonical.context,
                text: "second",
                createdAt: Date(timeIntervalSince1970: 30)
            )
            try store.applyAssistantResults([secondResult], vocabulary: [canonical])

            let cards = try store.loadReviewCards().filter {
                $0.vocabularyID.rawValue == lowercaseID && $0.face == "recognition"
            }
            #expect(cards.count == 1)
            #expect(cards.first?.id == canonicalCardID)
            #expect(cards.first?.reviewCount == 4)
            let events = try store.loadReviewEvents().filter {
                $0.id.rawValue == "card-path-review-\(path)"
            }
            #expect(events.count == 1)
            #expect(events.first?.vocabularyID.rawValue == lowercaseID)
            #expect(events.first?.cardID == canonicalCardID)
            #expect(Set(try store.loadAssistantResults().map(\.id)) == [
                firstResult.id, secondResult.id,
            ])
            let raw = SQLiteConnection(fileURL: databaseURL)
            #expect(try raw.query("PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test("Lowercase assistant writes consolidate legacy and custom same-face cards")
    func lowercaseAssistantConsolidatesLegacySameFaceCards() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-vocabulary-card-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: databaseURL)
        let lowercaseID = "dddddddd-eeee-4fff-8aaa-000000000001"
        let uppercaseID = lowercaseID.uppercased()
        let canonicalCardID = "card:\(lowercaseID):recognition"
        let bookID = BookID(rawValue: "legacy-card-book")
        let chapterID = ChapterID(rawValue: "legacy-card-chapter")
        var reviewed = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: uppercaseID),
            surface: "harbor",
            category: VocabCategory.word.rawValue,
            context: "The ship entered the harbor.",
            bookID: bookID,
            bookTitle: "Book",
            chapterID: chapterID,
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 10),
            reviewCount: 4,
            nextReview: Date(timeIntervalSince1970: 400),
            lastReviewedAt: Date(timeIntervalSince1970: 40),
            lastReviewQuality: VocabReviewQuality.remember.rawValue,
            reviewIntervalDays: 4,
            reviewEaseFactor: 2.7,
            isInLearnList: true
        )
        try store.upsertVocabulary(reviewed)
        try store.appendReviewEvent(
            StoredReviewEvent(
                id: ReviewEventID(rawValue: "legacy-card-event"),
                vocabularyID: reviewed.id,
                cardID: "card:\(uppercaseID):recognition",
                face: "recognition",
                rating: VocabReviewQuality.remember.rawValue,
                reviewedAt: Date(timeIntervalSince1970: 40)
            ),
            vocabulary: reviewed
        )
        reviewed.reviewCount = 5
        reviewed.nextReview = Date(timeIntervalSince1970: 500)
        reviewed.lastReviewedAt = Date(timeIntervalSince1970: 50)
        reviewed.reviewIntervalDays = 5
        try store.appendReviewEvent(
            StoredReviewEvent(
                id: ReviewEventID(rawValue: "custom-card-event"),
                vocabularyID: reviewed.id,
                cardID: "custom-review-card",
                face: "recognition",
                rating: VocabReviewQuality.remember.rawValue,
                reviewedAt: Date(timeIntervalSince1970: 50)
            ),
            vocabulary: reviewed
        )

        reviewed.id = VocabularyOccurrenceID(rawValue: lowercaseID)
        reviewed.reviewCount = 0
        reviewed.nextReview = nil
        reviewed.lastReviewedAt = nil
        reviewed.lastReviewQuality = nil
        reviewed.reviewIntervalDays = 0
        reviewed.reviewEaseFactor = 2.5
        reviewed.addedAt = Date(timeIntervalSince1970: 20)
        let firstResult = StoredAssistantResult(
            id: "legacy-card-first",
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh-Hans",
            model: "test",
            source: reviewed.context,
            text: "first",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        try store.applyAssistantResults([firstResult], vocabulary: [reviewed])

        var canonical = try #require(try store.loadVocabulary().first {
            $0.id.rawValue == lowercaseID
        })
        canonical.translation = "\u{6e2f}\u{53e3}"
        let secondResult = StoredAssistantResult(
            id: "legacy-card-second",
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh-Hans",
            model: "test",
            source: canonical.context,
            text: "second",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        try store.applyAssistantResults([secondResult], vocabulary: [canonical])

        let cards = try store.loadReviewCards().filter {
            $0.vocabularyID.rawValue == lowercaseID && $0.face == "recognition"
        }
        #expect(cards.count == 1)
        #expect(cards.first?.id == canonicalCardID)
        #expect(cards.first?.reviewCount == 5)
        let events = try store.loadReviewEvents().filter {
            $0.id.rawValue == "legacy-card-event" || $0.id.rawValue == "custom-card-event"
        }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.vocabularyID.rawValue == lowercaseID })
        #expect(events.allSatisfy { $0.cardID == canonicalCardID })
        #expect(try SQLiteConnection(fileURL: databaseURL).query("PRAGMA foreign_key_check").isEmpty)
    }

    @Test("Convention-shaped explicit card IDs remain valid through canonical parent repair")
    func conventionShapedExplicitCardIDUsesPersistedMapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-explicit-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: databaseURL)
        let lowercaseID = "eeeeeeee-ffff-4aaa-8bbb-000000000001"
        let uppercaseID = lowercaseID.uppercased()
        let explicitCardID = "card:\(uppercaseID):recognition"
        let bookID = BookID(rawValue: "explicit-card-book")
        let chapterID = ChapterID(rawValue: "explicit-card-chapter")
        var vocabulary = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: lowercaseID),
            surface: "harbor",
            category: VocabCategory.word.rawValue,
            context: "The ship entered the harbor.",
            bookID: bookID,
            bookTitle: "Book",
            chapterID: chapterID,
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 10)
        )
        try store.upsertVocabulary(vocabulary)
        vocabulary.id = VocabularyOccurrenceID(rawValue: uppercaseID)
        vocabulary.reviewCount = 1
        vocabulary.lastReviewedAt = Date(timeIntervalSince1970: 20)

        try store.appendReviewEvent(
            StoredReviewEvent(
                id: ReviewEventID(rawValue: "explicit-convention-event"),
                vocabularyID: vocabulary.id,
                cardID: explicitCardID,
                face: "recognition",
                rating: VocabReviewQuality.remember.rawValue,
                reviewedAt: Date(timeIntervalSince1970: 20)
            ),
            vocabulary: vocabulary
        )

        let card = try #require(try store.loadReviewCards().first)
        let event = try #require(try store.loadReviewEvents().first {
            $0.id.rawValue == "explicit-convention-event"
        })
        #expect(card.vocabularyID.rawValue == lowercaseID)
        #expect(event.vocabularyID.rawValue == lowercaseID)
        #expect(event.cardID == card.id)
        #expect(event.cardID == explicitCardID)

        var legacy = vocabulary
        legacy.id = VocabularyOccurrenceID(rawValue: "legacy-word")
        legacy.reviewCount = 2
        legacy.lastReviewedAt = Date(timeIntervalSince1970: 30)
        try store.appendReviewEvent(
            StoredReviewEvent(
                id: ReviewEventID(rawValue: "explicit-non-uuid-event"),
                vocabularyID: legacy.id,
                cardID: "custom:legacy-card",
                face: "recognition",
                rating: VocabReviewQuality.remember.rawValue,
                reviewedAt: Date(timeIntervalSince1970: 30)
            ),
            vocabulary: legacy
        )
        let legacyEvent = try #require(try store.loadReviewEvents().first {
            $0.id.rawValue == "explicit-non-uuid-event"
        })
        #expect(legacyEvent.vocabularyID.rawValue == "legacy-word")
        #expect(legacyEvent.cardID == "custom:legacy-card")
        #expect(try SQLiteConnection(fileURL: databaseURL).query("PRAGMA foreign_key_check").isEmpty)
    }

    @MainActor
    @Test("bootstrap and incremental transcript cleanup tombstones use the native applicator")
    func transcriptCleanupTombstonesUseNativeApplicator() async throws {
        for isBootstrap in [true, false] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("audio-reader-transcript-cleanup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
            let bookID = BookID(rawValue: "local-book")
            let chapterID = ChapterID(rawValue: "local-chapter")
            try store.saveBook(StoredBook(
                id: bookID,
                title: "Book",
                source: "test",
                chapters: [StoredChapter(id: chapterID, index: 0, title: "Chapter")]
            ))
            try store.saveTranscript(Self.syncTranscript(chapterID: chapterID, index: 0))

            let presentID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            let absentID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            let cleanup: (Int, String, String) -> SyncPulledChange = { sequence, entityID, remoteChapterID in
                SyncPulledChange(
                    sequence: sequence,
                    entityType: OutboxEntityType.transcript.rawValue,
                    entityId: entityID,
                    operation: OutboxOperation.delete.rawValue,
                    revision: 2,
                    changedAt: "2026-09-01T00:00:00Z",
                    payload: [
                        "assetId": .string(entityID),
                        "bookId": .string(AccountSyncApplicator.syncEntityID(bookID.rawValue, kind: "book")),
                        "chapterId": .string(remoteChapterID),
                        "revisionId": .string(entityID),
                        "kind": .string(SyncAssetKind.transcriptRevision.rawValue),
                    ]
                )
            }
            let changes = [
                cleanup(
                    2,
                    presentID,
                    AccountSyncApplicator.syncEntityID(chapterID.rawValue, kind: "chapter")
                ),
                cleanup(
                    3,
                    absentID,
                    AccountSyncApplicator.syncEntityID("absent-chapter", kind: "chapter")
                ),
            ]
            let sync = FakeSyncClient()
            sync.pullCursor = "3"
            if isBootstrap {
                sync.bootstrapPages = [SyncBootstrapResponse(
                    entities: changes.map { change in
                        SyncBootstrapEntity(
                            sequence: change.sequence,
                            entityType: change.entityType,
                            entityId: change.entityId,
                            operation: change.operation,
                            revision: change.revision,
                            changedAt: change.changedAt,
                            payload: change.payload,
                            payloadHash: SyncJSONCoding.payloadHash(
                                SyncJSONCoding.data(from: change.payload)
                            )
                        )
                    },
                    cursor: "3",
                    nextOffset: changes.count,
                    hasMore: false
                )]
            } else {
                try store.saveCursor("1")
                sync.pullChanges = changes
            }
            let account = AccountSession(
                client: FakeAuthClient(),
                store: InMemoryAuthSessionStore(),
                oauth: ScriptedOAuthBrowserSession.passthrough(),
                environment: .test,
                syncRuntime: AccountSyncRuntime(
                    client: sync,
                    outbox: InMemorySyncOutboxRepository(),
                    cursor: store,
                    snapshot: { [] },
                    applyPage: { changes, versions, cursor in
                        try AccountSyncApplicator.applyPage(
                            changes,
                            versions: versions,
                            cursor: cursor,
                            to: store
                        )
                    }
                )
            )
            await account.requestEmailCode("native-cleanup@example.com")
            await account.verifyEmailCode("123456")
            account.setSyncEnabled(true)

            await account.synchronize()

            #expect(account.syncStatus.phase == .completed)
            #expect(try store.loadTranscript(chapterID: chapterID) == nil)
            #expect(try store.loadVersion(
                entityType: OutboxEntityType.transcript.rawValue,
                entityID: presentID
            )?.payload == SyncJSONCoding.tombstonePayload)
            #expect(try store.loadVersion(
                entityType: OutboxEntityType.transcript.rawValue,
                entityID: absentID
            )?.payload == SyncJSONCoding.tombstonePayload)
            #expect(try store.loadCursor() == "3")
            #expect(sync.manifestLookups.isEmpty)
            #expect(sync.downloadedAssetIDs.isEmpty)
        }
    }

    @Test("orphan transcript revisions advance the page while a known chapter still hydrates")
    func orphanTranscriptRevisionDoesNotBlockKnownChapter() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-orphan-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let bookID = BookID(rawValue: "local-book")
        let knownChapterID = ChapterID(rawValue: "known-chapter")
        let orphanChapterID = ChapterID(rawValue: "deleted-on-this-device")
        try store.saveBook(StoredBook(
            id: bookID,
            title: "Book",
            source: "test",
            chapters: [StoredChapter(id: knownChapterID, index: 0, title: "Known")]
        ))
        let orphanID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let knownID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let orphan = try Self.hydratedTranscriptChange(
            sequence: 1,
            entityID: orphanID,
            sourceChapterID: orphanChapterID,
            announcedChapterID: AccountSyncApplicator.syncEntityID(orphanChapterID.rawValue, kind: "chapter"),
            directory: root
        )
        let known = try Self.hydratedTranscriptChange(
            sequence: 2,
            entityID: knownID,
            sourceChapterID: ChapterID(rawValue: "source-device-chapter-id"),
            announcedChapterID: AccountSyncApplicator.syncEntityID(knownChapterID.rawValue, kind: "chapter"),
            directory: root
        )

        try AccountSyncApplicator.applyPage([orphan, known], cursor: "2", to: store)

        let applied = try #require(try store.loadTranscript(chapterID: knownChapterID))
        #expect(applied.segments.first?.id == "segment-2")
        #expect(try store.loadTranscript(chapterID: orphanChapterID) == nil)
        #expect(try store.loadTranscripts().map(\.chapterID) == [knownChapterID])
        #expect(try store.loadSyncAssetManifests().map(\.id) == [knownID])
        #expect(try store.loadVersion(entityType: orphan.entityType, entityID: orphanID)?.serverVersion == 1)
        #expect(try store.loadVersion(entityType: known.entityType, entityID: knownID)?.serverVersion == 1)
        #expect(try store.loadCursor() == "2")
        for manifest in try store.loadSyncAssetManifests() {
            try? FileManager.default.removeItem(atPath: manifest.localObjectPath)
        }
    }

    @Test("a transcript hydrates when its catalog parent arrives in the same page")
    func transcriptUsesCatalogParentFromSamePage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-transcript-new-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let bookID = BookID(rawValue: "new-book")
        let chapterID = ChapterID(rawValue: "new-chapter")
        let bookMutation = try AccountSyncApplicator.bookMutation(for: StoredBook(
            id: bookID,
            title: "New Book",
            source: "test",
            chapters: [StoredChapter(id: chapterID, index: 0, title: "New Chapter")]
        ))
        let book = SyncPulledChange(
            sequence: 1,
            entityType: bookMutation.entityType.rawValue,
            entityId: bookMutation.entityID,
            operation: bookMutation.operation.rawValue,
            revision: 1,
            changedAt: "2026-09-01T00:00:00Z",
            payload: try JSONDecoder().decode([String: SyncJSONValue].self, from: bookMutation.payload)
        )
        let transcriptID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let transcript = try Self.hydratedTranscriptChange(
            sequence: 2,
            entityID: transcriptID,
            sourceChapterID: ChapterID(rawValue: "source-device-chapter-id"),
            announcedChapterID: AccountSyncApplicator.syncEntityID(chapterID.rawValue, kind: "chapter"),
            directory: root
        )

        try AccountSyncApplicator.applyPage([transcript, book], cursor: "2", to: store)

        #expect(try store.loadTranscript(chapterID: chapterID)?.segments.first?.id == "segment-2")
        #expect(try store.loadVersion(
            entityType: OutboxEntityType.transcript.rawValue,
            entityID: transcriptID
        )?.serverVersion == 1)
        #expect(try store.loadCursor() == "2")
        for manifest in try store.loadSyncAssetManifests() {
            try? FileManager.default.removeItem(atPath: manifest.localObjectPath)
        }
    }

    @Test("book sync preserves EPUB section identity and accepts legacy chapters without it")
    func bookSyncPreservesOptionalEbookSectionIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-book-epub-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let book = StoredBook(
            id: BookID(rawValue: "epub-book"),
            title: "EPUB Book",
            source: "files",
            chapters: [StoredChapter(
                id: ChapterID(rawValue: "title-page"),
                index: 0,
                title: "Title Page",
                ebookSectionIndex: 0
            )]
        )
        let mutation = try AccountSyncApplicator.bookMutation(for: book)
        let payload = try JSONDecoder().decode([String: SyncJSONValue].self, from: mutation.payload)
        let change = SyncPulledChange(
            sequence: 1,
            entityType: mutation.entityType.rawValue,
            entityId: mutation.entityID,
            operation: mutation.operation.rawValue,
            revision: 1,
            changedAt: "2026-09-01T00:00:00Z",
            payload: payload
        )

        try AccountSyncApplicator.applyPage([change], cursor: "1", to: store)

        #expect(try store.loadBooks().first?.chapters.first?.ebookSectionIndex == 0)

        let legacyPayload: [String: SyncJSONValue] = [
            "localId": .string("legacy-book"),
            "title": .string("Legacy Book"),
            "source": .string("files"),
            "chapters": .array([.object([
                "localId": .string("legacy-chapter"),
                "index": .number(0),
                "title": .string("Legacy Chapter"),
            ])]),
        ]
        let legacyChange = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.book.rawValue,
            entityId: AccountSyncApplicator.syncEntityID("legacy-book", kind: "book"),
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-09-01T00:00:01Z",
            payload: legacyPayload
        )

        try AccountSyncApplicator.applyPage([legacyChange], cursor: "2", to: store)

        let legacy = try #require(try store.loadBooks().first { $0.id.rawValue == "legacy-book" })
        #expect(legacy.chapters.first?.ebookSectionIndex == nil)
    }

    @Test("a concurrent catalog delete cannot make a transcript page permanently fail")
    func transcriptEligibilityRevalidatesAfterConcurrentDelete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-transcript-delete-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = LocalSQLiteStore(fileURL: databaseURL)
        let writer = LocalSQLiteStore(fileURL: databaseURL)
        let bookID = BookID(rawValue: "race-book")
        let chapterID = ChapterID(rawValue: "race-chapter")
        let book = StoredBook(
            id: bookID,
            title: "Race Book",
            source: "test",
            chapters: [StoredChapter(id: chapterID, index: 0, title: "Race Chapter")]
        )
        try store.saveBook(book)
        #expect(try store.journalMode() == "wal")
        let transcriptID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let transcript = try Self.hydratedTranscriptChange(
            sequence: 7,
            entityID: transcriptID,
            sourceChapterID: chapterID,
            announcedChapterID: AccountSyncApplicator.syncEntityID(chapterID.rawValue, kind: "chapter"),
            directory: root
        )
        let installedPath = Persistence.root
            .appendingPathComponent("SyncAssets-v2/transcriptRevision", isDirectory: true)
            .appendingPathComponent(String(repeating: "7", count: 64))
            .appendingPathExtension("object")
        try? FileManager.default.removeItem(at: installedPath)

        try AccountSyncApplicator.applyPage(
            [transcript],
            cursor: "7",
            to: store,
            interleavingBeforeTransaction: { try writer.deleteBook(id: bookID) }
        )

        #expect(try store.loadTranscript(chapterID: chapterID) == nil)
        #expect(try store.loadSyncAssetManifests().isEmpty)
        #expect(try store.loadVersion(
            entityType: OutboxEntityType.transcript.rawValue,
            entityID: transcriptID
        )?.serverVersion == 1)
        #expect(try store.loadCursor() == "7")
        #expect(!FileManager.default.fileExists(atPath: installedPath.path))
    }

    @Test("a concurrent catalog restore is visible before transcript acknowledgement")
    func transcriptEligibilityRevalidatesAfterConcurrentRestore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-transcript-restore-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = LocalSQLiteStore(fileURL: databaseURL)
        let writer = LocalSQLiteStore(fileURL: databaseURL)
        let bookID = BookID(rawValue: "race-book")
        let chapterID = ChapterID(rawValue: "race-chapter")
        let book = StoredBook(
            id: bookID,
            title: "Race Book",
            source: "test",
            chapters: [StoredChapter(id: chapterID, index: 0, title: "Race Chapter")]
        )
        try store.saveBook(book)
        try store.deleteBook(id: bookID)
        #expect(try store.journalMode() == "wal")
        let transcriptID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let transcript = try Self.hydratedTranscriptChange(
            sequence: 8,
            entityID: transcriptID,
            sourceChapterID: chapterID,
            announcedChapterID: AccountSyncApplicator.syncEntityID(chapterID.rawValue, kind: "chapter"),
            directory: root
        )

        try AccountSyncApplicator.applyPage(
            [transcript],
            cursor: "8",
            to: store,
            interleavingBeforeTransaction: { try writer.saveBook(book) }
        )

        #expect(try store.loadTranscript(chapterID: chapterID)?.segments.first?.id == "segment-8")
        #expect(try store.loadSyncAssetManifests().map(\.id) == [transcriptID])
        #expect(try store.loadVersion(
            entityType: OutboxEntityType.transcript.rawValue,
            entityID: transcriptID
        )?.serverVersion == 1)
        #expect(try store.loadCursor() == "8")
        for manifest in try store.loadSyncAssetManifests() {
            try? FileManager.default.removeItem(atPath: manifest.localObjectPath)
        }
    }

    @Test("pre-transaction preparation failure removes an installed transcript object")
    func preparationFailureCleansInstalledTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-transcript-preparation-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let bookID = BookID(rawValue: "local-book")
        let chapterID = ChapterID(rawValue: "local-chapter")
        try store.saveBook(StoredBook(
            id: bookID,
            title: "Book",
            source: "test",
            chapters: [StoredChapter(id: chapterID, index: 0, title: "Chapter")]
        ))
        let transcript = try Self.hydratedTranscriptChange(
            sequence: 9,
            entityID: "99999999-9999-4999-8999-999999999999",
            sourceChapterID: chapterID,
            announcedChapterID: AccountSyncApplicator.syncEntityID(chapterID.rawValue, kind: "chapter"),
            directory: root
        )
        let malformedVocabulary = SyncPulledChange(
            sequence: 10,
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-09-01T00:00:00Z",
            payload: [:]
        )
        let installedPath = Persistence.root
            .appendingPathComponent("SyncAssets-v2/transcriptRevision", isDirectory: true)
            .appendingPathComponent(String(repeating: "9", count: 64))
            .appendingPathExtension("object")
        try? FileManager.default.removeItem(at: installedPath)

        #expect(throws: (any Error).self) {
            try AccountSyncApplicator.applyPage(
                [transcript, malformedVocabulary],
                cursor: "10",
                to: store
            )
        }

        #expect(!FileManager.default.fileExists(atPath: installedPath.path))
        #expect(try store.loadTranscript(chapterID: chapterID) == nil)
        #expect(try store.loadSyncAssetManifests().isEmpty)
        #expect(try store.loadVersion(
            entityType: transcript.entityType,
            entityID: transcript.entityId
        ) == nil)
        #expect(try store.loadCursor() == "0")
    }

    @Test("a later invalid change rolls back a page that skips an orphan transcript")
    func invalidPageRollsBackAfterSkippingOrphanTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-orphan-transcript-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let bookID = BookID(rawValue: "local-book")
        let knownChapterID = ChapterID(rawValue: "known-chapter")
        let orphanChapterID = ChapterID(rawValue: "deleted-on-this-device")
        try store.saveBook(StoredBook(
            id: bookID,
            title: "Book",
            source: "test",
            chapters: [StoredChapter(id: knownChapterID, index: 0, title: "Known")]
        ))
        let orphan = try Self.hydratedTranscriptChange(
            sequence: 1,
            entityID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            sourceChapterID: orphanChapterID,
            announcedChapterID: AccountSyncApplicator.syncEntityID(orphanChapterID.rawValue, kind: "chapter"),
            directory: root
        )
        let known = try Self.hydratedTranscriptChange(
            sequence: 2,
            entityID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            sourceChapterID: knownChapterID,
            announcedChapterID: AccountSyncApplicator.syncEntityID(knownChapterID.rawValue, kind: "chapter"),
            directory: root
        )
        let invalid = SyncPulledChange(
            sequence: 3,
            entityType: OutboxEntityType.progress.rawValue,
            entityId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-09-01T00:00:00Z",
            payload: [:]
        )

        do {
            try AccountSyncApplicator.applyPage([orphan, known, invalid], cursor: "3", to: store)
            Issue.record("Expected the invalid progress change to fail the page")
        } catch {
            #expect(error.localizedDescription == "The progress sync change is missing vocabularyId.")
        }

        #expect(try store.loadTranscript(chapterID: knownChapterID) == nil)
        #expect(try store.loadSyncAssetManifests().isEmpty)
        #expect(try store.loadVersion(entityType: orphan.entityType, entityID: orphan.entityId) == nil)
        #expect(try store.loadVersion(entityType: known.entityType, entityID: known.entityId) == nil)
        #expect(try store.loadCursor() == "0")
    }

    @Test("a later invalid change rolls back a transcript cleanup tombstone")
    func invalidPageRollsBackTranscriptCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-transcript-cleanup-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let bookID = BookID(rawValue: "local-book")
        let chapterID = ChapterID(rawValue: "local-chapter")
        try store.saveBook(StoredBook(
            id: bookID,
            title: "Book",
            source: "test",
            chapters: [StoredChapter(id: chapterID, index: 0, title: "Chapter")]
        ))
        try store.saveTranscript(Self.syncTranscript(chapterID: chapterID, index: 0))
        let tombstone = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.transcript.rawValue,
            entityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            operation: OutboxOperation.delete.rawValue,
            revision: 2,
            changedAt: "2026-09-01T00:00:00Z",
            payload: [
                "chapterId": .string(AccountSyncApplicator.syncEntityID(chapterID.rawValue, kind: "chapter")),
                "kind": .string(SyncAssetKind.transcriptRevision.rawValue),
            ]
        )
        let invalid = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.progress.rawValue,
            entityId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-09-01T00:00:00Z",
            payload: [:]
        )

        #expect(throws: (any Error).self) {
            try AccountSyncApplicator.applyPage([tombstone, invalid], cursor: "2", to: store)
        }

        #expect(try store.loadTranscript(chapterID: chapterID) != nil)
        #expect(try store.loadVersion(entityType: tombstone.entityType, entityID: tombstone.entityId) == nil)
        #expect(try store.loadCursor() == "0")
    }

    @Test("A failed mixed sync page rolls back structured settings")
    func failedMixedSyncPageRollsBackStructuredSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-page-derived-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let settings = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.settings.rawValue,
            entityId: "settings",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: ["targetLanguage": .string("fr")]
        )
        let invalidProgress = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.progress.rawValue,
            entityId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: ["vocabularyId": .string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")]
        )

        #expect(throws: (any Error).self) {
            try AccountSyncApplicator.applyPage(
                [settings, invalidProgress],
                cursor: "2",
                to: store
            )
        }

        #expect(try store.loadVersion(entityType: settings.entityType, entityID: settings.entityId) == nil)
        #expect(try store.loadCursor() == "0")
        #expect(try store.loadSettings().targetLanguage == StoredSettings.default.targetLanguage)
    }

    @Test("Repeated lemma revisions update idempotently and advance the page cursor")
    func repeatedLemmaPageAdvancesCursor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-page-lemma-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        let first = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.lexemeState.rawValue,
            entityId: "lemma-read",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: ["language": .string("en"), "lemma": .string("read")]
        )
        var revision = first
        revision.sequence = 2
        revision.revision = 2
        revision.changedAt = "2026-08-31T00:00:00Z"

        try AccountSyncApplicator.applyPage([first], cursor: "1", to: store)
        try AccountSyncApplicator.applyPage([revision], cursor: "2", to: store)

        let deletion = SyncPulledChange(
            sequence: 3,
            entityType: OutboxEntityType.lexemeState.rawValue,
            entityId: "lemma-read",
            operation: OutboxOperation.delete.rawValue,
            revision: 3,
            changedAt: "2026-09-01T00:00:00Z",
            payload: ["language": .string("en"), "lemma": .string("read"), "state": .string("unknown")]
        )
        try AccountSyncApplicator.applyPage([deletion], cursor: "3", to: store)

        #expect(try store.loadKnownLemmas().isEmpty)
        #expect(try store.loadDeletedKnownLemmas().map(\.form) == ["read"])
        #expect(try store.loadVersion(entityType: deletion.entityType, entityID: deletion.entityId)?.serverVersion == 3)
        #expect(try store.loadCursor() == "3")
    }

    @Test("A 7,000-record bootstrap uses bounded page transactions")
    func largeBootstrapUsesBoundedPageWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-page-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let changes = (1...7_000).map(syncVocabularyChange(index:))

        for start in stride(from: 0, to: changes.count, by: 100) {
            let page = Array(changes[start..<min(start + 100, changes.count)])
            try AccountSyncApplicator.applyPage(
                page,
                cursor: String(start + page.count),
                to: store
            )
        }

        #expect(try store.loadVocabulary().count == 7_000)
        #expect(try store.loadCursor() == "7000")
    }

    @Test("A successful learning page commits vocabulary, progress, review, versions, and cursor together")
    func learningSyncPageCommitsOneTransaction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-page-learning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library.sqlite"))
        let vocabulary = syncVocabularyChange(index: 1)
        let progress = SyncPulledChange(
            sequence: 2,
            entityType: OutboxEntityType.progress.rawValue,
            entityId: vocabulary.entityId,
            operation: OutboxOperation.upsert.rawValue,
            revision: 2,
            changedAt: "2026-08-30T01:00:00Z",
            payload: [
                "vocabularyId": .string(vocabulary.entityId),
                "reviewCount": .number(1),
                "lastReviewedAt": .string("2026-08-30T01:00:00Z"),
                "lastReviewQuality": .string(VocabReviewQuality.remember.rawValue),
                "reviewIntervalDays": .number(1),
                "reviewEaseFactor": .number(2.6)
            ]
        )
        let review = SyncPulledChange(
            sequence: 3,
            entityType: OutboxEntityType.reviewEvent.rawValue,
            entityId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            operation: OutboxOperation.append.rawValue,
            revision: 1,
            changedAt: "2026-08-30T01:00:00Z",
            payload: [
                "vocabularyId": .string(vocabulary.entityId),
                "face": .string("recognition"),
                "rating": .string(VocabReviewQuality.remember.rawValue),
                "reviewedAt": .string("2026-08-30T01:00:00Z")
            ]
        )

        try AccountSyncApplicator.applyPage(
            [review, progress, vocabulary],
            cursor: "3",
            to: store
        )

        #expect(try store.loadVocabulary().first?.reviewCount == 1)
        #expect(try store.loadReviewEvents().map(\.id.rawValue) == [review.entityId])
        #expect(try store.loadVersion(entityType: review.entityType, entityID: review.entityId)?.serverVersion == 1)
        #expect(try store.loadCursor() == "3")
    }

    @Test("Incremental vocabulary apply preserves existing review schedule and history")
    func vocabularySyncApplyPreservesReviewHistory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-review-preservation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let incoming = syncVocabularyChange(index: 1)
        try AccountSyncApplicator.applyPage([incoming], cursor: "1", to: store)
        var existing = try #require(try store.loadVocabulary().first.map(VocabEntry.init))
        existing.reviewCount = 6
        existing.nextReview = Date(timeIntervalSince1970: 1_800_000_000)
        existing.lastReviewedAt = Date(timeIntervalSince1970: 1_799_000_000)
        existing.lastReviewQuality = .remember
        existing.reviewIntervalDays = 14
        existing.reviewEaseFactor = 2.8
        try store.upsertVocabulary(StoredVocabularyOccurrence(existing))
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "review-preserved"),
            vocabularyID: VocabularyOccurrenceID(rawValue: existing.id),
            face: "recognition",
            rating: VocabReviewQuality.remember.rawValue,
            reviewedAt: existing.lastReviewedAt!
        )
        try store.appendReviewEvent(event, vocabulary: StoredVocabularyOccurrence(existing))

        try AccountSyncApplicator.applyPage([incoming], cursor: "1", to: store)

        let restored = try #require(try store.loadVocabulary().first.map(VocabEntry.init))
        #expect(restored.reviewCount == 6)
        #expect(restored.nextReview == existing.nextReview)
        #expect(restored.reviewIntervalDays == 14)
        #expect(restored.reviewEaseFactor == 2.8)
        #expect(try store.loadReviewEvents() == [event])
    }

    @Test("Canonical structured page excludes transcript bytes while persisting other rows and cursor")
    func canonicalPagePersistsStructuredEntitiesTogether() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-structured-page-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let book = StoredBook(
            id: BookID(rawValue: "cloud-book"),
            title: "Cloud Book",
            author: "Author",
            source: BookSource.files.rawValue,
            chapters: [StoredChapter(id: ChapterID(rawValue: "cloud-chapter"), index: 0, title: "Chapter")]
        )
        let transcript = StoredTranscript(
            chapterID: ChapterID(rawValue: "cloud-chapter"),
            localMediaKey: "",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            locale: "en",
            source: "cloud",
            ebookAligned: false,
            segments: [StoredTranscriptSegment(
                id: "cloud-segment",
                start: 0,
                end: 1,
                words: [StoredTranscriptWord(id: "cloud-word", text: "hello", start: 0, end: 1)]
            )]
        )
        var settings = AppSettings.default
        settings.targetLanguage = "fr"
        let mutations = try AccountSyncApplicator.snapshot(
            settings: settings,
            vocabulary: [],
            lemmas: [KnownLemmaRecord(
                language: "en",
                form: "hello",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )],
            books: [book],
            transcripts: [transcript]
        )
        let pulled = try mutations.enumerated().map { index, mutation in
            pulledVocabularyChange(
                from: mutation,
                payload: try JSONDecoder().decode([String: SyncJSONValue].self, from: mutation.payload),
                sequence: index + 1
            )
        }

        try AccountSyncApplicator.applyPage(pulled, cursor: "4", to: store)

        #expect(try store.loadBooks() == [book])
        #expect(try store.loadTranscript(chapterID: transcript.chapterID) == nil)
        #expect(try store.loadKnownLemmas().map(\.form) == ["hello"])
        #expect(try store.loadSettings().targetLanguage == "fr")
        #expect(try store.loadCursor() == "4")
        #expect(Book(book).mediaAvailability == .metadataOnly)
        for change in pulled {
            #expect(try store.loadVersion(entityType: change.entityType, entityID: change.entityId) != nil)
        }
    }

    @Test("One assistant result identity and provenance round-trips every lifecycle state")
    func assistantResultLifecycleRoundTripsAcrossDevices() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-result-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalSQLiteStore(fileURL: root.appendingPathComponent("first.sqlite"))
        let second = LocalSQLiteStore(fileURL: root.appendingPathComponent("second.sqlite"))
        let resultID = "11111111-1111-4111-8111-111111111111"
        var result = StoredAssistantResult(
            id: resultID,
            kind: .sentenceGloss,
            status: .pending,
            language: "zh-Hans",
            model: "qwen3.5-plus-2026-08-01",
            promptVersion: "qwen-managed-v3",
            modelPolicyHash: String(repeating: "a", count: 64),
            chapterID: ChapterID(rawValue: "chapter-decision"),
            source: "Source sentence",
            text: "accepted",
            createdAt: Date(timeIntervalSince1970: 1),
            sharedCacheEntryID: "22222222-2222-4222-8222-222222222222"
        )

        func change(sequence: Int, revision: Int) throws -> SyncPulledChange {
            let data = try JSONEncoder.iso.encode(
                StoredAssistantDecisionPayload(result: result, vocabulary: [])
            )
            return SyncPulledChange(
                sequence: sequence,
                entityType: OutboxEntityType.assistantResult.rawValue,
                entityId: resultID,
                operation: OutboxOperation.upsert.rawValue,
                revision: revision,
                changedAt: "2026-09-01T00:00:0\(sequence)Z",
                payload: try JSONDecoder().decode([String: SyncJSONValue].self, from: data)
            )
        }

        let generated = try change(sequence: 1, revision: 1)
        try AccountSyncApplicator.applyPage([generated], cursor: "1", to: first)
        try AccountSyncApplicator.applyPage([generated], cursor: "1", to: second)

        func transition(
            to status: AssistantResultStatus,
            text: String,
            sequence: Int,
            configure: (inout StoredAssistantResult) -> Void = { _ in }
        ) throws {
            result.status = status
            result.text = text
            result.decidedAt = Date(timeIntervalSince1970: TimeInterval(sequence + 1))
            configure(&result)
            let encoded = try JSONEncoder.iso.encode(
                StoredAssistantDecisionPayload(result: result, vocabulary: [])
            )
            let mutation = OutboxMutation(
                id: MutationID(rawValue: UUID().uuidString.lowercased()),
                entityType: .assistantResult,
                entityID: resultID,
                operation: .upsert,
                baseRevision: ServerVersion(Int64(sequence - 1)),
                occurredAt: result.decidedAt ?? result.createdAt,
                payload: encoded
            )
            try first.updateAssistantResult(result, mutation: mutation)
            let queued = try #require(try first.pendingMutations().first { $0.id == mutation.id })
            #expect(queued.entityType == .assistantResult)
            #expect(queued.entityID == resultID)
            let queuedPayload = try JSONDecoder.iso.decode(
                StoredAssistantDecisionPayload.self,
                from: queued.payload
            )
            #expect(queuedPayload.result == result)
            let pulledPayload = try JSONDecoder().decode([String: SyncJSONValue].self, from: queued.payload)
            try AccountSyncApplicator.applyPage([
                SyncPulledChange(
                    sequence: sequence,
                    entityType: queued.entityType.rawValue,
                    entityId: queued.entityID,
                    operation: queued.operation.rawValue,
                    revision: sequence,
                    changedAt: "2026-09-01T00:00:0\(sequence)Z",
                    payload: pulledPayload
                ),
            ], cursor: String(sequence), to: second)
            try first.markAcknowledged(id: mutation.id)
        }

        try transition(to: .accepted, text: "accepted", sequence: 2)
        try transition(to: .edited, text: "edited", sequence: 3)
        try transition(to: .replaced, text: "replacement", sequence: 4) { replacement in
            replacement.model = "qwen3.5-plus-2026-08-31"
            replacement.promptVersion = "qwen-managed-v4"
            replacement.modelPolicyHash = String(repeating: "b", count: 64)
        }

        for store in [first, second] {
            let current = try #require(try store.loadAssistantResults().first)
            #expect(current.id == resultID)
            #expect(current.status == .replaced)
            #expect(current.model == "qwen3.5-plus-2026-08-31")
            #expect(current.promptVersion == "qwen-managed-v4")
            #expect(current.modelPolicyHash == String(repeating: "b", count: 64))
            #expect(current.sharedCacheEntryID == "22222222-2222-4222-8222-222222222222")
            #expect(try store.loadAssistantResultHistory(resultID: resultID).map(\.status) == [
                .pending, .accepted, .edited, .replaced,
            ])
        }
    }

    @Test("Legacy assistant hash round-trips through its UUID entity without duplicating locally")
    func legacyAssistantHashRoundTripsWithoutDuplicate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-legacy-result-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = LocalSQLiteStore(fileURL: root.appendingPathComponent("origin.sqlite"))
        let second = LocalSQLiteStore(fileURL: root.appendingPathComponent("second.sqlite"))
        let source = "One private source sentence."
        let context = "Private neighboring context."
        let legacyID = GlossEntry.makeID(
            kind: .sentence,
            language: "zh-Hans",
            source: source,
            context: context
        )
        let entityID = AccountSyncApplicator.syncEntityID(legacyID, kind: "assistant-result")
        let result = StoredAssistantResult(
            id: legacyID,
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh-Hans",
            model: "managed",
            source: source,
            text: "private translated text",
            context: context,
            createdAt: Date(timeIntervalSince1970: 1),
            decidedAt: Date(timeIntervalSince1970: 2)
        )
        try origin.saveAssistantResult(result)
        let payload = try JSONEncoder.iso.encode(
            StoredAssistantDecisionPayload(result: result, vocabulary: [])
        )
        let mutation = OutboxMutation(
            id: MutationID(rawValue: "00000000-0000-4000-8000-000000000001"),
            entityType: .assistantResult,
            entityID: entityID,
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: result.decidedAt ?? result.createdAt,
            payload: payload
        )
        let wire = try mutation.productMutation()
        let pulled = SyncPulledChange(
            sequence: 1,
            entityType: wire.entityType,
            entityId: wire.entityId,
            operation: wire.operation,
            revision: 1,
            changedAt: wire.occurredAt,
            payload: wire.payload
        )

        try AccountSyncApplicator.applyPage([pulled], cursor: "1", to: origin)
        try AccountSyncApplicator.applyPage([pulled], cursor: "1", to: second)

        #expect(try origin.loadAssistantResults() == [result])
        #expect(try second.loadAssistantResults() == [result])
        #expect(try origin.loadVersion(entityType: wire.entityType, entityID: entityID)?.serverVersion == 1)
        #expect(try second.loadVersion(entityType: wire.entityType, entityID: entityID)?.serverVersion == 1)
        let canonicalPayload = try #require(
            AccountSyncApplicator.snapshot(
                settings: .default,
                vocabulary: [],
                lemmas: [],
                assistantResults: [result]
            ).first { $0.entityType == .assistantResult }
        ).payload
        for store in [origin, second] {
            let version = try #require(
                try store.loadVersion(entityType: wire.entityType, entityID: entityID)
            )
            let durable = try JSONDecoder().decode(
                StoredAssistantDecisionPayload.self,
                from: version.payload
            )
            #expect(durable.result.id == legacyID)
            #expect(SyncJSONCoding.payloadsMatch(version.payload, canonicalPayload))
        }
    }

    @Test("Pulled page accepts historical numeric and current assistant dates atomically")
    func pulledPageAcceptsHistoricalAndCurrentAssistantDates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-assistant-date-compatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))

        func result(source: String, context: String, createdAt: Date) -> StoredAssistantResult {
            StoredAssistantResult(
                id: GlossEntry.makeID(
                    kind: .sentence,
                    language: "zh-Hans",
                    source: source,
                    context: context
                ),
                kind: .sentenceGloss,
                status: .accepted,
                language: "zh-Hans",
                model: "managed",
                source: source,
                text: "translated",
                context: context,
                createdAt: createdAt,
                decidedAt: createdAt.addingTimeInterval(1)
            )
        }

        let historical = result(
            source: "Historical source",
            context: "Historical context",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let historicalEntityID = AccountSyncApplicator.syncEntityID(
            historical.id,
            kind: "assistant-result"
        )
        let historicalData = try JSONEncoder().encode(
            StoredAssistantDecisionPayload(result: historical, vocabulary: [])
        )
        let historicalPayload = try JSONDecoder().decode(
            [String: SyncJSONValue].self,
            from: historicalData
        )

        let current = result(
            source: "Current source",
            context: "Current context",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100.625)
        )
        let currentEntityID = AccountSyncApplicator.syncEntityID(
            current.id,
            kind: "assistant-result"
        )
        let vocabulary = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "assistant-date-compatibility-vocabulary"),
            surface: current.source,
            captureSource: VocabularyCaptureSource.acceptedSentenceTranslation.rawValue,
            reviewEligible: false,
            category: VocabCategory.sentence.rawValue,
            context: current.source,
            bookID: BookID(rawValue: "assistant-date-compatibility-book"),
            bookTitle: "Book",
            chapterID: ChapterID(rawValue: "assistant-date-compatibility-chapter"),
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1_700_000_102)
        )
        let currentWire = try OutboxMutation(
            id: MutationID(rawValue: "00000000-0000-4000-8000-000000000001"),
            entityType: .assistantResult,
            entityID: currentEntityID,
            operation: .upsert,
            baseRevision: .zero,
            occurredAt: current.decidedAt ?? current.createdAt,
            payload: try JSONEncoder().encode(
                StoredAssistantDecisionPayload(result: current, vocabulary: [vocabulary])
            )
        ).productMutation()
        var currentPayload = currentWire.payload
        guard case .object(var currentResultPayload) = currentPayload["result"] else {
            Issue.record("Expected an assistant result object")
            return
        }
        currentResultPayload["createdAt"] = .string("2023-11-14T22:15:00.625Z")
        currentResultPayload["decidedAt"] = .string("2023-11-14T22:15:01.625Z")
        currentPayload["result"] = .object(currentResultPayload)
        let changes = [
            SyncPulledChange(
                sequence: 102,
                entityType: OutboxEntityType.assistantResult.rawValue,
                entityId: historicalEntityID,
                operation: OutboxOperation.upsert.rawValue,
                revision: 1,
                changedAt: "2026-09-01T00:00:00Z",
                payload: historicalPayload
            ),
            SyncPulledChange(
                sequence: 103,
                entityType: currentWire.entityType,
                entityId: currentWire.entityId,
                operation: currentWire.operation,
                revision: 1,
                changedAt: currentWire.occurredAt,
                payload: currentPayload
            ),
        ]

        try AccountSyncApplicator.applyPage(changes, cursor: "103", to: store)

        #expect(Set(try store.loadAssistantResults().map(\.id)) == [historical.id, current.id])
        #expect(try store.loadVocabulary() == [vocabulary])
        #expect(try store.loadCursor() == "103")
        let persistedCurrent = try #require(
            try store.loadAssistantResults().first { $0.id == current.id }
        )
        #expect(persistedCurrent.createdAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(persistedCurrent.decidedAt == Date(timeIntervalSince1970: 1_700_000_101))
        for change in changes {
            let version = try #require(
                try store.loadVersion(entityType: change.entityType, entityID: change.entityId)
            )
            let payload = try JSONDecoder().decode(
                StoredAssistantDecisionPayload.self,
                from: version.payload
            )
            #expect(payload.result.id == (change.entityId == historicalEntityID ? historical.id : current.id))
            if change.entityId == currentEntityID {
                #expect(payload.result.createdAt == Date(timeIntervalSince1970: 1_700_000_100))
                #expect(payload.result.decidedAt == Date(timeIntervalSince1970: 1_700_000_101))
            }
        }
    }

    @MainActor
    @Test("Fractional numeric assistant dates converge through apply and a real no-op sync")
    func fractionalNumericAssistantDatesConvergeWithoutRequeue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-fractional-assistant-convergence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        let source = "Fractional historical source"
        let context = "Fractional historical context"
        let legacyID = GlossEntry.makeID(
            kind: .sentence,
            language: "zh-Hans",
            source: source,
            context: context
        )
        let entityID = AccountSyncApplicator.syncEntityID(legacyID, kind: "assistant-result")
        let createdAt = Date(timeIntervalSinceReferenceDate: 777_000_000.625)
        let decidedAt = createdAt.addingTimeInterval(1.25)
        let result = StoredAssistantResult(
            id: legacyID,
            kind: .sentenceGloss,
            status: .edited,
            language: "zh-Hans",
            model: "managed",
            promptVersion: "assistant-prompts-v7",
            modelPolicyHash: "policy-hash-v7",
            source: source,
            text: "Fractional historical translation",
            context: context,
            createdAt: createdAt,
            decidedAt: decidedAt,
            sharedCacheEntryID: "cache-entry-v7"
        )
        let vocabulary = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "11111111-1111-4111-8111-111111111111"),
            surface: source,
            captureSource: VocabularyCaptureSource.acceptedSentenceTranslation.rawValue,
            reviewEligible: false,
            category: VocabCategory.sentence.rawValue,
            context: source,
            bookID: BookID(rawValue: "fractional-assistant-book"),
            bookTitle: "Book",
            chapterID: ChapterID(rawValue: "fractional-assistant-chapter"),
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let numericPayload = try JSONDecoder().decode(
            [String: SyncJSONValue].self,
            from: JSONEncoder().encode(
                StoredAssistantDecisionPayload(result: result, vocabulary: [vocabulary])
            )
        )
        let change = SyncPulledChange(
            sequence: 308,
            entityType: OutboxEntityType.assistantResult.rawValue,
            entityId: entityID,
            operation: OutboxOperation.upsert.rawValue,
            revision: 7,
            changedAt: "2026-09-01T00:00:00Z",
            payload: numericPayload
        )

        try AccountSyncApplicator.applyPage([change], cursor: "308", to: store)

        let expectedCreatedAt = Date(
            timeIntervalSince1970: floor(createdAt.timeIntervalSince1970)
        )
        let expectedDecidedAt = Date(
            timeIntervalSince1970: floor(decidedAt.timeIntervalSince1970)
        )
        let persisted = try #require(try store.loadAssistantResults().first)
        #expect(persisted.createdAt == expectedCreatedAt)
        #expect(persisted.decidedAt == expectedDecidedAt)
        #expect(persisted.status == .edited)
        #expect(persisted.promptVersion == result.promptVersion)
        #expect(persisted.modelPolicyHash == result.modelPolicyHash)
        #expect(persisted.sharedCacheEntryID == result.sharedCacheEntryID)
        #expect(try store.loadVocabulary() == [vocabulary])

        let snapshot: @Sendable () throws -> [OutboxMutation] = {
            try AccountSyncApplicator.snapshot(
                settings: .default,
                vocabulary: try store.loadVocabulary().map(VocabEntry.init),
                lemmas: [],
                assistantResults: try store.loadAssistantResults()
            )
        }
        for mutation in try snapshot() where mutation.entityType != .assistantResult {
            try store.saveVersion(SyncEntityVersion(
                entityType: mutation.entityType.rawValue,
                entityID: mutation.entityID,
                serverVersion: 1,
                payload: mutation.payload
            ))
        }
        let version = try #require(try store.loadVersion(
            entityType: change.entityType,
            entityID: change.entityId
        ))
        let assistantMutation = try #require(
            try snapshot().first { $0.entityType == .assistantResult }
        )
        #expect(SyncJSONCoding.payloadsMatch(version.payload, assistantMutation.payload))

        let sync = FakeSyncClient()
        sync.pullCursor = "308"
        let account = AccountSession(
            client: FakeAuthClient(),
            store: InMemoryAuthSessionStore(),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: store,
                cursor: store,
                versions: store,
                snapshot: snapshot,
                applyPage: { changes, versions, cursor in
                    try AccountSyncApplicator.applyPage(
                        changes,
                        versions: versions,
                        cursor: cursor,
                        to: store
                    )
                }
            )
        )
        await account.requestEmailCode("fractional-convergence@example.com")
        await account.verifyEmailCode("123456")
        account.setSyncEnabled(true)
        // Authentication bootstraps its own cursor; restore the cursor established by this
        // synthetic pulled page so the assertion covers only the immediate no-change sync.
        try store.saveCursor("308")

        await account.synchronize()

        #expect(sync.pushed.isEmpty)
        #expect(sync.downloadedAssetIDs.isEmpty)
        #expect(account.syncStatus.completedCount == 0)
        #expect(account.syncStatus.appliedCount == 0)
        #expect(try store.pendingMutations().isEmpty)
        #expect(try store.loadCursor() == "308")
        #expect(try store.loadAssistantResults() == [persisted])
        #expect(try store.loadVocabulary() == [vocabulary])
    }

    @Test("Malformed pulled assistant dates still reject the atomic page")
    func malformedPulledAssistantDatesRejectPage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-assistant-date-invalid-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSQLiteStore(fileURL: url)
        let change = SyncPulledChange(
            sequence: 102,
            entityType: OutboxEntityType.assistantResult.rawValue,
            entityId: "11111111-1111-4111-8111-111111111111",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-09-01T00:00:00Z",
            payload: [
                "result": .object([
                    "id": .string("11111111-1111-4111-8111-111111111111"),
                    "kind": .string(AssistantResultKind.sentenceGloss.rawValue),
                    "status": .string(AssistantResultStatus.accepted.rawValue),
                    "language": .string("zh-Hans"),
                    "model": .string("managed"),
                    "promptVersion": .string("local"),
                    "modelPolicyHash": .string("local"),
                    "source": .string("Source"),
                    "text": .string("Translation"),
                    "createdAt": .string("not-a-date")
                ]),
                "vocabulary": .array([])
            ]
        )

        #expect(throws: (any Error).self) {
            try AccountSyncApplicator.applyPage([change], cursor: "102", to: store)
        }
        #expect(try store.loadAssistantResults().isEmpty)
        #expect(try store.loadVersion(entityType: change.entityType, entityID: change.entityId) == nil)
        #expect(try store.loadCursor() == "0")
    }

    @MainActor
    @Test("Pulled assistant revisions match the production snapshot without requeueing")
    func samePageLegacyAssistantRevisionsDoNotRequeue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-legacy-result-revisions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        let source = "One private source sentence."
        let context = "Private neighboring context."
        let legacyID = GlossEntry.makeID(
            kind: .sentence,
            language: "zh-Hans",
            source: source,
            context: context
        )
        let entityID = AccountSyncApplicator.syncEntityID(legacyID, kind: "assistant-result")
        let first = StoredAssistantResult(
            id: legacyID,
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh-Hans",
            model: "managed",
            source: source,
            text: "first private translation",
            context: context,
            createdAt: Date(timeIntervalSince1970: 1),
            decidedAt: Date(timeIntervalSince1970: 2)
        )
        let latest = StoredAssistantResult(
            id: legacyID,
            kind: .sentenceGloss,
            status: .edited,
            language: "zh-Hans",
            model: "managed",
            source: source,
            text: "latest private translation",
            context: context,
            createdAt: Date(timeIntervalSince1970: 1),
            decidedAt: Date(timeIntervalSince1970: 3)
        )
        let pulled = try [first, latest].enumerated().map { offset, result in
            let revision = offset + 1
            let payload = try JSONEncoder.iso.encode(
                StoredAssistantDecisionPayload(result: result, vocabulary: [])
            )
            let wire = try OutboxMutation(
                id: MutationID(rawValue: "00000000-0000-4000-8000-00000000000\(revision)"),
                entityType: .assistantResult,
                entityID: entityID,
                operation: .upsert,
                baseRevision: ServerVersion(Int64(offset)),
                occurredAt: result.decidedAt ?? result.createdAt,
                payload: payload
            ).productMutation()
            return SyncPulledChange(
                sequence: revision,
                entityType: wire.entityType,
                entityId: wire.entityId,
                operation: wire.operation,
                revision: revision,
                changedAt: wire.occurredAt,
                payload: wire.payload
            )
        }

        try AccountSyncApplicator.applyPage(pulled, cursor: "2", to: store)

        #expect(try store.loadAssistantResults() == [latest])
        let assistantSnapshot = try #require(
            AccountSyncApplicator.snapshot(
                settings: .default,
                vocabulary: [],
                lemmas: [],
                assistantResults: [latest]
            ).first { $0.entityType == .assistantResult }
        )
        let version = try #require(
            try store.loadVersion(
                entityType: OutboxEntityType.assistantResult.rawValue,
                entityID: entityID
            )
        )
        #expect(version.serverVersion == 2)
        #expect(SyncJSONCoding.payloadsMatch(version.payload, assistantSnapshot.payload))

        let sync = FakeSyncClient()
        sync.pullCursor = "2"
        let account = AccountSession(
            client: FakeAuthClient(),
            store: InMemoryAuthSessionStore(),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: store,
                cursor: store,
                versions: store,
                snapshot: {
                    [assistantSnapshot]
                }
            )
        )
        await account.requestEmailCode("legacy-revisions@example.com")
        await account.verifyEmailCode("123456")
        account.setSyncEnabled(true)

        await account.synchronize()

        #expect(sync.pushed.isEmpty)
        #expect(try store.pendingMutations().isEmpty)
    }

    @Test("Pulled assistant result restores result and derived vocabulary canonically")
    func pulledTranslationDecisionRestoresLearningState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-decision-pull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        let result = StoredAssistantResult(
            id: "decision-result",
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh-Hans",
            model: "managed",
            chapterID: ChapterID(rawValue: "chapter-decision"),
            source: "Source sentence",
            text: "译文",
            createdAt: Date(timeIntervalSince1970: 1),
            decidedAt: Date(timeIntervalSince1970: 2)
        )
        let vocabulary = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "decision-vocabulary"),
            surface: "Source sentence",
            captureSource: VocabularyCaptureSource.acceptedSentenceTranslation.rawValue,
            reviewEligible: false,
            category: VocabCategory.sentence.rawValue,
            context: "Source sentence",
            bookID: BookID(rawValue: "book-decision"),
            bookTitle: "Book",
            chapterID: ChapterID(rawValue: "chapter-decision"),
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 2)
        )
        let payloadData = try JSONEncoder.iso.encode(
            StoredAssistantDecisionPayload(result: result, vocabulary: [vocabulary])
        )
        let payload = try JSONDecoder().decode([String: SyncJSONValue].self, from: payloadData)
        let change = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.assistantResult.rawValue,
            entityId: "11111111-1111-4111-8111-111111111111",
            operation: OutboxOperation.upsert.rawValue,
            revision: 3,
            changedAt: "2026-08-31T00:00:00Z",
            payload: payload
        )

        try AccountSyncApplicator.applyPage([change], cursor: "1", to: store)

        #expect(try store.loadAssistantResults() == [result])
        #expect(try store.loadVocabulary() == [vocabulary])
        #expect(try store.loadReviewCards().map(\.vocabularyID) == [vocabulary.id])
        #expect(try store.loadVersion(entityType: change.entityType, entityID: change.entityId)?.serverVersion == 3)
        #expect(try store.loadCursor() == "1")
    }

    @Test("Pulled decision cannot reduce a newer reviewed local schedule")
    func pulledDecisionPreservesReviewedLocalRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-reviewed-decision-pull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        var reviewed = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "reviewed-decision-vocabulary"),
            surface: "Source sentence",
            captureSource: VocabularyCaptureSource.acceptedSentenceTranslation.rawValue,
            reviewEligible: true,
            category: VocabCategory.sentence.rawValue,
            context: "Source sentence",
            bookID: BookID(rawValue: "book-decision"),
            bookTitle: "Book",
            chapterID: ChapterID(rawValue: "chapter-decision"),
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 2)
        )
        reviewed.reviewCount = 5
        reviewed.lastReviewedAt = Date(timeIntervalSince1970: 50)
        reviewed.nextReview = Date(timeIntervalSince1970: 500)
        reviewed.reviewIntervalDays = 14
        reviewed.reviewEaseFactor = 2.8
        try store.upsertVocabulary(reviewed)
        let event = StoredReviewEvent(
            id: ReviewEventID(rawValue: "reviewed-decision-event"),
            vocabularyID: reviewed.id,
            face: "recognition",
            rating: "easy",
            reviewedAt: reviewed.lastReviewedAt!
        )
        try store.appendReviewEvent(event, vocabulary: reviewed)
        var pulled = reviewed
        pulled.translation = "remote translation"
        pulled.reviewCount = 0
        pulled.lastReviewedAt = nil
        pulled.nextReview = nil
        pulled.reviewIntervalDays = 0
        pulled.reviewEaseFactor = 2.5
        let result = StoredAssistantResult(
            id: "reviewed-decision-result",
            kind: .sentenceGloss,
            status: .accepted,
            language: "zh-Hans",
            model: "managed",
            source: pulled.context,
            text: "remote translation",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let data = try JSONEncoder.iso.encode(StoredAssistantDecisionPayload(result: result, vocabulary: [pulled]))
        let change = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.assistantResult.rawValue,
            entityId: "reviewed-decision-entity",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-31T00:00:00Z",
            payload: try JSONDecoder().decode([String: SyncJSONValue].self, from: data)
        )

        try AccountSyncApplicator.applyPage([change], cursor: "reviewed-1", to: store)

        let persisted = try #require(try store.loadVocabulary().first)
        #expect(persisted.translation == "remote translation")
        #expect(persisted.reviewCount == 5)
        #expect(persisted.lastReviewedAt == reviewed.lastReviewedAt)
        #expect(persisted.nextReview == reviewed.nextReview)
        #expect(try store.loadReviewEvents() == [event])
        #expect(try store.loadCursor() == "reviewed-1")
    }

    @Test("Pulled rejected decision removes only its unreviewed derived row")
    func pulledRejectedDecisionDoesNotResurrectAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-rejected-decision-pull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library-vNext.sqlite")
        let store = LocalSQLiteStore(fileURL: url)
        let derived = StoredVocabularyOccurrence(
            id: VocabularyOccurrenceID(rawValue: "rejected-derived-vocabulary"),
            surface: "Source sentence",
            captureSource: VocabularyCaptureSource.acceptedSentenceTranslation.rawValue,
            reviewEligible: false,
            category: VocabCategory.sentence.rawValue,
            context: "Source sentence",
            bookID: BookID(rawValue: "book-decision"),
            bookTitle: "Book",
            chapterID: ChapterID(rawValue: "chapter-decision"),
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 2)
        )
        try store.upsertVocabulary(derived)
        let result = StoredAssistantResult(
            id: "rejected-pulled-result",
            kind: .sentenceGloss,
            status: .rejected,
            language: "zh-Hans",
            model: "managed",
            source: derived.context,
            text: "rejected",
            createdAt: Date(timeIntervalSince1970: 3),
            decidedAt: Date(timeIntervalSince1970: 4)
        )
        let data = try JSONEncoder.iso.encode(StoredAssistantDecisionPayload(
            result: result,
            vocabulary: [],
            removedVocabularyIDs: [derived.id]
        ))
        let change = SyncPulledChange(
            sequence: 1,
            entityType: OutboxEntityType.assistantResult.rawValue,
            entityId: "rejected-decision-entity",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-31T00:00:00Z",
            payload: try JSONDecoder().decode([String: SyncJSONValue].self, from: data)
        )

        try AccountSyncApplicator.applyPage([change], cursor: "rejected-1", to: store)

        let relaunched = LocalSQLiteStore(fileURL: url)
        #expect(try relaunched.loadAssistantResults() == [result])
        #expect(try relaunched.loadVocabulary().isEmpty)
        #expect(try relaunched.loadReviewCards().isEmpty)
        #expect(try relaunched.loadCursor() == "rejected-1")
    }

    @MainActor
    @Test("An immediate no-change sync does not requeue assistant results or reader progress")
    func immediateNoChangeSyncConvergesForAssistantResultsAndReaderProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-reader-sync-convergence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSQLiteStore(fileURL: root.appendingPathComponent("library-vNext.sqlite"))
        let createdAt = Date(timeIntervalSinceReferenceDate: 777_000_000.625)
        let assistantResults = (0..<17).map { index in
            let source = "source-\(index)"
            let context = "context-\(index)"
            return StoredAssistantResult(
                id: GlossEntry.makeID(
                    kind: .sentence,
                    language: "zh-Hans",
                    source: source,
                    context: context
                ),
                kind: .sentenceGloss,
                status: .accepted,
                language: "zh-Hans",
                model: "managed",
                source: source,
                text: "translation-\(index)",
                context: context,
                createdAt: createdAt,
                decidedAt: index == 16 ? nil : createdAt.addingTimeInterval(1.25)
            )
        }
        try store.replaceAssistantResults(assistantResults)
        for index in 0..<4 {
            _ = try store.mergeReaderProgress(StoredReaderProgress(
                id: "reader-progress-\(index)",
                bookID: BookID(rawValue: "book-\(index)"),
                chapterID: ChapterID(rawValue: "chapter-\(index)"),
                relativeSeconds: Double(index) + 0.5,
                updatedAt: createdAt,
                deviceID: "device-a",
                revision: 0
            ))
        }
        try store.saveCursor("287")

        let settingsMutation = try #require(AccountSyncApplicator.snapshot(
            settings: .default,
            vocabulary: [],
            lemmas: []
        ).first { $0.entityType == .settings })
        try store.saveVersion(SyncEntityVersion(
            entityType: settingsMutation.entityType.rawValue,
            entityID: settingsMutation.entityID,
            serverVersion: 1,
            payload: settingsMutation.payload
        ))

        let sync = EchoingSyncClient(initialCursor: 287)
        let account = AccountSession(
            client: FakeAuthClient(),
            store: InMemoryAuthSessionStore(),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test,
            syncRuntime: AccountSyncRuntime(
                client: sync,
                outbox: store,
                cursor: store,
                versions: store,
                snapshot: {
                    try AccountSyncApplicator.snapshot(
                        settings: .default,
                        vocabulary: try store.loadVocabulary().map(VocabEntry.init),
                        lemmas: [],
                        books: try store.loadBooks(),
                        readerProgress: try store.loadAllReaderProgress(),
                        assistantResults: try store.loadAssistantResults()
                    )
                },
                applyPage: { changes, versions, cursor in
                    try AccountSyncApplicator.applyPage(
                        changes,
                        versions: versions,
                        cursor: cursor,
                        to: store
                    )
                }
            )
        )
        await account.requestEmailCode("convergence@example.com")
        await account.verifyEmailCode("123456")
        account.setSyncEnabled(true)

        await account.synchronize()
        #expect(account.syncStatus.phase == .completed)
        #expect(await sync.pushedMutationCounts() == [21])
        #expect(try store.pendingMutations().isEmpty)

        await account.synchronize()

        #expect(account.syncStatus.phase == .completed)
        #expect(await sync.pushedMutationCounts() == [21])
        #expect(account.syncStatus.completedCount == 0)
        #expect(account.syncStatus.appliedCount == 0)
        #expect(try store.pendingMutations().isEmpty)
        #expect(try store.loadCursor() == "308")
    }

    @MainActor
    @Test("Managed Qwen is a shared account provider with no local API key")
    func managedQwenIsSharedAccountProvider() throws {
        #expect(LLMProvider.managedQwen.menuLabel == "Managed Qwen (account)")
        #expect(LLMProvider.managedQwen.environmentKey.isEmpty)
        #expect(LLMProvider.managedQwen.defaultEndpoint.isEmpty)
        #expect(LLMProvider.managedQwen.usesRemoteAPI)
        var settings = AppSettings.default
        LLMConnectionChoice.managedQwen.apply(to: &settings)
        #expect(settings.llmProvider == LLMProvider.managedQwen.rawValue)
        #expect(LLMConnectionChoice.selected(in: settings) == .managedQwen)
        #expect(LLMError.managedAccountRequired.localizedDescription.contains("Sign in"))
        let state = AppState(composition: .inMemory())
        state.settings.llmProvider = LLMProvider.managedQwen.rawValue
        #expect(state.selectedLLMModel == "Managed Qwen")
        #expect(!state.selectedLLMModel.localizedCaseInsensitiveContains("qwen3.7"))
        let player = try source("Sources/AudioReader/PlayerView.swift")
        #expect(player.contains("Asking \\(state.selectedLLMModel)"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func syncVocabularyChange(index: Int) -> SyncPulledChange {
        let suffix = String(format: "%012d", index)
        return SyncPulledChange(
            sequence: index,
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityId: "aaaaaaaa-aaaa-4aaa-8aaa-\(suffix)",
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: [
                "bookId": .string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
                "chapterId": .string("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
                "surface": .string("word-\(index)"),
                "context": .string("context"),
                "state": .string("learning")
            ]
        )
    }

    private func legacyVocabularyChange(
        id: String,
        category: VocabCategory,
        state: String
    ) -> SyncPulledChange {
        SyncPulledChange(
            sequence: id == "legacy-sentence" ? 1 : (id == "legacy-phrase" ? 2 : 3),
            entityType: OutboxEntityType.vocabulary.rawValue,
            entityId: id,
            operation: OutboxOperation.upsert.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: [
                "bookId": .string("book"),
                "chapterId": .string("chapter"),
                "bookTitle": .string("Book"),
                "chapterTitle": .string("Chapter"),
                "surface": .string(category == .sentence ? "A translated sentence." : "axes"),
                "category": .string(category.rawValue),
                "context": .string("The axes crossed."),
                "timestampSeconds": .number(1),
                "state": .string(state)
            ]
        )
    }

    private func pulledVocabularyChange(
        from mutation: OutboxMutation,
        payload: [String: SyncJSONValue],
        sequence: Int = 1
    ) -> SyncPulledChange {
        SyncPulledChange(
            sequence: sequence,
            entityType: mutation.entityType.rawValue,
            entityId: mutation.entityID,
            operation: mutation.operation.rawValue,
            revision: 1,
            changedAt: "2026-08-30T00:00:00Z",
            payload: payload
        )
    }
}

private actor EchoingSyncClient: SyncClient {
    private var nextSequence: Int
    private var changes: [SyncPulledChange] = []
    private var revisions: [String: Int] = [:]
    private var pushCounts: [Int] = []

    init(initialCursor: Int) {
        nextSequence = initialCursor
    }

    func push(
        accessToken: String,
        deviceID: String,
        request: SyncPushRequest
    ) async throws -> SyncPushResponse {
        _ = accessToken
        _ = deviceID
        pushCounts.append(request.mutations.count)
        let results = request.mutations.map { mutation in
            let key = "\(mutation.entityType)|\(mutation.entityId)"
            let revision = (revisions[key] ?? 0) + 1
            revisions[key] = revision
            nextSequence += 1
            changes.append(SyncPulledChange(
                sequence: nextSequence,
                entityType: mutation.entityType,
                entityId: mutation.entityId,
                operation: mutation.operation,
                revision: revision,
                changedAt: mutation.occurredAt,
                payload: mutation.payload
            ))
            return SyncMutationResult(
                mutationId: mutation.mutationId,
                status: "applied",
                entityRevision: revision
            )
        }
        return SyncPushResponse(
            batchId: request.batchId,
            results: results,
            cursor: String(nextSequence)
        )
    }

    func bootstrap(
        accessToken: String,
        deviceID: String,
        cursor: String?,
        offset: Int,
        limit: Int
    ) async throws -> SyncBootstrapResponse {
        _ = accessToken
        _ = deviceID
        _ = cursor
        _ = offset
        _ = limit
        return SyncBootstrapResponse(
            entities: [],
            cursor: String(nextSequence),
            nextOffset: 0,
            hasMore: false
        )
    }

    func pull(
        accessToken: String,
        deviceID: String,
        cursor: String,
        limit: Int
    ) async throws -> SyncPullResponse {
        _ = accessToken
        _ = deviceID
        let after = Int(cursor) ?? 0
        let page = Array(changes.lazy.filter { $0.sequence > after }.prefix(limit))
        let pageCursor = page.last?.sequence ?? after
        return SyncPullResponse(
            changes: page,
            cursor: String(pageCursor),
            hasMore: changes.contains { $0.sequence > pageCursor }
        )
    }

    func pushedMutationCounts() -> [Int] {
        pushCounts
    }
}
