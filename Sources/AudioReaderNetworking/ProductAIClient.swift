import Foundation

public struct ProductTranslationRequest: Codable, Equatable, Sendable {
    public var task: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var learnerLevel: String
    public var source: String
    public var editionFingerprint: String
    public var chapterFingerprint: String
    public var promptVersion: String
    public var contextBefore: String?
    public var targetId: String?

    public init(
        task: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        source: String,
        editionFingerprint: String = "",
        chapterFingerprint: String = "",
        promptVersion: String = "qwen-managed-v1",
        contextBefore: String? = nil,
        targetId: String? = nil
    ) {
        self.task = task
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.learnerLevel = learnerLevel
        self.source = source
        self.editionFingerprint = editionFingerprint
        self.chapterFingerprint = chapterFingerprint
        self.promptVersion = promptVersion
        self.contextBefore = contextBefore
        self.targetId = targetId
    }
}

public struct ProductLearningNote: Codable, Equatable, Sendable {
    public var source: String
    public var category: String
    public var explanation: String
}

public struct ProductTranslationResult: Codable, Equatable, Sendable {
    public var id: String
    public var translation: String
    public var notes: [ProductLearningNote]
    public var provenance: String
    public var policyVersion: String
    public var createdAt: String
}

public struct ProductChapterSummaryRequest: Codable, Equatable, Sendable {
    public var chapterId: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var learnerLevel: String
    public var editionFingerprint: String
    public var chapterFingerprint: String
    public var segments: [String]

    public init(
        chapterId: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        editionFingerprint: String = "",
        chapterFingerprint: String = "",
        segments: [String] = []
    ) {
        self.chapterId = chapterId
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.learnerLevel = learnerLevel
        self.editionFingerprint = editionFingerprint
        self.chapterFingerprint = chapterFingerprint
        self.segments = segments
    }
}

public struct ProductSummaryConcept: Codable, Equatable, Sendable {
    public var name: String
    public var explanation: String
}

public struct ProductChapterSummary: Codable, Equatable, Sendable {
    public var id: String
    public var overview: String
    public var keyPoints: [String]
    public var charactersOrIdeas: [String]?
    public var keyConcepts: [ProductSummaryConcept]
    public var themes: [String]
    public var provenance: String
    public var createdAt: String
}

public struct ProductChatRequest: Codable, Equatable, Sendable {
    public var threadId: String?
    public var chapterId: String
    public var question: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var learnerLevel: String
    public var contextSegments: [String]

    public init(
        threadId: String? = nil,
        chapterId: String,
        question: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        contextSegments: [String] = []
    ) {
        self.threadId = threadId
        self.chapterId = chapterId
        self.question = question
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.learnerLevel = learnerLevel
        self.contextSegments = contextSegments
    }
}

public struct ProductChatAccepted: Codable, Equatable, Sendable {
    public var threadId: String
    public var messageId: String
    public var streamUrl: String
}

public struct ProductChatMessage: Codable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public var createdAt: String
}

public protocol ProductAIClient: Sendable {
    func translate(
        accessToken: String,
        deviceID: String,
        request: ProductTranslationRequest
    ) async throws -> ProductTranslationResult

    func summarize(
        accessToken: String,
        deviceID: String,
        request: ProductChapterSummaryRequest
    ) async throws -> ProductChapterSummary

    func chat(
        accessToken: String,
        deviceID: String,
        request: ProductChatRequest
    ) async throws -> ProductChatAccepted

    func chatMessage(
        accessToken: String,
        deviceID: String,
        streamURL: String
    ) async throws -> ProductChatMessage
}

extension ProductAIClient {
    public func complete(
        accessToken: String,
        deviceID: String,
        system: String,
        user: String,
        sourceLanguage: String = "en",
        targetLanguage: String = "zh",
        learnerLevel: String = "intermediate",
        chapterID: String = ManagedAccountCredentials.unscopedChapterID
    ) async throws -> String {
        let accepted = try await chat(
            accessToken: accessToken,
            deviceID: deviceID,
            request: ProductChatRequest(
                chapterId: productAIUUIDOrUnscoped(chapterID),
                question: user,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                learnerLevel: learnerLevel,
                contextSegments: [system]
            )
        )
        let message = try await chatMessage(
            accessToken: accessToken,
            deviceID: deviceID,
            streamURL: accepted.streamUrl
        )
        return message.text
    }

}

private func productAIUUIDOrUnscoped(_ value: String) -> String {
    let pattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
    return value.wholeMatch(of: pattern) != nil
        ? value.lowercased()
        : ManagedAccountCredentials.unscopedChapterID
}

public enum ManagedAccountCredentials: Sendable {
    public static let unscopedChapterID = "00000000-0000-4000-8000-0000000000c1"

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var accessToken: String?
        var deviceID: String?
    }

    private static let box = Box()

    public static func publish(accessToken: String?, deviceID: String?) {
        box.lock.lock()
        box.accessToken = accessToken
        box.deviceID = deviceID
        box.lock.unlock()
    }

    public static func current() -> (accessToken: String, deviceID: String)? {
        box.lock.lock()
        defer { box.lock.unlock() }
        guard let accessToken = box.accessToken, let deviceID = box.deviceID,
              !accessToken.isEmpty, !deviceID.isEmpty
        else { return nil }
        return (accessToken, deviceID)
    }
}

