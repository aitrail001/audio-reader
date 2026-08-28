import Foundation
import Testing
@testable import AudioReaderNetworking

@Suite("Product managed Qwen client")
struct ProductAIClientTests {
    @Test("translate posts the product task and decodes a cacheable result")
    func translatePostsProductTask() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 200,
            json: """
            {"id":"3fa85f64-5717-4562-b3fc-2c963f66afa6","translation":"你好","notes":[],"provenance":"generated","policyVersion":"qwen-managed-v1","createdAt":"2026-08-28T00:00:00Z"}
            """
        )
        let client = LiveProductAIClient(http: http)
        let result = try await client.translate(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            request: ProductTranslationRequest(
                task: "sentence",
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate",
                source: "Hello"
            )
        )
        #expect(result.translation == "你好")
        #expect(http.requests.first?.path == "/v1/ai/translations")
        #expect(http.requests.first?.headers["Authorization"] == "Bearer access")
    }

    @Test("chat accepts then reads the assistant message")
    func chatThenReadsMessage() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 202,
            json: """
            {"threadId":"3fa85f64-5717-4562-b3fc-2c963f66afa6","messageId":"3fa85f64-5717-4562-b3fc-2c963f66afa7","streamUrl":"/v1/ai/chat/3fa85f64-5717-4562-b3fc-2c963f66afa6/messages/3fa85f64-5717-4562-b3fc-2c963f66afa7"}
            """
        )
        http.enqueue(
            status: 200,
            json: """
            {"id":"3fa85f64-5717-4562-b3fc-2c963f66afa7","role":"assistant","text":"The ice is isolation.","createdAt":"2026-08-28T00:00:00Z"}
            """
        )
        let client = LiveProductAIClient(http: http)
        let accepted = try await client.chat(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            request: ProductChatRequest(
                chapterId: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                question: "What does the ice mean?",
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate"
            )
        )
        let message = try await client.chatMessage(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            streamURL: accepted.streamUrl
        )
        #expect(message.text == "The ice is isolation.")
        #expect(http.requests.last?.method == "GET")
        #expect(http.requests.last?.path == accepted.streamUrl)
    }

    @Test("complete concatenates a system prompt into managed chat")
    func completeUsesChat() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 202,
            json: """
            {"threadId":"3fa85f64-5717-4562-b3fc-2c963f66afa6","messageId":"3fa85f64-5717-4562-b3fc-2c963f66afa7","streamUrl":"/v1/ai/chat/3fa85f64-5717-4562-b3fc-2c963f66afa6/messages/3fa85f64-5717-4562-b3fc-2c963f66afa7"}
            """
        )
        http.enqueue(
            status: 200,
            json: """
            {"id":"3fa85f64-5717-4562-b3fc-2c963f66afa7","role":"assistant","text":"Ice.","createdAt":"2026-08-28T00:00:00Z"}
            """
        )
        let client = LiveProductAIClient(http: http)
        let text = try await client.complete(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            system: "Summarize",
            user: "Chapter text"
        )
        #expect(text == "Ice.")
        let body = try #require(http.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["question"] as? String == "Chapter text")
        #expect((json?["contextSegments"] as? [String])?.first == "Summarize")
    }
}
