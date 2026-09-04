import CryptoKit
import Foundation
#if os(macOS)
import LocalAuthentication
#endif
import Security

protocol CredentialVault {
    func read(account: String) -> String?
    func contains(account: String) -> Bool
    @discardableResult func save(_ secret: String, account: String) -> Bool
    @discardableResult func delete(account: String) -> Bool
}

/// The former per-provider Keychain store. It remains available only to migrate
/// credentials that were saved by an earlier AudioReader version.
struct KeychainCredentialVault: CredentialVault {
    static let shared = KeychainCredentialVault(
        service: "com.johnsonzhang.AudioReader.llm-api-keys"
    )

    let service: String

    func read(account: String) -> String? {
        guard let data = readData(account: account),
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty
        else { return nil }
        return secret
    }

    func contains(account: String) -> Bool {
        SecItemCopyMatching(baseQuery(account: account) as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func save(_ secret: String, account: String) -> Bool {
        saveData(Data(secret.utf8), account: account)
    }

    @discardableResult
    func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func saveData(_ value: Data, account: String) -> Bool {
        let update = [kSecValueData as String: value]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var item = baseQuery(account: account)
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
#if os(macOS)
        // Legacy provider items may have an ACL tied to an older ad-hoc build.
        // Migration must fail safely instead of opening repeated permission dialogs.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
#endif
        return query
    }
}

protocol CredentialVaultKeyProvider {
    func key(vaultExists: Bool) throws -> SymmetricKey
}

/// Read/delete-only wrapping-key source used to seed `credential-vault.key` once.
protocol CredentialVaultWrappingKeySource: Sendable {
    func read() throws -> Data?
    func delete() -> Bool
}

/// Older builds stored the vault wrapping key in Keychain. The file next to the
/// vault is now source of truth; this type only copies that key onto disk once.
struct LegacyKeychainCredentialVaultWrappingKey: CredentialVaultWrappingKeySource {
    static let service = "com.johnsonzhang.AudioReader.credential-vault-key"
    static let account = "credential-vault-wrapping-key"

    func read() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialVaultKeyError.unavailable
        }
        return data.isEmpty ? nil : data
    }

    func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
#if os(macOS)
        // Fail closed without a permission prompt; a missing copy must not mint a new key.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
#endif
        return query
    }
}

struct LegacyCredentialMigrationSession {
    private(set) var hasRun = false

    mutating func runOnce(_ operation: () -> Void) {
        guard !hasRun else { return }
        hasRun = true
        operation()
    }
}

enum CredentialVaultKeyError: Error, Equatable {
    case unavailable
    case missingForExistingVault
    case invalidStoredKey
}

final class FileCredentialVaultKeyProvider: CredentialVaultKeyProvider, @unchecked Sendable {
    static let shared = FileCredentialVaultKeyProvider(
        fileURL: Persistence.root.appendingPathComponent("credential-vault.key"),
        legacyWrappingKey: LegacyKeychainCredentialVaultWrappingKey()
    )

    private let fileURL: URL
    private let legacyWrappingKey: (any CredentialVaultWrappingKeySource)?
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?
    private var cachedError: CredentialVaultKeyError?

    init(
        fileURL: URL,
        legacyWrappingKey: (any CredentialVaultWrappingKeySource)? = nil
    ) {
        self.fileURL = fileURL
        self.legacyWrappingKey = legacyWrappingKey
    }