public struct LiveProductAIClient: ProductAIClient, Sendable {
    private let http: any HTTPPerforming
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(http: any HTTPPerforming, baseURL: URL = ProductAPI.defaultBaseURL) {
        self.http = http
        _ = baseURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .useDefaultKeys
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public init(baseURL: URL) {
        self.init(http: LiveHTTPClient(baseURL: baseURL), baseURL: baseURL)
    }

    public func translate(
        accessToken: String,
        deviceID: String,
        request: ProductTranslationRequest
    ) async throws -> ProductTranslationResult {
        try await send(
            method: "POST",
            path: "/v1/ai/translations",
            accessToken: accessToken,
            deviceID: deviceID,
            body: request
        )
    }

    public func summarize(
        accessToken: String,
        deviceID: String,
        request: ProductChapterSummaryRequest
    ) async throws -> ProductChapterSummary {
        try await send(
            method: "POST",
            path: "/v1/ai/chapter-summaries",
            accessToken: accessToken,
            deviceID: deviceID,
            body: request
        )
    }

    public func chat(
        accessToken: String,
        deviceID: String,
        request: ProductChatRequest
    ) async throws -> ProductChatAccepted {
        try await send(
            method: "POST",
            path: "/v1/ai/chat",
            accessToken: accessToken,
            deviceID: deviceID,
            body: request
        )
    }

    public func chatMessage(
        accessToken: String,
        deviceID: String,
        streamURL: String
    ) async throws -> ProductChatMessage {
        try await send(
            method: "GET",
            path: streamURL,
            accessToken: accessToken,
            deviceID: deviceID
        )
    }

    private func send<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        accessToken: String,
        deviceID: String,
        body: Body
    ) async throws -> Response {
        try await send(
            method: method,
            path: path,
            accessToken: accessToken,
            deviceID: deviceID,
            data: try encoder.encode(body)
        )
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        accessToken: String,
        deviceID: String,
        data: Data? = nil
    ) async throws -> Response {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "X-Device-Id": deviceID,
            "Accept": "application/json",
            "Idempotency-Key": UUID().uuidString.lowercased()
        ]
        if data != nil {
            headers["Content-Type"] = "application/json"
        }
        let response = try await http.send(
            HTTPRequest(method: method, path: path, headers: headers, body: data)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw mapProblem(status: response.statusCode, body: response.body)
        }
        do {
            return try decoder.decode(Response.self, from: response.body)
        } catch {
            throw AuthClientError.invalidResponse
        }
    }

    private func mapProblem(status: Int, body: Data) -> AuthClientError {
        let problem = try? decoder.decode(APIProblem.self, from: body)
        let detail = problem?.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? problem?.title
            ?? "Managed Qwen request failed (\(status))."
        let code = problem?.code ?? "error"
        if status == 401 {
            return .unauthorized(detail)
        }
        if code == "device_revoked" {
            return .deviceRevoked(detail)
        }
        return .problem(status: status, code: code, detail: detail)
    }
}

public final class FakeProductAIClient: ProductAIClient, @unchecked Sendable {
    public var translation = ProductTranslationResult(
        id: "00000000-0000-4000-8000-0000000000d1",
        translation: "你好",
        notes: [],
        provenance: "generated",
        policyVersion: "qwen-managed-v1",
        createdAt: "2026-08-28T00:00:00Z"
    )
    public var summary = ProductChapterSummary(
        id: "00000000-0000-4000-8000-0000000000d2",
        overview: "A chapter about ice.",
        keyPoints: ["Ice"],
        charactersOrIdeas: ["the ice"],
        keyConcepts: [ProductSummaryConcept(name: "metaphor", explanation: "ice as isolation")],
        themes: ["isolation"],
        provenance: "generated",
        createdAt: "2026-08-28T00:00:00Z"
    )
    public var reply = "Managed Qwen reply"
    public private(set) var translateCalls = 0
    public private(set) var chatCalls = 0
    private let lock = NSLock()
    private var messages: [String: ProductChatMessage] = [:]

    public init() {}

    public func translate(
        accessToken: String,
        deviceID: String,
        request: ProductTranslationRequest
    ) async throws -> ProductTranslationResult {
        _ = accessToken
        _ = deviceID
        _ = request
        return withLock {
            translateCalls += 1
            return translation
        }
    }

    public func summarize(
        accessToken: String,
        deviceID: String,
        request: ProductChapterSummaryRequest
    ) async throws -> ProductChapterSummary {
        _ = accessToken
        _ = deviceID
        _ = request
        return summary
    }

    public func chat(
        accessToken: String,
        deviceID: String,
        request: ProductChatRequest
    ) async throws -> ProductChatAccepted {
        _ = accessToken
        _ = deviceID
        _ = request
        return withLock {
            chatCalls += 1
            let threadId = request.threadId ?? UUID().uuidString.lowercased()
            let messageId = UUID().uuidString.lowercased()
            messages[messageId] = ProductChatMessage(
                id: messageId,
                role: "assistant",
                text: reply,
                createdAt: "2026-08-28T00:00:00Z"
            )
            return ProductChatAccepted(
                threadId: threadId,
                messageId: messageId,
                streamUrl: "/v1/ai/chat/\(threadId)/messages/\(messageId)"
            )
        }
    }

    public func chatMessage(
        accessToken: String,
        deviceID: String,
        streamURL: String
    ) async throws -> ProductChatMessage {
        _ = accessToken
        _ = deviceID
        return try withLock {
            if let message = messages.values.first(where: { streamURL.contains($0.id) }) {
                return message
            }
            throw AuthClientError.invalidResponse
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
