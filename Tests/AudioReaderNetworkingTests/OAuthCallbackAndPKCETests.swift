import Foundation
import Testing
@testable import AudioReaderNetworking

@Suite("OAuth callback and PKCE")
struct OAuthCallbackAndPKCETests {
    @Test("PKCE S256 challenge is URL-safe and matches the verifier")
    func pkceChallengeIsS256() throws {
        let pair = PKCEPair.generate()

        #expect(pair.verifier.count >= 43)
        #expect(pair.verifier.count <= 128)
        #expect(pair.challenge.count >= 43)
        #expect(pair.challenge == PKCEPair.challenge(for: pair.verifier))
        #expect(pair.challenge.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        })
        #expect(!pair.challenge.contains("+"))
        #expect(!pair.challenge.contains("/"))
        #expect(!pair.challenge.contains("="))

        let other = PKCEPair.generate()
        #expect(pair.verifier != other.verifier)
        #expect(PKCEPair.challenge(for: "a-different-verifier-value-0123456789abcd") != pair.challenge)
    }

    @Test("callback with matching state yields the authorization code")
    func matchingCallbackYieldsCode() throws {
        let pending = samplePending()
        let url = callbackURL(code: "auth-code-1", state: pending.state)

        #expect(try OAuthCallbackValidator.authorizationCode(from: url, pending: pending) == "auth-code-1")
    }

    @Test("hosted GoTrue callback with code and no state yields the authorization code")
    func hostedCallbackWithoutStateYieldsCode() throws {
        let pending = samplePending()
        let url = callbackURL(code: "auth-code-hosted", state: nil)

        #expect(try OAuthCallbackValidator.authorizationCode(from: url, pending: pending) == "auth-code-hosted")
    }

    @Test("callback state mismatch is rejected before code exchange")
    func callbackStateMismatchIsRejected() {
        let pending = samplePending()
        let url = callbackURL(code: "auth-code-1", state: "other-state-value")

        #expect(throws: OAuthCallbackError.stateMismatch) {
            try OAuthCallbackValidator.authorizationCode(from: url, pending: pending)
        }
    }

    @Test("PKCE mismatch is rejected before code exchange")
    func pkceMismatchIsRejected() {
        var pending = samplePending()
        pending.pkce = PKCEPair(verifier: pending.pkce.verifier, challenge: "tampered-challenge-value-0123456789abcde")
        let url = callbackURL(code: "auth-code-1", state: pending.state)

        #expect(throws: OAuthCallbackError.pkceMismatch) {
            try OAuthCallbackValidator.authorizationCode(from: url, pending: pending)
        }
    }

    @Test("callback without a code is rejected")
    func missingCodeIsRejected() {
        let pending = samplePending()
        let url = callbackURL(code: nil, state: pending.state)

        #expect(throws: OAuthCallbackError.missingCode) {
            try OAuthCallbackValidator.authorizationCode(from: url, pending: pending)
        }
    }

    @Test("provider error callbacks are rejected")
    func providerErrorIsRejected() {
        let pending = samplePending()
        var components = URLComponents(url: ProductAPI.callbackURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "error", value: "access_denied"),
            URLQueryItem(name: "state", value: pending.state)
        ]
        let url = try! #require(components.url)

        #expect(throws: OAuthCallbackError.provider("access_denied")) {
            try OAuthCallbackValidator.authorizationCode(from: url, pending: pending)
        }
    }

    private func samplePending() -> PendingOAuth {
        PendingOAuth(
            provider: .google,
            redirectURI: ProductAPI.callbackURL,
            state: "oauth-state-value",
            pkce: PKCEPair.generate()
        )
    }

    private func callbackURL(code: String?, state: String?) -> URL {
        var components = URLComponents(url: ProductAPI.callbackURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let code {
            items.append(URLQueryItem(name: "code", value: code))
        }
        if let state {
            items.append(URLQueryItem(name: "state", value: state))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }
}
