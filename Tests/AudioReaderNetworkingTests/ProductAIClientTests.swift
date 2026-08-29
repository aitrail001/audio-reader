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

    @Test("translateBatch posts the chapter block and decodes per-sentence cache results")
    func translateBatchPostsChapterBlock() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 200,
            json: """
            {"results":[{"id":"3fa85f64-5717-4562-b3fc-2c963f66afa6","targetId":"s1","source":"Hello","translation":"你好","notes":[],"provenance":"cache_shared_exact","policyVersion":"qwen-managed-v1","createdAt":"2026-08-28T00:00:00Z"},{"id":"3fa85f64-5717-4562-b3fc-2c963f66afa7","targetId":"s2","source":"World","translation":"世界","notes":[],"provenance":"generated","policyVersion":"qwen-managed-v1","createdAt":"2026-08-28T00:00:00Z"}],"missingIds":[],"generatedCount":1,"cacheHitCount":1}
            """
        )
        let client = LiveProductAIClient(http: http)
        let result = try await client.translateBatch(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            request: ProductTranslationBatchRequest(
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate",
                sentences: [
                    ProductTranslationSentence(id: "s1", text: "Hello"),
                    ProductTranslationSentence(id: "s2", text: "World")
                ],
                contextBefore: "PREVIOUS: The room fell silent.\nTARGET id=s2: World\nNEXT: Everyone relaxed.",
                lookupOnly: true
            )
        )
        #expect(result.results.count == 2)
        #expect(result.cacheHitCount == 1)
        #expect(http.requests.first?.path == "/v1/ai/translation-batches")
        let body = try #require(http.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["task"] as? String == "chapter_batch")
        #expect(json?["lookupOnly"] as? Bool == true)
        #expect(json?["contextBefore"] as? String == "PREVIOUS: The room fell silent.\nTARGET id=s2: World\nNEXT: Everyone relaxed.")
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

    @Test("translate lookupOnly maps a cache miss to a not-found problem")
    func translateLookupOnlyMapsNotFound() async {
        let http = StubHTTPClient()
        http.enqueue(
            status: 404,
            json: """
            {"type":"https://api.example.com/problems/not_found","title":"Not found","status":404,"code":"not_found","detail":"No cached translation matched this request.","traceId":"trace","retryAfterSeconds":null,"fieldErrors":[]}
            """
        )
        let client = LiveProductAIClient(http: http)
        await #expect(throws: AuthClientError.problem(
            status: 404,
            code: "not_found",
            detail: "No cached translation matched this request."
        )) {
            _ = try await client.translate(
                accessToken: "access",
                deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                request: ProductTranslationRequest(
                    task: "sentence",
                    sourceLanguage: "en",
                    targetLanguage: "zh",
                    learnerLevel: "intermediate",
                    source: "Hello",
                    lookupOnly: true
                )
            )
        }
    }

    @Test("fake product client treats lookupOnly as a cache miss")
    func fakeLookupOnlyMisses() async throws {
        let client = FakeProductAIClient()
        await #expect(throws: AuthClientError.problem(
            status: 404,
            code: "not_found",
            detail: "No cached translation matched this request."
        )) {
            _ = try await client.translate(
                accessToken: "access",
                deviceID: "device",
                request: ProductTranslationRequest(
                    task: "word",
                    sourceLanguage: "en",
                    targetLanguage: "zh",
                    learnerLevel: "intermediate",
                    source: "ice",
                    lookupOnly: true
                )
            )
        }
        let batch = try await client.translateBatch(
            accessToken: "access",
            deviceID: "device",
            request: ProductTranslationBatchRequest(
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate",
                sentences: [ProductTranslationSentence(id: "s1", text: "Hello")],
                lookupOnly: true
            )
        )
        #expect(batch.results.isEmpty)
        #expect(batch.missingIds == ["s1"])
        await #expect(throws: AuthClientError.problem(
            status: 404,
            code: "not_found",
            detail: "No cached chapter summary matched this request."
        )) {
            _ = try await client.summarize(
                accessToken: "access",
                deviceID: "device",
                request: ProductChapterSummaryRequest(
                    chapterId: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                    sourceLanguage: "en",
                    targetLanguage: "zh",
                    learnerLevel: "intermediate",
                    lookupOnly: true
                )
            )
        }
        #expect(client.translateCalls == 0)
        #expect(client.translateBatchCalls == 1)
        #expect(client.summarizeCalls == 0)
    }

    @Test("summarize posts lookupOnly and refresh flags")
    func summarizePostsLookupAndRefresh() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 200,
            json: """
            {"id":"3fa85f64-5717-4562-b3fc-2c963f66afa6","overview":"概述","keyPoints":[],"keyConcepts":[],"themes":[],"provenance":"generated","createdAt":"2026-08-28T00:00:00Z"}
            """
        )
        let client = LiveProductAIClient(http: http)
        let result = try await client.summarize(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            request: ProductChapterSummaryRequest(
                chapterId: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate",
                lookupOnly: false,
                refresh: true
            )
        )
        #expect(result.overview == "概述")
        #expect(http.requests.first?.path == "/v1/ai/chapter-summaries")
        let body = try #require(http.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["refresh"] as? Bool == true)
        #expect(json?["lookupOnly"] as? Bool == false)
    }

    @Test("summarize lookupOnly maps a cache miss to a not-found problem")
    func summarizeLookupOnlyMapsNotFound() async {
        let http = StubHTTPClient()
        http.enqueue(
            status: 404,
            json: """
            {"type":"https://api.example.com/problems/not_found","title":"Not found","status":404,"code":"not_found","detail":"No cached chapter summary matched this request.","traceId":"trace","retryAfterSeconds":null,"fieldErrors":[]}
            """
        )
        let client = LiveProductAIClient(http: http)
        await #expect(throws: AuthClientError.problem(
            status: 404,
            code: "not_found",
            detail: "No cached chapter summary matched this request."
        )) {
            _ = try await client.summarize(
                accessToken: "access",
                deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                request: ProductChapterSummaryRequest(
                    chapterId: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                    sourceLanguage: "en",
                    targetLanguage: "zh",
                    learnerLevel: "intermediate",
                    lookupOnly: true
                )
            )
        }
    }

    @Test("translate encodes refresh and maps quota and revoked-device failures")
    func translateEncodesRefreshAndMapsProblems() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 200,
            json: """
            {"id":"3fa85f64-5717-4562-b3fc-2c963f66afa6","translation":"你好","notes":[],"provenance":"generated","policyVersion":"qwen-managed-v1","createdAt":"2026-08-28T00:00:00Z"}
            """
        )
        http.enqueue(
            status: 429,
            json: """
            {"type":"https://api.example.com/problems/rate_limited","title":"Too many requests","status":429,"code":"rate_limited","detail":"Daily managed Qwen quota exceeded.","traceId":"trace","retryAfterSeconds":3600,"fieldErrors":[]}
            """
        )
        http.enqueue(
            status: 403,
            json: """
            {"type":"https://api.example.com/problems/device_revoked","title":"Forbidden","status":403,"code":"device_revoked","detail":"This device was revoked.","traceId":"trace","retryAfterSeconds":null,"fieldErrors":[]}
            """
        )
        http.enqueue(
            status: 401,
            json: """
            {"type":"https://api.example.com/problems/unauthorized","title":"Unauthorized","status":401,"code":"unauthorized","detail":"Session expired.","traceId":"trace","retryAfterSeconds":null,"fieldErrors":[]}
            """
        )
        let client = LiveProductAIClient(http: http)
        _ = try await client.translate(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            request: ProductTranslationRequest(
                task: "sentence",
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate",
                source: "Hello",
                refresh: true
            )
        )
        let body = try #require(http.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["refresh"] as? Bool == true)

        await #expect(throws: AuthClientError.problem(
            status: 429,
            code: "rate_limited",
            detail: "Daily managed Qwen quota exceeded."
        )) {
            _ = try await client.translate(
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
        }
        await #expect(throws: AuthClientError.deviceRevoked("This device was revoked.")) {
            _ = try await client.translate(
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
        }
        await #expect(throws: AuthClientError.unauthorized("Session expired.")) {
            _ = try await client.translate(
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
        }
    }

    @Test("translateBatch encodes refreshIds")
    func translateBatchEncodesRefreshIds() async throws {
        let http = StubHTTPClient()
        http.enqueue(
            status: 200,
            json: """
            {"results":[],"missingIds":[],"generatedCount":0,"cacheHitCount":0}
            """
        )
        let client = LiveProductAIClient(http: http)
        _ = try await client.translateBatch(
            accessToken: "access",
            deviceID: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            request: ProductTranslationBatchRequest(
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate",
                sentences: [ProductTranslationSentence(id: "s1", text: "Hello")],
                refreshIds: ["s1"]
            )
        )
        let body = try #require(http.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["refreshIds"] as? [String] == ["s1"])
        #expect(json?["task"] as? String == "chapter_batch")
    }

    @Test("fake product client generates batch and summary results")
    func fakeGeneratesBatchAndSummary() async throws {
        let client = FakeProductAIClient()
        let batch = try await client.translateBatch(
            accessToken: "access",
            deviceID: "device",
            request: ProductTranslationBatchRequest(
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate",
                sentences: [
                    ProductTranslationSentence(id: "s1", text: "Hello"),
                    ProductTranslationSentence(id: "s2", text: "World")
                ]
            )
        )
        #expect(batch.results.map(\.targetId) == ["s1", "s2"])
        #expect(batch.generatedCount == 2)
        #expect(batch.missingIds.isEmpty)
        let summary = try await client.summarize(
            accessToken: "access",
            deviceID: "device",
            request: ProductChapterSummaryRequest(
                chapterId: "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                sourceLanguage: "en",
                targetLanguage: "zh",
                learnerLevel: "intermediate"
            )
        )
        #expect(summary.overview == "A chapter about ice.")
        #expect(client.translateBatchCalls == 1)
        #expect(client.summarizeCalls == 1)
    }
}
