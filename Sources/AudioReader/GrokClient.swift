import Foundation

enum LLMError: LocalizedError {
    case noAPIKey(LLMProvider)
    case grokBuildNotLoggedIn
    case codexUnavailable
    case codexNotLoggedIn
    case codexFailed(String)
    case invalidEndpoint(String)
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let provider):
            "No \(provider.apiLabel) API key. Add \(provider.environmentKey) in Settings or configure it in the environment."
        case .grokBuildNotLoggedIn:
            "Grok Build is not signed in. Run `grok login`, or choose API key in Settings."
        case .codexUnavailable:
            "Codex CLI was not found. Install Codex or set AUDIOREADER_CODEX_PATH, then sign in with ChatGPT."
        case .codexNotLoggedIn:
            "Codex is not signed in with ChatGPT. Run `codex login`, then try again."
        case .codexFailed(let message):
            "Codex request failed: \(message)"
        case .invalidEndpoint(let endpoint):
            "Invalid LLM endpoint: \(endpoint)"
        case .http(let code, let body):
            "LLM request failed (\(code)): \(body)"
        case .empty:
            "The LLM returned an empty reply."
        }
    }

    var rejectsStructuredOutput: Bool {
        guard case .http(_, let body) = self else { return false }
        let message = body.lowercased()
        let namesJSONMode = message.contains("response_format") || message.contains("json_object")
        let rejectsParameter = message.contains("unsupported")
            || message.contains("unknown")
            || message.contains("invalid")
            || message.contains("not support")
        return namesJSONMode && rejectsParameter
    }
}

enum ResponsesFallbackPolicy {
    static func shouldFallbackToChat(after error: Error) -> Bool {
        guard let llmError = error as? LLMError,
              case .http(let status, let body) = llmError,
              [400, 404, 405, 422].contains(status)
        else { return false }

        let message = body.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        let namesResponsesFeature = message.contains("tool choice")
            || message.contains("\"tools\"")
            || message.contains("'tools'")
            || message.contains("parameter: tools")
            || message.contains("parameter tools")
            || message.contains("tools parameter")
            || message.contains("tools are")
            || message.contains("function calling")
            || message.contains("reasoning effort")
            || message.contains("/responses")
            || message.contains("responses endpoint")
            || message.contains("responses api")
        let rejectsFeature = message.contains("unsupported")
            || message.contains("not supported")
            || message.contains("does not support")
            || message.contains("unknown")
            || message.contains("unrecognized")
            || message.contains("invalid")
            || message.contains("not allowed")
            || message.contains("not found")
            || message.contains("not implemented")
        return namesResponsesFeature && rejectsFeature
    }
}

enum LLMProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case grok
    case qwenCloud
    case openAI

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .grok: "Grok (xAI)"
        case .qwenCloud: "QwenCloud"
        case .openAI: "OpenAI / ChatGPT"
        }
    }

    var environmentKey: String {
        switch self {
        case .grok: "XAI_API_KEY"
        case .qwenCloud: "DASHSCOPE_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        }
    }

    var apiLabel: String {
        switch self {
        case .grok: "xAI"
        case .qwenCloud: "QwenCloud"
        case .openAI: "OpenAI"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .grok: "https://api.x.ai/v1"
        case .qwenCloud: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
        case .openAI: "https://api.openai.com/v1"
        }
    }
}

enum APIKeyStore {
    static var fileURL: URL { Persistence.root.appendingPathComponent("xai-api-key") }

    @discardableResult
    static func migrateLegacyCredential() -> [LegacyCredentialMigrationResult] {
        ProviderAPIKeyStore.migrateLegacyCredentials(fileURL: fileURL, for: .grok)
    }

    static func load() -> String? {
        return ProviderAPIKeyStore.load(.grok)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let saved = ProviderAPIKeyStore.save(key, for: .grok)
        if saved, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return saved
    }

    @discardableResult
    static func clear() -> Bool {
        ProviderAPIKeyStore.clear(.grok)
    }

