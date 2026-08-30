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

public enum AccountSyncPhase: String, Equatable, Sendable {
    case idle
    case preparing
    case uploading
    case downloading
    case applying
    case completed
    case failed
}

public struct AccountSyncEntityProgress: Equatable, Sendable, Identifiable {
    public var entityType: String
    public var completedCount: Int
    public var totalCount: Int

    public var id: String { entityType }

    public init(entityType: String, completedCount: Int, totalCount: Int) {
        self.entityType = entityType
        self.completedCount = completedCount
        self.totalCount = totalCount
    }

    public var title: String {
        switch entityType {
        case OutboxEntityType.settings.rawValue: "Settings"
        case OutboxEntityType.book.rawValue: "Books"
        case OutboxEntityType.chapter.rawValue: "Chapters"
        case OutboxEntityType.progress.rawValue: "Reading progress"
        case OutboxEntityType.vocabulary.rawValue: "Vocabulary"
        case OutboxEntityType.lexemeState.rawValue: "Known words"
        case OutboxEntityType.reviewEvent.rawValue: "Reviews"
        case OutboxEntityType.transcript.rawValue: "Transcripts"
        case OutboxEntityType.transcriptOverlay.rawValue: "Transcript corrections"
        case OutboxEntityType.translationDecision.rawValue: "Translation decisions"
        case OutboxEntityType.summaryDecision.rawValue: "Summary decisions"
        case OutboxEntityType.chatMessage.rawValue: "Chat messages"
        case OutboxEntityType.studyActivity.rawValue: "Study activity"
        default: entityType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Observable sync progress contains only counts and entity categories; it must never expose
/// learning content, mutation payloads, credentials, or server response bodies to the UI.
public struct AccountSyncStatus: Equatable, Sendable {
    public var phase: AccountSyncPhase
    public var entityType: String?
    public var completedCount: Int
    public var totalCount: Int
    public var appliedCount: Int
    public var batchIndex: Int?
    public var batchCount: Int?
    public var pendingCount: Int
    public var conflictCount: Int
    public var errorMessage: String?
    public var entityProgress: [AccountSyncEntityProgress]

    public static let idle = AccountSyncStatus(phase: .idle)

    public init(
        phase: AccountSyncPhase,
        entityType: String? = nil,
        completedCount: Int = 0,
        totalCount: Int = 0,
        appliedCount: Int = 0,
        batchIndex: Int? = nil,
        batchCount: Int? = nil,
        pendingCount: Int = 0,
        conflictCount: Int = 0,
        errorMessage: String? = nil,
        entityProgress: [AccountSyncEntityProgress] = []
    ) {
        self.phase = phase
        self.entityType = entityType
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.appliedCount = appliedCount
        self.batchIndex = batchIndex
        self.batchCount = batchCount
        self.pendingCount = pendingCount
        self.conflictCount = conflictCount
        self.errorMessage = errorMessage
        self.entityProgress = entityProgress
    }

    public static func uploading(
        entityType: String?,
        completedCount: Int,
        totalCount: Int,
        batchIndex: Int,
        batchCount: Int,
        pendingCount: Int,
        conflictCount: Int = 0,
        entityProgress: [AccountSyncEntityProgress]
    ) -> AccountSyncStatus {
        AccountSyncStatus(
            phase: .uploading,
            entityType: entityType,
            completedCount: completedCount,
            totalCount: totalCount,
            batchIndex: batchIndex,
            batchCount: batchCount,
            pendingCount: pendingCount,
            conflictCount: conflictCount,
            entityProgress: entityProgress
        )
    }

    public static func completed(
        uploadedCount: Int,
        appliedCount: Int,
        pendingCount: Int,
        conflictCount: Int,
        entityProgress: [AccountSyncEntityProgress]
    ) -> AccountSyncStatus {
        AccountSyncStatus(
            phase: .completed,
            completedCount: uploadedCount,
            totalCount: uploadedCount + pendingCount,
            appliedCount: appliedCount,
            pendingCount: pendingCount,
            conflictCount: conflictCount,
            entityProgress: entityProgress
        )
    }

    public var isActive: Bool {
        phase == .preparing || phase == .uploading || phase == .downloading || phase == .applying
    }

    public var requiresAttention: Bool {
        phase == .failed || conflictCount > 0
    }

    public var title: String {
        switch phase {
        case .idle: "Up to date"
        case .preparing: "Preparing sync"
        case .uploading:
            if let entityType {
                "Uploading \(AccountSyncEntityProgress(entityType: entityType, completedCount: 0, totalCount: 0).title.lowercased())"
            } else {
                "Uploading learning data"
            }
        case .downloading: "Downloading changes"
        case .applying:
            if let entityType {
                "Applying \(AccountSyncEntityProgress(entityType: entityType, completedCount: 0, totalCount: 0).title.lowercased())"
            } else {
                "Applying downloaded changes"
            }
        case .completed where conflictCount > 0: "Sync conflicts need review"
        case .completed where pendingCount > 0: "Sync has pending changes"
        case .completed: "Up to date"
        case .failed: "Sync needs attention"
        }
    }

    public var detail: String {
        var parts: [String] = []
        switch phase {
        case .preparing:
            parts.append("Checking local changes")
        case .uploading:
            parts.append("\(completedCount) of \(totalCount) changes")
            if let batchIndex, let batchCount {
                parts.append("batch \(batchIndex) of \(batchCount)")
            }
        case .downloading:
            if let batchIndex {
                parts.append("page \(batchIndex)")
            }
            parts.append("\(completedCount) downloaded")
        case .applying:
            parts.append("\(completedCount) of \(totalCount) changes")
        case .completed:
            if completedCount > 0 { parts.append("\(completedCount) uploaded") }
            if appliedCount > 0 { parts.append("\(appliedCount) applied") }
        case .failed:
            if let errorMessage, !errorMessage.isEmpty { parts.append(errorMessage) }
        case .idle:
            break
        }
        if conflictCount > 0 {
            parts.append("\(conflictCount) conflict\(conflictCount == 1 ? "" : "s")")
        }
        if pendingCount > 0 {
            parts.append("\(pendingCount) pending")
        }
        return parts.joined(separator: " · ")
    }

    public var accessibilityDescription: String {
        let entityDetails = entityProgress
            .filter { $0.totalCount > 0 }
            .map { "\($0.title) \($0.completedCount) of \($0.totalCount)" }
        return ([title, detail] + entityDetails)
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
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
    public var handleConflict: @Sendable (OutboxMutation, Int64) throws -> Void

    public init(
        client: any SyncClient,
        outbox: any SyncOutboxRepository,
        cursor: any SyncCursorStoring,
        versions: (any SyncEntityVersionStoring)? = nil,
        snapshot: @escaping @Sendable () throws -> [OutboxMutation] = { [] },
        applyChange: @escaping @Sendable (SyncPulledChange) throws -> Void = { _ in },
        handleConflict: @escaping @Sendable (OutboxMutation, Int64) throws -> Void = { _, _ in }
    ) {
        self.client = client
        self.outbox = outbox
        self.cursor = cursor
        self.versions = versions
        self.snapshot = snapshot
        self.applyChange = applyChange
        self.handleConflict = handleConflict
    }
}

enum SyncJSONCoding {
    static let tombstonePayload = Data("{\"_deleted\":true}".utf8)

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
    /// Parent upserts precede dependents; vocabulary tombstones follow them so deletion wins.
    static func applying(_ changes: [SyncPulledChange]) -> [SyncPulledChange] {
        let rank: [String: Int] = [
            OutboxEntityType.book.rawValue: 0,
            OutboxEntityType.chapter.rawValue: 1,
            OutboxEntityType.vocabulary.rawValue: 2,
            OutboxEntityType.settings.rawValue: 3,
            OutboxEntityType.transcript.rawValue: 4,
            OutboxEntityType.transcriptOverlay.rawValue: 5,
            OutboxEntityType.lexemeState.rawValue: 6,
            OutboxEntityType.progress.rawValue: 7,
            OutboxEntityType.reviewEvent.rawValue: 8
        ]
        return changes.sorted { lhs, rhs in
            // A vocabulary upsert is a dependency, while its tombstone must run after
            // dependent progress/reviews so one pull page ends in the deleted state.
            let left = lhs.entityType == OutboxEntityType.vocabulary.rawValue &&
                lhs.operation == OutboxOperation.delete.rawValue ? 9 : rank[lhs.entityType] ?? 50
            let right = rhs.entityType == OutboxEntityType.vocabulary.rawValue &&
                rhs.operation == OutboxOperation.delete.rawValue ? 9 : rank[rhs.entityType] ?? 50
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
