import Foundation
import Observation

@MainActor
@Observable
public final class AccountSession {
    public private(set) var mode: AccountMode = .local
    public private(set) var profile: AccountProfile?
    public private(set) var accessToken: String?
    public private(set) var devices: [AccountDevice] = []
    public private(set) var recoveryMessage: String?
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false
    public private(set) var pendingEmail: String?
    var pendingOAuth: PendingOAuth?
    var pendingAuthorizationURL: URL?

    public var persistedRefreshToken: String? {
        try? store.load()?.refreshToken
    }

    public let store: any AuthSessionStoring
    private let client: any AuthClient
    private let oauth: any OAuthBrowserSession
    private let environment: AccountDeviceEnvironment

    public static let revokedDeviceRecoveryMessage =
        "This device is no longer signed in. Books on this device were kept. Sign in again to reconnect."

    public init(
        client: any AuthClient,
        store: any AuthSessionStoring,
        oauth: any OAuthBrowserSession,
        environment: AccountDeviceEnvironment
    ) {
        self.client = client
        self.store = store
        self.oauth = oauth
        self.environment = environment
    }

    public static func isolated(
        client: FakeAuthClient = FakeAuthClient(),
        store: InMemoryAuthSessionStore = InMemoryAuthSessionStore(),
        oauth: ScriptedOAuthBrowserSession = .passthrough(),
        environment: AccountDeviceEnvironment = .test
    ) -> AccountSession {
        AccountSession(client: client, store: store, oauth: oauth, environment: environment)
    }

    public func restore() async {
        guard let persisted = try? store.load() else {
            mode = .local
            profile = nil
            accessToken = nil
            return
        }
        mode = persisted.mode
        profile = persisted.profile
        await refreshSession()
    }

    public func requestEmailCode(_ email: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else {
            errorMessage = "Enter a valid email address."
            return
        }
        await run {
            try await client.requestEmailOTP(email: trimmed)
            pendingEmail = trimmed
            errorMessage = nil
            recoveryMessage = nil
        }
    }

    public func verifyEmailCode(_ code: String) async {
        let digits = code.filter(\.isNumber)
        guard let email = pendingEmail else {
            errorMessage = "Request an email sign-in code first."
            return
        }
        guard digits.count == 6 else {
            errorMessage = "Enter the six-digit email sign-in code."
            return
        }
        await run {
            let tokens = try await client.verifyEmailOTP(
                email: email,
                code: digits,
                deviceID: try store.deviceID()
            )
            try await establishSession(tokens: tokens)
            pendingEmail = nil
        }
    }

    public func beginOAuth(_ provider: AuthOAuthProvider) async {
        await run {
            let pkce = PKCEPair.generate()
            let state = PKCEPair.randomState()
            let pending = PendingOAuth(
                provider: provider,
                redirectURI: ProductAPI.callbackURL,
                state: state,
                pkce: pkce
            )
            pendingOAuth = pending
            let started = try await client.authorizeOAuth(
                provider: provider,
                redirectURI: pending.redirectURI,
                codeChallenge: pkce.challenge,
                state: state
            )
            guard started.state == state else {
                throw OAuthCallbackError.stateMismatch
            }
            pendingAuthorizationURL = started.authorizationURL
            errorMessage = nil
        }
    }

    public func signInWithOAuth(_ provider: AuthOAuthProvider) async {
        await beginOAuth(provider)
        guard let pending = pendingOAuth, let authorizationURL = pendingAuthorizationURL, errorMessage == nil else { return }
        await run {
            let callback = try await oauth.start(
                authorizationURL: authorizationURL,
                callbackScheme: ProductAPI.callbackScheme
            )
            try await finishOAuth(callbackURL: callback, pending: pending)
        }
    }

    public func completeOAuth(callbackURL: URL) async {
        guard let pending = pendingOAuth else {
            errorMessage = OAuthCallbackError.missingPendingSession.errorDescription
            return
        }
        await run {
            try await finishOAuth(callbackURL: callbackURL, pending: pending)
        }
    }

    public func refreshSession() async {
        guard (try? store.load()) != nil else { return }
        await run {
            try await refreshAccessTokenKeepingSession()
            guard mode.isSignedIn else { return }
            try await loadDevices()
        }
    }

    public func signOut() async {
        await run {
            let refreshToken = try? store.load()?.refreshToken
            if let refreshToken {
                try? await client.logout(refreshToken: refreshToken)
            }
            clearLocalSession(recovery: nil)
        }
    }

    public func setSyncEnabled(_ enabled: Bool) {
        guard mode.isSignedIn else { return }
        let previous = mode
        mode = enabled ? .signedInSyncOn : .signedInSyncOff
        do {
            guard var persisted = try store.load() else {
                throw AuthSessionStoreError.saveFailed
            }
            persisted.mode = mode
            try store.save(persisted)
            errorMessage = nil
        } catch {
            mode = previous
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not save the sync preference."
        }
    }

