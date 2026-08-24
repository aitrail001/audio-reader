import Foundation

enum CodexExecutableResolver {
    private static var platformPackage: String {
#if arch(arm64)
        "codex-darwin-arm64"
#else
        "codex-darwin-x64"
#endif
    }

    private static var targetTriple: String {
#if arch(arm64)
        "aarch64-apple-darwin"
#else
        "x86_64-apple-darwin"
#endif
    }

    static func nativeCandidates(forResolvedLauncher launcher: URL) -> [URL] {
        let packageRoot = launcher.deletingLastPathComponent().deletingLastPathComponent()
        let nativeTail = "\(platformPackage)/vendor/\(targetTriple)/bin/codex"
        return [
            packageRoot.appendingPathComponent("node_modules/@openai/\(nativeTail)"),
            packageRoot.deletingLastPathComponent().appendingPathComponent(nativeTail),
            packageRoot.appendingPathComponent("vendor/\(targetTriple)/bin/codex")
        ]
    }

    static func preferredExecutable(
        for launcher: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let resolvedLauncher = launcher.resolvingSymlinksInPath()
        guard resolvedLauncher.pathExtension == "js" else { return launcher }
        return nativeCandidates(forResolvedLauncher: resolvedLauncher)
            .first { fileManager.isExecutableFile(atPath: $0.path) } ?? launcher
    }

    static func processEnvironment(
        for executable: URL,
        inherited: [String: String],
        fileManager: FileManager = .default
    ) -> [String: String] {
        var environment = inherited
        let executableDirectory = executable.deletingLastPathComponent()
        let siblingNode = executableDirectory.appendingPathComponent("node")
        guard fileManager.isExecutableFile(atPath: siblingNode.path) else { return environment }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        environment["PATH"] = ([executableDirectory.path] + pathEntries.filter { $0 != executableDirectory.path })
            .joined(separator: ":")
        return environment
    }
}

struct CodexCLIInvocation: Equatable {
    var model: String
    var effort: String
    var outputSchemaPath: String?

    var arguments: [String] {
        var result = [
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
            "--model", model,
            "--config", "model_reasoning_effort=\"\(effort)\""
        ]
        if let outputSchemaPath {
            result += ["--output-schema", outputSchemaPath]
        }
        result.append("-")
        return result
    }
}

actor CodexCLIClient {
    static let shared = CodexCLIClient()

    static var executableURL: URL? {
#if os(macOS)
        let fileManager = FileManager.default
        if let configured = ProcessInfo.processInfo.environment["AUDIOREADER_CODEX_PATH"],
           !configured.isEmpty,
           fileManager.isExecutableFile(atPath: configured) {
            return CodexExecutableResolver.preferredExecutable(for: URL(fileURLWithPath: configured))
        }

        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        let commonCandidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        for candidate in pathCandidates + commonCandidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return CodexExecutableResolver.preferredExecutable(for: candidate)
        }

        let nodeVersions = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versionDirectories = (try? fileManager.contentsOfDirectory(
            at: nodeVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending } ?? []
        let launcher = versionDirectories
            .map { $0.appendingPathComponent("bin/codex") }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
        return launcher.map { CodexExecutableResolver.preferredExecutable(for: $0) }
#else
        nil
#endif
    }

    static var isAvailable: Bool { executableURL != nil }

    static var executableLabel: String {
        executableURL?.path ?? "Codex CLI not found"
    }

    func loginStatus() async -> String {
#if os(macOS)
        guard let executable = Self.executableURL else { return LLMError.codexUnavailable.localizedDescription }
        do {
            let result = try await run(executable: executable, arguments: ["login", "status"], input: nil)
            let output = decoded(result.stdout + result.stderr)
            return output.isEmpty ? "Codex login status unavailable" : output
        } catch {
            return error.localizedDescription
        }
#else
        return "ChatGPT-plan access through Codex is available on macOS only."
#endif
    }

    func complete(
        system: String,
        user: String,
        model: String,
        effort: String,
        structuredJSON: Bool
    ) async throws -> String {
#if os(macOS)
        guard let executable = Self.executableURL else { throw LLMError.codexUnavailable }
        let schemaURL = structuredJSON ? try makeTranslationSchemaFile() : nil
        defer {
            if let schemaURL { try? FileManager.default.removeItem(at: schemaURL) }
        }
        let invocation = CodexCLIInvocation(
            model: model,
            effort: effort,
            outputSchemaPath: schemaURL?.path
        )
        let prompt = """
        Act only as the language model for an audiobook reading assistant. Do not inspect files, run commands, or use tools.
        Follow the SYSTEM instructions below exactly. Return only the requested answer, without commentary or Markdown fences.

        SYSTEM:
        \(system)

        USER:
        \(user)
        """
        let result = try await run(
            executable: executable,
            arguments: invocation.arguments,
            input: Data(prompt.utf8)
        )
        guard result.status == 0 else {
            let failure = decoded(result.stderr + result.stdout)
            if failure.localizedCaseInsensitiveContains("not logged in") {
                throw LLMError.codexNotLoggedIn
            }
            throw LLMError.codexFailed(failure.isEmpty ? "The Codex process exited with status \(result.status)." : failure)
        }
        let output = decoded(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw LLMError.empty }
        return output
#else
        throw LLMError.codexUnavailable
#endif
    }

#if os(macOS)
    private struct ProcessResult: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stdoutURL = root.appendingPathComponent("stdout")
        let stderrURL = root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CodexExecutableResolver.processEnvironment(
            for: executable,
            inherited: ProcessInfo.processInfo.environment
        )
        process.currentDirectoryURL = root
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let stdinPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        try process.run()
        if let input, let stdinPipe {
            try stdinPipe.fileHandleForWriting.write(contentsOf: input)
            try stdinPipe.fileHandleForWriting.close()
        }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: try Data(contentsOf: stdoutURL),
            stderr: try Data(contentsOf: stderrURL)
        )
    }

    private func makeTranslationSchemaFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Translation-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: SentenceTranslationContract.jsonSchema)
            .write(to: url, options: .atomic)
        return url
    }
#endif

    private func decoded(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
