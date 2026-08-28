import Foundation
import Observation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

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
    public private(set) var featureFlags: [FeatureFlag] = []
    public private(set) var quotas: [Quota] = []
    public private(set) var lastExportStatus: String?
    var pendingOAuth: PendingOAuth?
    var pendingAuthorizationURL: URL?

    public var persistedRefreshToken: String? {
        try? store.load()?.refreshToken
    }

    public let store: any AuthSessionStoring
    private let client: any AuthClient
    private let oauth: any OAuthBrowserSession
    private let environment: AccountDeviceEnvironment
    private let syncRuntime: AccountSyncRuntime?

    public static let revokedDeviceRecoveryMessage =
        "This device is no longer signed in. Books on this device were kept. Sign in again to reconnect."

    public init(
        client: any AuthClient,
        store: any AuthSessionStoring,
        oauth: any OAuthBrowserSession,
        environment: AccountDeviceEnvironment,
        syncRuntime: AccountSyncRuntime? = nil
    ) {
        self.client = client
        self.store = store
        self.oauth = oauth
        self.environment = environment
        self.syncRuntime = syncRuntime
    }

    public static func isolated(
        client: FakeAuthClient = FakeAuthClient(),
        store: InMemoryAuthSessionStore = InMemoryAuthSessionStore(),
        oauth: ScriptedOAuthBrowserSession = .passthrough(),
        environment: AccountDeviceEnvironment = .test,
        syncRuntime: AccountSyncRuntime? = nil
    ) -> AccountSession {
        AccountSession(
            client: client,
            store: store,
            oauth: oauth,
            environment: environment,
            syncRuntime: syncRuntime
        )
    }

    public func restore() async {
        guard let persisted = try? store.load() else {
            mode = .local
            profile = nil
            accessToken = nil
            publishManagedCredentials()
            return
        }
        mode = persisted.mode
        profile = persisted.profile
        await refreshSession()
        if mode.isSyncEnabled {
            await synchronize()
        }
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
        guard (6...12).contains(digits.count) else {
            errorMessage = "Enter the email sign-in code from your message."
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

    public func flagEnabled(_ key: String, default defaultValue: Bool = true) -> Bool {
        featureFlags.first(where: { $0.key == key })?.enabled ?? defaultValue
    }

    public func exportAccount() async {
        await run {
            let deviceID = try store.deviceID()
            let job = try await withAccessToken { access in
                try await client.createAccountExport(accessToken: access, deviceID: deviceID, format: "zip_json")
            }
            lastExportStatus = "Export \(job.status)."
            errorMessage = nil
        }
    }

    public func deleteAccount(reason: String) async {
        await run {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 5 else {
                errorMessage = "Enter a short reason for deleting the account."
                return
            }
            let deviceID = try store.deviceID()
            try await withAccessToken { access in
                try await client.requestAccountDeletion(accessToken: access, deviceID: deviceID, reason: trimmed)
            }
            clearLocalSession(recovery: "Account deletion was requested. This device is back in local mode.")
        }
    }

    public func setSyncEnabled(_ enabled: Bool) {
        guard mode.isSignedIn else { return }
        guard !enabled || flagEnabled("account_sync") else {
            errorMessage = "Account sync is turned off for this product right now."
            return
        }
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

    public func synchronize() async {
        guard mode.isSyncEnabled, let runtime = syncRuntime else { return }
        await run {
            try await drainSync(runtime: runtime)
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
        publishManagedCredentials()
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
        publishManagedCredentials()
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
        featureFlags = bootstrap.featureFlags
        quotas = bootstrap.quotas
        mode = .signedInSyncOff
        pendingOAuth = nil
        recoveryMessage = nil
        errorMessage = nil
        try persist(tokens: tokens, profile: bootstrap.profile, mode: .signedInSyncOff)
        if let cursor = bootstrap.syncCursor, let runtime = syncRuntime {
            try runtime.cursor.saveCursor(cursor)
        }
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

    private func drainSync(runtime: AccountSyncRuntime) async throws {
        let deviceID = try store.deviceID()
        for mutation in try runtime.snapshot() {
            try runtime.outbox.enqueue(mutation)
        }
        let pending = try runtime.outbox.pendingMutations()
        let cursor = try runtime.cursor.loadCursor()
        if !pending.isEmpty {
            let request = SyncPushRequest(
                deviceId: deviceID,
                batchId: UUID().uuidString.lowercased(),
                baseCursor: cursor,
                mutations: try pending.map { try $0.productMutation() }
            )
            let pushed = try await withAccessToken { access in
                try await runtime.client.push(accessToken: access, deviceID: deviceID, request: request)
            }
            try runtime.cursor.saveCursor(pushed.cursor)
            for result in pushed.results
                where result.status == "applied" || result.status == "duplicate" || result.status == "conflict"
            {
                try runtime.outbox.markAcknowledged(id: MutationID(rawValue: result.mutationId))
            }
        }
        let pulled = try await withAccessToken { access in
            try await runtime.client.pull(
                accessToken: access,
                deviceID: deviceID,
                cursor: try runtime.cursor.loadCursor(),
                limit: 100
            )
        }
        for change in pulled.changes {
            try runtime.applyChange(change)
        }
        try runtime.cursor.saveCursor(pulled.cursor)
    }

    private func refreshAccessTokenKeepingSession() async throws {
        guard let persisted = try store.load() else {
            throw AuthClientError.invalidResponse
        }
        do {
            let tokens = try await client.refresh(refreshToken: persisted.refreshToken)
            accessToken = tokens.accessToken
            publishManagedCredentials()
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
        publishManagedCredentials()
        devices = []
        featureFlags = []
        quotas = []
        lastExportStatus = nil
        pendingOAuth = nil
        pendingAuthorizationURL = nil
        pendingEmail = nil
        errorMessage = nil
        recoveryMessage = recovery
    }

    private func publishManagedCredentials() {
        ManagedAccountCredentials.publish(
            accessToken: accessToken,
            deviceID: try? store.deviceID()
        )
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
