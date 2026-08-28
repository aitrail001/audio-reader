import Foundation
import CryptoKit
import Testing
@testable import AudioReader

@Suite("Provider credentials")
struct ProviderCredentialTests {
    @Test("Top-bar connections distinguish provider-managed sign-in from API keys")
    func topBarConnectionChoices() {
        #expect(LLMConnectionChoice.allCases == [
            .managedQwen, .grokBuild, .grokAPIKey, .qwenAPIKey, .chatGPTPlan, .openAIAPIKey, .appleFoundation
        ])

        var settings = AppSettings.default
        LLMConnectionChoice.openAIAPIKey.apply(to: &settings)
        #expect(settings.llmProvider == LLMProvider.openAI.rawValue)
        #expect(settings.openAIAuthentication == OpenAIAuthentication.apiKey.rawValue)

        LLMConnectionChoice.grokBuild.apply(to: &settings)
        #expect(settings.llmProvider == LLMProvider.grok.rawValue)
        #expect(settings.grokAuthentication == GrokAuthentication.grokBuild.rawValue)

#if os(macOS)
        #expect(LLMConnectionChoice.availableOnCurrentPlatform == LLMConnectionChoice.allCases)
#else
        #expect(LLMConnectionChoice.availableOnCurrentPlatform == [
            .managedQwen, .grokAPIKey, .qwenAPIKey, .openAIAPIKey, .appleFoundation
        ])
