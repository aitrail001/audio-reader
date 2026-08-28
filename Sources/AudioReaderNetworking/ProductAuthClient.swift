import Foundation

public struct ProductAuthClient: AuthClient, Sendable {
    private let http: any HTTPPerforming
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(http: any HTTPPerforming, baseURL: URL = ProductAPI.defaultBaseURL) {
        self.http = http
        _ = baseURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public init(baseURL: URL) {
        self.init(http: LiveHTTPClient(baseURL: baseURL), baseURL: baseURL)
    }

    public func authConfig() async throws -> AuthConfig {
        try await send(method: "GET", path: "/v1/auth/config")
    }

    public func requestEmailOTP(email: String) async throws {
        try await sendVoid(
            method: "POST",
            path: "/v1/auth/email-otp/request",
            body: ["email": email]
        )
    }

    public func verifyEmailOTP(email: String, code: String, deviceID: String) async throws -> TokenPair {
        try await send(
            method: "POST",
            path: "/v1/auth/email-otp/verify",
            body: EmailOTPVerifyBody(email: email, code: code, deviceId: deviceID)
        )
    }

    public func authorizeOAuth(
        provider: AuthOAuthProvider,
        redirectURI: URL,
        codeChallenge: String,
        state: String
    ) async throws -> OAuthAuthorization {
        try await send(
            method: "POST",
            path: "/v1/auth/oauth/authorize",
            body: OAuthAuthorizeBody(
                provider: provider.rawValue,
                redirectUri: redirectURI.absoluteString,
                codeChallenge: codeChallenge,
                codeChallengeMethod: "S256",
                state: state
            )
        )
    }

    public func exchangeOAuth(
        provider: AuthOAuthProvider,
        code: String,
        codeVerifier: String,
        redirectURI: URL,
        state: String,
        deviceID: String
    ) async throws -> TokenPair {
        try await send(
            method: "POST",
            path: "/v1/auth/oauth/exchange",
            headers: ["X-Device-Id": deviceID],
            body: OAuthExchangeBody(
                provider: provider.rawValue,
                code: code,
                codeVerifier: codeVerifier,
                redirectUri: redirectURI.absoluteString,
                state: state
            )
        )
    }

    public func refresh(refreshToken: String) async throws -> TokenPair {
        try await send(
            method: "POST",
            path: "/v1/auth/token/refresh",
            body: ["refreshToken": refreshToken]
        )
    }

    public func logout(refreshToken: String) async throws {
        try await sendVoid(
            method: "POST",
            path: "/v1/auth/logout",
            body: ["refreshToken": refreshToken]
        )
    }

    public func bootstrap(accessToken: String, request: AuthBootstrapRequest) async throws -> BootstrapResponse {
        try await send(
            method: "POST",
            path: "/v1/auth/bootstrap",
            headers: authenticatedHeaders(accessToken: accessToken, deviceID: request.deviceId),
            body: request
        )
    }

    public func profile(accessToken: String, deviceID: String) async throws -> AccountProfile {
        try await send(
            method: "GET",
            path: "/v1/me",
            headers: authenticatedHeaders(accessToken: accessToken, deviceID: deviceID)
        )
    }

    public func listDevices(accessToken: String, deviceID: String) async throws -> [AccountDevice] {
        try await send(
            method: "GET",
            path: "/v1/me/devices",
            headers: authenticatedHeaders(accessToken: accessToken, deviceID: deviceID)
        )
    }

    public func revokeDevice(accessToken: String, deviceID: String, targetDeviceID: String) async throws {
        try await sendVoid(
            method: "DELETE",
            path: "/v1/me/devices/\(targetDeviceID)",
            headers: authenticatedHeaders(accessToken: accessToken, deviceID: deviceID)
        )
    }

    public func createAccountExport(accessToken: String, deviceID: String, format: String) async throws -> AccountExportJob {
        try await send(
            method: "POST",
            path: "/v1/exports",
            headers: authenticatedHeaders(accessToken: accessToken, deviceID: deviceID),
            body: ["format": format]
        )
    }

    public func requestAccountDeletion(accessToken: String, deviceID: String, reason: String) async throws {
        try await sendVoid(
            method: "POST",
            path: "/v1/me/deletion",
            headers: authenticatedHeaders(accessToken: accessToken, deviceID: deviceID),
            body: DeletionBody(confirmation: "DELETE MY ACCOUNT", reason: reason)
        )
    }

    private func authenticatedHeaders(accessToken: String, deviceID: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "X-Device-Id": deviceID,
            "Idempotency-Key": UUID().uuidString.lowercased()
        ]
    }

    private func send<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Body
    ) async throws -> Response {
        try await send(method: method, path: path, headers: headers, data: try encoder.encode(body))
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        headers: [String: String] = [:],
        data: Data? = nil
    ) async throws -> Response {
        let response = try await raw(method: method, path: path, headers: headers, data: data)
        do {
            return try decoder.decode(Response.self, from: response.body)
        } catch {
            throw AuthClientError.invalidResponse
        }
    }

    private func sendVoid<Body: Encodable>(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Body
    ) async throws {
        try await sendVoid(method: method, path: path, headers: headers, data: try encoder.encode(body))
    }

    private func sendVoid(
        method: String,
        path: String,
        headers: [String: String] = [:],
        data: Data? = nil
    ) async throws {
        _ = try await raw(method: method, path: path, headers: headers, data: data)
    }

    private func raw(
        method: String,
        path: String,
        headers: [String: String],
        data: Data?
    ) async throws -> HTTPResponse {
        var merged = headers
        merged["Accept"] = "application/json"
        if data != nil {
            merged["Content-Type"] = "application/json"
        }
        let response = try await http.send(
            HTTPRequest(method: method, path: path, headers: merged, body: data)
        )
        if (200..<300).contains(response.statusCode) {
            return response
        }
        throw mapProblem(status: response.statusCode, body: response.body)
    }

    private func mapProblem(status: Int, body: Data) -> AuthClientError {
        let problem = (try? decoder.decode(APIProblem.self, from: body))
        let fieldDetail = problem?.fieldErrors?
            .map(\.message)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        let detail = [
            fieldDetail,
            problem?.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            problem?.title,
        ]
        .compactMap { $0 }
        .first { !$0.isEmpty }
            ?? "Account request failed (\(status))."
        let code = problem?.code ?? ""
        let looksRevoked = code == "device_revoked"
            || detail.localizedCaseInsensitiveContains("revoked")
        if looksRevoked {
            return .deviceRevoked(detail)
        }
        if status == 401 {
            return .unauthorized(detail)
        }
        return .problem(status: status, code: code.isEmpty ? "error" : code, detail: detail)
    }
}

private struct EmailOTPVerifyBody: Encodable {
    var email: String
    var code: String
    var deviceId: String
}

private struct OAuthAuthorizeBody: Encodable {
    var provider: String
    var redirectUri: String
    var codeChallenge: String
    var codeChallengeMethod: String
    var state: String
}

private struct DeletionBody: Encodable {
    var confirmation: String
    var reason: String
}

private struct OAuthExchangeBody: Encodable {
    var provider: String
    var code: String
    var codeVerifier: String
    var redirectUri: String
    var state: String
}
