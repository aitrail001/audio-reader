import CryptoKit
import Foundation
import Security

public struct PersistedAuthSession: Codable, Equatable, Sendable {
    public var refreshToken: String
    public var expiresAt: String
    public var profile: AccountProfile
    public var mode: AccountMode

    public init(refreshToken: String, expiresAt: String, profile: AccountProfile, mode: AccountMode) {
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.profile = profile
        self.mode = mode
    }
}

public protocol AuthSessionStoring: Sendable {
    func load() throws -> PersistedAuthSession?
    func save(_ session: PersistedAuthSession) throws
    func clear() throws
    func deviceID() throws -> String
}

public final class InMemoryAuthSessionStore: AuthSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: PersistedAuthSession?
    private var storedDeviceID: String
    public var saveError: Error?

    public init(deviceID: String = UUID().uuidString.lowercased()) {
        storedDeviceID = deviceID
    }

    public func load() throws -> PersistedAuthSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func save(_ session: PersistedAuthSession) throws {
        lock.lock()
        defer { lock.unlock() }
        if let saveError { throw saveError }
        self.session = session
    }

    public func clear() throws {
        lock.lock()
        session = nil
        lock.unlock()
    }

    public func deviceID() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return storedDeviceID
    }
}

public struct KeychainAuthSessionStore: AuthSessionStoring, Sendable {
    public static let defaultService = "com.johnsonzhang.AudioReader.account-session"

    private let service: String
    private let sessionAccount = "session"
    private let deviceAccount = "device-id"

    public init(service: String = KeychainAuthSessionStore.defaultService) {
        self.service = service
    }

    public func load() throws -> PersistedAuthSession? {
        guard let data = try read(account: sessionAccount) else { return nil }
        return try JSONDecoder().decode(PersistedAuthSession.self, from: data)
    }

    public func save(_ session: PersistedAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        try write(data, account: sessionAccount)
    }

    public func clear() throws {
        try delete(account: sessionAccount)
    }

    public func deviceID() throws -> String {
        if let stored = try read(account: deviceAccount).flatMap({ String(data: $0, encoding: .utf8) }),
           UUID(uuidString: stored) != nil {
            return stored.lowercased()
        }
        let created = UUID().uuidString.lowercased()
        try write(Data(created.utf8), account: deviceAccount)
        return created
    }

    public func deleteDeviceID() throws {
        try delete(account: deviceAccount)
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AuthSessionStoreError.keychain(status) }
        return result as? Data
    }

    private func write(_ data: Data, account: String) throws {
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        if updated != errSecItemNotFound {
            throw AuthSessionStoreError.keychain(updated)
        }
        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw AuthSessionStoreError.keychain(added) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthSessionStoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum AuthSessionStoreError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    case saveFailed
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .keychain, .unavailable:
            "The account session could not be stored in the encrypted local vault."
        case .saveFailed:
            "The account session could not be saved."
        }
    }
}

public final class EncryptedFileAuthSessionStore: AuthSessionStoring, @unchecked Sendable {
    private struct Envelope: Codable {
        var version: Int
        var sealedData: Data
    }

    private struct Document: Codable {
        var deviceID: String
        var session: PersistedAuthSession?
    }

    private let directory: URL
    private let legacy: KeychainAuthSessionStore?
    private let lock = NSLock()

    public init(directory: URL, legacy: KeychainAuthSessionStore? = nil) {
        self.directory = directory
        self.legacy = legacy
    }

    public func load() throws -> PersistedAuthSession? {
        try withLock {
            try migrateLegacyIfNeeded()
            return try readDocument().session
        }
    }

    public func save(_ session: PersistedAuthSession) throws {
        try withLock {
            try migrateLegacyIfNeeded()
            var document = try readDocument()
            document.session = session
            try writeDocument(document)
            try legacy?.clear()
        }
    }

    public func clear() throws {
        try withLock {
            try migrateLegacyIfNeeded()
            var document = try readDocument()
            document.session = nil
            try writeDocument(document)
            try legacy?.clear()
        }
    }

    public func deviceID() throws -> String {
        try withLock {
            try migrateLegacyIfNeeded()
            return try readDocument().deviceID
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private var vaultURL: URL { directory.appendingPathComponent("account-session.vault") }
    private var keyURL: URL { directory.appendingPathComponent("account-session.key") }

    private func migrateLegacyIfNeeded() throws {
        if FileManager.default.fileExists(atPath: vaultURL.path) { return }
        guard let legacy else { return }
        let session = try? legacy.load()
        let device = (try? legacy.deviceID()) ?? UUID().uuidString.lowercased()
        try writeDocument(Document(deviceID: device, session: session))
        try legacy.clear()
        try? legacy.deleteDeviceID()
    }

    private func readDocument() throws -> Document {
        let exists = FileManager.default.fileExists(atPath: vaultURL.path)
        let key = try wrappingKey(vaultExists: exists)
        guard exists else {
            let created = Document(deviceID: UUID().uuidString.lowercased(), session: nil)
            try writeDocument(created, key: key)
            return created
        }
        let data = try Data(contentsOf: vaultURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw AuthSessionStoreError.unavailable }
        let box = try AES.GCM.SealedBox(combined: envelope.sealedData)
        let plain = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(Document.self, from: plain)
    }

    private func writeDocument(_ document: Document, key: SymmetricKey? = nil) throws {
        let wrapping = try key ?? wrappingKey(vaultExists: FileManager.default.fileExists(atPath: vaultURL.path))
        let plaintext = try JSONEncoder().encode(document)
        let sealed = try AES.GCM.seal(plaintext, using: wrapping)
        guard let combined = sealed.combined else { throw AuthSessionStoreError.unavailable }
        let data = try JSONEncoder().encode(Envelope(version: 1, sealedData: combined))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: vaultURL, options: .atomic)
        try protect(vaultURL)
    }

    private func wrappingKey(vaultExists: Bool) throws -> SymmetricKey {
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else { throw AuthSessionStoreError.unavailable }
            return SymmetricKey(data: data)
        }
        guard !vaultExists else { throw AuthSessionStoreError.unavailable }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: keyURL, options: .atomic)
        try protect(keyURL)
        return key
    }

    private func protect(_ url: URL) throws {
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#elseif os(macOS)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
#endif
    }
}
