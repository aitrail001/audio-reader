import Foundation
import Observation
import os
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
    /// Operator-visible status for restore, sync, and other cloud work. Settings must stay interactive while this is set.
    public private(set) var activityMessage: String?
    public private(set) var syncStatus: AccountSyncStatus = .idle
    public private(set) var pendingEmail: String?
    public private(set) var featureFlags: [FeatureFlag] = []
    public private(set) var quotas: [Quota] = []
    public private(set) var accountSyncReadiness: AccountSyncReadiness = .notConfigured
    public private(set) var lastExportStatus: String?
    public private(set) var pendingExport: AccountExportFile?
    public private(set) var operatorLearningAnalyticsEnabled: Bool?
    public private(set) var availableOAuthProviders: Set<AuthOAuthProvider> = []
    public private(set) var authConfigurationLoaded = false
    var pendingOAuth: PendingOAuth?
    var pendingAuthorizationURL: URL?
    @ObservationIgnored private var oauthSignInInProgress = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncReadinessRetryTask: Task<Void, Never>?

    public var persistedRefreshToken: String? {
        try? store.load()?.refreshToken
    }

    /// Explains server-effective readiness even while the local sync engine is idle or switched off.
    public var syncReadinessMessage: String? {
        guard profile != nil, !accountSyncReadiness.effective else { return nil }
        if syncAvailabilityManagedByOperator {
            return "Sync unavailable — the service operator has not enabled cross-device sync."
        }
        let reason = accountSyncReadiness.pausedDescription
            .replacingOccurrences(of: "Paused — ", with: "")
        if accountSyncReadiness.requested {
            return "Sync paused — \(reason)"
        }
        guard !accountSyncReadiness.ready else { return nil }
        return "Sync unavailable — \(reason). Turn on sync after readiness is restored."
    }

    /// Native can refresh this server-owned policy, but must not attempt to enable it itself.
    public var syncAvailabilityManagedByOperator: Bool {
        profile != nil && accountSyncReadiness.ready && !accountSyncReadiness.requested
    }

    public let store: any AuthSessionStoring
    private let client: any AuthClient
    private let oauth: any OAuthBrowserSession
    private let environment: AccountDeviceEnvironment
    private let syncRuntime: AccountSyncRuntime?
    /// Reloads in-memory learning state after a pull so a later local save cannot clobber it.
    public var onLearningDataApplied: (@MainActor () -> Void)?
    private static let syncLog = Logger(subsystem: "com.johnsonzhang.AudioReader", category: "account-sync")
    private static let usageLog = Logger(subsystem: "com.johnsonzhang.AudioReader", category: "product-usage")
    // A live 500-row vocabulary batch exceeded Cloudflare CPU at only 427 KB.
    // Count-bound small rows separately from the byte-bound transcript envelope.
    nonisolated private static let syncPushBatchSize = 100
    // The largest production transcript is 2.60 MB. A 2.99 MB mixed batch exhausted the
    // Worker, so keep the complete native envelope below 2.625 MiB and send that row alone.
    nonisolated private static let syncPushBatchBytes = 2_752_512
    nonisolated private static let syncPushEnvelopeReserve = 16 * 1_024
    nonisolated private static let syncPullPageLimit = 100
    nonisolated private static let syncPullPageCap = 64

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

    /// Reloads a persisted session without blocking the library UI. Callers should run this
    /// beside `rescan()` and read `activityMessage` instead of greying out Settings.
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
        Self.syncLog.info("account_restore_start message=account_restore_start")
        defer {
            activityMessage = nil
            Self.syncLog.info("account_restore_finished message=account_restore_finished signedIn=\(self.mode.isSignedIn, privacy: .public)")
        }
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
        await run(activity: "Sending sign-in code…") {
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
        await run(activity: "Signing in…") {
            let tokens = try await client.verifyEmailOTP(
                email: email,
                code: digits,
                deviceID: try store.deviceID()
            )
            try await establishSession(tokens: tokens)
            pendingEmail = nil
            recordUsage(name: "account.signed_in", properties: ["method": "email_otp"])
        }
    }

    public func beginOAuth(_ provider: AuthOAuthProvider) async {
        await run(activity: "Opening sign-in…") {
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
        // One pending verifier must own the entire browser round trip. A rapid second
        // tap can otherwise replace it while the first authorization request is suspended.
        guard !oauthSignInInProgress else { return }
        oauthSignInInProgress = true
        defer { oauthSignInInProgress = false }
        if !authConfigurationLoaded {
            await refreshAuthConfiguration()
        }
        guard availableOAuthProviders.contains(provider) else {
            let name = provider == .google ? "Google" : "Microsoft"
            errorMessage = "\(name) sign-in is not available right now. Use email sign-in or try again later."
            return
        }
        await beginOAuth(provider)
        guard let pending = pendingOAuth, let authorizationURL = pendingAuthorizationURL, errorMessage == nil else { return }
        await run(activity: "Signing in…") {
            let callback = try await oauth.start(
                authorizationURL: authorizationURL,
                callbackScheme: ProductAPI.callbackScheme
            )
            try await finishOAuth(callbackURL: callback, pending: pending)
        }
    }

    /// The server reflects the hosted identity provider's current switches; clients
    /// must not offer a social login solely because this app knows its identifier.
    public func refreshAuthConfiguration() async {
        do {
            let config = try await client.authConfig()
            availableOAuthProviders = Set(
                config.providers.compactMap { AuthOAuthProvider(rawValue: $0.id) }
            )
            authConfigurationLoaded = true
        } catch {
            availableOAuthProviders = []
            authConfigurationLoaded = true
        }
    }

    public func completeOAuth(callbackURL: URL) async {
        guard let pending = pendingOAuth else {
            errorMessage = OAuthCallbackError.missingPendingSession.errorDescription
            return
        }
        await run(activity: "Signing in…") {
            try await finishOAuth(callbackURL: callbackURL, pending: pending)
        }
    }

    public func refreshSession() async {
        guard (try? store.load()) != nil else { return }
        await run(activity: activityMessage ?? "Refreshing your account…") {
            try await refreshAccessTokenKeepingSession()
            guard mode.isSignedIn else { return }
            try await loadDevices()
            try await refreshProductBootstrap()
            try? await loadAnalyticsPreference()
        }
    }

    /// Reloads flags and quotas from bootstrap. Empty flags must not default
    /// account_sync to on after a cold start.
    private func refreshProductBootstrap() async throws {
        guard let accessToken else { return }
        let deviceID = try store.deviceID()
        let bootstrap = try await client.bootstrap(
            accessToken: accessToken,
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
        accountSyncReadiness = bootstrap.accountSyncReadiness.enforcingAppVersion(environment.appVersion)
    }

    public func signOut() async {
        recordUsage(name: "account.signed_out")
        await run(activity: "Signing out…") {
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
        if pendingExport != nil {
            lastExportStatus = "Choose where to save your account data."
            return
        }
        var prepared: AccountExportFile?
        await run(activity: "Preparing export…") {
            let deviceID = try store.deviceID()
            lastExportStatus = "Preparing export…"
            let job = try await withAccessToken { access in
                try await client.createAccountExport(accessToken: access, deviceID: deviceID, format: "zip_json")
            }
            guard let assetID = job.assetId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !assetID.isEmpty
            else {
                lastExportStatus = "Export \(job.status)."
                Self.syncLog.error(
                    "account_export_missing_asset message=account_export_missing_asset status=\(job.status, privacy: .public)"
                )
                return
            }
            lastExportStatus = "Downloading export…"
            let data = try await withAccessToken { access in
                try await client.downloadAccountExport(accessToken: access, deviceID: deviceID, assetID: assetID)
            }
            let fileName = "audioreader-account-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"
            prepared = AccountExportFile(id: job.id, fileName: fileName, data: data)
            errorMessage = nil
            recordUsage(name: "account.export.created", properties: ["bytes": "\(data.count)"])
            Self.usageLog.info(
                "account_export_ready message=account_export_ready bytes=\(data.count, privacy: .public)"
            )
        }
        if let prepared {
            pendingExport = prepared
            lastExportStatus = "Choose where to save your account data."
        }
    }

    public func markExportSaved() {
        if let pendingExport {
            lastExportStatus = "Saved \(pendingExport.fileName)."
        }
        pendingExport = nil
        recordUsage(name: "account.export.saved")
    }

    public func markExportSaveCancelled() {
        lastExportStatus = "Export is ready. Tap Save export to pick a location."
    }

    /// Fire-and-forget usage row. Must not toggle isBusy or block reading.
    public func recordUsage(name: String, outcome: String = "ok", properties: [String: String] = [:]) {
        guard mode.isSignedIn, let accessToken else { return }
        let deviceID: String
        do {
            deviceID = try store.deviceID()
        } catch {
            return
        }
        let event = ProductUsageEvent(
            name: name,
            outcome: outcome,
            properties: properties,
            occurredAt: ISO8601DateFormatter().string(from: Date())
        )
        Task { [client, accessToken, deviceID] in
            do {
                try await client.recordProductEvents(
                    accessToken: accessToken,
                    deviceID: deviceID,
                    events: [event]
                )
            } catch {
                Self.usageLog.error(
                    "product_usage_failed message=product_usage_failed name=\(name, privacy: .public)"
                )
            }
        }
    }

    public func deleteAccount(reason: String) async {
        await run(activity: "Deleting account…") {
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
        guard !enabled || accountSyncReadiness.effective else {
            errorMessage = accountSyncReadiness.pausedDescription
            return
        }
        let previous = mode
        mode = enabled ? .signedInSyncOn : .signedInSyncOff
        if !enabled {
            syncReadinessRetryTask?.cancel()
            syncReadinessRetryTask = nil
            syncStatus = .idle
        }
        recordUsage(name: enabled ? "account.sync_enabled" : "account.sync_disabled")
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
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSynchronize(runtime: runtime)
        }
        syncTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        syncTask = nil
    }

    private func performSynchronize(runtime: AccountSyncRuntime) async {
        await run {
            do {
                // Bootstrap is the server-owned readiness decision. Check it before reading a
                // snapshot, creating upload intent, or advancing the local acknowledgement cursor.
                try await refreshProductBootstrap()
                guard accountSyncReadiness.effective else {
                    let pendingCount = (try? runtime.outbox.pendingMutations().count) ?? 0
                    syncStatus = .paused(
                        reason: accountSyncReadiness.pausedDescription,
                        pendingCount: pendingCount
                    )
                    scheduleSyncReadinessRetry()
                    Self.syncLog.info(
                        "sync_paused message=sync_paused reason=\(self.accountSyncReadiness.reason ?? "unavailable", privacy: .public) pending=\(pendingCount, privacy: .public)"
                    )
                    return
                }
                syncReadinessRetryTask?.cancel()
                syncReadinessRetryTask = nil
                syncStatus = AccountSyncStatus(phase: .preparing)
                try await drainSync(runtime: runtime)
                errorMessage = nil
                recordUsage(
                    name: "sync.completed",
                    properties: [
                        "feature": "sync",
                        "uploadedCount": "\(syncStatus.completedCount)",
                        "appliedCount": "\(syncStatus.appliedCount)",
                        "pendingCount": "\(syncStatus.pendingCount)",
                        "conflictCount": "\(syncStatus.conflictCount)"
                    ]
                )
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let pendingCount = (try? runtime.outbox.pendingMutations().count) ?? syncStatus.pendingCount
                syncStatus = AccountSyncStatus(
                    phase: .failed,
                    completedCount: syncStatus.completedCount,
                    totalCount: syncStatus.totalCount,
                    appliedCount: syncStatus.appliedCount,
                    pendingCount: pendingCount,
                    conflictCount: syncStatus.conflictCount,
                    conflicts: syncStatus.conflicts,
                    errorMessage: message,
                    entityProgress: syncStatus.entityProgress
                )
                recordUsage(
                    name: "sync.failed",
                    outcome: "failed",
                    properties: [
                        "feature": "sync",
                        "pendingCount": "\(pendingCount)",
                        "conflictCount": "\(syncStatus.conflictCount)"
                    ]
                )
                throw error
            }
        }
    }

    /// A bounded retry automatically resumes a requested-on sync after a transient outage.
    private func scheduleSyncReadinessRetry() {
        syncReadinessRetryTask?.cancel()
        let seconds = max(1, min(accountSyncReadiness.retryAfterSeconds, 300))
        syncReadinessRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.mode.isSyncEnabled else { return }
            self.syncReadinessRetryTask = nil
            await self.synchronize()
        }
    }

    public var syncStatusAccessibilityDescription: String {
        if syncStatus.phase != .idle {
            return syncStatus.accessibilityDescription
        }
        switch mode {
        case .local: return "Local only. Account sync is unavailable."
        case .signedInSyncOff: return "Sync is off."
        case .signedInSyncOn: return "Up to date."
        }
    }

    /// Reloads the device list without toggling `isBusy`. Settings stay scrollable.
    public func refreshDevices() async {
        guard mode.isSignedIn else { return }
        do {
            try await loadDevices()
        } catch {
            present(error)
        }
    }

    /// Reloads the learner-owned switch that gates optional Operator learning aggregates.
    public func refreshAnalyticsPreference() async {
        guard mode.isSignedIn else {
            operatorLearningAnalyticsEnabled = nil
            return
        }
        await run(activity: "Refreshing privacy preference…") {
            try await loadAnalyticsPreference()
            errorMessage = nil
        }
    }

    /// Only aggregate counts and timestamps are shared; content remains excluded server-side.
    public func setOperatorLearningAnalyticsEnabled(_ enabled: Bool) async {
        guard mode.isSignedIn else { return }
        await run(activity: "Updating privacy preference…") {
            let deviceID = try store.deviceID()
            let preference = try await withAccessToken { access in
                try await client.setAnalyticsPreference(
                    accessToken: access,
                    deviceID: deviceID,
                    enabled: enabled
                )
            }
            operatorLearningAnalyticsEnabled = preference.operatorLearningAnalyticsEnabled
            errorMessage = nil
        }
    }

    public func revokeDevice(_ device: AccountDevice) async {
        await run(activity: "Revoking device…") {
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
        recordUsage(name: "account.signed_in", properties: ["method": pending.provider.rawValue])
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
        accountSyncReadiness = bootstrap.accountSyncReadiness.enforcingAppVersion(environment.appVersion)
        mode = .signedInSyncOff
        pendingOAuth = nil
        recoveryMessage = nil
        errorMessage = nil
        try persist(tokens: tokens, profile: bootstrap.profile, mode: .signedInSyncOff)
        if let cursor = bootstrap.syncCursor, let runtime = syncRuntime {
            try runtime.cursor.saveCursor(cursor)
        }
        try await loadDevices()
        try? await loadAnalyticsPreference()
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

    private func loadAnalyticsPreference() async throws {
        let deviceID = try store.deviceID()
        let preference = try await withAccessToken { access in
            try await client.analyticsPreference(accessToken: access, deviceID: deviceID)
        }
        guard mode.isSignedIn else { return }
        operatorLearningAnalyticsEnabled = preference.operatorLearningAnalyticsEnabled
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

    /// Snapshot enumerates local learning data; only rows whose payload differs
    /// from the last applied version are enqueued. Review conflicts keep their
    /// stale mutation pending until the remote alternative has been pulled.
    private func drainSync(runtime: AccountSyncRuntime) async throws {
        let jobID = ProductHTTP.makeRequestID()
        let deviceID = try store.deviceID()
        syncStatus = AccountSyncStatus(phase: .preparing)
        try await bootstrapInitialStateIfNeeded(runtime: runtime, deviceID: deviceID, jobID: jobID)
        try await publishPendingAssets(runtime: runtime, deviceID: deviceID, jobID: jobID)
        try await Task.detached { try Self.enqueueDirtySnapshot(runtime: runtime) }.value
        let (pendingBeforeCoalescing, pending, plan) = try await Task.detached {
            let pendingBeforeCoalescing = try runtime.outbox.pendingMutations().count
            let pending = try Self.coalescePendingMutations(runtime: runtime)
            return (
                pendingBeforeCoalescing,
                pending,
                try Self.syncPushPlan(pending)
            )
        }.value
        if pending.count != pendingBeforeCoalescing {
            Self.syncLog.info(
                "sync_outbox_coalesced message=sync_outbox_coalesced requestId=\(jobID, privacy: .public) superseded=\(pendingBeforeCoalescing - pending.count, privacy: .public) retained=\(pending.count, privacy: .public)"
            )
        }
        var entityProgress = Self.syncEntityProgress(pending)
        var uploaded = 0
        var detectedReviewConflicts: [AccountSyncConflictKind] = []
        var reviewMutationIDs: [MutationID] = []
        var automaticRetries: [OutboxMutation] = []
        Self.syncLog.info(
            "sync_push_start message=sync_push_start requestId=\(jobID, privacy: .public) pending=\(pending.count, privacy: .public) uploadable=\(plan.uploadableCount, privacy: .public) skipped=\(plan.skipped.count, privacy: .public) encodedBytes=\(plan.encodedBytes, privacy: .public) maxMutationBytes=\(plan.maximumMutationBytes, privacy: .public)"
        )
        if !plan.skipped.isEmpty {
            Self.syncLog.error(
                "sync_push_skipped message=sync_push_skipped requestId=\(jobID, privacy: .public) count=\(plan.skipped.count, privacy: .public) encodedBytes=\(plan.skipped.reduce(0) { $0 + $1.encodedBytes }, privacy: .public) maxMutationBytes=\(plan.skipped.map(\.encodedBytes).max() ?? 0, privacy: .public)"
            )
        }
        if !plan.batches.isEmpty {
            var lookup = Dictionary(uniqueKeysWithValues: pending.map { ($0.id.rawValue, $0) })
            for (batchOffset, batch) in plan.batches.enumerated() {
                let entityTypes = Set(batch.map(\.entityType.rawValue))
                syncStatus = .uploading(
                    entityType: entityTypes.count == 1 ? entityTypes.first : nil,
                    completedCount: uploaded,
                    totalCount: pending.count,
                    batchIndex: batchOffset + 1,
                    batchCount: plan.batches.count,
                    pendingCount: pending.count - uploaded,
                    conflictCount: detectedReviewConflicts.count,
                    conflicts: detectedReviewConflicts,
                    entityProgress: entityProgress
                )
                let request = SyncPushRequest(
                    deviceId: deviceID,
                    batchId: UUID().uuidString.lowercased(),
                    baseCursor: try runtime.cursor.loadCursor(),
                    mutations: try batch.map { try $0.productMutation() }
                )
                let pushed = try await withAccessToken { access in
                    try await runtime.client.push(accessToken: access, deviceID: deviceID, request: request)
                }
                // A push returns the server high-water mark, which can include changes from
                // another device that this client has not pulled. Only a successfully applied
                // pull page may advance the local acknowledgement cursor.
                for result in pushed.results {
                    let disposition = try applyPushResult(
                        result,
                        lookup: &lookup,
                        runtime: runtime,
                        jobID: jobID
                    )
                    if result.status == "applied" || result.status == "duplicate" {
                        uploaded += 1
                        if let mutation = lookup[result.mutationId],
                           let index = entityProgress.firstIndex(where: { $0.entityType == mutation.entityType.rawValue })
                        {
                            entityProgress[index].completedCount += 1
                        }
                    }
                    switch disposition {
                    case .retry(let mutation): automaticRetries.append(mutation)
                    case .needsReview(let kind, let mutationID):
                        detectedReviewConflicts.append(kind)
                        reviewMutationIDs.append(mutationID)
                    case nil: break
                    }
                }
            }
        }

        if !automaticRetries.isEmpty {
            let retryPlan = try Self.syncPushPlan(automaticRetries)
            var lookup = Dictionary(uniqueKeysWithValues: automaticRetries.map { ($0.id.rawValue, $0) })
            var stillChanging = 0
            Self.syncLog.info(
                "sync_conflict_retry_start message=sync_conflict_retry_start requestId=\(jobID, privacy: .public) count=\(automaticRetries.count, privacy: .public)"
            )
            for batch in retryPlan.batches {
                let request = SyncPushRequest(
                    deviceId: deviceID,
                    batchId: UUID().uuidString.lowercased(),
                    baseCursor: try runtime.cursor.loadCursor(),
                    mutations: try batch.map { try $0.productMutation() }
                )
                let pushed = try await withAccessToken { access in
                    try await runtime.client.push(accessToken: access, deviceID: deviceID, request: request)
                }
                for result in pushed.results {
                    let disposition = try applyPushResult(
                        result,
                        lookup: &lookup,
                        runtime: runtime,
                        jobID: jobID
                    )
                    if result.status == "applied" || result.status == "duplicate" {
                        uploaded += 1
                        if let mutation = lookup[result.mutationId],
                           let index = entityProgress.firstIndex(where: { $0.entityType == mutation.entityType.rawValue })
                        {
                            entityProgress[index].completedCount += 1
                        }
                    }
                    switch disposition {
                    case .retry: stillChanging += 1
                    case .needsReview(let kind, let mutationID):
                        detectedReviewConflicts.append(kind)
                        reviewMutationIDs.append(mutationID)
                    case nil: break
                    }
                }
            }
            guard stillChanging == 0 else {
                Self.syncLog.info(
                    "sync_conflict_retry_finished message=sync_conflict_retry_finished requestId=\(jobID, privacy: .public) outcome=still_changing count=\(stillChanging, privacy: .public)"
                )
                throw AccountSyncRunError.concurrentChanges
            }
            Self.syncLog.info(
                "sync_conflict_retry_finished message=sync_conflict_retry_finished requestId=\(jobID, privacy: .public) outcome=applied count=\(automaticRetries.count, privacy: .public)"
            )
        }

        var hasMore = true
        var pages = 0
        var applied = 0
        while hasMore {
            guard pages < Self.syncPullPageCap else { break }
            pages += 1
            syncStatus = AccountSyncStatus(
                phase: .downloading,
                completedCount: applied,
                batchIndex: pages,
                pendingCount: (try? runtime.outbox.pendingMutations().count) ?? 0,
                conflictCount: detectedReviewConflicts.count,
                conflicts: detectedReviewConflicts,
                entityProgress: entityProgress
            )
            let pulled = try await withAccessToken { access in
                try await runtime.client.pull(
                    accessToken: access,
                    deviceID: deviceID,
                    cursor: try runtime.cursor.loadCursor(),
                    limit: Self.syncPullPageLimit
                )
            }
            let hydratedChanges = try await hydrateAssetChanges(
                pulled.changes,
                runtime: runtime,
                deviceID: deviceID
            )
            let orderedChanges = SyncPulledChange.applying(hydratedChanges)
            syncStatus = AccountSyncStatus(
                phase: .applying,
                completedCount: 0,
                totalCount: orderedChanges.count,
                appliedCount: applied,
                batchIndex: pages,
                pendingCount: (try? runtime.outbox.pendingMutations().count) ?? 0,
                conflictCount: detectedReviewConflicts.count,
                conflicts: detectedReviewConflicts,
                entityProgress: entityProgress
            )
            // Even device-local media announcements are consumed with this cursor page.
            // Keep their version ledger and cursor advancement in the same atomic transaction.
            let appliedEntityKeys = Set(orderedChanges.map { "\($0.entityType)|\($0.entityId)" })
            let skippedChanges = pulled.changes.filter {
                !appliedEntityKeys.contains("\($0.entityType)|\($0.entityId)")
            }
            let pageVersions = Self.entityVersions(for: orderedChanges + skippedChanges)
            do {
                try await Task.detached {
                    try runtime.applyPage(orderedChanges, pageVersions, pulled.cursor)
                }.value
                Self.removeHydratedAssetFiles(orderedChanges)
            } catch {
                Self.removeHydratedAssetFiles(orderedChanges)
                throw error
            }
            applied += orderedChanges.count
            syncStatus = AccountSyncStatus(
                phase: .applying,
                completedCount: orderedChanges.count,
                totalCount: orderedChanges.count,
                appliedCount: applied,
                batchIndex: pages,
                pendingCount: (try? runtime.outbox.pendingMutations().count) ?? 0,
                conflictCount: detectedReviewConflicts.count,
                conflicts: detectedReviewConflicts,
                entityProgress: entityProgress
            )
            hasMore = pulled.hasMore
            Self.syncLog.info(
                "sync_pull_page message=sync_pull_page requestId=\(jobID, privacy: .public) cursor=\(pulled.cursor, privacy: .public) hasMore=\(pulled.hasMore, privacy: .public) changes=\(pulled.changes.count, privacy: .public)"
            )
            if !hasMore { break }
        }
        if hasMore {
            throw AccountSyncRunError.pullPageLimitReached
        }
        // A retained review mutation stays stale until its remote alternative is
        // durably applied, so an interrupted pull can never turn it into an overwrite.
        try runtime.outbox.markAcknowledged(ids: reviewMutationIDs)
        Self.syncLog.info(
            "sync_finish message=sync_finish requestId=\(jobID, privacy: .public) applied=\(applied, privacy: .public)"
        )
        let remaining = try runtime.outbox.pendingMutations().count
        let retainedConflicts = try runtime.reviewConflicts()
        syncStatus = .completed(
            uploadedCount: uploaded,
            appliedCount: applied,
            pendingCount: remaining,
            conflictCount: retainedConflicts.count,
            conflicts: retainedConflicts,
            entityProgress: entityProgress
        )
        if applied > 0 {
            onLearningDataApplied?()
        }
    }

    /// Transcript revisions are the only consented cloud assets in this release. Explicit other or
    /// unknown kinds are skipped; a missing kind on a transcript entity retains the legacy fallback.
    private func hydrateAssetChanges(
        _ changes: [SyncPulledChange],
        runtime: AccountSyncRuntime,
        deviceID: String
    ) async throws -> [SyncPulledChange] {
        var hydrated: [SyncPulledChange] = []
        hydrated.reserveCapacity(changes.count)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderSyncAssets-v2-\(UUID().uuidString)", isDirectory: true)
        do {
            for var change in changes {
                guard change.entityType == OutboxEntityType.transcript.rawValue
                        || change.entityType == OutboxEntityType.asset.rawValue else {
                    hydrated.append(change)
                    continue
                }
                let announcedKind = change.payload["kind"]?.stringValue
                    ?? (change.entityType == OutboxEntityType.transcript.rawValue
                        ? SyncAssetKind.transcriptRevision.rawValue : "")
                guard announcedKind == SyncAssetKind.transcriptRevision.rawValue else {
                    Self.syncLog.info(
                        "sync_asset_hydration_skipped message=sync_asset_hydration_skipped entityId=\(change.entityId, privacy: .public) kind=\(announcedKind, privacy: .public) outcome=device_local"
                    )
                    continue
                }
                if change.operation == OutboxOperation.delete.rawValue {
                    // Cleanup tombstones carry no immutable bytes; the transcript deletion itself
                    // remains consented learning data and must reach the atomic page application.
                    Self.syncLog.info(
                        "sync_asset_hydration_bypassed message=sync_asset_hydration_bypassed entityId=\(change.entityId, privacy: .public) kind=\(announcedKind, privacy: .public) outcome=tombstone"
                    )
                    hydrated.append(change)
                    continue
                }
                guard let assetID = change.payload["assetId"]?.stringValue,
                      let kind = SyncAssetKind(rawValue: announcedKind),
                      let sha256 = change.payload["sha256"]?.stringValue,
                      let bytesValue = change.payload["compressedBytes"]?.numberValue,
                      bytesValue.rounded() == bytesValue,
                      bytesValue >= 1
                else { throw AccountSyncRunError.invalidTranscriptManifest }
                let maximumBytes: Double = kind == .transcriptRevision
                    ? 67_108_864 : 2_147_483_648
                guard bytesValue <= maximumBytes else {
                    throw AccountSyncRunError.invalidTranscriptManifest
                }
                let manifest = try await withAccessToken { access in
                    try await runtime.client.assetManifest(
                        accessToken: access, deviceID: deviceID, assetID: assetID
                    )
                }
                guard manifest.status == "ready", manifest.kind == kind,
                      manifest.sha256 == sha256, manifest.compressedBytes == Int(bytesValue)
                else { throw AccountSyncRunError.invalidTranscriptManifest }
                let downloadedURL = try await withAccessToken { access in
                    try await runtime.client.downloadAsset(
                        accessToken: access,
                        deviceID: deviceID,
                        assetID: assetID,
                        sha256: sha256,
                        compressedBytes: Int(bytesValue)
                    )
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("\(change.entityId)-\(UUID().uuidString).object")
                do {
                    try FileManager.default.moveItem(at: downloadedURL, to: url)
                } catch {
                    try? FileManager.default.removeItem(at: downloadedURL)
                    throw error
                }
                change.payload["kind"] = .string(manifest.kind.rawValue)
                change.payload["contentType"] = .string(manifest.contentType)
                change.payload["encoding"] = .string(manifest.encoding)
                change.payload["originalBytes"] = .number(Double(manifest.originalBytes))
                change.payload["segmentCount"] = manifest.segmentCount.map { .number(Double($0)) } ?? .null
                change.payload["revisionId"] = manifest.revisionId.map(SyncJSONValue.string) ?? .null
                change.payload["bookId"] = manifest.bookId.map(SyncJSONValue.string) ?? .null
                change.payload["chapterId"] = manifest.chapterId.map(SyncJSONValue.string) ?? .null
                change.payload["localObjectPath"] = .string(url.path)
                hydrated.append(change)
            }
            return hydrated
        } catch {
            Self.removeHydratedAssetFiles(hydrated)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    nonisolated private static func removeHydratedAssetFiles(_ changes: [SyncPulledChange]) {
        let paths = changes.compactMap { $0.payload["localObjectPath"]?.stringValue }
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
        for directory in Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Ready-manifest publication is server-atomic; a failed object upload leaves the
    /// local transcript available and does not mutate the outbox or cursor.
    private func publishPendingAssets(
        runtime: AccountSyncRuntime,
        deviceID: String,
        jobID: String
    ) async throws {
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderSyncAssetUploads-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let assets = try await Task.detached {
            try runtime.assetUploads(stagingDirectory)
        }.value
        let stagingPath = stagingDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard assets.filter(\.deleteFileAfterUpload).allSatisfy({ asset in
            asset.fileURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(stagingPath)
        }) else {
            throw AccountSyncRunError.invalidAssetStaging
        }
        var uploaded = 0
        for asset in assets {
            if asset.kind == .transcriptRevision,
               let version = try runtime.versions?.loadVersion(
                entityType: OutboxEntityType.transcript.rawValue,
                entityID: asset.revisionID
            ),
               let payload = try? SyncJSONCoding.decoder.decode(
                   [String: SyncJSONValue].self,
                   from: version.payload
               ),
               payload["sha256"]?.stringValue == asset.sha256 {
                continue
            }
            syncStatus = AccountSyncStatus(
                phase: .uploading,
                completedCount: uploaded,
                totalCount: assets.count,
                appliedCount: 0,
                batchIndex: uploaded + 1,
                pendingCount: (try? runtime.outbox.pendingMutations().count) ?? 0,
                entityProgress: [
                    AccountSyncEntityProgress(
                        entityType: OutboxEntityType.transcript.rawValue,
                        completedCount: uploaded,
                        totalCount: assets.count
                    )
                ]
            )
            try await withAccessToken { access in
                try await runtime.client.publishAsset(
                    accessToken: access,
                    deviceID: deviceID,
                    asset: asset
                )
            }
            uploaded += 1
            Self.syncLog.info(
                "sync_asset_publish message=sync_asset_publish requestId=\(jobID, privacy: .public) kind=\(asset.kind.rawValue, privacy: .public) outcome=ready completed=\(uploaded, privacy: .public) total=\(assets.count, privacy: .public)"
            )
        }
    }

    /// A first sync reads one consistent latest-state snapshot before creating upload intent.
    /// The fixed high-water cursor prevents concurrent writes from changing later bootstrap pages.
    private func bootstrapInitialStateIfNeeded(
        runtime: AccountSyncRuntime,
        deviceID: String,
        jobID: String
    ) async throws {
        guard try runtime.cursor.loadCursor() == "0" else { return }
        let local = try await Task.detached { try runtime.snapshot() }.value
        let localByEntity = Dictionary(uniqueKeysWithValues: local.map { (Self.entityKey($0), $0) })
        var snapshotCursor: String?
        var offset = 0
        var hasMore = true
        var pages = 0
        while hasMore {
            let page = try await withAccessToken { access in
                try await runtime.client.bootstrap(
                    accessToken: access,
                    deviceID: deviceID,
                    cursor: snapshotCursor,
                    offset: offset,
                    limit: Self.syncPullPageLimit
                )
            }
            if let snapshotCursor, page.cursor != snapshotCursor {
                throw AccountSyncRunError.inconsistentBootstrapCursor
            }
            snapshotCursor = page.cursor
            guard page.nextOffset >= offset + page.entities.count else {
                throw AccountSyncRunError.invalidBootstrapPage
            }
            let remoteToApply = page.entities.compactMap { entity -> SyncPulledChange? in
                let key = "\(entity.entityType)|\(entity.entityId)"
                guard let localMutation = localByEntity[key] else { return entity.change }
                let localHash = SyncJSONCoding.payloadHash(localMutation.payload)
                if localMutation.operation.rawValue == entity.operation && localHash == entity.payloadHash {
                    return nil
                }
                // Preserve a genuinely different local value; after this page records the
                // server revision, dirty-snapshot enqueue uploads it with the correct base.
                return nil
            }
            let versions = page.entities.map {
                SyncEntityVersion(
                    entityType: $0.entityType,
                    entityID: $0.entityId,
                    serverVersion: Int64($0.revision),
                    payload: $0.operation == OutboxOperation.delete.rawValue
                        ? SyncJSONCoding.tombstonePayload
                        : SyncJSONCoding.data(from: $0.payload)
                )
            }
            let cursorToPersist = page.hasMore ? "0" : page.cursor
            if !page.entities.isEmpty || cursorToPersist != "0" {
                let hydrated = try await hydrateAssetChanges(
                    remoteToApply,
                    runtime: runtime,
                    deviceID: deviceID
                )
                let ordered = SyncPulledChange.applying(hydrated)
                do {
                    try await Task.detached {
                        try runtime.applyPage(ordered, versions, cursorToPersist)
                    }.value
                    Self.removeHydratedAssetFiles(ordered)
                } catch {
                    Self.removeHydratedAssetFiles(ordered)
                    throw error
                }
            }
            pages += 1
            offset = page.nextOffset
            hasMore = page.hasMore
            Self.syncLog.info(
                "sync_bootstrap_page message=sync_bootstrap_page requestId=\(jobID, privacy: .public) page=\(pages, privacy: .public) entities=\(page.entities.count, privacy: .public) hasMore=\(page.hasMore, privacy: .public)"
            )
            if page.entities.isEmpty && page.hasMore {
                throw AccountSyncRunError.invalidBootstrapPage
            }
        }
    }

    private static func entityVersions(for changes: [SyncPulledChange]) -> [SyncEntityVersion] {
        changes.map { change in
            var durablePayload = change.payload
            durablePayload.removeValue(forKey: "localObjectPath")
            return SyncEntityVersion(
                entityType: change.entityType,
                entityID: change.entityId,
                serverVersion: Int64(change.revision),
                payload: change.operation == OutboxOperation.delete.rawValue
                    ? SyncJSONCoding.tombstonePayload
                    : SyncJSONCoding.data(from: durablePayload)
            )
        }
    }

    nonisolated private static func syncEntityProgress(_ pending: [OutboxMutation]) -> [AccountSyncEntityProgress] {
        let totals = Dictionary(grouping: pending, by: { $0.entityType.rawValue }).mapValues(\.count)
        return totals.keys.sorted().map {
            AccountSyncEntityProgress(entityType: $0, completedCount: 0, totalCount: totals[$0] ?? 0)
        }
    }

    /// Keeps sync pushes below the Worker's sync-only body allowance. Count-only batching is
    /// insufficient because one transcript can be several megabytes while most rows are tiny.
    nonisolated static func syncPushPlan(_ pending: [OutboxMutation]) throws -> SyncPushPlan {
        var batches: [[OutboxMutation]] = []
        var skipped: [SyncSkippedMutation] = []
        var batch: [OutboxMutation] = []
        var encodedBytes = syncPushEnvelopeReserve
        var totalEncodedBytes = 0
        var maximumMutationBytes = 0
        let encoder = JSONEncoder()

        for mutation in pending {
            let mutationBytes = try encoder.encode(mutation.productMutation()).count + 1
            maximumMutationBytes = max(maximumMutationBytes, mutationBytes)
            guard syncPushEnvelopeReserve + mutationBytes <= syncPushBatchBytes else {
                skipped.append(SyncSkippedMutation(mutationID: mutation.id, encodedBytes: mutationBytes))
                continue
            }
            if !batch.isEmpty,
               batch.count >= syncPushBatchSize || encodedBytes + mutationBytes > syncPushBatchBytes
            {
                batches.append(batch)
                totalEncodedBytes += encodedBytes
                batch = []
                encodedBytes = syncPushEnvelopeReserve
            }
            batch.append(mutation)
            encodedBytes += mutationBytes
        }
        if !batch.isEmpty {
            batches.append(batch)
            totalEncodedBytes += encodedBytes
        }
        return SyncPushPlan(
            batches: batches,
            skipped: skipped,
            encodedBytes: totalEncodedBytes,
            maximumMutationBytes: maximumMutationBytes
        )
    }

    nonisolated static func syncPushBatches(_ pending: [OutboxMutation]) throws -> [[OutboxMutation]] {
        try syncPushPlan(pending).batches
    }

    private enum PushConflictDisposition {
        case retry(OutboxMutation)
        case needsReview(AccountSyncConflictKind, MutationID)
    }

    private func applyPushResult(
        _ result: SyncMutationResult,
        lookup: inout [String: OutboxMutation],
        runtime: AccountSyncRuntime,
        jobID: String
    ) throws -> PushConflictDisposition? {
        let mutationID = MutationID(rawValue: result.mutationId)
        switch result.status {
        case "applied", "duplicate":
            try runtime.outbox.markAcknowledged(id: mutationID)
            if let mutation = lookup[result.mutationId] {
                try runtime.versions?.saveVersion(
                    SyncEntityVersion(
                        entityType: mutation.entityType.rawValue,
                        entityID: mutation.entityID,
                        serverVersion: Int64(result.entityRevision ?? Int(mutation.baseRevision.rawValue) + 1),
                        payload: mutation.payload,
                        lastMutationID: result.mutationId
                    )
                )
            }
        case "conflict":
            guard let mutation = lookup[result.mutationId] else { return nil }
            let serverRevision = Int64(result.entityRevision ?? Int(mutation.baseRevision.rawValue))
            if let kind = Self.reviewConflictKind(for: mutation) {
                try runtime.handleConflict(mutation, serverRevision)
                Self.syncLog.info(
                    "sync_conflict_retained message=sync_conflict_retained requestId=\(jobID, privacy: .public) entityType=\(mutation.entityType.rawValue, privacy: .public)"
                )
                return .needsReview(kind, mutationID)
            }
            var retry = mutation
            retry.id = MutationID.generate()
            retry.baseRevision = ServerVersion(serverRevision)
            try runtime.outbox.enqueue(retry)
            try runtime.outbox.markAcknowledged(id: mutationID)
            Self.syncLog.info(
                "sync_conflict_requeued message=sync_conflict_requeued requestId=\(jobID, privacy: .public) entityType=\(mutation.entityType.rawValue, privacy: .public)"
            )
            return .retry(retry)
        default:
            Self.syncLog.info(
                "sync_push_rejected message=sync_push_rejected requestId=\(jobID, privacy: .public) status=\(result.status, privacy: .public)"
            )
        }
        return nil
    }

    nonisolated private static func reviewConflictKind(for mutation: OutboxMutation) -> AccountSyncConflictKind? {
        if mutation.entityType == .transcriptOverlay {
            return .transcriptCorrection
        }
        guard mutation.entityType == .progress,
              let payload = try? SyncJSONCoding.decoder.decode(
                  [String: SyncJSONValue].self,
                  from: mutation.payload
              ),
              payload["progressKind"]?.stringValue == "reader"
        else { return nil }
        return .readerProgress
    }

    nonisolated private static func enqueueDirtySnapshot(runtime: AccountSyncRuntime) throws {
        let candidates = try runtime.snapshot()
        let pending = try runtime.outbox.pendingMutations()
        var pendingByEntity: [String: [OutboxMutation]] = [:]
        for item in pending {
            pendingByEntity[Self.entityKey(item), default: []].append(item)
        }
        for var candidate in candidates {
            let key = Self.entityKey(candidate)
            let existingRows = pendingByEntity[key] ?? []
            // A genuine reader/transcript conflict must remain stale until pull applies
            // the other device's value and presents both candidates to the learner.
            if existingRows.contains(where: { Self.reviewConflictKind(for: $0) != nil }) {
                continue
            }
            if let version = try runtime.versions?.loadVersion(
                entityType: candidate.entityType.rawValue,
                entityID: candidate.entityID
            ) {
                candidate.baseRevision = ServerVersion(version.serverVersion)
                if SyncJSONCoding.payloadsMatch(version.payload, candidate.payload)
                    || (candidate.operation == .delete && version.payload == SyncJSONCoding.tombstonePayload) {
                    // The learner reverted to the last server-applied value. Any older local
                    // intent for this entity is stale and must not be uploaded after the skip.
                    try runtime.outbox.markAcknowledged(ids: existingRows.map(\.id))
                    continue
                }
            } else {
                candidate.baseRevision = candidate.baseRevision.rawValue == 0 ? .zero : candidate.baseRevision
            }
            if let existing = existingRows.last {
                candidate.baseRevision = max(existing.baseRevision, candidate.baseRevision)
                if SyncJSONCoding.payloadsMatch(existing.payload, candidate.payload),
                   existing.baseRevision == candidate.baseRevision {
                    continue
                }
                var updated = existing
                updated.operation = candidate.operation
                updated.payload = candidate.payload
                updated.baseRevision = candidate.baseRevision
                updated.occurredAt = candidate.occurredAt
                try runtime.outbox.updatePending(updated)
            } else {
                try runtime.outbox.enqueue(candidate)
            }
        }
    }

    /// Repeated snapshots from older builds may leave many pending rows for one entity.
    /// Keep the latest payload at the highest known server revision before network batching.
    nonisolated private static func coalescePendingMutations(runtime: AccountSyncRuntime) throws -> [OutboxMutation] {
        let pending = try runtime.outbox.pendingMutations()
        struct Winner {
            var order: Int
            var mutation: OutboxMutation
            var needsUpdate: Bool
        }
        var winners: [String: Winner] = [:]
        var superseded: [MutationID] = []
        for (order, mutation) in pending.enumerated() {
            let key = Self.entityKey(mutation)
            guard let existing = winners[key] else {
                winners[key] = Winner(order: order, mutation: mutation, needsUpdate: false)
                continue
            }
            var replacement = mutation
            replacement.baseRevision = max(existing.mutation.baseRevision, mutation.baseRevision)
            winners[key] = Winner(
                order: existing.order,
                mutation: replacement,
                needsUpdate: replacement.baseRevision != mutation.baseRevision
            )
            superseded.append(existing.mutation.id)
        }
        for winner in winners.values where winner.needsUpdate {
            try runtime.outbox.updatePending(winner.mutation)
        }
        try runtime.outbox.markAcknowledged(ids: superseded)
        return winners.values.sorted { $0.order < $1.order }.map(\.mutation)
    }

    nonisolated private static func entityKey(_ mutation: OutboxMutation) -> String {
        "\(mutation.entityType.rawValue)|\(mutation.entityID)"
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
        accountSyncReadiness = .notConfigured
        lastExportStatus = nil
        pendingExport = nil
        operatorLearningAnalyticsEnabled = nil
        pendingOAuth = nil
        pendingAuthorizationURL = nil
        pendingEmail = nil
        syncStatus = .idle
        syncReadinessRetryTask?.cancel()
        syncReadinessRetryTask = nil
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

    private func run(activity: String? = nil, _ operation: () async throws -> Void) async {
        isBusy = true
        if let activity {
            activityMessage = activity
        }
        defer {
            isBusy = false
            if let activity, activityMessage == activity {
                activityMessage = nil
            }
        }
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

private enum AccountSyncRunError: LocalizedError {
    case pullPageLimitReached
    case inconsistentBootstrapCursor
    case invalidBootstrapPage
    case invalidTranscriptManifest
    case invalidAssetStaging
    case concurrentChanges

    var errorDescription: String? {
        switch self {
        case .pullPageLimitReached:
            "More sync changes remain on the server. Sync again to continue."
        case .inconsistentBootstrapCursor:
            "Initial sync changed snapshots between pages. Try syncing again."
        case .invalidBootstrapPage:
            "Initial sync returned an invalid page. Try syncing again."
        case .invalidTranscriptManifest:
            "A transcript object manifest is invalid. Sync paused before changing local data."
        case .invalidAssetStaging:
            "A generated sync asset escaped its private staging directory. Sync paused without deleting local media."
        case .concurrentChanges:
            "Another device is still changing the same data. AudioReader kept this device's change and will retry on the next sync."
        }
    }
}

struct SyncSkippedMutation: Equatable, Sendable {
    var mutationID: MutationID
    var encodedBytes: Int
}

struct SyncPushPlan: Equatable, Sendable {
    var batches: [[OutboxMutation]]
    var skipped: [SyncSkippedMutation]
    var encodedBytes: Int
    var maximumMutationBytes: Int

    var uploadableCount: Int { batches.reduce(0) { $0 + $1.count } }
}
