import Foundation
import Testing
@testable import AudioReaderNetworking

@Suite("Product API base URL")
struct ProductAPIBaseURLTests {
    @Test("environment override wins over the Info.plist value")
    func environmentOverrideWins() {
        let url = ProductAPI.resolveBaseURL(
            environment: [ProductAPI.environmentKey: "https://api.example.test"],
            infoDictionary: [ProductAPI.infoDictionaryKey: "https://plist.example.test"]
        )
        #expect(url.absoluteString == "https://api.example.test")
    }

    @Test("Info.plist ProductAPIBaseURL is used when the environment is unset")
    func plistValueIsUsedWithoutEnvironment() {
        let url = ProductAPI.resolveBaseURL(
            environment: [:],
            infoDictionary: [ProductAPI.infoDictionaryKey: "https://audio-reader-api.example.workers.dev"]
        )
        #expect(url.absoluteString == "https://audio-reader-api.example.workers.dev")
    }

    @Test("empty or non-http values fall back to localhost")
    func emptyOrInvalidValuesFallBackToLocalhost() {
        let empty = ProductAPI.resolveBaseURL(
            environment: [ProductAPI.environmentKey: "  "],
            infoDictionary: [ProductAPI.infoDictionaryKey: ""]
        )
        #expect(empty == ProductAPI.defaultBaseURL)

        let customScheme = ProductAPI.resolveBaseURL(
            environment: [:],
            infoDictionary: [ProductAPI.infoDictionaryKey: "audioreader://auth/callback"]
        )
        #expect(customScheme == ProductAPI.defaultBaseURL)

        let missing = ProductAPI.resolveBaseURL(environment: [:], infoDictionary: nil)
        #expect(missing == ProductAPI.defaultBaseURL)
    }
}
