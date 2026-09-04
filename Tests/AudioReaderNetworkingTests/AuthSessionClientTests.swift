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

    @Test("account export discovery and integrity verification use only v2 private assets")
    func accountExportUsesV2Manifest() async throws {
        let http = StubHTTPClient()
        let client = ProductAuthClient(http: http, baseURL: ProductAPI.defaultBaseURL)
        http.enqueue(status: 200, json: """
        {"assets":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","compressedBytes":11,"sha256":"4062edaf750fb8074e7e83e0c9028c94e32468a8b6f1614774328ef045150f93"}]}
        """)
        http.enqueue(status: 200, json: """
        {"url":"http://localhost:8787/v2/assets/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/content"}
        """)
        http.enqueue(status: 200, body: Data("{\"ok\":true}".utf8))

        let data = try await client.downloadAccountExport(
            accessToken: "access",
            deviceID: deviceID,
            assetID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )

        #expect(data == Data("{\"ok\":true}".utf8))
        #expect(http.requests.map(\.path) == [
            "/v2/assets?kind=accountExport",
            "/v2/assets/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/download",
            "http://localhost:8787/v2/assets/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/content",
        ])
        #expect(http.requests.allSatisfy { !$0.path.contains("/v1/assets") })
    }

    @Test("HTTP authorize sends the native audioreader callback URI")
    func httpAuthorizeSendsNativeCallback() async throws {
        let http = StubHTTPClient()
        let client = ProductAuthClient(http: http, baseURL: ProductAPI.defaultBaseURL)
        http.enqueue(
            status: 200,
            json: """
            {"authorizationUrl":"https://auth.example.invalid/oauth/google?code=c&state=native-state","state":"native-state"}
            """
        )

        let started = try await client.authorizeOAuth(
            provider: .google,
            redirectURI: ProductAPI.callbackURL,
            codeChallenge: String(repeating: "a", count: 43),
            state: "native-state"
        )

        #expect(started.state == "native-state")
        #expect(http.requests[0].path == "/v1/auth/oauth/authorize")
        let payload = try JSONDecoder().decode(
            NativeCallbackAuthorizeBody.self,
            from: try #require(http.requests[0].body)
        )
        #expect(payload.redirectUri == ProductAPI.callbackURL.absoluteString)
    }

    @Test("HTTP client surfaces problem fieldErrors instead of a generic body message")
    func fieldErrorsOverrideGenericBodyDetail() async {
        let http = StubHTTPClient()
        let client = ProductAuthClient(http: http, baseURL: ProductAPI.defaultBaseURL)
        http.enqueue(
            status: 400,
            json: """
            {"type":"https://api.example.com/problems/bad_request","title":"Bad request","status":400,"code":"bad_request","detail":"The request body is invalid.","fieldErrors":[{"field":"codeVerifier","message":"codeVerifier must be a PKCE verifier."}]}
            """
        )

        await #expect(throws: AuthClientError.problem(
            status: 400,
            code: "bad_request",
            detail: "codeVerifier must be a PKCE verifier."
        )) {
            _ = try await client.exchangeOAuth(
                provider: .google,
                code: "auth-code-1",
                codeVerifier: String(repeating: "a", count: 43),
                redirectURI: ProductAPI.callbackURL,
                state: "native-state",
                deviceID: deviceID
            )
        }
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

    @Test("Bootstrap decodes the effective account sync readiness contract")
    func bootstrapDecodesAccountSyncReadiness() async throws {
        let http = StubHTTPClient()
        let client = ProductAuthClient(http: http, baseURL: ProductAPI.defaultBaseURL)
        http.enqueue(
            status: 200,
            json: """
            {"profile":{"id":"00000000-0000-4000-8000-000000000010","accountId":"00000000-0000-4000-8000-000000000010","email":"reader@example.com","displayName":null,"avatarUrl":null,"createdAt":"2026-08-31T00:00:00Z","updatedAt":"2026-08-31T00:00:00Z","deletionPendingAt":null},"device":{"id":"00000000-0000-4000-8000-000000000001","platform":"macos","name":"Mac","appVersion":"1.6.0","buildNumber":"90","createdAt":"2026-08-31T00:00:00Z","lastSeenAt":"2026-08-31T00:00:00Z","revoked":false,"revokedAt":null},"syncCursor":"7","featureFlags":[{"key":"account_sync","enabled":false,"variant":null}],"quotas":[],"accountSyncReadiness":{"requiredSchemaVersion":"20260830123000","schemaReady":true,"provider":"gcs","bucket":"private-sync","credentialStatus":"failed","uploadStatus":"not_checked","downloadStatus":"not_checked","checksumStatus":"not_checked","deleteStatus":"not_checked","notFoundStatus":"not_checked","ready":false,"requested":true,"effective":false,"reason":"storage_credentials_invalid","checkedAt":"2026-08-31T00:00:00Z","cachedUntil":"2026-08-31T00:00:05Z","retryAfterSeconds":5,"lastSuccessAt":null,"lastFailureAt":"2026-08-31T00:00:00Z","lastFailureCode":"storage_credentials_invalid","lastFailureDetail":"Object storage credentials could not access the configured bucket."}}
            """
        )

        let bootstrap = try await client.bootstrap(
            accessToken: "access-1",
            request: AuthBootstrapRequest(
                deviceId: deviceID,
                platform: .macos,
                deviceName: "Mac",
                appVersion: "1.6.0",
                buildNumber: "90",
                locale: "en-AU",
                timeZone: "Australia/Melbourne"
            )
        )

        let fieldNames = Set(Mirror(reflecting: bootstrap).children.compactMap(\.label))
        #expect(fieldNames.contains("accountSyncReadiness"))
    }

    @Test("Analytics preference uses the authenticated self-service endpoint")
    func analyticsPreferenceOverHTTP() async throws {
        let http = StubHTTPClient()
        let client = ProductAuthClient(http: http, baseURL: ProductAPI.defaultBaseURL)
        http.enqueue(
            status: 200,
            json: """
            {"operatorLearningAnalyticsEnabled":false,"updatedAt":"2026-08-30T04:00:00Z"}
            """
        )
        http.enqueue(
            status: 200,
            json: """
            {"operatorLearningAnalyticsEnabled":true,"updatedAt":"2026-08-30T04:01:00Z"}
            """
        )

        let initial = try await client.analyticsPreference(
            accessToken: "access-1",
            deviceID: deviceID
        )
        let updated = try await client.setAnalyticsPreference(
            accessToken: "access-1",
            deviceID: deviceID,
            enabled: true
        )

        #expect(initial.operatorLearningAnalyticsEnabled == false)
        #expect(updated.operatorLearningAnalyticsEnabled)
        #expect(http.requests.map(\.path) == [
            "/v1/me/analytics-preferences",
            "/v1/me/analytics-preferences",
        ])
        #expect(http.requests.map(\.method) == ["GET", "PUT"])
        #expect(http.requests.allSatisfy { $0.headers["X-Device-Id"] == deviceID })
        #expect(String(data: http.requests[1].body ?? Data(), encoding: .utf8)?.contains("true") == true)
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
        #expect(session.flagEnabled("managed_qwen"))
        #expect(session.quotas.contains { $0.key == "qwen_tasks_day" && $0.limit == 50 })
    }

    @MainActor
    @Test("OAuth sign-in ignores a second attempt while authorization is starting")
    func overlappingOAuthSignInIsIgnored() async throws {
        let gate = OAuthAuthorizeGate()
        let client = FakeAuthClient()
        client.authorizeHook = { attempt in
            if attempt == 1 {
                await gate.wait()
            }
        }
        let session = AccountSession(
            client: client,
            store: InMemoryAuthSessionStore(deviceID: deviceID),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )

        let first = Task { await session.signInWithOAuth(.google) }
        await gate.waitUntilEntered()
        let second = Task { await session.signInWithOAuth(.google) }
        await second.value
        await gate.release()
        await first.value

        #expect(client.authorizeCount == 1)
        #expect(client.exchangeCount == 1)
        #expect(session.mode == .signedInSyncOff)
        #expect(session.errorMessage == nil)
    }

    @MainActor
    @Test("OAuth sign-in does not open a provider the server reports unavailable")
    func unavailableOAuthProviderDoesNotOpen() async throws {
        let client = FakeAuthClient()
        client.authProviders = [AuthProvider(id: "email_otp")]
        let session = AccountSession(
            client: client,
            store: InMemoryAuthSessionStore(deviceID: deviceID),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )

        await session.signInWithOAuth(.google)

        #expect(client.authorizeCount == 0)
        #expect(session.availableOAuthProviders.isEmpty)
        #expect(session.errorMessage == "Google sign-in is not available right now. Use email sign-in or try again later.")
    }

    @MainActor
    @Test("OAuth provider configuration can recover after a transient failure")
    func oauthProviderConfigurationRecovers() async throws {
        let client = FakeAuthClient()
        client.authConfigError = URLError(.notConnectedToInternet)
        let session = AccountSession(
            client: client,
            store: InMemoryAuthSessionStore(deviceID: deviceID),
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )

        await session.refreshAuthConfiguration()
        #expect(session.authConfigurationLoaded)
        #expect(session.availableOAuthProviders.isEmpty)

        client.authConfigError = nil
        await session.refreshAuthConfiguration()
        #expect(session.availableOAuthProviders == Set(AuthOAuthProvider.allCases))
    }

    @MainActor
    @Test("email sign-in accepts 6 to 12 digit codes")
    func emailSignInAcceptsLongerCodes() async throws {
        let client = FakeAuthClient()
        client.otpCode = "12345678"
        let store = InMemoryAuthSessionStore(deviceID: deviceID)
        let session = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        await session.requestEmailCode(email)
        await session.verifyEmailCode("12345678")
        #expect(session.mode == .signedInSyncOff)
        #expect(session.errorMessage == nil)
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
    @Test("expired or missing access token refreshes instead of clearing the session store")
    func accessTokenFailureDoesNotClearRefreshSession() async throws {
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
        let refresh = try #require(session.persistedRefreshToken)

        session.forgetAccessToken()
        await session.refreshDevices()
        #expect(session.mode == .signedInSyncOff)
        #expect(session.accessToken != nil)
        #expect(try store.load()?.refreshToken != nil)
        #expect(session.recoveryMessage == nil)

        client.expireAccessTokens()
        await session.refreshDevices()
        #expect(session.mode == .signedInSyncOff)
        #expect(try store.load() != nil)
        #expect(session.persistedRefreshToken != refresh)
        #expect(session.recoveryMessage == nil)
    }

    @MainActor
    @Test("listing a revoked current device returns to local mode")
    func listingRevokedCurrentDeviceReturnsToLocalMode() async throws {
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

        client.markDeviceRevokedKeepingAccess(deviceID)
        await session.refreshDevices()

        #expect(session.mode == .local)
        #expect(try store.load() == nil)
        #expect(try store.deviceID() == deviceID)
        #expect(session.recoveryMessage != nil)
    }

    @MainActor
    @Test("enabling sync persists and restore keeps signed-in-sync-on")
    func enablingSyncPersistsAcrossRestore() async throws {
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

        session.setSyncEnabled(true)
        #expect(session.mode == .signedInSyncOn)
        #expect(try store.load()?.mode == .signedInSyncOn)
        #expect(session.errorMessage == nil)

        let restored = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        await restored.restore()
        #expect(restored.mode == .signedInSyncOn)
        #expect(restored.profile?.email == email)
        #expect(restored.flagEnabled("managed_qwen"))
        #expect(client.bootstrapCount == 2)
    }

    @MainActor
    @Test("a failed sync preference save stays visible and does not change mode")
    func failedSyncSaveIsVisible() async throws {
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
        store.saveError = AuthSessionStoreError.saveFailed

        session.setSyncEnabled(true)

        #expect(session.mode == .signedInSyncOff)
        #expect(try store.load()?.mode == .signedInSyncOff)
        #expect(session.errorMessage == AuthSessionStoreError.saveFailed.errorDescription)
    }

    @MainActor
    @Test("export downloads account JSON for the save panel")
    func exportDownloadsAccountJSON() async throws {
        let session = try await signedInSession()
        await session.exportAccount()
        #expect(session.pendingExport != nil)
        #expect(session.pendingExport?.fileName.hasSuffix(".json") == true)
        #expect(String(data: session.pendingExport?.data ?? Data(), encoding: .utf8)?.contains("reader@example.com") == true)
        #expect(session.lastExportStatus?.contains("Choose where to save") == true)
        session.markExportSaved()
        #expect(session.pendingExport == nil)
        #expect(session.lastExportStatus?.hasPrefix("Saved ") == true)
    }

    @MainActor
    @Test("Learner controls Operator aggregate analytics and the choice reloads")
    func learnerControlsAnalyticsPreference() async throws {
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

        #expect(session.operatorLearningAnalyticsEnabled == false)
        await session.setOperatorLearningAnalyticsEnabled(true)
        #expect(session.operatorLearningAnalyticsEnabled == true)

        let restored = AccountSession(
            client: client,
            store: store,
            oauth: ScriptedOAuthBrowserSession.passthrough(),
            environment: .test
        )
        await restored.restore()
        #expect(restored.operatorLearningAnalyticsEnabled == true)
    }

    @MainActor
    @Test("Encrypted file session store keeps the device ID after logout")
    func encryptedFileStoreSurvivesLogout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = EncryptedFileAuthSessionStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

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

    private struct NativeCallbackAuthorizeBody: Decodable {
        var redirectUri: String
    }

    private actor OAuthAuthorizeGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var entered = false
        private var released = false

        func wait() async {
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredContinuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
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
