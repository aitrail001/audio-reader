import Foundation
import Testing
@testable import AudioReader

@Suite("OpenAI provider")
struct OpenAIProviderTests {
    @Test("Provider exposes separate ChatGPT-plan and API-key authentication")
    func exposesOpenAIAuthenticationModes() {
        #expect(LLMProvider.openAI.menuLabel == "OpenAI / ChatGPT")
        #expect(LLMProvider.openAI.environmentKey == "OPENAI_API_KEY")
        #expect(LLMProvider.openAI.defaultEndpoint == "https://api.openai.com/v1")
        #expect(OpenAIAuthentication.allCases == [.chatGPT, .apiKey])
        #expect(OpenAIAuthentication.chatGPT.menuLabel == "ChatGPT plan")
        #expect(OpenAIAuthentication.apiKey.menuLabel == "API key")
    }

    @Test("OpenAI defaults suit efficient reading assistance")
    func defaultsOpenAISettings() {
        let settings = AppSettings.default

        #expect(settings.openAIAuthentication == OpenAIAuthentication.chatGPT.rawValue)
        #expect(settings.openAIEndpoint == LLMProvider.openAI.defaultEndpoint)
        #expect(settings.openAIModel == OpenAIModel.gpt56Luna.rawValue)
        #expect(settings.openAIEffort == OpenAIEffort.medium.rawValue)
    }

    @Test("Existing settings decode with OpenAI defaults")
    func migratesExistingSettings() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "openAIAuthentication")
        object.removeValue(forKey: "openAIEndpoint")
        object.removeValue(forKey: "openAIModel")
        object.removeValue(forKey: "openAIEffort")

        let migrated = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(migrated.openAIAuthentication == OpenAIAuthentication.chatGPT.rawValue)
        #expect(migrated.openAIEndpoint == LLMProvider.openAI.defaultEndpoint)
        #expect(migrated.openAIModel == OpenAIModel.gpt56Luna.rawValue)
        #expect(migrated.openAIEffort == OpenAIEffort.medium.rawValue)
    }

    @Test("API-key mode builds a standard OpenAI Responses request")
    func buildsOpenAIResponsesRequest() throws {
        let request = try LLMRequestBuilder.responses(
            provider: .openAI,
            apiKey: "test-openai-key",
            baseURL: LLMProvider.openAI.defaultEndpoint,
            model: OpenAIModel.gpt56Luna.rawValue,
            system: "Be concise.",
            user: "Reply only OK.",
            effort: OpenAIEffort.medium.rawValue,
            enableThinking: false
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try #require(json["reasoning"] as? [String: String])

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-openai-key")
        #expect(reasoning["effort"] == OpenAIEffort.medium.rawValue)
        #expect(json["enable_thinking"] == nil)
    }

    @Test("ChatGPT-plan mode uses an ephemeral read-only Codex invocation")
    func buildsSafeCodexInvocation() {
        let invocation = CodexCLIInvocation(
            model: OpenAIModel.gpt56Luna.rawValue,
            effort: OpenAIEffort.medium.rawValue,
            outputSchemaPath: nil
        )

        #expect(invocation.arguments == [
            "exec",
            "--ephemeral",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--color", "never",
            "--disable", "shell_tool",
            "--disable", "unified_exec",
            "--disable", "apps",
            "--disable", "plugins",
            "--disable", "memories",
            "--disable", "skill_search",
            "--disable", "hooks",
            "--disable", "browser_use",
            "--disable", "computer_use",
            "--disable", "image_generation",
            "--disable", "multi_agent",
            "--disable", "goals",
            "--disable", "workspace_dependencies",
            "--disable", "view_image",
            "--model", "gpt-5.6-luna",
            "--config", "model_reasoning_effort=\"medium\"",
            "-"
        ])
    }

    @Test("npm Codex installations expose their bundled native executable")
    func findsBundledNativeCodex() {
        let launcher = URL(fileURLWithPath: "/Users/test/.nvm/versions/node/v24.18.0/lib/node_modules/@openai/codex/bin/codex.js")

        let candidates = CodexExecutableResolver.nativeCandidates(forResolvedLauncher: launcher)

#if arch(arm64)
        #expect(candidates.contains(URL(fileURLWithPath: "/Users/test/.nvm/versions/node/v24.18.0/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex")))
#else
        #expect(candidates.contains(URL(fileURLWithPath: "/Users/test/.nvm/versions/node/v24.18.0/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex")))
#endif
    }

    @Test("Codex resolver prefers an executable native binary over its JavaScript launcher")
    func prefersBundledNativeCodex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Codex-Native-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = root.appendingPathComponent("node_modules/@openai/codex", isDirectory: true)
        let script = packageRoot.appendingPathComponent("bin/codex.js")
        let launcher = root.appendingPathComponent("bin/codex")
        let native = CodexExecutableResolver.nativeCandidates(forResolvedLauncher: script)[0]
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FileManager.default.createFile(atPath: script.path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: native.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: native.path)
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: script)

        #expect(CodexExecutableResolver.preferredExecutable(for: launcher) == native)
    }

    @Test("npm launcher fallback can find its sibling Node runtime")
    func prependsSiblingNodeDirectoryToPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Codex-Resolver-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let launcher = bin.appendingPathComponent("codex")
        let node = bin.appendingPathComponent("node")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FileManager.default.createFile(atPath: launcher.path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: node.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let environment = CodexExecutableResolver.processEnvironment(
            for: launcher,
            inherited: ["PATH": "/usr/bin:/bin"]
        )

        #expect(environment["PATH"] == "\(bin.path):/usr/bin:/bin")
    }
}
