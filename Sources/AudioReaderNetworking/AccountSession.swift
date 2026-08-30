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
    public private(set) var lastExportStatus: String?
    public private(set) var pendingExport: AccountExportFile?
    public private(set) var operatorLearningAnalyticsEnabled: Bool?
    var pendingOAuth: PendingOAuth?
    var pendingAuthorizationURL: URL?
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    public var persistedRefreshToken: String? {
        try? store.load()?.refreshToken
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
        guard !enabled || flagEnabled("account_sync", default: false) else {
            errorMessage = "Account sync is turned off for this product right now."
            return
        }
        let previous = mode
        mode = enabled ? .signedInSyncOn : .signedInSyncOff
        if !enabled {
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
        await task.value
        syncTask = nil
    }

    private func performSynchronize(runtime: AccountSyncRuntime) async {
        syncStatus = AccountSyncStatus(phase: .preparing)
        await run {
            do {
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
    /// from the last applied version are enqueued. Conflicts stay pending as a
    /// new mutation at the server revision so the original mutationId is not
    /// retried as a duplicate.
    private func drainSync(runtime: AccountSyncRuntime) async throws {
        let jobID = ProductHTTP.makeRequestID()
        let deviceID = try store.deviceID()
        syncStatus = AccountSyncStatus(phase: .preparing)
        try await bootstrapInitialStateIfNeeded(runtime: runtime, deviceID: deviceID, jobID: jobID)
        try await Task.detached { try Self.enqueueDirtySnapshot(runtime: runtime) }.value
        let (pendingBeforeCoalescing, pending, batches) = try await Task.detached {
            let pendingBeforeCoalescing = try runtime.outbox.pendingMutations().count
            let pending = try Self.coalescePendingMutations(runtime: runtime)
            return (pendingBeforeCoalescing, pending, try Self.syncPushBatches(pending))
        }.value
        if pending.count != pendingBeforeCoalescing {
            Self.syncLog.info(
                "sync_outbox_coalesced message=sync_outbox_coalesced requestId=\(jobID, privacy: .public) superseded=\(pendingBeforeCoalescing - pending.count, privacy: .public) retained=\(pending.count, privacy: .public)"
            )
        }
        var entityProgress = Self.syncEntityProgress(pending)
        var uploaded = 0
        var conflicts = 0
        Self.syncLog.info(
            "sync_push_start message=sync_push_start requestId=\(jobID, privacy: .public) pending=\(pending.count, privacy: .public)"
        )
        if !pending.isEmpty {
            var lookup = Dictionary(uniqueKeysWithValues: pending.map { ($0.id.rawValue, $0) })
            for (batchOffset, batch) in batches.enumerated() {
                let entityTypes = Set(batch.map(\.entityType.rawValue))
                syncStatus = .uploading(
                    entityType: entityTypes.count == 1 ? entityTypes.first : nil,
                    completedCount: uploaded,
                    totalCount: pending.count,
                    batchIndex: batchOffset + 1,
                    batchCount: batches.count,
                    pendingCount: pending.count - uploaded,
                    conflictCount: conflicts,
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
                    try applyPushResult(result, lookup: &lookup, runtime: runtime, jobID: jobID)
                    if result.status == "applied" || result.status == "duplicate" {
                        uploaded += 1
                        if let mutation = lookup[result.mutationId],
                           let index = entityProgress.firstIndex(where: { $0.entityType == mutation.entityType.rawValue })
                        {
                            entityProgress[index].completedCount += 1
                        }
                    } else if result.status == "conflict" {
                        conflicts += 1
                    }
                }
            }
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
                conflictCount: conflicts,
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
            let orderedChanges = SyncPulledChange.applying(pulled.changes)
            syncStatus = AccountSyncStatus(
                phase: .applying,
                completedCount: 0,
                totalCount: orderedChanges.count,
                appliedCount: applied,
                batchIndex: pages,
                pendingCount: (try? runtime.outbox.pendingMutations().count) ?? 0,
                conflictCount: conflicts,
                entityProgress: entityProgress
            )
            let pageVersions = Self.entityVersions(for: orderedChanges)
            try await Task.detached {
                try runtime.applyPage(orderedChanges, pageVersions, pulled.cursor)
            }.value
            applied += orderedChanges.count
            syncStatus = AccountSyncStatus(
                phase: .applying,
                completedCount: orderedChanges.count,
                totalCount: orderedChanges.count,
                appliedCount: applied,
                batchIndex: pages,
                pendingCount: (try? runtime.outbox.pendingMutations().count) ?? 0,
                conflictCount: conflicts,
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
        Self.syncLog.info(
            "sync_finish message=sync_finish requestId=\(jobID, privacy: .public) applied=\(applied, privacy: .public)"
        )
        let remaining = try runtime.outbox.pendingMutations().count
        syncStatus = .completed(
            uploadedCount: uploaded,
            appliedCount: applied,
            pendingCount: remaining,
            conflictCount: conflicts,
            entityProgress: entityProgress
        )
        if applied > 0 {
            onLearningDataApplied?()
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
                try await Task.detached {
                    try runtime.applyPage(
                        SyncPulledChange.applying(remoteToApply),
                        versions,
                        cursorToPersist
                    )
                }.value
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
            SyncEntityVersion(
                entityType: change.entityType,
                entityID: change.entityId,
                serverVersion: Int64(change.revision),
                payload: change.operation == OutboxOperation.delete.rawValue
                    ? SyncJSONCoding.tombstonePayload
                    : SyncJSONCoding.data(from: change.payload)
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
    nonisolated static func syncPushBatches(_ pending: [OutboxMutation]) throws -> [[OutboxMutation]] {
        var batches: [[OutboxMutation]] = []
        var batch: [OutboxMutation] = []
        var encodedBytes = syncPushEnvelopeReserve
        let encoder = JSONEncoder()

        for mutation in pending {
            let mutationBytes = try encoder.encode(mutation.productMutation()).count + 1
            guard syncPushEnvelopeReserve + mutationBytes <= syncPushBatchBytes else {
                throw AccountSyncRunError.mutationTooLarge(entityType: mutation.entityType.rawValue)
            }
            if !batch.isEmpty,
               batch.count >= syncPushBatchSize || encodedBytes + mutationBytes > syncPushBatchBytes
            {
                batches.append(batch)
                batch = []
                encodedBytes = syncPushEnvelopeReserve
            }
            batch.append(mutation)
            encodedBytes += mutationBytes
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private func applyPushResult(
        _ result: SyncMutationResult,
        lookup: inout [String: OutboxMutation],
        runtime: AccountSyncRuntime,
        jobID: String
    ) throws {
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
            guard let mutation = lookup[result.mutationId] else { return }
            let serverRevision = Int64(result.entityRevision ?? Int(mutation.baseRevision.rawValue))
            try runtime.handleConflict(mutation, serverRevision)
            var retry = mutation
            retry.id = MutationID.generate()
            retry.baseRevision = ServerVersion(serverRevision)
            try runtime.outbox.enqueue(retry)
            try runtime.outbox.markAcknowledged(id: mutationID)
            Self.syncLog.info(
                "sync_conflict_requeued message=sync_conflict_requeued requestId=\(jobID, privacy: .public) entityType=\(mutation.entityType.rawValue, privacy: .public)"
            )
        default:
            Self.syncLog.info(
                "sync_push_rejected message=sync_push_rejected requestId=\(jobID, privacy: .public) status=\(result.status, privacy: .public)"
            )
        }
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
            if let version = try runtime.versions?.loadVersion(
                entityType: candidate.entityType.rawValue,
                entityID: candidate.entityID
            ) {
                candidate.baseRevision = ServerVersion(version.serverVersion)
                if SyncJSONCoding.payloadsMatch(version.payload, candidate.payload) {
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
        lastExportStatus = nil
        pendingExport = nil
        operatorLearningAnalyticsEnabled = nil
        pendingOAuth = nil
        pendingAuthorizationURL = nil
        pendingEmail = nil
        syncStatus = .idle
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
    case mutationTooLarge(entityType: String)

    var errorDescription: String? {
        switch self {
        case .pullPageLimitReached:
            "More sync changes remain on the server. Sync again to continue."
        case .inconsistentBootstrapCursor:
            "Initial sync changed snapshots between pages. Try syncing again."
        case .invalidBootstrapPage:
            "Initial sync returned an invalid page. Try syncing again."
        case .mutationTooLarge(let entityType):
            "One \(entityType.replacingOccurrences(of: "_", with: " ")) record is too large to sync safely. Keep it on this device or shorten that chapter transcript."
        }
    }
}
