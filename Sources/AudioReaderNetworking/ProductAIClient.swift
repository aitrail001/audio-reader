import CryptoKit
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
    public var contextPrevious: [String]
    public var contextNext: [String]
    public var targetId: String?
    public var bookTitle: String
    public var author: String
    public var chapterTitle: String
    public var lookupOnly: Bool
    public var refresh: Bool
    public var assistantResultId: String?

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
        contextPrevious: [String] = [],
        contextNext: [String] = [],
        targetId: String? = nil,
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        lookupOnly: Bool = false,
        refresh: Bool = false,
        assistantResultId: String? = nil
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
        self.contextPrevious = contextPrevious
        self.contextNext = contextNext
        self.targetId = targetId
        self.bookTitle = bookTitle
        self.author = author
        self.chapterTitle = chapterTitle
        self.lookupOnly = lookupOnly
        self.refresh = refresh
        self.assistantResultId = assistantResultId
    }
}

public struct ProductTranslationSentence: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var assistantResultId: String?

    public init(id: String, text: String, assistantResultId: String? = nil) {
        self.id = id
        self.text = text
        self.assistantResultId = assistantResultId
    }
}

public struct ProductTranslationBatchRequest: Codable, Equatable, Sendable {
    public var task: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var learnerLevel: String
    public var sentences: [ProductTranslationSentence]
    public var editionFingerprint: String
    public var chapterFingerprint: String
    public var promptVersion: String
    public var contextBefore: String?
    public var contextPrevious: [String]
    public var contextNext: [String]
    public var bookTitle: String
    public var author: String
    public var chapterTitle: String
    public var lookupOnly: Bool
    public var refreshIds: [String]

    public init(
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        sentences: [ProductTranslationSentence],
        editionFingerprint: String = "",
        chapterFingerprint: String = "",
        promptVersion: String = "qwen-managed-v1",
        contextBefore: String? = nil,
        contextPrevious: [String] = [],
        contextNext: [String] = [],
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        lookupOnly: Bool = false,
        refreshIds: [String] = []
    ) {
        self.task = "chapter_batch"
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.learnerLevel = learnerLevel
        self.sentences = sentences
        self.editionFingerprint = editionFingerprint
        self.chapterFingerprint = chapterFingerprint
        self.promptVersion = promptVersion
        self.contextBefore = contextBefore
        self.contextPrevious = contextPrevious
        self.contextNext = contextNext
        self.bookTitle = bookTitle
        self.author = author
        self.chapterTitle = chapterTitle
        self.lookupOnly = lookupOnly
        self.refreshIds = refreshIds
    }
}

public struct ProductLearningNote: Codable, Equatable, Sendable {
    public var source: String
    public var category: String
    public var explanation: String

    public init(source: String, category: String, explanation: String) {
        self.source = source
        self.category = category
        self.explanation = explanation
    }
}

public struct ProductTranslationResult: Codable, Equatable, Sendable {
    public var id: String
    public var sharedCacheEntryID: String?
    public var targetId: String?
    public var source: String?
    public var translation: String
    public var notes: [ProductLearningNote]
    public var provenance: String
    public var policyVersion: String
    public var model: String?
    public var promptVersion: String?
    public var modelPolicyHash: String?
    public var createdAt: String

    public init(
        id: String,
        sharedCacheEntryID: String? = nil,
        translation: String,
        notes: [ProductLearningNote],
        provenance: String,
        policyVersion: String,
        model: String? = nil,
        promptVersion: String? = nil,
        modelPolicyHash: String? = nil,
        createdAt: String,
        targetId: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.sharedCacheEntryID = sharedCacheEntryID
        self.targetId = targetId
        self.source = source
        self.translation = translation
        self.notes = notes
        self.provenance = provenance
        self.policyVersion = policyVersion
        self.model = model
        self.promptVersion = promptVersion
        self.modelPolicyHash = modelPolicyHash
        self.createdAt = createdAt
    }
}

public struct ProductTranslationBatchResult: Codable, Equatable, Sendable {
    public var results: [ProductTranslationResult]
    public var missingIds: [String]
    public var generatedCount: Int?
    public var cacheHitCount: Int?

    public init(
        results: [ProductTranslationResult],
        missingIds: [String] = [],
        generatedCount: Int? = nil,
        cacheHitCount: Int? = nil
    ) {
        self.results = results
        self.missingIds = missingIds
        self.generatedCount = generatedCount
        self.cacheHitCount = cacheHitCount
    }
}

