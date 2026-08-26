import Foundation

public protocol AuthClient: Sendable {
    func authConfig() async throws -> AuthConfig
    func requestEmailOTP(email: String) async throws
    func verifyEmailOTP(email: String, code: String, deviceID: String) async throws -> TokenPair
    func authorizeOAuth(
        provider: AuthOAuthProvider,
        redirectURI: URL,
        codeChallenge: String,
        state: String
    ) async throws -> OAuthAuthorization
    func exchangeOAuth(
        provider: AuthOAuthProvider,
        code: String,
        codeVerifier: String,
        redirectURI: URL,
        state: String,
        deviceID: String
    ) async throws -> TokenPair
    func refresh(refreshToken: String) async throws -> TokenPair
    func logout(refreshToken: String) async throws
    func bootstrap(accessToken: String, request: AuthBootstrapRequest) async throws -> BootstrapResponse
    func profile(accessToken: String, deviceID: String) async throws -> AccountProfile
    func listDevices(accessToken: String, deviceID: String) async throws -> [AccountDevice]
    func revokeDevice(accessToken: String, deviceID: String, targetDeviceID: String) async throws
}

public protocol OAuthBrowserSession: Sendable {
    func start(authorizationURL: URL, callbackScheme: String) async throws -> URL
}

public struct ScriptedOAuthBrowserSession: OAuthBrowserSession {
    public var rewriteToCallback: Bool

    public init(rewriteToCallback: Bool = true) {
        self.rewriteToCallback = rewriteToCallback
    }

    public static func passthrough() -> ScriptedOAuthBrowserSession {
        ScriptedOAuthBrowserSession(rewriteToCallback: true)
    }

    public func start(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        guard rewriteToCallback else { throw AuthClientError.cancelled }
        let source = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
        var destination = URLComponents(url: ProductAPI.callbackURL, resolvingAgainstBaseURL: false)!
        destination.queryItems = source?.queryItems
        guard let url = destination.url else { throw AuthClientError.invalidResponse }
        return url
    }
}
