import CryptoKit
import Foundation
import Security

public struct PKCEPair: Equatable, Sendable {
    public var verifier: String
    public var challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    public static func generate() -> PKCEPair {
        let verifier = randomVerifier()
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    public static func randomState() -> String {
        randomBytes(count: 24).base64URLEncodedString()
    }

    public var isInternallyConsistent: Bool {
        verifier.count >= 43
            && verifier.count <= 128
            && challenge == Self.challenge(for: verifier)
    }

    private static func randomVerifier() -> String {
        randomBytes(count: 32).base64URLEncodedString()
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