public struct ProductChapterSummaryRequest: Codable, Equatable, Sendable {
    public var chapterId: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var learnerLevel: String
    public var editionFingerprint: String
    public var chapterFingerprint: String
    public var bookTitle: String
    public var author: String
    public var chapterTitle: String
    public var segments: [String]
    public var lookupOnly: Bool
    public var refresh: Bool
    public var assistantResultId: String?

    public init(
        chapterId: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        editionFingerprint: String = "",
        chapterFingerprint: String = "",
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        segments: [String] = [],
        lookupOnly: Bool = false,
        refresh: Bool = false,
        assistantResultId: String? = nil
    ) {
        self.chapterId = chapterId
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.learnerLevel = learnerLevel
        self.editionFingerprint = editionFingerprint
        self.chapterFingerprint = chapterFingerprint
        self.bookTitle = bookTitle
        self.author = author
        self.chapterTitle = chapterTitle
        self.segments = segments
        self.lookupOnly = lookupOnly
        self.refresh = refresh
        self.assistantResultId = assistantResultId
    }
}

public struct ProductSummaryConcept: Codable, Equatable, Sendable {
    public var name: String
    public var explanation: String
}

public struct ProductChapterSummary: Codable, Equatable, Sendable {
    public var id: String
    public var sharedCacheEntryID: String?
    public var overview: String
    public var keyPoints: [String]
    public var charactersOrIdeas: [String]?
    public var keyConcepts: [ProductSummaryConcept]
    public var themes: [String]
    public var provenance: String
    public var model: String?
    public var promptVersion: String?
    public var modelPolicyHash: String?
    public var policyVersion: String?
    public var createdAt: String
}

public struct ProductHeardSegment: Codable, Equatable, Sendable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct ProductHeardQuizRequest: Codable, Equatable, Sendable {
    public var task: String
    public var chapterId: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var learnerLevel: String
    public var bookTitle: String
    public var author: String
    public var chapterTitle: String
    public var segments: [ProductHeardSegment]

    public init(
        chapterId: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        segments: [ProductHeardSegment]
    ) {
        self.task = "heard_quiz"
        self.chapterId = chapterId
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.learnerLevel = learnerLevel
        self.bookTitle = bookTitle
        self.author = author
        self.chapterTitle = chapterTitle
        self.segments = segments
    }
}

public struct ProductHeardQuizResponse: Codable, Equatable, Sendable {
    public var raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

public struct ProductChatRequest: Codable, Equatable, Sendable {
    public var threadId: String?
    public var chapterId: String
    public var question: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var learnerLevel: String
    public var bookTitle: String
    public var author: String
    public var chapterTitle: String
    public var contextSegments: [String]