    static var hasSavedKey: Bool {
        return ProviderAPIKeyStore.hasSavedKey(.grok)
    }
    static var isConfigured: Bool {
        return ProviderAPIKeyStore.isConfigured(.grok)
    }
    static var sourceLabel: String {
        return ProviderAPIKeyStore.sourceLabel(.grok)
    }
}

enum GrokBuildCredentialProvider {
    static var authURL: URL {
#if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
#else
        Persistence.root.appendingPathComponent("grok-auth-unavailable")
#endif
    }

    /// OAuth access token managed by `grok login` / Grok Build. Not an API-console key.
    static func load() -> String? {
#if os(macOS)
        guard let data = try? Data(contentsOf: authURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for value in obj.values {
            guard let rec = value as? [String: Any],
                  let key = rec["key"] as? String,
                  !key.isEmpty
            else { continue }
            return key
        }
        return nil
#else
        return nil
#endif
    }

    static var sourceLabel: String {
        load() == nil ? "Grok Build sign-in not found" : "Grok Build sign-in found"
    }
}

enum QwenAPIKeyStore {
    static var fileURL: URL { Persistence.root.appendingPathComponent("dashscope-api-key") }

    @discardableResult
    static func migrateLegacyCredential() -> [LegacyCredentialMigrationResult] {
        ProviderAPIKeyStore.migrateLegacyCredentials(fileURL: fileURL, for: .qwenCloud)
    }

    static func load() -> String? {
        return ProviderAPIKeyStore.load(.qwenCloud)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let saved = ProviderAPIKeyStore.save(key, for: .qwenCloud)
        if saved, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return saved
    }

    @discardableResult static func clear() -> Bool { ProviderAPIKeyStore.clear(.qwenCloud) }
    static var hasSavedKey: Bool {
        return ProviderAPIKeyStore.hasSavedKey(.qwenCloud)
    }
    static var isConfigured: Bool {
        return ProviderAPIKeyStore.isConfigured(.qwenCloud)
    }
    static var sourceLabel: String {
        return ProviderAPIKeyStore.sourceLabel(.qwenCloud)
    }
}

enum OpenAIAPIKeyStore {
    static var fileURL: URL { Persistence.root.appendingPathComponent("openai-api-key") }

    @discardableResult
    static func migrateLegacyCredential() -> [LegacyCredentialMigrationResult] {
        ProviderAPIKeyStore.migrateLegacyCredentials(fileURL: fileURL, for: .openAI)
    }

    static func load() -> String? {
        return ProviderAPIKeyStore.load(.openAI)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let saved = ProviderAPIKeyStore.save(key, for: .openAI)
        if saved, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return saved
    }

    @discardableResult static func clear() -> Bool { ProviderAPIKeyStore.clear(.openAI) }
    static var hasSavedKey: Bool {
        return ProviderAPIKeyStore.hasSavedKey(.openAI)
    }
    static var isConfigured: Bool {
        return ProviderAPIKeyStore.isConfigured(.openAI)
    }
    static var sourceLabel: String {
        return ProviderAPIKeyStore.sourceLabel(.openAI)
    }
}

enum GrokEffort: String, CaseIterable, Identifiable {
    case none, low, medium, high, xhigh

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .none: "None — no reasoning"
        case .low: "Low — fast"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "xHigh — slowest"
        }
    }
}

enum OpenAIAuthentication: String, CaseIterable, Identifiable, Codable, Sendable {
    case chatGPT
    case apiKey

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .chatGPT: "ChatGPT plan"
        case .apiKey: "API key"
        }
    }
}

enum GrokAuthentication: String, CaseIterable, Identifiable, Codable, Sendable {
    case grokBuild
    case apiKey

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .grokBuild: "Grok Build"
        case .apiKey: "API key"
        }
    }
}

