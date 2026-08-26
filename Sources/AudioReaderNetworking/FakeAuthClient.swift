import Foundation

public final class FakeAuthClient: AuthClient, @unchecked Sendable {
    public var otpCode = "123456"
    public private(set) var authorizeCount = 0
    public private(set) var exchangeCount = 0
    public private(set) var bootstrapCount = 0
    public private(set) var logoutTokens: [String] = []

    private let lock = NSLock()
    private var otpEmails: Set<String> = []
    private var accessTokens: [String: SessionRecord] = [:]
    private var refreshTokens: [String: SessionRecord] = [:]
    private var oauthCodes: [String: OAuthRecord] = [:]
    private var devices: [String: AccountDevice] = [:]
    private var revokedDeviceIDs: Set<String> = []
    private var profiles: [String: AccountProfile] = [:]
    private var tokenSerial = 0

    public init() {}

    public func revokeDeviceLocally(_ deviceID: String) {
        withLock { applyRevocationLocked(deviceID) }
    }

    public func authConfig() async throws -> AuthConfig {
        AuthConfig(providers: [
            AuthProvider(id: "google"),
            AuthProvider(id: "microsoft"),
            AuthProvider(id: "email_otp")
        ])
    }

    public func requestEmailOTP(email: String) async throws {
        withLock { _ = otpEmails.insert(normalize(email)) }
    }

    public func verifyEmailOTP(email: String, code: String, deviceID: String) async throws -> TokenPair {
        try withLock {
            let normalized = normalize(email)
            guard otpEmails.contains(normalized), code == otpCode else {
                throw AuthClientError.unauthorized("The email code is invalid or expired.")
            }
            otpEmails.remove(normalized)
            return issueLocked(email: normalized, deviceID: deviceID)
        }
    }