    public init(
        threadId: String? = nil,
        chapterId: String,
        question: String,
        sourceLanguage: String,
        targetLanguage: String,
        learnerLevel: String,
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = "",
        contextSegments: [String] = []
    ) {
        self.threadId = threadId
        self.chapterId = chapterId
        self.question = question
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.learnerLevel = learnerLevel
        self.bookTitle = bookTitle
        self.author = author
        self.chapterTitle = chapterTitle
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

public struct ProductAICompletion: Equatable, Sendable {
    public let text: String
    public let traceID: String

    public init(text: String, traceID: String) {
        self.text = text
        self.traceID = traceID
    }
}

public protocol ProductAIClient: Sendable {
    func translate(
        accessToken: String,
        deviceID: String,
        request: ProductTranslationRequest
    ) async throws -> ProductTranslationResult

    func translateBatch(
        accessToken: String,
        deviceID: String,
        request: ProductTranslationBatchRequest
    ) async throws -> ProductTranslationBatchResult

    func summarize(
        accessToken: String,
        deviceID: String,
        request: ProductChapterSummaryRequest
    ) async throws -> ProductChapterSummary

    func heardQuiz(
        accessToken: String,
        deviceID: String,
        request: ProductHeardQuizRequest
    ) async throws -> ProductHeardQuizResponse

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
    /// Chat-only fallback. Translations and summaries must use `translate` / `summarize`
    /// so the Worker can write `assistant_cache_entries`.
    public func complete(
        accessToken: String,
        deviceID: String,
        system: String,
        user: String,
        sourceLanguage: String = "en",
        targetLanguage: String = "zh",
        learnerLevel: String = "intermediate",
        chapterID: String = ManagedAccountCredentials.unscopedChapterID,
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = ""
    ) async throws -> String {
        try await completeWithTrace(
            accessToken: accessToken,
            deviceID: deviceID,
            system: system,
            user: user,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            learnerLevel: learnerLevel,
            chapterID: chapterID,
            bookTitle: bookTitle,
            author: author,
            chapterTitle: chapterTitle
        ).text
    }

    /// Returns the provider-owned message identifier alongside its text so
    /// downstream provenance never depends on model-authored content.
    public func completeWithTrace(
        accessToken: String,
        deviceID: String,
        system: String,
        user: String,
        sourceLanguage: String = "en",
        targetLanguage: String = "zh",
        learnerLevel: String = "intermediate",
        chapterID: String = ManagedAccountCredentials.unscopedChapterID,
        bookTitle: String = "",
        author: String = "",
        chapterTitle: String = ""
    ) async throws -> ProductAICompletion {
        let accepted = try await chat(
            accessToken: accessToken,
            deviceID: deviceID,
            request: ProductChatRequest(
                chapterId: productAIUUIDOrUnscoped(chapterID),
                question: user,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                learnerLevel: learnerLevel,
                bookTitle: bookTitle,
                author: author,
                chapterTitle: chapterTitle,
                contextSegments: [system]
            )
        )
        let message = try await chatMessage(
            accessToken: accessToken,
            deviceID: deviceID,
            streamURL: accepted.streamUrl
        )
        guard message.id == accepted.messageId else { throw AuthClientError.invalidResponse }
        return ProductAICompletion(text: message.text, traceID: message.id)
    }

}

private func productAIUUIDOrUnscoped(_ value: String) -> String {
    let pattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
    if value.wholeMatch(of: pattern) != nil {
        return value.lowercased()
    }
    let digest = SHA256.hash(data: Data("chapter:\(value)".utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let start = hex.startIndex
    func slice(_ offset: Int, _ count: Int) -> String {
        let from = hex.index(start, offsetBy: offset)
        let to = hex.index(from, offsetBy: count)
        return String(hex[from..<to])
    }
    return "\(slice(0, 8))-\(slice(8, 4))-\(slice(12, 4))-\(slice(16, 4))-\(slice(20, 12))"
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

    public func translateBatch(
        accessToken: String,
        deviceID: String,
        request: ProductTranslationBatchRequest
    ) async throws -> ProductTranslationBatchResult {
        try await send(
            method: "POST",
            path: "/v1/ai/translation-batches",
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

    public func heardQuiz(
        accessToken: String,
        deviceID: String,
        request: ProductHeardQuizRequest
    ) async throws -> ProductHeardQuizResponse {
        try await send(
            method: "POST",
            path: "/v1/ai/heard-quizzes",
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
    public var heardQuizRaw = #"{"questions":[]}"#
    public private(set) var translateCalls = 0
    public private(set) var translateBatchCalls = 0
    public private(set) var summarizeCalls = 0
    public private(set) var chatCalls = 0
    public private(set) var heardQuizCalls = 0
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
        if request.lookupOnly {
            throw AuthClientError.problem(
                status: 404,
                code: "not_found",
                detail: "No cached translation matched this request."
            )
        }
        return withLock {
            translateCalls += 1
            return translation
        }
    }

    public func translateBatch(
        accessToken: String,
        deviceID: String,
        request: ProductTranslationBatchRequest
    ) async throws -> ProductTranslationBatchResult {
        _ = accessToken
        _ = deviceID
        return withLock {
            translateBatchCalls += 1
            if request.lookupOnly {
                return ProductTranslationBatchResult(results: [], missingIds: request.sentences.map(\.id), generatedCount: 0, cacheHitCount: 0)
            }
            let results = request.sentences.map { sentence in
                ProductTranslationResult(
                    id: translation.id,
                    translation: translation.translation,
                    notes: translation.notes,
                    provenance: translation.provenance,
                    policyVersion: translation.policyVersion,
                    createdAt: translation.createdAt,
                    targetId: sentence.id,
                    source: sentence.text
                )
            }
            return ProductTranslationBatchResult(
                results: results,
                missingIds: [],
                generatedCount: results.count,
                cacheHitCount: 0
            )
        }
    }

    public func summarize(
        accessToken: String,
        deviceID: String,
        request: ProductChapterSummaryRequest
    ) async throws -> ProductChapterSummary {
        _ = accessToken
        _ = deviceID
        if request.lookupOnly {
            throw AuthClientError.problem(
                status: 404,
                code: "not_found",
                detail: "No cached chapter summary matched this request."
            )
        }
        return withLock {
            summarizeCalls += 1
            return summary
        }
    }

    public func heardQuiz(
        accessToken: String,
        deviceID: String,
        request: ProductHeardQuizRequest
    ) async throws -> ProductHeardQuizResponse {
        _ = accessToken
        _ = deviceID
        _ = request
        return withLock {
            heardQuizCalls += 1
            return ProductHeardQuizResponse(raw: heardQuizRaw)
        }
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