    func key(vaultExists: Bool) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }

        if let cachedKey { return cachedKey }
        if let cachedError { throw cachedError }

        do {
            let key = try loadOrCreateKey(vaultExists: vaultExists)
            cachedKey = key
            return key
        } catch let error as CredentialVaultKeyError {
            cachedError = error
            throw error
        } catch {
            cachedError = .unavailable
            throw CredentialVaultKeyError.unavailable
        }
    }

    /// File `credential-vault.key` owns the wrapping key. Copy a 32-byte legacy
    /// Keychain item onto that file when the vault already exists and the file
    /// is missing. Never mint a replacement key for a vault that cannot unlock.
    private func loadOrCreateKey(vaultExists: Bool) throws -> SymmetricKey {
        if let stored = try readFileKey() {
            guard stored.count == 32 else { throw CredentialVaultKeyError.invalidStoredKey }
            return SymmetricKey(data: stored)
        }
        if vaultExists {
            try migrateLegacyWrappingKeyToFile()
            if let migrated = try readFileKey() {
                guard migrated.count == 32 else { throw CredentialVaultKeyError.invalidStoredKey }
                return SymmetricKey(data: migrated)
            }
            throw CredentialVaultKeyError.missingForExistingVault
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveFileKey(data)
        return key
    }

    /// One-shot Keychain → file copy. Leaves the vault locked if the item is
    /// missing or not 32 bytes so an existing ciphertext is never re-keyed.
    private func migrateLegacyWrappingKeyToFile() throws {
        guard let legacy = try legacyWrappingKey?.read(), legacy.count == 32 else { return }
        try saveFileKey(legacy)
        guard let stored = try readFileKey(), stored == legacy else {
            throw CredentialVaultKeyError.unavailable
        }
        _ = legacyWrappingKey?.delete()
    }

    private func readFileKey() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return data.isEmpty ? nil : data
    }

    private func saveFileKey(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#elseif os(macOS)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
#endif
    }

}

final class EncryptedFileCredentialVault: CredentialVault, @unchecked Sendable {
    static let shared = EncryptedFileCredentialVault(
        fileURL: Persistence.root.appendingPathComponent("llm-credentials.vault"),
        keyProvider: FileCredentialVaultKeyProvider.shared
    )

    private struct EncryptedDocument: Codable {
        let version: Int
        let sealedData: Data
    }

    private struct CredentialDocument: Codable {
        var values: [String: String]
    }

    private let fileURL: URL
    private let keyProvider: any CredentialVaultKeyProvider
    private let lock = NSLock()

    init(fileURL: URL, keyProvider: any CredentialVaultKeyProvider) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
    }

    func read(account: String) -> String? {
        withLock {
            try? loadValues()[account]
        }
    }

    func contains(account: String) -> Bool {
        read(account: account) != nil
    }

    @discardableResult
    func save(_ secret: String, account: String) -> Bool {
        withLock {
            do {
                var values = try loadValues()
                values[account] = secret
                try saveValues(values)
                return try loadValues()[account] == secret
            } catch {
                return false
            }
        }
    }

    @discardableResult
    func delete(account: String) -> Bool {
        withLock {
            do {
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
                var values = try loadValues()
                values.removeValue(forKey: account)
                try saveValues(values)
                return try loadValues()[account] == nil
            } catch {
                return false
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func loadValues() throws -> [String: String] {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let key = try keyProvider.key(vaultExists: exists)
        guard exists else { return [:] }

        let data = try Data(contentsOf: fileURL)
        let encrypted = try JSONDecoder().decode(EncryptedDocument.self, from: data)
        guard encrypted.version == 1 else { throw CredentialVaultKeyError.unavailable }
        let sealedBox = try AES.GCM.SealedBox(combined: encrypted.sealedData)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        return try JSONDecoder().decode(CredentialDocument.self, from: plaintext).values
    }

    private func saveValues(_ values: [String: String]) throws {
        let key = try keyProvider.key(
            vaultExists: FileManager.default.fileExists(atPath: fileURL.path)
        )
        let plaintext = try JSONEncoder().encode(CredentialDocument(values: values))
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else { throw CredentialVaultKeyError.unavailable }
        let data = try JSONEncoder().encode(EncryptedDocument(version: 1, sealedData: combined))

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#elseif os(macOS)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
#endif
    }
}

enum LegacyCredentialMigrationResult: Equatable {
    case notNeeded
    case migrated
    case failed
}

enum LegacyCredentialMigration {
    static func migrate(
        fileURL: URL,
        account: String,
        vault: CredentialVault = EncryptedFileCredentialVault.shared
    ) -> LegacyCredentialMigrationResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .notNeeded }

        if vault.read(account: account) != nil {
            return removeLegacyFile(fileURL) ? .migrated : .failed
        }

        guard let data = try? Data(contentsOf: fileURL),
              let secret = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty,
              vault.save(secret, account: account),
              vault.read(account: account) == secret
        else { return .failed }

        return removeLegacyFile(fileURL) ? .migrated : .failed
    }

    private static func removeLegacyFile(_ fileURL: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }
}

