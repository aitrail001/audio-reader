import Foundation
import Testing
@testable import AudioReaderNetworking

@Suite("Auth session client")
struct AuthSessionClientTests {
    private let deviceID = "00000000-0000-4000-8000-000000000001"
    private let email = "reader@example.com"

    @Test("HTTP refresh and logout follow the product auth contract")
    func refreshAndLogoutOverHTTP() async throws {
        let http = StubHTTPClient()
        let client = ProductAuthClient(http: http, baseURL: ProductAPI.defaultBaseURL)
        http.enqueue(
            status: 200,
            json: """
            {"accessToken":"access-2","refreshToken":"refresh-token-value2","expiresAt":"2026-08-27T12:00:00Z","tokenType":"Bearer"}
            """
        )
        http.enqueue(status: 204, body: Data())

        let refreshed = try await client.refresh(refreshToken: "refresh-token-value1")
        #expect(refreshed.accessToken == "access-2")
        #expect(refreshed.refreshToken == "refresh-token-value2")
        try await client.logout(refreshToken: refreshed.refreshToken)

        #expect(http.requests.map(\.path) == ["/v1/auth/token/refresh", "/v1/auth/logout"])
        #expect(http.requests[0].method == "POST")
        #expect(http.requests[1].method == "POST")
        #expect(String(data: http.requests[0].body ?? Data(), encoding: .utf8)?.contains("refresh-token-value1") == true)
        #expect(String(data: http.requests[1].body ?? Data(), encoding: .utf8)?.contains("refresh-token-value2") == true)
        #expect(http.requests.allSatisfy { $0.headers["Content-Type"] == "application/json" })
    }

