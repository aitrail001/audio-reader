import Foundation
import Testing
@testable import AudioReader

@Suite("Native account session flow")
struct AccountSessionFlowTests {
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
        #expect(appState.contains("async let accountRestore"))
        #expect(appState.contains("ManagedProductLLM.translateBatch"))
        #expect(appState.contains("ManagedProductLLM.lookupSummary"))
        #expect(appState.contains("ManagedProductLLM.summarize"))
        #expect(appState.contains("ManagedProductLLM.translate"))
        #expect(appState.contains("lookupOnly: true"))
        #expect(appState.contains("contextPrevious"))
        #expect(appState.contains("contextNext"))
        #expect(appState.contains("contextBefore:"))
        #expect(!appState.contains("ManagedProductLLM.translationEnvelope"))
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
            ]
        )
        #expect(mutations.contains(where: { $0.entityType == .settings }))
        #expect(mutations.contains(where: { $0.entityType == .vocabulary && $0.entityID == vocabID }))
        #expect(mutations.contains(where: { $0.entityType == .lexemeState }))
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
                    face: "recognition",
                    rating: "remember",
                    reviewedAt: Date(timeIntervalSince1970: 1_777_000_100)
                )
            ]
        )
        #expect(mutations.contains(where: { $0.entityType == .book && $0.entityID == bookID }))
        #expect(mutations.contains(where: { $0.entityType == .transcript && $0.entityID == chapterID }))
        let overlay = try #require(mutations.first(where: { $0.entityType == .transcriptOverlay }))
        let overlayPayload = try JSONDecoder().decode([String: SyncJSONValue].self, from: overlay.payload)
        #expect(overlayPayload["localChapterId"]?.stringValue == chapterID)
        #expect(overlayPayload["overlayJSON"]?.stringValue?.contains("Corrected") == true)
        #expect(mutations.contains(where: { $0.entityType == .reviewEvent }))
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
                "surface": .string("ice"),
                "category": .string("word"),
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

    @Test("Pulled review events append immutable history for cross-device learning statistics")
    func pulledReviewAppendsHistory() throws {
        let repository = InMemoryReviewEventRepository()
        let change = SyncPulledChange(
            sequence: 8,
            entityType: OutboxEntityType.reviewEvent.rawValue,
            entityId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            operation: OutboxOperation.append.rawValue,
            revision: 2,
            changedAt: "2026-08-30T02:15:00Z",
            payload: [
                "vocabularyId": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                "face": .string("recognition"),
                "rating": .string(VocabReviewQuality.remember.rawValue),
                "reviewedAt": .string("2026-08-30T02:14:30Z")
            ]
        )

        try AccountSyncApplicator.appendReviewHistory(change, to: repository)
        try AccountSyncApplicator.appendReviewHistory(change, to: repository)

        let events = try repository.loadReviewEvents()
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.id.rawValue == change.entityId)
        #expect(event.vocabularyID.rawValue == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        #expect(event.face == "recognition")
        #expect(event.rating == VocabReviewQuality.remember.rawValue)
        #expect(event.reviewedAt == ISO8601DateFormatter().date(from: "2026-08-30T02:14:30Z"))
    }

    @Test("Vocabulary sync carries local sentence and translation provenance additively")
    func vocabularySyncCarriesPortableFields() throws {
        let item = VocabEntry(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            word: "ice",
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
}