enum LegacyVaultCredentialMigration {
    static func migrate(
        account: String,
        source: CredentialVault,
        destination: CredentialVault
    ) -> LegacyCredentialMigrationResult {
        guard let secret = source.read(account: account) else { return .notNeeded }
        if destination.contains(account: account) {
            return source.delete(account: account) ? .migrated : .failed
        }
        guard destination.save(secret, account: account),
              destination.read(account: account) == secret,
              source.delete(account: account)
        else { return .failed }
        return .migrated
    }
}

enum ProviderAPIKeyStore {
    static let savedCredentialSourceLabel = "Ready — API key stored in encrypted local vault"

    static func legacyFileURL(for provider: LLMProvider) -> URL? {
        let fileName: String? = switch provider {
        case .grok: "xai-api-key"
        case .qwenCloud: "dashscope-api-key"
        case .openAI: "openai-api-key"
        case .managedQwen, .appleFoundation: nil
        }
        return fileName.map { Persistence.root.appendingPathComponent($0) }
    }

    static func load(_ provider: LLMProvider) -> String? {
        guard provider.usesRemoteAPI, !provider.environmentKey.isEmpty else { return nil }
        if let environmentValue = ProcessInfo.processInfo.environment[provider.environmentKey],
           !environmentValue.isEmpty {
            return environmentValue
        }
        return EncryptedFileCredentialVault.shared.read(account: provider.rawValue)
    }

    static func hasSavedKey(_ provider: LLMProvider) -> Bool {
        EncryptedFileCredentialVault.shared.contains(account: provider.rawValue)
    }

    static func isConfigured(_ provider: LLMProvider) -> Bool {
        guard provider.usesRemoteAPI, !provider.environmentKey.isEmpty else { return false }
        if let environmentValue = ProcessInfo.processInfo.environment[provider.environmentKey],
           !environmentValue.isEmpty {
            return true
        }
        return hasSavedKey(provider)
    }

    @discardableResult
    static func save(_ key: String, for provider: LLMProvider) -> Bool {
        guard provider.usesRemoteAPI else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard EncryptedFileCredentialVault.shared.save(trimmed, account: provider.rawValue) else {
            return false
        }
        // Delete the plaintext predecessor only after the encrypted vault accepted its replacement.
        if let fileURL = legacyFileURL(for: provider) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return true
    }

    @discardableResult
    static func clear(_ provider: LLMProvider) -> Bool {
        EncryptedFileCredentialVault.shared.delete(account: provider.rawValue)
    }

    static func sourceLabel(_ provider: LLMProvider) -> String {
        guard provider.usesRemoteAPI, !provider.environmentKey.isEmpty else {
            return "On-device — no API key"
        }
        if let environmentValue = ProcessInfo.processInfo.environment[provider.environmentKey],
           !environmentValue.isEmpty {
            return environmentSourceLabel(provider)
        }
        if hasSavedKey(provider) {
            return savedCredentialSourceLabel
        }
        return "API key required"
    }

    static func environmentSourceLabel(_ provider: LLMProvider) -> String {
        "Ready — using \(provider.environmentKey) from the environment"
    }

    static func migrateLegacyFile(_ fileURL: URL, for provider: LLMProvider) -> LegacyCredentialMigrationResult {
        LegacyCredentialMigration.migrate(fileURL: fileURL, account: provider.rawValue)
    }

    static func migrateLegacyKeychain(_ provider: LLMProvider) -> LegacyCredentialMigrationResult {
        LegacyVaultCredentialMigration.migrate(
            account: provider.rawValue,
            source: KeychainCredentialVault.shared,
            destination: EncryptedFileCredentialVault.shared
        )
    }

    static func migrateLegacyCredentials(for provider: LLMProvider) -> [LegacyCredentialMigrationResult] {
        guard let fileURL = legacyFileURL(for: provider) else {
            return [migrateLegacyKeychain(provider)]
        }
        return [
            migrateLegacyKeychain(provider),
            migrateLegacyFile(fileURL, for: provider)
        ]
    }
}
