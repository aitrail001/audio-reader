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

    public var errorDescription: String? {
        switch self {
        case .keychain:
            "The account session could not be stored in Keychain."
        case .saveFailed:
            "The account session could not be saved."
        }
    }
}