enum LLMConnectionChoice: String, CaseIterable, Identifiable, Sendable {
    case grokBuild
    case grokAPIKey
    case qwenAPIKey
    case chatGPTPlan
    case openAIAPIKey

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .grokBuild: "xAI · Grok Build (OAuth)"
        case .grokAPIKey: "xAI · API key"
        case .qwenAPIKey: "Qwen · API key"
        case .chatGPTPlan: "OpenAI · ChatGPT plan (OAuth)"
        case .openAIAPIKey: "OpenAI · API key"
        }
    }

    var compactLabel: String {
        switch self {
        case .grokBuild: "xAI OAuth"
        case .grokAPIKey: "xAI API"
        case .qwenAPIKey: "Qwen API"
        case .chatGPTPlan: "ChatGPT OAuth"
        case .openAIAPIKey: "OpenAI API"
        }
    }

    static var availableOnCurrentPlatform: [Self] {
#if os(macOS)
        allCases
#else
        [.grokAPIKey, .qwenAPIKey, .openAIAPIKey]
#endif
    }

    static func selected(in settings: AppSettings) -> Self {
        switch LLMProvider(rawValue: settings.llmProvider) ?? .grok {
        case .grok:
            GrokAuthentication(rawValue: settings.grokAuthentication) == .apiKey
                ? .grokAPIKey
                : .grokBuild
        case .qwenCloud:
            .qwenAPIKey
        case .openAI:
            OpenAIAuthentication(rawValue: settings.openAIAuthentication) == .apiKey
                ? .openAIAPIKey
                : .chatGPTPlan
        }
    }

    func apply(to settings: inout AppSettings) {
        switch self {
        case .grokBuild:
            settings.llmProvider = LLMProvider.grok.rawValue
            settings.grokAuthentication = GrokAuthentication.grokBuild.rawValue
        case .grokAPIKey:
            settings.llmProvider = LLMProvider.grok.rawValue
            settings.grokAuthentication = GrokAuthentication.apiKey.rawValue
        case .qwenAPIKey:
            settings.llmProvider = LLMProvider.qwenCloud.rawValue
        case .chatGPTPlan:
            settings.llmProvider = LLMProvider.openAI.rawValue
            settings.openAIAuthentication = OpenAIAuthentication.chatGPT.rawValue
        case .openAIAPIKey:
            settings.llmProvider = LLMProvider.openAI.rawValue
            settings.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue
        }
    }
}

enum OpenAIModel: String, CaseIterable, Identifiable {
    case gpt56Sol = "gpt-5.6-sol"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Luna = "gpt-5.6-luna"

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .gpt56Sol: "GPT-5.6 Sol — highest capability"
        case .gpt56Terra: "GPT-5.6 Terra — balanced"
        case .gpt56Luna: "GPT-5.6 Luna — efficient"
        }
    }
}

enum OpenAIEffort: String, CaseIterable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .none: "None — fastest"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "xHigh"
        case .max: "Maximum"
        }
    }
}

enum QwenEffort: String, CaseIterable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .none: "None — fastest"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "xHigh"
        case .max: "Maximum"
        }
    }
}

enum LLMAPIStyle: Equatable {
    case responses
    case chat
}

enum QwenRequestPolicy {
    static func supportedEfforts(model: String) -> [QwenEffort] {
        let id = model.lowercased()
        guard id.hasPrefix("qwen") || id.hasPrefix("deepseek") || id.hasPrefix("glm") else { return [] }
        return isThinkingOnly(model: id)
            ? QwenEffort.allCases.filter { $0 != .none }
            : QwenEffort.allCases
    }

    static func effort(
        model: String,
        requested: String,
        thinking: Bool,
        api: LLMAPIStyle
    ) -> String? {
        let id = model.lowercased()
        let responsesEfforts = Set(QwenEffort.allCases.map(\.rawValue))
        if api == .responses,
           id.hasPrefix("qwen") || id.hasPrefix("deepseek") || id.hasPrefix("glm") {
            if id.hasPrefix("qwen"), !thinking, !isThinkingOnly(model: id) { return "none" }
            if isThinkingOnly(model: id), requested == QwenEffort.none.rawValue {
                return QwenEffort.minimal.rawValue
            }
            return responsesEfforts.contains(requested) ? requested : "xhigh"
        }
        guard api == .chat else { return nil }
        if id.hasPrefix("deepseek-v4-flash-0731") || id.hasPrefix("deepseek-v4-pro-0813") {
            switch requested {
            case "minimal", "low": return "low"
            case "max": return "max"
            case "medium", "high", "xhigh": return "high"
            default: return nil
            }
        }
        if id.hasPrefix("deepseek") || id.hasPrefix("glm") {
            switch requested {
            case "xhigh", "max": return "max"
            case "minimal", "low", "medium", "high": return "high"
            default: return nil
            }
        }
        return nil
    }

