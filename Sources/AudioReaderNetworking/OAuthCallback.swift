import Foundation

public enum OAuthCallbackValidator: Sendable {
    public static func authorizationCode(from url: URL, pending: PendingOAuth) throws -> String {
        guard pending.pkce.isInternallyConsistent else {
            throw OAuthCallbackError.pkceMismatch
        }

        let items = queryItems(from: url)
        if let error = value("error", in: items), !error.isEmpty {
            throw OAuthCallbackError.provider(error)
        }
        // Hosted GoTrue PKCE returns `?code=` only. Extra `state` on redirect_to
        // is not allow-listed and falls back to Site URL. Require a match only
        // when the callback includes state (local-complete still sends it).
        if let state = value("state", in: items), state != pending.state {
            throw OAuthCallbackError.stateMismatch
        }
        guard let code = value("code", in: items), !code.isEmpty else {
            throw OAuthCallbackError.missingCode
        }
        return code
    }

    private static func queryItems(from url: URL) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            items.append(contentsOf: components.queryItems ?? [])
            if let fragment = components.fragment, !fragment.isEmpty {
                var fragmentComponents = URLComponents()
                fragmentComponents.query = fragment
                items.append(contentsOf: fragmentComponents.queryItems ?? [])
            }
        }
        return items
    }

    private static func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }
}
