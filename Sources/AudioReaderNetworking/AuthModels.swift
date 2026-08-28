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

public enum AuthOAuthProvider: String, Codable, Sendable, CaseIterable {
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
    public var createdAt: String?

    public init(id: String, status: String, format: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.status = status
        self.format = format
        self.createdAt = createdAt
    }
}

public struct BootstrapResponse: Codable, Equatable, Sendable {
    public var profile: AccountProfile
    public var device: AccountDevice
    public var syncCursor: String?
    public var featureFlags: [FeatureFlag]
    public var quotas: [Quota]

    public init(
        profile: AccountProfile,
        device: AccountDevice,
        syncCursor: String?,
        featureFlags: [FeatureFlag] = [],
        quotas: [Quota] = []
    ) {
        self.profile = profile
        self.device = device
        self.syncCursor = syncCursor
        self.featureFlags = featureFlags
        self.quotas = quotas
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(AccountProfile.self, forKey: .profile)
        device = try container.decode(AccountDevice.self, forKey: .device)
        syncCursor = try container.decodeIfPresent(String.self, forKey: .syncCursor)
        featureFlags = try container.decodeIfPresent([FeatureFlag].self, forKey: .featureFlags) ?? []
        quotas = try container.decodeIfPresent([Quota].self, forKey: .quotas) ?? []
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