    static func supportsThinkingToggle(model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("qwen") && !isThinkingOnly(model: id)
    }

    private static func isThinkingOnly(model: String) -> Bool {
        model.contains("-thinking")
            || model == "qwen3.7-max-preview"
            || model == "qwen3.7-max-2026-05-17"
    }
}

struct LLMModelInfo: Identifiable, Hashable, Sendable {
    var id: String
    var brand: String
    var capabilities: String
    var supportsText: Bool

    var menuLabel: String { "\(id) — \(brand)" }
}

enum GrokModelCatalog {
    static let fallback: [LLMModelInfo] = [
        .init(id: "grok-4.6", brand: "xAI", capabilities: "Current flagship reasoning model", supportsText: true),
        .init(id: "grok-4.5", brand: "xAI", capabilities: "Reasoning model", supportsText: true),
        .init(id: "grok-4.3", brand: "xAI", capabilities: "Reasoning model", supportsText: true),
        .init(id: "grok-4.20", brand: "xAI", capabilities: "Reasoning model", supportsText: true),
        .init(id: "grok-4.20-non-reasoning", brand: "xAI", capabilities: "Fast non-reasoning model", supportsText: true),
        .init(id: "grok-4.20-multi-agent", brand: "xAI", capabilities: "Multi-agent reasoning model", supportsText: true),
        .init(id: "grok-build-0.1", brand: "Grok Build", capabilities: "Grok Build managed model", supportsText: true)
    ]

    static func discovered(_ modelIDs: [String]) -> [LLMModelInfo] {
        discoveredModels(modelIDs, fallback: fallback, brand: "xAI") { id in
            id.lowercased().hasPrefix("grok-") && !isMediaOnlyModel(id)
        }
    }
}

enum OpenAIModelCatalog {
    static let fallback: [LLMModelInfo] = [
        .init(id: "gpt-5.6-luna", brand: "OpenAI", capabilities: "Efficient reasoning model", supportsText: true),
        .init(id: "gpt-5.6-terra", brand: "OpenAI", capabilities: "Balanced reasoning model", supportsText: true),
        .init(id: "gpt-5.6-sol", brand: "OpenAI", capabilities: "Highest-capability reasoning model", supportsText: true),
        .init(id: "gpt-5.5", brand: "OpenAI", capabilities: "Reasoning model", supportsText: true),
        .init(id: "gpt-5.5-pro", brand: "OpenAI", capabilities: "High-compute reasoning model", supportsText: true),
        .init(id: "gpt-5.4", brand: "OpenAI", capabilities: "Reasoning model", supportsText: true),
        .init(id: "gpt-5.4-mini", brand: "OpenAI", capabilities: "Efficient reasoning model", supportsText: true),
        .init(id: "gpt-5.4-nano", brand: "OpenAI", capabilities: "Fast compact reasoning model", supportsText: true),
        .init(id: "gpt-5.4-pro", brand: "OpenAI", capabilities: "High-compute reasoning model", supportsText: true)
    ]

    static func discovered(_ modelIDs: [String]) -> [LLMModelInfo] {
        discoveredModels(modelIDs, fallback: fallback, brand: "OpenAI") { id in
            let lower = id.lowercased()
            return (lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4"))
                && !isMediaOnlyModel(id)
        }
    }
}

private func discoveredModels(
    _ modelIDs: [String],
    fallback: [LLMModelInfo],
    brand: String,
    include: (String) -> Bool
) -> [LLMModelInfo] {
    let fallbackByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
    return Set(modelIDs.filter(include)).map { id in
        fallbackByID[id] ?? .init(
            id: id,
            brand: brand,
            capabilities: "Discovered from the provider API",
            supportsText: true
        )
    }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
}

private func isMediaOnlyModel(_ id: String) -> Bool {
    let markers = ["image", "audio", "voice", "realtime", "transcribe", "tts", "embedding", "moderation"]
    return markers.contains { id.localizedCaseInsensitiveContains($0) }
}

enum GrokRequestPolicy {
    static func supportedEfforts(model: String) -> [GrokEffort] {
        let id = model.lowercased()
        if id.contains("grok-4.20-multi-agent") {
            return [.low, .medium, .high, .xhigh]
        }
        if id.contains("grok-4.6") { return [.low, .medium, .high, .xhigh] }
        if id.contains("grok-4.5") { return [.low, .medium, .high] }
        if id.contains("grok-4.3") { return [.none, .low, .medium, .high] }
        return []
    }

