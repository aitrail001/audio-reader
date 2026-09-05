import Foundation

public enum ProductAPI: Sendable {
    public static let callbackScheme = "audioreader"
    public static let callbackURL = URL(string: "audioreader://auth/callback")!
    public static let defaultBaseURL = URL(string: "http://localhost:8787")!
    public static let hostedProductionBaseURL = URL(
        string: "https://audio-reader-api-worker-production.audio-reader-service.workers.dev"
    )!
    public static let environmentKey = "AUDIOREADER_API_BASE_URL"
    public static let infoDictionaryKey = "ProductAPIBaseURL"

    public static var resolvedBaseURL: URL {
        resolveBaseURL(
            environment: ProcessInfo.processInfo.environment,
            infoDictionary: Bundle.main.infoDictionary
        )
    }

    public static func resolveBaseURL(
        environment: [String: String],
        infoDictionary: [String: Any]?
    ) -> URL {
        if let url = httpURL(environment[environmentKey]) {
            return url
        }
        if let bundled = infoDictionary?[infoDictionaryKey] as? String, let url = httpURL(bundled) {
            return url
        }
        return defaultBaseURL
    }

    private static func httpURL(_ raw: String?) -> URL? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return nil
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}

public enum AccountMode: String, Codable, Sendable, Equatable {
    case local
    case signedInSyncOff
    case signedInSyncOn

    public var isSignedIn: Bool { self != .local }
    public var isSyncEnabled: Bool { self == .signedInSyncOn }
}

public enum AuthOAuthProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case google
    case microsoft
}

public enum ProductDevicePlatform: String, Codable, Sendable {
    case macos
    case ios
    case ipados
}

public struct TokenPair: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: String
    public var tokenType: String?

    public init(accessToken: String, refreshToken: String, expiresAt: String, tokenType: String? = "Bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
    }
}

public struct AuthConfig: Codable, Equatable, Sendable {
    public var providers: [AuthProvider]

    public init(providers: [AuthProvider]) {
        self.providers = providers
    }
}

public struct AuthProvider: Codable, Equatable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct OAuthAuthorization: Codable, Equatable, Sendable {
    public var authorizationURL: URL
    public var state: String

    public init(authorizationURL: URL, state: String) {
        self.authorizationURL = authorizationURL
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case authorizationURL = "authorizationUrl"
        case state
    }
}

public struct AccountProfile: Codable, Equatable, Sendable {
    public var id: String
    public var accountId: String
    public var email: String
    public var displayName: String?
    public var avatarUrl: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletionPendingAt: String?

    public init(
        id: String,
        accountId: String,
        email: String,
        displayName: String?,
        avatarUrl: String?,
        createdAt: String,
        updatedAt: String,
        deletionPendingAt: String?
    ) {
        self.id = id
        self.accountId = accountId
        self.email = email
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletionPendingAt = deletionPendingAt
    }
}

public struct AccountDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var platform: String
    public var name: String?
    public var appVersion: String
    public var buildNumber: String?
    public var createdAt: String
    public var lastSeenAt: String
    public var revoked: Bool
    public var revokedAt: String?

    public init(
        id: String,
        platform: String,
        name: String?,
        appVersion: String,
        buildNumber: String?,
        createdAt: String,
        lastSeenAt: String,
        revoked: Bool,
        revokedAt: String?
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revoked = revoked
        self.revokedAt = revokedAt
    }

    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "\(platform) device" : trimmed
    }
}

public struct AuthBootstrapRequest: Codable, Equatable, Sendable {
    public var deviceId: String
    public var platform: ProductDevicePlatform
    public var deviceName: String?
    public var appVersion: String
    public var buildNumber: String?
    public var locale: String?
    public var timeZone: String?

    public init(
        deviceId: String,
        platform: ProductDevicePlatform,
        deviceName: String?,
        appVersion: String,
        buildNumber: String?,
        locale: String?,
        timeZone: String?
    ) {
        self.deviceId = deviceId
        self.platform = platform
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.locale = locale
        self.timeZone = timeZone
    }
}

public struct FeatureFlag: Codable, Equatable, Sendable {
    public var key: String
    public var enabled: Bool
    public var variant: String?

    public init(key: String, enabled: Bool, variant: String? = nil) {
        self.key = key
        self.enabled = enabled
        self.variant = variant
    }
}

/// Server-derived readiness is authoritative; native code must not infer cloud safety from config.
public struct AccountSyncReadiness: Codable, Equatable, Sendable {
    public var minAppVersion: String?
    public var requiredSchemaVersion: String
    public var schemaReady: Bool
    public var provider: String
    public var bucket: String?
    public var credentialStatus: String
    public var uploadStatus: String
    public var downloadStatus: String
    public var checksumStatus: String
    public var deleteStatus: String
    public var notFoundStatus: String
    public var ready: Bool
    public var requested: Bool
    public var effective: Bool
    public var reason: String?
    public var checkedAt: String
    public var cachedUntil: String
    public var retryAfterSeconds: Int
    public var lastSuccessAt: String?
    public var lastFailureAt: String?
    public var lastFailureCode: String?
    public var lastFailureDetail: String?

