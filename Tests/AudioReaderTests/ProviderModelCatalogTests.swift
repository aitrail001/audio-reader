import Foundation
import Testing
@testable import AudioReader

@Suite("Provider model catalogs")
struct ProviderModelCatalogTests {
    @Test("xAI fallback catalog contains current language models and excludes retired defaults")
    func xAIFallbackCatalog() {
        let ids = GrokModelCatalog.fallback.map(\.id)

        #expect(ids.contains("grok-4.6"))
        #expect(ids.contains("grok-4.5"))
        #expect(ids.contains("grok-4.3"))
        #expect(ids.contains("grok-4.20"))
        #expect(ids.contains("grok-4.20-non-reasoning"))
        #expect(!ids.contains("grok-4-1-fast-reasoning"))
        #expect(!ids.contains("grok-3"))
    }

    @Test("OpenAI fallback catalog contains current reading-compatible models")
    func openAIFallbackCatalog() {
        let ids = OpenAIModelCatalog.fallback.map(\.id)

        #expect(ids.prefix(3) == ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"])
        #expect(ids.contains("gpt-5.5"))
        #expect(ids.contains("gpt-5.5-pro"))
        #expect(ids.contains("gpt-5.4"))
        #expect(ids.contains("gpt-5.4-mini"))
        #expect(ids.contains("gpt-5.4-nano"))
        #expect(ids.contains("gpt-5.4-pro"))
    }

    @Test("Discovered catalogs keep language generation models and reject media-only models")
    func filtersDiscoveredModels() {
        let grok = GrokModelCatalog.discovered([
            "grok-4.6", "grok-4.6", "grok-imagine-image-2", "grok-voice-latest"
        ])
        let openAI = OpenAIModelCatalog.discovered([
            "gpt-5.6-luna", "gpt-4.1", "gpt-image-2", "gpt-realtime", "text-embedding-3-small"
        ])

        #expect(grok.map(\.id) == ["grok-4.6"])
        #expect(openAI.map(\.id) == ["gpt-4.1", "gpt-5.6-luna"])
    }

    @Test("xAI effort choices follow the selected model")
    func xAIEfforts() {
        #expect(GrokRequestPolicy.supportedEfforts(model: "grok-4.6") == [.low, .medium, .high, .xhigh])
        #expect(GrokRequestPolicy.supportedEfforts(model: "grok-4.5") == [.low, .medium, .high])
        #expect(GrokRequestPolicy.supportedEfforts(model: "grok-4.3") == [.none, .low, .medium, .high])
        #expect(GrokRequestPolicy.supportedEfforts(model: "grok-4.20").isEmpty)
        #expect(GrokRequestPolicy.supportedEfforts(model: "grok-4.20-non-reasoning").isEmpty)
        #expect(GrokRequestPolicy.supportedEfforts(model: "grok-4.20-multi-agent") == [.low, .medium, .high, .xhigh])
        #expect(GrokRequestPolicy.supportedEfforts(model: "grok-build-0.1").isEmpty)
    }

    @Test("OpenAI API effort choices exclude unsupported Codex-only values")
    func openAIEfforts() {
        #expect(OpenAIRequestPolicy.supportedAPIEfforts(model: "gpt-5.6-luna") == [
            .none, .minimal, .low, .medium, .high, .xhigh
        ])
        #expect(OpenAIRequestPolicy.supportedAPIEfforts(model: "gpt-5.5-pro") == [.high])
        #expect(OpenAIRequestPolicy.supportedAPIEfforts(model: "gpt-4.1").isEmpty)
    }

    @Test("Provider model discovery uses each official endpoint")
    func discoveryRequests() throws {
        let xAI = try LLMModelDiscovery.request(
            provider: .grok,
            baseURL: "https://api.x.ai/v1/",
            apiKey: "xai-test"
        )
        let openAI = try LLMModelDiscovery.request(
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            apiKey: "openai-test"
        )

        #expect(xAI.url?.absoluteString == "https://api.x.ai/v1/models")
        #expect(xAI.value(forHTTPHeaderField: "Authorization") == "Bearer xai-test")
        #expect(openAI.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer openai-test")
    }

    @Test("Provider model discovery decodes xAI and OpenAI response shapes")
    func discoveryResponses() throws {
        let xAI = Data(#"{"object":"list","data":[{"id":"grok-4.6"},{"id":"grok-4.5"}]}"#.utf8)
        let openAI = Data(#"{"object":"list","data":[{"id":"gpt-5.6-luna"}]}"#.utf8)

        #expect(try LLMModelDiscovery.decodeModelIDs(xAI, provider: .grok) == ["grok-4.6", "grok-4.5"])
        #expect(try LLMModelDiscovery.decodeModelIDs(openAI, provider: .openAI) == ["gpt-5.6-luna"])
    }
}