    @Test("HTTP client maps a revoked-device bootstrap to deviceRevoked")
    func revokedDeviceProblemMapsToClientError() async {
        let http = StubHTTPClient()
        let client = ProductAuthClient(http: http, baseURL: ProductAPI.defaultBaseURL)
        http.enqueue(
            status: 403,
            json: """
            {"type":"https://api.example.com/problems/forbidden","title":"Forbidden","status":403,"code":"forbidden","detail":"This device has been revoked.","traceId":"trace-1"}
            """
        )

        await #expect(throws: AuthClientError.deviceRevoked("This device has been revoked.")) {
            _ = try await client.bootstrap(
                accessToken: "access-1",
                request: AuthBootstrapRequest(
                    deviceId: deviceID,
                    platform: .macos,
                    deviceName: "Mac",
                    appVersion: "1.0.59",
                    buildNumber: "60",
                    locale: "en-US",
                    timeZone: "UTC"
                )
            )
        }
    }

    @MainActor
    @Test("refresh rotates tokens and logout rejects the previous refresh token")
    func refreshAndLogout() async throws {
        let session = try await signedInSession()

        #expect(session.mode == .signedInSyncOff)
        let firstAccess = try #require(session.accessToken)
        let firstRefresh = try #require(session.persistedRefreshToken)

        await session.refreshSession()
        #expect(session.mode == .signedInSyncOff)
        #expect(session.accessToken != firstAccess)
        #expect(session.persistedRefreshToken != firstRefresh)
        #expect(session.recoveryMessage == nil)

        await session.signOut()
        #expect(session.mode == .local)
        #expect(session.accessToken == nil)
        #expect(session.profile == nil)
        #expect(session.recoveryMessage == nil)

        await session.refreshSession()
        #expect(session.mode == .local)
        #expect(session.accessToken == nil)
    }

    @MainActor
    @Test("callback state mismatch never exchanges an OAuth code")
    func mismatchedCallbackDoesNotExchange() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: deviceID)
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        await session.beginOAuth(.google)
        let pending = try #require(session.pendingOAuth)
        #expect(client.authorizeCount == 1)

        var components = URLComponents(url: ProductAPI.callbackURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "stolen-code"),
            URLQueryItem(name: "state", value: "forged-state")
        ]
        await session.completeOAuth(callbackURL: try #require(components.url))

        #expect(client.exchangeCount == 0)
        #expect(session.mode == .local)
        #expect(session.pendingOAuth?.state == pending.state)
        #expect(session.errorMessage?.localizedCaseInsensitiveContains("state") == true)
    }

    @MainActor
    @Test("PKCE mismatch never exchanges an OAuth code")
    func mismatchedPKCEDoesNotExchange() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: deviceID)
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        await session.beginOAuth(.microsoft)
        let pending = try #require(session.pendingOAuth)
        session.pendingOAuth = PendingOAuth(
            provider: pending.provider,
            redirectURI: pending.redirectURI,
            state: pending.state,
            pkce: PKCEPair(verifier: pending.pkce.verifier, challenge: "tampered-challenge-value-0123456789abcde")
        )
        var components = URLComponents(url: ProductAPI.callbackURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "auth-code"),
            URLQueryItem(name: "state", value: pending.state)
        ]
        await session.completeOAuth(callbackURL: try #require(components.url))

        #expect(client.exchangeCount == 0)
        #expect(session.mode == .local)
        #expect(session.errorMessage?.localizedCaseInsensitiveContains("pkce") == true
                || session.errorMessage?.localizedCaseInsensitiveContains("verifier") == true)
    }

    @MainActor
    @Test("OAuth sign-in stores a refresh token in the session store")
    func oauthSignInPersistsRefreshToken() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: deviceID)
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )

        await session.signInWithOAuth(.google)

        #expect(session.mode == .signedInSyncOff)
        #expect(session.profile?.email.isEmpty == false)
        #expect(try store.load()?.refreshToken.isEmpty == false)
        #expect(try store.deviceID() == deviceID)
        #expect(client.exchangeCount == 1)
        #expect(client.bootstrapCount == 1)
    }

    @MainActor
    @Test("revoked device returns to local mode with recovery copy")
    func revokedDeviceReturnsToLocalMode() async throws {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: deviceID)
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        await session.requestEmailCode(email)
        await session.verifyEmailCode("123456")
        #expect(session.mode == .signedInSyncOff)
        #expect(try store.load() != nil)

        client.revokeDeviceLocally(deviceID)
        await session.refreshSession()

        #expect(session.mode == .local)
        #expect(session.profile == nil)
        #expect(session.accessToken == nil)
        #expect(try store.load() == nil)
        #expect(try store.deviceID() == deviceID)
        let recovery = try #require(session.recoveryMessage)
        #expect(recovery.localizedCaseInsensitiveContains("sign in") )
        #expect(recovery.localizedCaseInsensitiveContains("kept") || recovery.localizedCaseInsensitiveContains("this device"))
    }

    @MainActor
    @Test("Keychain session store keeps the device ID after logout")
    func keychainStoreSurvivesLogout() throws {
        let service = "com.johnsonzhang.AudioReader.account-session.tests.\(UUID().uuidString)"
        let store = KeychainAuthSessionStore(service: service)
        defer { try? store.clear(); try? store.deleteDeviceID() }

        let device = try store.deviceID()
        #expect(UUID(uuidString: device) != nil)
        try store.save(
            PersistedAuthSession(
                refreshToken: "refresh-token-value1",
                expiresAt: "2026-08-27T12:00:00Z",
                profile: AccountProfile(
                    id: "11111111-1111-4111-8111-111111111111",
                    accountId: "22222222-2222-4222-8222-222222222222",
                    email: email,
                    displayName: "Reader",
                    avatarUrl: nil,
                    createdAt: "2026-08-26T00:00:00Z",
                    updatedAt: "2026-08-26T00:00:00Z",
                    deletionPendingAt: nil
                ),
                mode: .signedInSyncOn
            )
        )

        #expect(try store.load()?.refreshToken == "refresh-token-value1")
        #expect(try store.load()?.mode == .signedInSyncOn)
        try store.clear()
        #expect(try store.load() == nil)
        #expect(try store.deviceID() == device)
    }

    @MainActor
    private func signedInSession() async throws -> AccountSession {
        let client = FakeAuthClient()
        let store = InMemoryAuthSessionStore(deviceID: deviceID)
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        await session.requestEmailCode(email)
        await session.verifyEmailCode("123456")
        return session
    }
}
