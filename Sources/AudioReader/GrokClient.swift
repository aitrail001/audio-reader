import Foundation

enum LLMError: LocalizedError {
    case noAPIKey(LLMProvider)
    case invalidEndpoint(String)
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let provider):
            "No \(provider.menuLabel) API key. Add \(provider.environmentKey) in Settings."
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

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .grok: "Grok (xAI)"
        case .qwenCloud: "QwenCloud"
        }
    }

    var environmentKey: String {
        switch self {
        case .grok: "XAI_API_KEY"
        case .qwenCloud: "DASHSCOPE_API_KEY"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .grok: "https://api.x.ai/v1"
        case .qwenCloud: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
        }
    }
}

enum APIKeyStore {
    static var fileURL: URL { Persistence.root.appendingPathComponent("xai-api-key") }

    static var grokAuthURL: URL {
#if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
#else
        Persistence.root.appendingPathComponent("grok-auth-unavailable")
#endif
    }

    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["XAI_API_KEY"], !env.isEmpty {
            return env
        }
        if let file = savedFileKey() { return file }
        if let grok = grokBuildToken() { return grok }
        return nil
    }

    static func savedFileKey() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// OAuth access token from `grok login` / Grok Build. Not an API-console key.
    static func grokBuildToken() -> String? {
#if os(macOS)
        guard let data = try? Data(contentsOf: grokAuthURL),
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

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
            do {
                try FileManager.default.removeItem(at: fileURL)
                return true
            } catch {
                return false
            }
        }
        do {
            try Data(trimmed.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    static var isConfigured: Bool { load() != nil }

    static var sourceLabel: String {
        if let env = ProcessInfo.processInfo.environment["XAI_API_KEY"], !env.isEmpty {
            return "Using XAI_API_KEY from the environment"
        }
        if savedFileKey() != nil { return "Using a saved xAI API key" }
        if grokBuildToken() != nil { return "Signed in via Grok Build — no extra key needed" }
        return "Not signed in"
    }
}

enum QwenAPIKeyStore {
    static var fileURL: URL { Persistence.root.appendingPathComponent("dashscope-api-key") }

    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"], !env.isEmpty {
            return env
        }
        return savedFileKey()
    }

    static func savedFileKey() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
            do {
                try FileManager.default.removeItem(at: fileURL)
                return true
            } catch {
                return false
            }
        }
        do {
            try Data(trimmed.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    static var isConfigured: Bool { load() != nil }

    static var sourceLabel: String {
        if let env = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"], !env.isEmpty {
            return "Using DASHSCOPE_API_KEY from the environment"
        }
        if savedFileKey() != nil { return "Using a saved QwenCloud API key" }
        return "Not configured"
    }
}

enum GrokModel: String, CaseIterable, Identifiable {
    case grok46 = "grok-4.6"
    case grokBuild = "grok-build-0.1"

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .grok46: "grok-4.6 — general / translation"
        case .grokBuild: "grok-build-0.1 — Grok Build"
        }
    }

    var supportsEffort: Bool {
        self == .grok46
    }
}

enum GrokEffort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .low: "Low — fast"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "xHigh — slowest"
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
        enableThinking: Bool
    ) async throws -> String {
        let key = provider == .grok ? APIKeyStore.load() : QwenAPIKeyStore.load()
        guard let key else { throw LLMError.noAPIKey(provider) }

        do {
            let request = try LLMRequestBuilder.responses(
                provider: provider,
                apiKey: key,
                baseURL: baseURL,
                model: model,
                system: system,
                user: user,
                effort: effort,
                enableThinking: enableThinking
            )
            return try await sendResponses(request)
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
        enableThinking: Bool
    ) async throws -> String {
        let key = provider == .grok ? APIKeyStore.load() : QwenAPIKeyStore.load()
        guard let key else { throw LLMError.noAPIKey(provider) }
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
        let supplied = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = supplied?.isEmpty == false ? supplied : QwenAPIKeyStore.load() else {
            throw LLMError.noAPIKey(.qwenCloud)
        }
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let data = try await qwenModelData(urlString: trimmed + "/models", key: key)
        let parsed = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return parsed.data.map(\.id)
    }

    private func qwenModelData(urlString: String, key: String) async throws -> Data {
        guard let url = URL(string: urlString), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw LLMError.invalidEndpoint(urlString)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
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

    private struct ModelListResponse: Decodable {
        struct Model: Decodable { var id: String }
        var data: [Model]
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
        } else if GrokModel(rawValue: model)?.supportsEffort == true {
            body["reasoning"] = ["effort": effort]
        }
        if structuredJSON {
            body["tools"] = [translationSubmissionTool]
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
        } else if GrokModel(rawValue: model)?.supportsEffort == true {
            body["reasoning_effort"] = effort
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

    private static var translationSubmissionTool: [String: Any] {
        [
            "type": "function",
            "name": "submit_translations",
            "description": "Submit one contextual translation result for each requested sentence ID.",
            "parameters": [
                "type": "object",
                "properties": [
                    "translations": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "translation": ["type": "string"],
                                "phrases": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "source": ["type": "string"],
                                            "explanation": ["type": "string"]
                                        ],
                                        "required": ["source", "explanation"]
                                    ]
                                ]
                            ],
                            "required": ["id", "translation", "phrases"]
                        ]
                    ]
                ],
                "required": ["translations"]
            ]
        ]
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
