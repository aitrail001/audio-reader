import Foundation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

public struct SyncPushMutation: Codable, Equatable, Sendable {
    public var mutationId: String
    public var entityType: String
    public var entityId: String
    public var operation: String
    public var baseRevision: Int
    public var occurredAt: String
    public var payload: [String: SyncJSONValue]

    public init(
        mutationId: String,
        entityType: String,
        entityId: String,
        operation: String,
        baseRevision: Int,
        occurredAt: String,
        payload: [String: SyncJSONValue]
    ) {
        self.mutationId = mutationId
        self.entityType = entityType
        self.entityId = entityId
        self.operation = operation
        self.baseRevision = baseRevision
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

public struct SyncPushRequest: Codable, Equatable, Sendable {
    public var deviceId: String
    public var batchId: String
    public var baseCursor: String?
    public var mutations: [SyncPushMutation]

    public init(deviceId: String, batchId: String, baseCursor: String? = nil, mutations: [SyncPushMutation]) {
        self.deviceId = deviceId
        self.batchId = batchId
        self.baseCursor = baseCursor
        self.mutations = mutations
    }
}

public struct SyncMutationResult: Codable, Equatable, Sendable {
    public var mutationId: String
    public var status: String
    public var entityRevision: Int?
    public var problem: APIProblem?

    public init(mutationId: String, status: String, entityRevision: Int? = nil, problem: APIProblem? = nil) {
        self.mutationId = mutationId
        self.status = status
        self.entityRevision = entityRevision
        self.problem = problem
    }
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
    public var batchId: String
    public var results: [SyncMutationResult]
    public var cursor: String

    public init(batchId: String, results: [SyncMutationResult], cursor: String) {
        self.batchId = batchId
        self.results = results
        self.cursor = cursor
    }
}

public struct SyncPulledChange: Codable, Equatable, Sendable {
    public var sequence: Int
    public var entityType: String
    public var entityId: String
    public var operation: String
    public var revision: Int
    public var changedAt: String
    public var payload: [String: SyncJSONValue]

    public init(
        sequence: Int,
        entityType: String,
        entityId: String,
        operation: String,
        revision: Int,
        changedAt: String,
        payload: [String: SyncJSONValue]
    ) {
        self.sequence = sequence
        self.entityType = entityType
        self.entityId = entityId
        self.operation = operation
        self.revision = revision
        self.changedAt = changedAt
        self.payload = payload
    }
}

public struct SyncPullResponse: Codable, Equatable, Sendable {
    public var changes: [SyncPulledChange]
    public var cursor: String
    public var hasMore: Bool

    public init(changes: [SyncPulledChange], cursor: String, hasMore: Bool) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public enum SyncJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: SyncJSONValue])
    case array([SyncJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: SyncJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SyncJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

public protocol SyncClient: Sendable {
    func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse
    func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse
}

public struct AccountSyncRuntime: Sendable {
    public var client: any SyncClient
    public var outbox: any SyncOutboxRepository
    public var cursor: any SyncCursorStoring
    public var versions: (any SyncEntityVersionStoring)?
    public var snapshot: @Sendable () throws -> [OutboxMutation]
    public var applyChange: @Sendable (SyncPulledChange) throws -> Void

    public init(
        client: any SyncClient,
        outbox: any SyncOutboxRepository,
        cursor: any SyncCursorStoring,
        versions: (any SyncEntityVersionStoring)? = nil,
        snapshot: @escaping @Sendable () throws -> [OutboxMutation] = { [] },
        applyChange: @escaping @Sendable (SyncPulledChange) throws -> Void = { _ in }
    ) {
        self.client = client
        self.outbox = outbox
        self.cursor = cursor
        self.versions = versions
        self.snapshot = snapshot
        self.applyChange = applyChange
    }
}

enum SyncJSONCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }

    static func payloadsMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = try? decoder.decode([String: SyncJSONValue].self, from: lhs)
        let right = try? decoder.decode([String: SyncJSONValue].self, from: rhs)
        if let left, let right {
            return left == right
        }
        return lhs == rhs
    }

    static func data(from payload: [String: SyncJSONValue]) -> Data {
        (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }
}

extension SyncPulledChange {
    /// Books and vocabulary first so progress/reviews can attach to rows that exist.
    static func applying(_ changes: [SyncPulledChange]) -> [SyncPulledChange] {
        let rank: [String: Int] = [
            OutboxEntityType.book.rawValue: 0,
            OutboxEntityType.chapter.rawValue: 1,
            OutboxEntityType.vocabulary.rawValue: 2,
            OutboxEntityType.settings.rawValue: 3,
            OutboxEntityType.transcript.rawValue: 4,
            OutboxEntityType.lexemeState.rawValue: 5,
            OutboxEntityType.progress.rawValue: 6,
            OutboxEntityType.reviewEvent.rawValue: 7
        ]
        return changes.sorted { lhs, rhs in
            let left = rank[lhs.entityType] ?? 50
            let right = rank[rhs.entityType] ?? 50
            if left != right { return left < right }
            return lhs.sequence < rhs.sequence
        }
    }
}

extension OutboxMutation {
    func productMutation() throws -> SyncPushMutation {
        let object = (try? JSONDecoder().decode([String: SyncJSONValue].self, from: payload)) ?? [:]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return SyncPushMutation(
            mutationId: id.rawValue,
            entityType: entityType.rawValue,
            entityId: entityID,
            operation: operation.rawValue,
            baseRevision: Int(baseRevision.rawValue),
            occurredAt: formatter.string(from: occurredAt),
            payload: object
        )
    }
}
