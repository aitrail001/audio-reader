import Foundation

enum GrokError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "No xAI API key. Add XAI_API_KEY in Settings (console.x.ai)."
        case .http(let code, let body):
            "Grok request failed (\(code)): \(body)"
        case .empty:
            "Grok returned an empty reply."
        }
    }
}

enum APIKeyStore {
    static var fileURL: URL { Persistence.root.appendingPathComponent("xai-api-key") }

    static var grokAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
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
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? trimmed.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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

actor GrokClient {
    static let shared = GrokClient()

    func complete(system: String, user: String, model: String, effort: String) async throws -> String {
        guard let key = APIKeyStore.load() else { throw GrokError.noAPIKey }
        let useEffort = GrokModel(rawValue: model)?.supportsEffort == true

        do {
            return try await postResponses(key: key, system: system, user: user, model: model, effort: useEffort ? effort : nil)
        } catch {
            return try await postChat(key: key, system: system, user: user, model: model, effort: useEffort ? effort : nil)
        }
    }

    private func postResponses(key: String, system: String, user: String, model: String, effort: String?) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if let effort {
            body["reasoning"] = ["effort": effort]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw GrokError.http(code, String(snippet.prefix(400)))
        }
        let parsed = try JSONDecoder().decode(ResponsesAPI.self, from: data)
        let text = parsed.resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw GrokError.empty }
        return text
    }

    private func postChat(key: String, system: String, user: String, model: String, effort: String?) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if let effort {
            body["reasoning_effort"] = effort
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw GrokError.http(code, String(snippet.prefix(400)))
        }
        let parsed = try JSONDecoder().decode(ChatResponse.self, from: data)
        let text = parsed.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { throw GrokError.empty }
        return text
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    private struct ResponsesAPI: Decodable {
        var output_text: String?
        var output: [OutputItem]?

        struct OutputItem: Decodable {
            var content: [ContentItem]?
        }
        struct ContentItem: Decodable {
            var text: String?
        }

        var resolved: String {
            if let output_text, !output_text.isEmpty { return output_text }
            let parts = output?.flatMap { $0.content ?? [] }.compactMap(\.text) ?? []
            return parts.joined(separator: "\n")
        }
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