    public init(
        minAppVersion: String? = "2.0.0",
        requiredSchemaVersion: String = "20260830123000",
        schemaReady: Bool = true,
        provider: String = "memory",
        bucket: String? = "local-test",
        credentialStatus: String = "ok",
        uploadStatus: String = "ok",
        downloadStatus: String = "ok",
        checksumStatus: String = "ok",
        deleteStatus: String = "ok",
        notFoundStatus: String = "ok",
        ready: Bool = true,
        requested: Bool = true,
        effective: Bool = true,
        reason: String? = nil,
        checkedAt: String = "1970-01-01T00:00:00Z",
        cachedUntil: String = "1970-01-01T00:00:30Z",
        retryAfterSeconds: Int = 30,
        lastSuccessAt: String? = nil,
        lastFailureAt: String? = nil,
        lastFailureCode: String? = nil,
        lastFailureDetail: String? = nil
    ) {
        self.minAppVersion = minAppVersion
        self.requiredSchemaVersion = requiredSchemaVersion
        self.schemaReady = schemaReady
        self.provider = provider
        self.bucket = bucket
        self.credentialStatus = credentialStatus
        self.uploadStatus = uploadStatus
        self.downloadStatus = downloadStatus
        self.checksumStatus = checksumStatus
        self.deleteStatus = deleteStatus
        self.notFoundStatus = notFoundStatus
        self.ready = ready
        self.requested = requested
        self.effective = effective
        self.reason = reason
        self.checkedAt = checkedAt
        self.cachedUntil = cachedUntil
        self.retryAfterSeconds = retryAfterSeconds
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.lastFailureCode = lastFailureCode
        self.lastFailureDetail = lastFailureDetail
    }

    public static let notConfigured = AccountSyncReadiness(
        schemaReady: false,
        provider: "none",
        bucket: nil,
        credentialStatus: "not_checked",
        uploadStatus: "not_checked",
        downloadStatus: "not_checked",
        checksumStatus: "not_checked",
        deleteStatus: "not_checked",
        notFoundStatus: "not_checked",
        ready: false,
        requested: false,
        effective: false,
        reason: "storage_not_configured",
        retryAfterSeconds: 5
    )

    public var pausedDescription: String {
        switch reason {
        case "upgrade_required": "Paused — update AudioReader to continue syncing"
        case "required_schema_unavailable": "Paused — required sync schema unavailable"
        case "storage_not_configured": "Paused — object storage not configured"
        case "storage_bucket_missing": "Paused — storage bucket missing"
        case "storage_credentials_missing": "Paused — storage credentials missing"
        case "storage_credentials_invalid": "Paused — storage credentials unavailable"
        case "storage_public_access_allowed": "Paused — storage is publicly accessible"
        case "storage_privacy_verification_failed": "Paused — storage privacy verification unavailable"
        case "storage_upload_failed": "Paused — storage upload unavailable"
        case "storage_download_failed": "Paused — storage download unavailable"
        case "storage_checksum_mismatch": "Paused — storage verification failed"
        case "storage_delete_failed", "storage_delete_verification_failed":
            "Paused — storage cleanup verification failed"
        default: "Paused — account sync unavailable"
        }
    }
}

public extension AccountSyncReadiness {
    /// Bootstrap remains authoritative, with a native semver fence before sync controls become usable.
    func enforcingAppVersion(_ appVersion: String) -> AccountSyncReadiness {
        guard let minAppVersion,
              Self.semanticVersion(appVersion).lexicographicallyPrecedes(Self.semanticVersion(minAppVersion)) else {
            return self
        }
        var copy = self
        copy.effective = false
        copy.reason = "upgrade_required"
        return copy
    }

    private static func semanticVersion(_ value: String) -> [Int] {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [Int.max, Int.max, Int.max] }
        let parsed = parts.compactMap { Int($0) }
        return parsed.count == 3 ? parsed : [Int.max, Int.max, Int.max]
    }
}

public struct Quota: Codable, Equatable, Sendable {
    public var key: String
    public var used: Double
    public var limit: Double
    public var periodEndsAt: String

    public init(key: String, used: Double, limit: Double, periodEndsAt: String) {
        self.key = key
        self.used = used
        self.limit = limit
        self.periodEndsAt = periodEndsAt
    }
}

public struct AccountExportJob: Codable, Equatable, Sendable {
    public var id: String
    public var status: String
    public var format: String?
    public var assetId: String?
    public var createdAt: String?

    public init(
        id: String,
        status: String,
        format: String? = nil,
        assetId: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.status = status
        self.format = format
        self.assetId = assetId
        self.createdAt = createdAt
    }
}

public struct AccountExportFile: Equatable, Sendable, Identifiable {
    public var id: String
    public var fileName: String
    public var data: Data

    public init(id: String, fileName: String, data: Data) {
        self.id = id
        self.fileName = fileName
        self.data = data
    }
}

public struct ProductUsageEvent: Codable, Equatable, Sendable {
    public var name: String
    public var outcome: String
    public var properties: [String: String]
    public var occurredAt: String

