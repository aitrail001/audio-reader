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
        #expect(view.contains(".accessibilityLabel(\"Six-digit email sign-in code\")"))
        #expect(view.contains(".accessibilityLabel(\"Verify email sign-in code\")"))
        #expect(view.contains(".accessibilityLabel(\"Sign out of AudioReader account\")"))
        #expect(view.contains(".accessibilityLabel(\"Sync learning data across devices\")"))
        #expect(view.contains(".accessibilityLabel(\"Account session recovery\")"))
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
        #expect(settings.contains("accountSection"))
        #expect(appState.contains("await account.restore()"))
        #expect(appState.contains("init(composition: AppComposition"))
        #expect(live.contains("ASWebAuthenticationSession"))
        #expect(live.contains("callbackURLScheme"))
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
        #expect(!live.contains("OpenAIAPIKeyStore"))
        #expect(!live.contains("codex login"))
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