    public func refreshDevices() async {
        guard mode.isSignedIn else { return }
        await run {
            try await loadDevices()
        }
    }

    public func revokeDevice(_ device: AccountDevice) async {
        await run {
            let currentID = try store.deviceID()
            try await withAccessToken { access in
                try await client.revokeDevice(
                    accessToken: access,
                    deviceID: currentID,
                    targetDeviceID: device.id
                )
            }
            if device.id == currentID {
                enterLocalAfterInvalidSession()
            } else if mode.isSignedIn {
                try await loadDevices()
            }
        }
    }

    func forgetAccessToken() {
        accessToken = nil
    }

    public var currentDeviceID: String? {
        try? store.deviceID()
    }

    private func finishOAuth(callbackURL: URL, pending: PendingOAuth) async throws {
        let code = try OAuthCallbackValidator.authorizationCode(from: callbackURL, pending: pending)
        let tokens = try await client.exchangeOAuth(
            provider: pending.provider,
            code: code,
            codeVerifier: pending.pkce.verifier,
            redirectURI: pending.redirectURI,
            state: pending.state,
            deviceID: try store.deviceID()
        )
        pendingOAuth = nil
        pendingAuthorizationURL = nil
        try await establishSession(tokens: tokens)
    }

    private func establishSession(tokens: TokenPair) async throws {
        accessToken = tokens.accessToken
        let deviceID = try store.deviceID()
        let bootstrap = try await client.bootstrap(
            accessToken: tokens.accessToken,
            request: AuthBootstrapRequest(
                deviceId: deviceID,
                platform: environment.platform,
                deviceName: environment.deviceName,
                appVersion: environment.appVersion,
                buildNumber: environment.buildNumber,
                locale: environment.locale,
                timeZone: environment.timeZone
            )
        )
        profile = bootstrap.profile
        mode = .signedInSyncOff
        pendingOAuth = nil
        recoveryMessage = nil
        errorMessage = nil
        try persist(tokens: tokens, profile: bootstrap.profile, mode: .signedInSyncOff)
        try await loadDevices()
    }

    private func persist(tokens: TokenPair, profile: AccountProfile, mode: AccountMode) throws {
        try store.save(
            PersistedAuthSession(
                refreshToken: tokens.refreshToken,
                expiresAt: tokens.expiresAt,
                profile: profile,
                mode: mode
            )
        )
    }

    private func loadDevices() async throws {
        let currentID = try store.deviceID()
        let listed = try await withAccessToken { access in
            try await client.listDevices(accessToken: access, deviceID: currentID)
        }
        guard mode.isSignedIn else { return }
        let current = listed.first { $0.id == currentID }
        if current == nil || current?.revoked == true {
            enterLocalAfterInvalidSession()
            return
        }
        devices = listed.filter { !$0.revoked }
    }

    private func withAccessToken<T>(_ operation: (String) async throws -> T) async throws -> T {
        let first = try await resolvedAccessToken()
        do {
            return try await operation(first)
        } catch {
            guard isAccessTokenFailure(error), mode.isSignedIn, try store.load() != nil else {
                throw error
            }
            try await refreshAccessTokenKeepingSession()
            guard mode.isSignedIn, let retry = accessToken else { throw error }
            return try await operation(retry)
        }
    }

    private func resolvedAccessToken() async throws -> String {
        if let accessToken { return accessToken }
        try await refreshAccessTokenKeepingSession()
        guard let accessToken else {
            throw AuthClientError.invalidResponse
        }
        return accessToken
    }

    private func refreshAccessTokenKeepingSession() async throws {
        guard let persisted = try store.load() else {
            throw AuthClientError.invalidResponse
        }
        do {
            let tokens = try await client.refresh(refreshToken: persisted.refreshToken)
            accessToken = tokens.accessToken
            try persist(tokens: tokens, profile: persisted.profile, mode: persisted.mode)
            recoveryMessage = nil
            errorMessage = nil
        } catch {
            if isInvalidSession(error) {
                enterLocalAfterInvalidSession()
            }
            throw error
        }
    }

    private func enterLocalAfterInvalidSession() {
        clearLocalSession(recovery: Self.revokedDeviceRecoveryMessage)
    }

    private func clearLocalSession(recovery: String?) {
        try? store.clear()
        mode = .local
        profile = nil
        accessToken = nil
        devices = []
        pendingOAuth = nil
        pendingAuthorizationURL = nil
        pendingEmail = nil
        errorMessage = nil
        recoveryMessage = recovery
    }

    private func isInvalidSession(_ error: Error) -> Bool {
        if let auth = error as? AuthClientError {
            return auth.isSessionInvalid
        }
        return false
    }

    private func isAccessTokenFailure(_ error: Error) -> Bool {
        guard let auth = error as? AuthClientError else { return false }
        switch auth {
        case .unauthorized, .deviceRevoked:
            return true
        case .problem(let status, _, _) where status == 401 || status == 403:
            return true
        default:
            return false
        }
    }

    private func run(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        guard recoveryMessage == nil else { return }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
