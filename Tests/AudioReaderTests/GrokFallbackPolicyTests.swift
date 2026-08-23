import Foundation
import Testing
@testable import AudioReader

@Suite("Grok Responses fallback policy")
struct GrokFallbackPolicyTests {
    @Test("Explicit Responses feature incompatibilities allow Chat fallback")
    func allowsExplicitResponsesCompatibilityRejections() {
        let errors: [Error] = [
            LLMError.http(400, "Unknown parameter: tools"),
            LLMError.http(400, "tool_choice is not supported by this model"),
            LLMError.http(422, "The reasoning_effort parameter is unsupported"),
            LLMError.http(404, "POST /v1/responses endpoint not found")
        ]

        for error in errors {
            #expect(ResponsesFallbackPolicy.shouldFallbackToChat(after: error))
        }
    }

    @Test("Authentication, throttling, and unrelated failures preserve the Responses error")
    func rejectsNonCompatibilityFailures() {
        let decodingError = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Malformed Responses reply")
        )
        let errors: [Error] = [
            LLMError.http(401, "tool_choice is not supported"),
            LLMError.http(429, "tools are temporarily unavailable"),
            CancellationError(),
            URLError(.notConnectedToInternet),
            decodingError,
            LLMError.empty
        ]

        for error in errors {
            #expect(!ResponsesFallbackPolicy.shouldFallbackToChat(after: error))
        }
    }

    @Test("Chat JSON mode retains its response format compatibility fallback")
    func preservesChatJSONModeFallback() {
        let error = LLMError.http(400, "response_format json_object is unsupported")

        #expect(error.rejectsStructuredOutput)
    }
}