    static func effort(model: String, requested: String) -> String? {
        let supported = supportedEfforts(model: model)
        guard !supported.isEmpty else { return nil }
        if let requested = GrokEffort(rawValue: requested), supported.contains(requested) {
            return requested.rawValue
        }
        return supported.contains(.medium) ? GrokEffort.medium.rawValue : supported[0].rawValue
    }
}

enum OpenAIRequestPolicy {
    static func supportedAPIEfforts(model: String) -> [OpenAIEffort] {
        let id = model.lowercased()
        guard id.hasPrefix("gpt-5.4") || id.hasPrefix("gpt-5.5") || id.hasPrefix("gpt-5.6") else {
            return []
        }
        if id.contains("-pro") { return [.high] }
        return [.none, .minimal, .low, .medium, .high, .xhigh]
    }

    static func apiEffort(model: String, requested: String) -> String? {
        let supported = supportedAPIEfforts(model: model)
        guard !supported.isEmpty else { return nil }
        if let requested = OpenAIEffort(rawValue: requested), supported.contains(requested) {
            return requested.rawValue
        }
        return supported.contains(.medium) ? OpenAIEffort.medium.rawValue : supported[0].rawValue
    }
}

enum LLMModelDiscovery {
    static func request(provider: LLMProvider, baseURL: String, apiKey: String) throws -> URLRequest {
        let path = "models"
        let endpoint = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path
        guard let url = URL(string: endpoint), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw LLMError.invalidEndpoint(baseURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    static func decodeModelIDs(_ data: Data, provider: LLMProvider) throws -> [String] {
        try JSONDecoder().decode(OpenAIModelListResponse.self, from: data).data.map(\.id)
    }

    private struct OpenAIModelListResponse: Decodable {
        struct Model: Decodable { var id: String }
        var data: [Model]
    }
}

enum QwenModelCatalog {
    static let fallback: [LLMModelInfo] = [
        .init(id: "qwen3.8-max", brand: "Qwen", capabilities: "Text Generation, Reasoning Model, Visual Understanding", supportsText: true),
        .init(id: "qwen3.7-plus", brand: "Qwen", capabilities: "Text Generation, Reasoning Model, Visual Understanding", supportsText: true),
        .init(id: "qwen3.7-max", brand: "Qwen", capabilities: "Text Generation, Reasoning Model", supportsText: true),
        .init(id: "qwen3.7-flash", brand: "Qwen", capabilities: "Text Generation, Reasoning Model", supportsText: true),
        .init(id: "qwen3.6-flash", brand: "Qwen", capabilities: "Text Generation, Reasoning Model, Visual Understanding", supportsText: true),
        .init(id: "qwen-image-3.0-pro", brand: "Qwen", capabilities: "Image Generation", supportsText: false),
        .init(id: "qwen-audio-3.0-asr-flash", brand: "Qwen", capabilities: "Speech Recognition", supportsText: false),
        .init(id: "qwen-audio-3.0-tts-plus", brand: "Qwen", capabilities: "Real-Time Speech Synthesis, Text-to-Speech", supportsText: false),
        .init(id: "qwen-audio-3.0-realtime-plus", brand: "Qwen", capabilities: "Realtime-Chatting", supportsText: false),
        .init(id: "wan2.7-image", brand: "Wan", capabilities: "Image Generation", supportsText: false),
        .init(id: "wan2.7-image-pro", brand: "Wan", capabilities: "Image Generation", supportsText: false),
        .init(id: "happyhorse-1.1-i2v", brand: "HappyHorse", capabilities: "Video Generation", supportsText: false),
        .init(id: "happyhorse-1.1-t2v", brand: "HappyHorse", capabilities: "Video Generation", supportsText: false),
        .init(id: "happyhorse-1.1-r2v", brand: "HappyHorse", capabilities: "Video Generation", supportsText: false),
        .init(id: "deepseek-v4-pro-0813", brand: "DeepSeek", capabilities: "Text Generation, Reasoning Model", supportsText: true),
        .init(id: "deepseek-v4-pro", brand: "DeepSeek", capabilities: "Text Generation, Reasoning Model", supportsText: true),
        .init(id: "deepseek-v4-flash-0731", brand: "DeepSeek", capabilities: "Text Generation, Reasoning Model", supportsText: true),
        .init(id: "glm-5.2", brand: "Zhipu AI", capabilities: "Text Generation, Reasoning Model", supportsText: true)
    ]

    static func discovered(_ modelIDs: [String]) -> [LLMModelInfo] {
        let fallbackByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        return Set(modelIDs).map { id in
            fallbackByID[id] ?? .init(
                id: id,
                brand: inferredBrand(id),
                capabilities: "Discovered from QwenCloud",
                supportsText: inferredTextSupport(id)
            )
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func inferredBrand(_ id: String) -> String {
        if id.hasPrefix("qwen") { return "Qwen" }
        if id.hasPrefix("wan") { return "Wan" }
        if id.hasPrefix("deepseek") { return "DeepSeek" }
        if id.hasPrefix("glm") { return "Zhipu AI" }
        if id.hasPrefix("happyhorse") { return "HappyHorse" }
        return "QwenCloud"
    }

    private static func inferredTextSupport(_ id: String) -> Bool {
        let mediaMarkers = ["image", "audio", "tts", "asr", "realtime", "i2v", "t2v", "r2v", "wan"]
        return !mediaMarkers.contains { id.localizedCaseInsensitiveContains($0) }
    }
}

actor GrokClient {
    static let shared = GrokClient()

    func complete(
        provider: LLMProvider,
        system: String,
        user: String,
        baseURL: String,
        model: String,
        effort: String,
        enableThinking: Bool,
        grokAuthentication: GrokAuthentication = .apiKey,
        openAIAuthentication: OpenAIAuthentication = .apiKey
    ) async throws -> String {
        if provider == .openAI, openAIAuthentication == .chatGPT {
            return try await CodexCLIClient.shared.complete(
                system: system,
                user: user,
                model: model,
                effort: effort,
                structuredJSON: false
            )
        }
        let key: String?
        switch provider {
        case .grok:
            key = grokAuthentication == .grokBuild
                ? GrokBuildCredentialProvider.load()
                : APIKeyStore.load()
        case .qwenCloud: key = QwenAPIKeyStore.load()
        case .openAI: key = OpenAIAPIKeyStore.load()
        }
        guard let key else {
            if provider == .grok, grokAuthentication == .grokBuild {
                throw LLMError.grokBuildNotLoggedIn
            }
            throw LLMError.noAPIKey(provider)
        }

        let responsesRequest = try LLMRequestBuilder.responses(
            provider: provider,
            apiKey: key,
            baseURL: baseURL,
            model: model,
            system: system,
            user: user,
            effort: effort,
            enableThinking: enableThinking
        )
        if provider == .openAI {
            return try await sendResponses(responsesRequest)
        }
        do {
            return try await sendResponses(responsesRequest)
        } catch {
            let request = try LLMRequestBuilder.chat(
                provider: provider,
                apiKey: key,
                baseURL: baseURL,
                model: model,
                system: system,
                user: user,
                effort: effort,
                enableThinking: enableThinking
            )
            return try await sendChat(request)
        }
    }

    func completeStructuredJSON(
        provider: LLMProvider,
        system: String,
        user: String,
        baseURL: String,
        model: String,
        effort: String,
        enableThinking: Bool,
        grokAuthentication: GrokAuthentication = .apiKey,
        openAIAuthentication: OpenAIAuthentication = .apiKey
    ) async throws -> String {
        if provider == .openAI, openAIAuthentication == .chatGPT {
            return try await CodexCLIClient.shared.complete(
                system: system,
                user: user,
                model: model,
                effort: effort,
                structuredJSON: true
            )
        }
        let key: String?
        switch provider {
        case .grok:
            key = grokAuthentication == .grokBuild
                ? GrokBuildCredentialProvider.load()
                : APIKeyStore.load()
        case .qwenCloud: key = QwenAPIKeyStore.load()
        case .openAI: key = OpenAIAPIKeyStore.load()
        }
        guard let key else {
            if provider == .grok, grokAuthentication == .grokBuild {
                throw LLMError.grokBuildNotLoggedIn
            }
            throw LLMError.noAPIKey(provider)
        }
        if provider == .openAI {
            let request = try LLMRequestBuilder.responses(
                provider: provider,
                apiKey: key,
                baseURL: baseURL,
                model: model,
                system: system,
                user: user,
                effort: effort,
                enableThinking: enableThinking,
                structuredJSON: true
            )
            return try await sendResponses(request)
        }
        if provider == .qwenCloud {
            do {
                let request = try LLMRequestBuilder.responses(
                    provider: provider,
                    apiKey: key,
                    baseURL: baseURL,
                    model: model,
                    system: system,
                    user: user,
                    effort: effort,
                    enableThinking: enableThinking,
                    structuredJSON: true
                )
                return try await sendResponses(request)
            } catch where ResponsesFallbackPolicy.shouldFallbackToChat(after: error) {
                // Some models or plans reject Responses tools or a particular
                // Responses effort. Fall through to documented Chat JSON mode.
            } catch {
                throw error
            }
        }
        let request = try LLMRequestBuilder.chat(
            provider: provider,
            apiKey: key,
            baseURL: baseURL,
            model: model,
            system: system,
            user: user,
            effort: effort,
            enableThinking: enableThinking,
            structuredJSON: true
        )
        do {
            return try await sendChat(request)
        } catch let error as LLMError where error.rejectsStructuredOutput {
            let fallback = try LLMRequestBuilder.chat(
                provider: provider,
                apiKey: key,
                baseURL: baseURL,
                model: model,
                system: system,
                user: user,
                effort: effort,
                enableThinking: enableThinking
            )
            return try await sendChat(fallback)
        }
    }

    func qwenModels(baseURL: String, apiKey: String? = nil) async throws -> [String] {
        try await providerModels(provider: .qwenCloud, baseURL: baseURL, apiKey: apiKey)
    }

    func providerModels(provider: LLMProvider, baseURL: String, apiKey: String? = nil) async throws -> [String] {
        let supplied = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedKey: String?
        switch provider {
        case .grok: savedKey = APIKeyStore.load()
        case .qwenCloud: savedKey = QwenAPIKeyStore.load()
        case .openAI: savedKey = OpenAIAPIKeyStore.load()
        }
        guard let key = supplied?.isEmpty == false ? supplied : savedKey else {
            throw LLMError.noAPIKey(provider)
        }
        let request = try LLMModelDiscovery.request(provider: provider, baseURL: baseURL, apiKey: key)
        let data = try await modelData(request: request)
        return try LLMModelDiscovery.decodeModelIDs(data, provider: provider)
    }

    private func modelData(request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(code, String(snippet.prefix(400)))
        }
        return data
    }

    private func sendResponses(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(code, String(snippet.prefix(400)))
        }
        let parsed = try JSONDecoder().decode(ResponsesAPI.self, from: data)
        let text = parsed.resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw LLMError.empty }
        return text
    }

    private func sendChat(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(code, String(snippet.prefix(400)))
        }
        let parsed = try JSONDecoder().decode(ChatResponse.self, from: data)
        let text = parsed.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { throw LLMError.empty }
        return text
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    private struct ModelPermissionsResponse: Decodable {
        struct Output: Decodable {
            struct Permission: Decodable { var model: String }
            var permissions: [Permission]
        }
        var output: Output?
    }

    private struct ResponsesAPI: Decodable {
        var output_text: String?
        var output: [OutputItem]?

        struct OutputItem: Decodable {
            var content: [ContentItem]?
            var arguments: String?
        }
        struct ContentItem: Decodable {
            var text: String?
        }

        var resolved: String {
            if let output_text, !output_text.isEmpty { return output_text }
            if let arguments = output?.compactMap(\.arguments).first, !arguments.isEmpty {
                return arguments
            }
            let parts = output?.flatMap { $0.content ?? [] }.compactMap(\.text) ?? []
            return parts.joined(separator: "\n")
        }
    }
}

enum LLMRequestBuilder {
    static func responses(
        provider: LLMProvider,
        apiKey: String,
        baseURL: String,
        model: String,
        system: String,
        user: String,
        effort: String,
        enableThinking: Bool,
        structuredJSON: Bool = false
    ) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if provider == .qwenCloud {
            if QwenRequestPolicy.supportsThinkingToggle(model: model) {
                body["enable_thinking"] = effort == QwenEffort.none.rawValue ? false : enableThinking
            }
            if let normalized = QwenRequestPolicy.effort(
                model: model,
                requested: effort,
                thinking: enableThinking,
                api: .responses
            ) {
                body["reasoning"] = ["effort": normalized]
            }
        } else if provider == .openAI,
                  let normalized = OpenAIRequestPolicy.apiEffort(model: model, requested: effort) {
            body["reasoning"] = ["effort": normalized]
        } else if provider == .grok,
                  let normalized = GrokRequestPolicy.effort(model: model, requested: effort) {
            body["reasoning"] = ["effort": normalized]
        }
        if structuredJSON {
            body["tools"] = [SentenceTranslationContract.submissionTool]
            body["tool_choice"] = "required"
        }
        return try request(path: "responses", apiKey: apiKey, baseURL: baseURL, body: body)
    }

