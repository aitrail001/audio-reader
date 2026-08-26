import Foundation

/// Typed identifier shared by local persistence and the remote contract.
/// Codable as a JSON string so legacy stored IDs keep decoding.
public protocol StableDomainIdentifier: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
    static func generate() -> Self
    static func remote(rawValue: String) -> Self?
}

public struct StableID<Kind: Sendable>: StableDomainIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Unique and independent of any local filesystem location.
    public static func generate() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())
    }

    /// Accepts a persisted remote ID. Absolute local paths are never valid remote identities.
    public static func remote(rawValue: String) -> Self? {
        guard !isAbsoluteLocalPath(rawValue) else { return nil }
        return Self(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum UserIDTag: Sendable {}
public enum DeviceIDTag: Sendable {}
public enum BookIDTag: Sendable {}
public enum AssetIDTag: Sendable {}
public enum ChapterIDTag: Sendable {}
public enum TranscriptRevisionIDTag: Sendable {}
public enum VocabularyOccurrenceIDTag: Sendable {}
public enum ReviewEventIDTag: Sendable {}
public enum MutationIDTag: Sendable {}

public typealias UserID = StableID<UserIDTag>
public typealias DeviceID = StableID<DeviceIDTag>
public typealias BookID = StableID<BookIDTag>
public typealias AssetID = StableID<AssetIDTag>
public typealias ChapterID = StableID<ChapterIDTag>
public typealias TranscriptRevisionID = StableID<TranscriptRevisionIDTag>
public typealias VocabularyOccurrenceID = StableID<VocabularyOccurrenceIDTag>
public typealias ReviewEventID = StableID<ReviewEventIDTag>
public typealias MutationID = StableID<MutationIDTag>

/// Monotonic server revision; distinct from UUID entity IDs.
public struct ServerVersion: Hashable, Sendable, Codable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static let zero = ServerVersion(0)

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private func isAbsoluteLocalPath(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("/") { return true }
    if trimmed.hasPrefix("~") { return true }
    if trimmed.lowercased().hasPrefix("file:") { return true }
    return false
}