    public init(name: String, outcome: String = "ok", properties: [String: String] = [:], occurredAt: String) {
        self.name = name
        self.outcome = outcome
        self.properties = properties
        self.occurredAt = occurredAt
    }
}

public struct BootstrapResponse: Codable, Equatable, Sendable {
    public var profile: AccountProfile
    public var device: AccountDevice
    public var syncCursor: String?
    public var featureFlags: [FeatureFlag]
    public var quotas: [Quota]
    public var accountSyncReadiness: AccountSyncReadiness
    public var sentenceTranslationBatchSize: Int?

    public init(
        profile: AccountProfile,
        device: AccountDevice,
        syncCursor: String?,
        featureFlags: [FeatureFlag] = [],
        quotas: [Quota] = [],
        accountSyncReadiness: AccountSyncReadiness = AccountSyncReadiness(),
        sentenceTranslationBatchSize: Int? = nil
    ) {
        self.profile = profile
        self.device = device
        self.syncCursor = syncCursor
        self.featureFlags = featureFlags
        self.quotas = quotas
        self.accountSyncReadiness = accountSyncReadiness
        self.sentenceTranslationBatchSize = sentenceTranslationBatchSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(AccountProfile.self, forKey: .profile)
        device = try container.decode(AccountDevice.self, forKey: .device)
        syncCursor = try container.decodeIfPresent(String.self, forKey: .syncCursor)
        featureFlags = try container.decodeIfPresent([FeatureFlag].self, forKey: .featureFlags) ?? []
        quotas = try container.decodeIfPresent([Quota].self, forKey: .quotas) ?? []
        accountSyncReadiness = try container.decode(AccountSyncReadiness.self, forKey: .accountSyncReadiness)
        sentenceTranslationBatchSize = try container.decodeIfPresent(Int.self, forKey: .sentenceTranslationBatchSize)
    }
}

public struct PendingOAuth: Equatable, Sendable {
    public var provider: AuthOAuthProvider
    public var redirectURI: URL
    public var state: String
    public var pkce: PKCEPair

    public init(provider: AuthOAuthProvider, redirectURI: URL, state: String, pkce: PKCEPair) {
        self.provider = provider
        self.redirectURI = redirectURI
        self.state = state
        self.pkce = pkce
    }
}

public struct AccountDeviceEnvironment: Equatable, Sendable {
    public var platform: ProductDevicePlatform
    public var deviceName: String
    public var appVersion: String
    public var buildNumber: String
    public var locale: String
    public var timeZone: String

    public init(
        platform: ProductDevicePlatform,
        deviceName: String,
        appVersion: String,
        buildNumber: String,
        locale: String,
        timeZone: String
    ) {
        self.platform = platform
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.locale = locale
        self.timeZone = timeZone
    }

    public static let test = AccountDeviceEnvironment(
        platform: .macos,
        deviceName: "Test Device",
        appVersion: "test",
        buildNumber: "0",
        locale: "en-US",
        timeZone: "UTC"
    )
}

public struct APIProblem: Codable, Equatable, Sendable {
    public var type: String?
    public var title: String?
    public var status: Int?
    public var code: String?
    public var detail: String?
    public var traceId: String?
    public var fieldErrors: [APIProblemFieldError]?
}

public struct APIProblemFieldError: Codable, Equatable, Sendable {
    public var field: String
    public var message: String
}

public struct AccountAnalyticsPreference: Codable, Equatable, Sendable {
    public var operatorLearningAnalyticsEnabled: Bool
    public var updatedAt: String

    public init(operatorLearningAnalyticsEnabled: Bool, updatedAt: String) {
        self.operatorLearningAnalyticsEnabled = operatorLearningAnalyticsEnabled
        self.updatedAt = updatedAt
    }
}

public enum AuthClientError: Error, Equatable, LocalizedError {
    case unauthorized(String)
    case deviceRevoked(String)
    case problem(status: Int, code: String, detail: String)
    case invalidResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let detail):
            detail
        case .deviceRevoked(let detail):
            detail
        case .problem(_, _, let detail):
            detail
        case .invalidResponse:
            "The account service returned an unexpected response."
        case .cancelled:
            "Sign-in was cancelled."
        }
    }

    public var isSessionInvalid: Bool {
        switch self {
        case .unauthorized, .deviceRevoked:
            true
        case .problem(let status, _, _) where status == 401 || status == 403:
            true
        default:
            false
        }
    }
}

public enum OAuthCallbackError: Error, Equatable, LocalizedError {
    case stateMismatch
    case pkceMismatch
    case missingCode
    case missingPendingSession
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .stateMismatch:
            "The sign-in callback state did not match this device. The authorization code was not sent."
        case .pkceMismatch:
            "The sign-in PKCE verifier did not match this device. The authorization code was not sent."
        case .missingCode:
            "The sign-in callback did not include an authorization code."
        case .missingPendingSession:
            "No in-progress sign-in was found. Start Google or Microsoft sign-in again."
        case .provider(let code):
            "The identity provider rejected sign-in (\(code))."
        }
    }
}