    public func authorizeOAuth(
        provider: AuthOAuthProvider,
        redirectURI: URL,
        codeChallenge: String,
        state: String
    ) async throws -> OAuthAuthorization {
        withLock {
            authorizeCount += 1
            let code = "oauth-code-\(authorizeCount)"
            oauthCodes[code] = OAuthRecord(
                provider: provider,
                redirectURI: redirectURI,
                challenge: codeChallenge,
                state: state,
                email: "\(provider.rawValue)-user@example.com"
            )
            var url = URLComponents(string: "https://auth.example.invalid/oauth/\(provider.rawValue)")!
            url.queryItems = [
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString)
            ]
            return OAuthAuthorization(authorizationURL: url.url!, state: state)
        }
    }

    public func exchangeOAuth(
        provider: AuthOAuthProvider,
        code: String,
        codeVerifier: String,
        redirectURI: URL,
        state: String,
        deviceID: String
    ) async throws -> TokenPair {
        try withLock {
            exchangeCount += 1
            guard let record = oauthCodes.removeValue(forKey: code),
                  record.provider == provider,
                  record.redirectURI == redirectURI,
                  record.state == state,
                  record.challenge == PKCEPair.challenge(for: codeVerifier)
            else {
                throw AuthClientError.unauthorized("The OAuth authorization code is invalid.")
            }
            return issueLocked(email: record.email, deviceID: deviceID)
        }
    }

    public func refresh(refreshToken: String) async throws -> TokenPair {
        try withLock {
            guard let record = refreshTokens.removeValue(forKey: refreshToken) else {
                throw AuthClientError.unauthorized("The refresh token is invalid.")
            }
            if revokedDeviceIDs.contains(record.deviceID) {
                throw AuthClientError.unauthorized("The refresh token is invalid.")
            }
            accessTokens.removeValue(forKey: record.accessToken)
            return issueLocked(email: record.email, deviceID: record.deviceID, profileID: record.profileID, accountID: record.accountID)
        }
    }

    public func logout(refreshToken: String) async throws {
        withLock {
            logoutTokens.append(refreshToken)
            if let record = refreshTokens.removeValue(forKey: refreshToken) {
                accessTokens.removeValue(forKey: record.accessToken)
            }
        }
    }

    public func bootstrap(accessToken: String, request: AuthBootstrapRequest) async throws -> BootstrapResponse {
        try withLock {
            bootstrapCount += 1
            let record = try sessionLocked(accessToken: accessToken, deviceID: request.deviceId)
            if revokedDeviceIDs.contains(request.deviceId) {
                throw AuthClientError.deviceRevoked("This device has been revoked.")
            }
            let timestamp = Self.timestamp()
            let device = AccountDevice(
                id: request.deviceId,
                platform: request.platform.rawValue,
                name: request.deviceName,
                appVersion: request.appVersion,
                buildNumber: request.buildNumber,
                createdAt: devices[request.deviceId]?.createdAt ?? timestamp,
                lastSeenAt: timestamp,
                revoked: false,
                revokedAt: nil
            )
            devices[request.deviceId] = device
            return BootstrapResponse(profile: profiles[record.profileID]!, device: device, syncCursor: "0")
        }
    }

    public func profile(accessToken: String, deviceID: String) async throws -> AccountProfile {
        try withLock {
            let record = try sessionLocked(accessToken: accessToken, deviceID: deviceID)
            return profiles[record.profileID]!
        }
    }

    public func listDevices(accessToken: String, deviceID: String) async throws -> [AccountDevice] {
        try withLock {
            _ = try sessionLocked(accessToken: accessToken, deviceID: deviceID)
            return devices.values.sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func revokeDevice(accessToken: String, deviceID: String, targetDeviceID: String) async throws {
        try withLock {
            _ = try sessionLocked(accessToken: accessToken, deviceID: deviceID)
            applyRevocationLocked(targetDeviceID)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func applyRevocationLocked(_ deviceID: String) {
        revokedDeviceIDs.insert(deviceID)
        let invalidRefresh = refreshTokens.filter { $0.value.deviceID == deviceID }.map(\.key)
        for token in invalidRefresh {
            refreshTokens.removeValue(forKey: token)
        }
        let invalidAccess = accessTokens.filter { $0.value.deviceID == deviceID }.map(\.key)
        for token in invalidAccess {
            accessTokens.removeValue(forKey: token)
        }
        if var device = devices[deviceID] {
            device.revoked = true
            device.revokedAt = Self.timestamp()
            devices[deviceID] = device
        }
    }

    private func issueLocked(
        email: String,
        deviceID: String,
        profileID: String? = nil,
        accountID: String? = nil
    ) -> TokenPair {
        tokenSerial += 1
        let access = "access-\(tokenSerial)-\(UUID().uuidString)"
        let refresh = "refresh-token-value-\(tokenSerial)-\(UUID().uuidString)"
        let profileID = profileID ?? UUID().uuidString.lowercased()
        let accountID = accountID ?? UUID().uuidString.lowercased()
        let timestamp = Self.timestamp()
        if profiles[profileID] == nil {
            profiles[profileID] = AccountProfile(
                id: profileID,
                accountId: accountID,
                email: email,
                displayName: nil,
                avatarUrl: nil,
                createdAt: timestamp,
                updatedAt: timestamp,
                deletionPendingAt: nil
            )
        }
        let record = SessionRecord(
            accessToken: access,
            email: email,
            deviceID: deviceID,
            profileID: profileID,
            accountID: accountID
        )
        accessTokens[access] = record
        refreshTokens[refresh] = record
        return TokenPair(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: timestamp,
            tokenType: "Bearer"
        )
    }

    private func sessionLocked(accessToken: String, deviceID: String) throws -> SessionRecord {
        guard let record = accessTokens[accessToken] else {
            throw AuthClientError.unauthorized("Authentication required.")
        }
        if revokedDeviceIDs.contains(deviceID) || revokedDeviceIDs.contains(record.deviceID) {
            throw AuthClientError.deviceRevoked("This device has been revoked.")
        }
        return record
    }

    private func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private struct SessionRecord {
        var accessToken: String
        var email: String
        var deviceID: String
        var profileID: String
        var accountID: String
    }

    private struct OAuthRecord {
        var provider: AuthOAuthProvider
        var redirectURI: URL
        var challenge: String
        var state: String
        var email: String
    }
}