#endif
    }

    @Test("Legacy credential migration runs only once per app session")
    func legacyCredentialMigrationIsSessionScoped() {
        var session = LegacyCredentialMigrationSession()
        var runCount = 0

        session.runOnce { runCount += 1 }
        session.runOnce { runCount += 1 }

        #expect(runCount == 1)
    }

    @Test("Every API provider has a persisted default endpoint")
    func providerEndpointDefaults() {
        let settings = AppSettings.default

        #expect(settings.grokEndpoint == LLMProvider.grok.defaultEndpoint)
        #expect(settings.qwenEndpoint == LLMProvider.qwenCloud.defaultEndpoint)
        #expect(settings.openAIEndpoint == LLMProvider.openAI.defaultEndpoint)
        #expect(settings.endpoint(for: .grok) == LLMProvider.grok.defaultEndpoint)
        #expect(settings.endpoint(for: .qwenCloud) == LLMProvider.qwenCloud.defaultEndpoint)
        #expect(settings.endpoint(for: .openAI) == LLMProvider.openAI.defaultEndpoint)
    }

    @Test("Grok Build and xAI API key are separate authentication modes")
    func grokAuthenticationModes() {
        #expect(GrokAuthentication.allCases == [.grokBuild, .apiKey])
        #expect(AppSettings.default.grokAuthentication == GrokAuthentication.grokBuild.rawValue)
    }

    @Test("Environment credential status names the provider variable")
    func environmentCredentialStatus() {
        #expect(
            ProviderAPIKeyStore.environmentSourceLabel(.openAI)
                == "Ready — using OPENAI_API_KEY from the environment"
        )
    }

    @Test("Saved credential status names the encrypted local vault")
    func savedCredentialStatus() {
        #expect(
            ProviderAPIKeyStore.savedCredentialSourceLabel
                == "Ready — API key stored in encrypted local vault"
        )
    }

    @Test("Wrapping key is a 256-bit file and never Keychain for new vaults")
    func wrappingKeyLivesInAProtectedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Wrapping-Key-\(UUID().uuidString)", isDirectory: true)
        let keyURL = root.appendingPathComponent("credential-vault.key")
        let vaultURL = root.appendingPathComponent("credentials.vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = FileCredentialVaultKeyProvider(fileURL: keyURL)
        let vault = EncryptedFileCredentialVault(fileURL: vaultURL, keyProvider: provider)
        #expect(vault.save("sk-test-secret", account: LLMProvider.openAI.rawValue))
        #expect(FileManager.default.fileExists(atPath: keyURL.path))
        let keyData = try Data(contentsOf: keyURL)
        #expect(keyData.count == 32)
#if os(macOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
#endif
        #expect(vault.read(account: LLMProvider.openAI.rawValue) == "sk-test-secret")
    }

    @Test("Encrypted credential vault round-trips without plaintext on disk")
    func encryptedCredentialVaultRoundTrip() throws {
        let fixture = try CredentialVaultFixture()
        defer { fixture.remove() }

        #expect(fixture.vault.save("sk-test-secret", account: LLMProvider.openAI.rawValue))
        #expect(fixture.vault.read(account: LLMProvider.openAI.rawValue) == "sk-test-secret")

        let stored = try Data(contentsOf: fixture.fileURL)
        #expect(!stored.contains(Data("sk-test-secret".utf8)))
        #expect(!String(decoding: stored, as: UTF8.self).contains("sk-test-secret"))
#if os(macOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
#endif
    }

    @Test("Encrypted credential vault rejects a different wrapping key")
    func encryptedCredentialVaultRejectsWrongKey() throws {
        let fixture = try CredentialVaultFixture()
        defer { fixture.remove() }
        #expect(fixture.vault.save("sk-test-secret", account: LLMProvider.openAI.rawValue))

        let otherKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))
        let otherVault = EncryptedFileCredentialVault(
            fileURL: fixture.fileURL,
            keyProvider: FixedCredentialVaultKeyProvider(otherKey)
        )

        #expect(otherVault.read(account: LLMProvider.openAI.rawValue) == nil)
    }

    @Test("Encrypted credential vault detects tampering")
    func encryptedCredentialVaultDetectsTampering() throws {
        let fixture = try CredentialVaultFixture()
        defer { fixture.remove() }
        #expect(fixture.vault.save("sk-test-secret", account: LLMProvider.openAI.rawValue))

        var stored = try Data(contentsOf: fixture.fileURL)
        stored[stored.index(before: stored.endIndex)] ^= 0x01
        try stored.write(to: fixture.fileURL, options: .atomic)

        #expect(fixture.vault.read(account: LLMProvider.openAI.rawValue) == nil)
    }

    @Test("Existing settings migrate all provider endpoints and Grok authentication")
    func migratesProviderSettings() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "grokAuthentication")
        object.removeValue(forKey: "grokEndpoint")
        object.removeValue(forKey: "openAIEndpoint")

        let migrated = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(migrated.grokAuthentication == GrokAuthentication.grokBuild.rawValue)
        #expect(migrated.grokEndpoint == LLMProvider.grok.defaultEndpoint)
        #expect(migrated.openAIEndpoint == LLMProvider.openAI.defaultEndpoint)
    }

    @Test("Legacy plaintext credentials move into secure storage and are removed")
    func migratesLegacyPlaintextCredential() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Credential-Migration-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("openai-api-key")
        let vault = TestCredentialVault()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("legacy-secret\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = LegacyCredentialMigration.migrate(
            fileURL: file,
            account: LLMProvider.openAI.rawValue,
            vault: vault
        )

        #expect(result == .migrated)
        #expect(vault.read(account: LLMProvider.openAI.rawValue) == "legacy-secret")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Failed secure migration never deletes the only credential copy")
    func preservesLegacyCredentialWhenSecureWriteFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Credential-Failure-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("xai-api-key")
        let vault = TestCredentialVault(acceptsWrites: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("legacy-secret".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = LegacyCredentialMigration.migrate(
            fileURL: file,
            account: LLMProvider.grok.rawValue,
            vault: vault
        )

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Legacy Keychain credentials move to the encrypted vault before deletion")
    func migratesLegacyKeychainCredential() throws {
        let source = TestCredentialVault(values: [LLMProvider.openAI.rawValue: "legacy-secret"])
        let destination = TestCredentialVault()

        let result = LegacyVaultCredentialMigration.migrate(
            account: LLMProvider.openAI.rawValue,
            source: source,
            destination: destination
        )

        #expect(result == .migrated)
        #expect(source.read(account: LLMProvider.openAI.rawValue) == nil)
        #expect(destination.read(account: LLMProvider.openAI.rawValue) == "legacy-secret")
    }

    @Test("Failed encrypted migration preserves the legacy Keychain credential")
    func preservesLegacyKeychainCredentialWhenEncryptedWriteFails() {
        let source = TestCredentialVault(values: [LLMProvider.grok.rawValue: "legacy-secret"])
        let destination = TestCredentialVault(acceptsWrites: false)

        let result = LegacyVaultCredentialMigration.migrate(
            account: LLMProvider.grok.rawValue,
            source: source,
            destination: destination
        )

        #expect(result == .failed)
        #expect(source.read(account: LLMProvider.grok.rawValue) == "legacy-secret")
        #expect(destination.read(account: LLMProvider.grok.rawValue) == nil)
    }

    @Test("An existing encrypted credential wins over an older Keychain value")
    func preservesExistingEncryptedCredentialDuringMigration() {
        let source = TestCredentialVault(values: [LLMProvider.openAI.rawValue: "older-secret"])
        let destination = TestCredentialVault(values: [LLMProvider.openAI.rawValue: "current-secret"])

        let result = LegacyVaultCredentialMigration.migrate(
            account: LLMProvider.openAI.rawValue,
            source: source,
            destination: destination
        )

        #expect(result == .migrated)
        #expect(source.read(account: LLMProvider.openAI.rawValue) == nil)
        #expect(destination.read(account: LLMProvider.openAI.rawValue) == "current-secret")
    }
}

private final class TestCredentialVault: CredentialVault {
    private var values: [String: String] = [:]
    private let acceptsWrites: Bool

    init(values: [String: String] = [:], acceptsWrites: Bool = true) {
        self.values = values
        self.acceptsWrites = acceptsWrites
    }

    func read(account: String) -> String? {
        values[account]
    }

    func contains(account: String) -> Bool {
        values[account] != nil
    }

    func save(_ secret: String, account: String) -> Bool {
        guard acceptsWrites else { return false }
        values[account] = secret
        return true
    }

    func delete(account: String) -> Bool {
        values.removeValue(forKey: account)
        return true
    }
}

private struct FixedCredentialVaultKeyProvider: CredentialVaultKeyProvider {
    let wrappingKey: SymmetricKey

    init(_ wrappingKey: SymmetricKey) {
        self.wrappingKey = wrappingKey
    }

    func key(vaultExists: Bool) throws -> SymmetricKey {
        wrappingKey
    }
}

private struct CredentialVaultFixture {
    let root: URL
    let fileURL: URL
    let vault: EncryptedFileCredentialVault

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReader-Encrypted-Credential-\(UUID().uuidString)", isDirectory: true)
        fileURL = root.appendingPathComponent("credentials.vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = SymmetricKey(data: Data(repeating: 0x5A, count: 32))
        vault = EncryptedFileCredentialVault(
            fileURL: fileURL,
            keyProvider: FixedCredentialVaultKeyProvider(key)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