    static func chat(
        provider: LLMProvider,
        apiKey: String,
        baseURL: String,
        model: String,
        system: String,
        user: String,
        effort: String,
        enableThinking: Bool,
        structuredJSON: Bool = false
    ) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if provider == .qwenCloud {
            if QwenRequestPolicy.supportsThinkingToggle(model: model) {
                body["enable_thinking"] = effort == QwenEffort.none.rawValue ? false : enableThinking
            }
            if let normalized = QwenRequestPolicy.effort(
                model: model,
                requested: effort,
                thinking: enableThinking,
                api: .chat
            ) {
                body["reasoning_effort"] = normalized
            }
        } else if provider == .openAI,
                  let normalized = OpenAIRequestPolicy.apiEffort(model: model, requested: effort) {
            body["reasoning_effort"] = normalized
        } else if provider == .grok,
                  let normalized = GrokRequestPolicy.effort(model: model, requested: effort) {
            body["reasoning_effort"] = normalized
        }
        if structuredJSON {
            body["response_format"] = ["type": "json_object"]
        }
        return try request(path: "chat/completions", apiKey: apiKey, baseURL: baseURL, body: body)
    }

    private static func request(path: String, apiKey: String, baseURL: String, body: [String: Any]) throws -> URLRequest {
        let endpoint = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path
        guard let url = URL(string: endpoint), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw LLMError.invalidEndpoint(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

}

enum StudyLanguage: String, CaseIterable, Identifiable, Sendable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja = "ja"
    case ko = "ko"
    case es = "es"
    case fr = "fr"
    case de = "de"
    case en = "en"

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .zhHans: "简体中文 (Chinese, simplified)"
        case .zhHant: "繁體中文 (Chinese, traditional)"
        case .ja: "日本語 (Japanese)"
        case .ko: "한국어 (Korean)"
        case .es: "Español"
        case .fr: "Français"
        case .de: "Deutsch"
        case .en: "English"
        }
    }

    var promptName: String {
        switch self {
        case .zhHans: "Simplified Chinese (简体中文)"
        case .zhHant: "Traditional Chinese (繁體中文)"
        case .ja: "Japanese"
        case .ko: "Korean"
        case .es: "Spanish"
        case .fr: "French"
        case .de: "German"
        case .en: "English (plain paraphrase)"
        }
    }
}
