import CryptoKit
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

/// One latest server entity in a consistent initial-sync snapshot.
public struct SyncBootstrapEntity: Codable, Equatable, Sendable {
    public var sequence: Int
    public var entityType: String
    public var entityId: String
    public var operation: String
    public var revision: Int
    public var changedAt: String
    public var payload: [String: SyncJSONValue]
    public var payloadHash: String

    public init(
        sequence: Int,
        entityType: String,
        entityId: String,
        operation: String,
        revision: Int,
        changedAt: String,
        payload: [String: SyncJSONValue],
        payloadHash: String
    ) {
        self.sequence = sequence
        self.entityType = entityType
        self.entityId = entityId
        self.operation = operation
        self.revision = revision
        self.changedAt = changedAt
        self.payload = payload
        self.payloadHash = payloadHash
    }

    public var change: SyncPulledChange {
        SyncPulledChange(
            sequence: sequence,
            entityType: entityType,
            entityId: entityId,
            operation: operation,
            revision: revision,
            changedAt: changedAt,
            payload: payload
        )
    }
}

public struct SyncBootstrapResponse: Codable, Equatable, Sendable {
    public var entities: [SyncBootstrapEntity]
    public var cursor: String
    public var nextOffset: Int
    public var hasMore: Bool

    public init(entities: [SyncBootstrapEntity], cursor: String, nextOffset: Int, hasMore: Bool) {
        self.entities = entities
        self.cursor = cursor
        self.nextOffset = nextOffset
        self.hasMore = hasMore
    }
}

public enum AccountSyncPhase: String, Equatable, Sendable {
    case idle
    case paused
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
        case OutboxEntityType.assistantResult.rawValue: "Assistant results"
        case OutboxEntityType.chatMessage.rawValue: "Chat messages"
        case OutboxEntityType.studyActivity.rawValue: "Study activity"
        default: entityType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public enum AccountSyncConflictKind: String, Hashable, Sendable {
    case readerProgress
    case transcriptCorrection

    public var title: String {
        switch self {
        case .readerProgress: "Reading position"
        case .transcriptCorrection: "Transcript correction"
        }
    }

    public var resolutionHelp: String {
        switch self {
        case .readerProgress:
            "Open the affected book to compare chapter, position, device, and time, then choose where to continue."
        case .transcriptCorrection:
            "Open the affected chapter and use its correction banner to compare text, timing, and device."
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
    public var conflicts: [AccountSyncConflictKind]
    public var skippedDeletedAssetCount: Int
    public var errorMessage: String?
    public var entityProgress: [AccountSyncEntityProgress]

    public static let idle = AccountSyncStatus(phase: .idle)

    /// Readiness pauses preserve the user's requested-on preference and all local sync state.
    public static func paused(reason: String, pendingCount: Int) -> AccountSyncStatus {
        AccountSyncStatus(
            phase: .paused,
            pendingCount: pendingCount,
            errorMessage: reason
        )
    }

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
        conflicts: [AccountSyncConflictKind] = [],
        skippedDeletedAssetCount: Int = 0,
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
        self.conflicts = conflicts
        self.skippedDeletedAssetCount = skippedDeletedAssetCount
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
        conflicts: [AccountSyncConflictKind] = [],
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
            conflicts: conflicts,
            entityProgress: entityProgress
        )
    }

    public static func completed(
        uploadedCount: Int,
        appliedCount: Int,
        pendingCount: Int,
        conflictCount: Int,
        conflicts: [AccountSyncConflictKind] = [],
        skippedDeletedAssetCount: Int = 0,
        entityProgress: [AccountSyncEntityProgress]
    ) -> AccountSyncStatus {
        AccountSyncStatus(
            phase: .completed,
            completedCount: uploadedCount,
            totalCount: uploadedCount + pendingCount,
            appliedCount: appliedCount,
            pendingCount: pendingCount,
            conflictCount: conflictCount,
            conflicts: conflicts,
            skippedDeletedAssetCount: skippedDeletedAssetCount,
            entityProgress: entityProgress
        )
    }

    public var isActive: Bool {
        phase == .preparing || phase == .uploading || phase == .downloading || phase == .applying
    }

    public var requiresAttention: Bool {
        phase == .paused || phase == .failed || conflictCount > 0
    }

    public var title: String {
        switch phase {
        case .idle: "Up to date"
        case .paused: "Sync paused"
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
        case .completed where conflictCount > 0: "Choose what to keep"
        case .completed where pendingCount > 0: "Sync has pending changes"
        case .completed: "Up to date"
        case .failed: "Sync needs attention"
        }
    }

    public var detail: String {
        var parts: [String] = []
        switch phase {
        case .paused:
            if let errorMessage, !errorMessage.isEmpty { parts.append(errorMessage) }
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
        for kind in Set(conflicts).sorted(by: { $0.rawValue < $1.rawValue }) {
            let count = conflicts.filter { $0 == kind }.count
            parts.append("\(count) \(kind.title.lowercased()) conflict\(count == 1 ? "" : "s")")
        }
        if conflictCount > conflicts.count {
            let otherCount = conflictCount - conflicts.count
            parts.append("\(otherCount) other conflict\(otherCount == 1 ? "" : "s")")
        }
        if pendingCount > 0 {
            parts.append("\(pendingCount) pending")
        }
        if skippedDeletedAssetCount > 0 {
            let noun = skippedDeletedAssetCount == 1 ? "transcript" : "transcripts"
            parts.append("\(skippedDeletedAssetCount) \(noun) skipped because the book was deleted on another device")
        }
        return parts.joined(separator: " · ")
    }

    public var accessibilityDescription: String {
        let entityDetails = entityProgress
            .filter { $0.totalCount > 0 }
            .map { "\($0.title) \($0.completedCount) of \($0.totalCount)" }
        return ([title, detail] + entityDetails + resolutionHelp)
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    public var resolutionHelp: [String] {
        Set(conflicts).sorted(by: { $0.rawValue < $1.rawValue }).map(\.resolutionHelp)
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
    func publishAsset(accessToken: String, deviceID: String, asset: SyncAssetUpload) async throws
    func downloadAsset(
        accessToken: String,
        deviceID: String,
        assetID: String,
        sha256: String,
        compressedBytes: Int
    ) async throws -> URL
    func assetManifest(
        accessToken: String,
        deviceID: String,
        assetID: String
    ) async throws -> SyncAssetManifest
    func discoverAssets(
        accessToken: String,
        deviceID: String,
        kind: SyncAssetKind?,
        bookID: String?,
        chapterID: String?
    ) async throws -> [SyncAssetManifest]
    func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse
    func bootstrap(
        accessToken: String,
        deviceID: String,
        cursor: String?,
        offset: Int,
        limit: Int
    ) async throws -> SyncBootstrapResponse
    func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse
}

public extension SyncClient {
    func publishAsset(accessToken: String, deviceID: String, asset: SyncAssetUpload) async throws {
        _ = accessToken
        _ = deviceID
        _ = asset
        throw AuthClientError.problem(
            status: 503,
            code: "asset_transfer_unavailable",
            detail: "This sync client cannot publish private assets."
        )
    }

    func downloadAsset(
        accessToken: String,
        deviceID: String,
        assetID: String,
        sha256: String,
        compressedBytes: Int
    ) async throws -> URL {
        _ = accessToken
        _ = deviceID
        _ = assetID
        _ = sha256
        _ = compressedBytes
        throw AuthClientError.problem(
            status: 503,
            code: "asset_transfer_unavailable",
            detail: "This sync client cannot download private assets."
        )
    }

    func assetManifest(
        accessToken: String,
        deviceID: String,
        assetID: String
    ) async throws -> SyncAssetManifest {
        _ = accessToken
        _ = deviceID
        _ = assetID
        throw AuthClientError.problem(
            status: 503,
            code: "asset_transfer_unavailable",
            detail: "This sync client cannot discover private assets."
        )
    }

    func discoverAssets(
        accessToken: String,
        deviceID: String,
        kind: SyncAssetKind?,
        bookID: String?,
        chapterID: String?
    ) async throws -> [SyncAssetManifest] {
        _ = accessToken
        _ = deviceID
        _ = kind
        _ = bookID
        _ = chapterID
        return []
    }

    func downloadAsset(
        accessToken: String,
        deviceID: String,
        manifest: SyncAssetManifest
    ) async throws -> URL {
        try await downloadAsset(
            accessToken: accessToken,
            deviceID: deviceID,
            assetID: manifest.id,
            sha256: manifest.sha256,
            compressedBytes: manifest.compressedBytes
        )
    }

    func bootstrap(
        accessToken: String,
        deviceID: String,
        cursor: String?,
        offset: Int,
        limit: Int
    ) async throws -> SyncBootstrapResponse {
        _ = accessToken
        _ = deviceID
        _ = cursor
        _ = offset
        _ = limit
        return SyncBootstrapResponse(entities: [], cursor: "0", nextOffset: 0, hasMore: false)
    }
}

public enum SyncAssetKind: String, Codable, CaseIterable, Sendable {
    case audio
    case epub
    case cover
    case transcriptRevision
    case epubReadingPackage
    case alignmentPackage
    case mediaAnalysis
    case transcriptExport
    case accountExport
    case assistantArtifact
    case otherLargeImmutable
}

public struct SyncAssetManifest: Codable, Equatable, Sendable {
    public var id: String
    public var kind: SyncAssetKind
    public var contentType: String
    public var compressedBytes: Int
    public var originalBytes: Int
    public var sha256: String
    public var encoding: String
    public var revisionId: String?
    public var bookId: String?
    public var chapterId: String?
    public var segmentCount: Int?
    public var status: String

    public init(
        id: String,
        kind: SyncAssetKind,
        contentType: String,
        compressedBytes: Int,
        originalBytes: Int,
        sha256: String,
        encoding: String,
        revisionId: String? = nil,
        bookId: String? = nil,
        chapterId: String? = nil,
        segmentCount: Int? = nil,
        status: String = "ready"
    ) {
        self.id = id
        self.kind = kind
        self.contentType = contentType
        self.compressedBytes = compressedBytes
        self.originalBytes = originalBytes
        self.sha256 = sha256
        self.encoding = encoding
        self.revisionId = revisionId
        self.bookId = bookId
        self.chapterId = chapterId
        self.segmentCount = segmentCount
        self.status = status
    }
}

public struct SyncAssetUpload: Equatable, Sendable {
    public var kind: SyncAssetKind
    public var revisionID: String
    public var bookID: String?
    public var chapterID: String
    public var contentType: String
    public var encoding: String
    public var sha256: String
    public var originalBytes: Int
    public var segmentCount: Int
    public var fileURL: URL
    public var compressedBytes: Int
    public var deleteFileAfterUpload: Bool

    public init(
        revisionID: String,
        bookID: String? = nil,
        chapterID: String,
        contentType: String = "application/json",
        encoding: String = "identity-json-v1",
        sha256: String,
        originalBytes: Int,
        segmentCount: Int,
        fileURL: URL,
        compressedBytes: Int,
        deleteFileAfterUpload: Bool = false
    ) {
        self.kind = .transcriptRevision
        self.revisionID = revisionID
        self.bookID = bookID
        self.chapterID = chapterID
        self.contentType = contentType
        self.encoding = encoding
        self.sha256 = sha256
        self.originalBytes = originalBytes
        self.segmentCount = segmentCount
        self.fileURL = fileURL
        self.compressedBytes = compressedBytes
        self.deleteFileAfterUpload = deleteFileAfterUpload
    }

    public init(
        kind: SyncAssetKind,
        revisionID: String? = nil,
        bookID: String? = nil,
        chapterID: String? = nil,
        contentType: String,
        encoding: String = "identity",
        sha256: String,
        originalBytes: Int,
        segmentCount: Int? = nil,
        fileURL: URL,
        compressedBytes: Int,
        deleteFileAfterUpload: Bool = false
    ) {
        self.kind = kind
        self.revisionID = revisionID ?? UUID().uuidString.lowercased()
        self.bookID = bookID
        self.chapterID = chapterID ?? ""
        self.contentType = contentType
        self.encoding = encoding
        self.sha256 = sha256
        self.originalBytes = originalBytes
        self.segmentCount = segmentCount ?? 0
        self.fileURL = fileURL
        self.compressedBytes = compressedBytes
        self.deleteFileAfterUpload = deleteFileAfterUpload
    }
}

public struct SyncAssetFileDigest: Equatable, Sendable {
    public var sha256: String
    public var byteCount: Int
    public var maximumChunkBytes: Int
}

public enum SyncAssetFileIO {
    public static let chunkBytes = 64 * 1024

    /// Hashes immutable asset files incrementally so large media never becomes one `Data` value.
    public static func digest(fileURL: URL) throws -> SyncAssetFileDigest {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        var largest = 0
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
            let addition = total.addingReportingOverflow(chunk.count)
            guard !addition.overflow else { throw CocoaError(.fileReadTooLarge) }
            total = addition.partialValue
            largest = max(largest, chunk.count)
        }
        return SyncAssetFileDigest(
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: total,
            maximumChunkBytes: largest
        )
    }
}

public struct AccountSyncRuntime: Sendable {
    public var client: any SyncClient
    public var outbox: any SyncOutboxRepository
    public var cursor: any SyncCursorStoring
    public var versions: (any SyncEntityVersionStoring)?
    public var snapshot: @Sendable () throws -> [OutboxMutation]
    public var assetUploads: @Sendable (URL) throws -> [SyncAssetUpload]
    public var applyPage: @Sendable ([SyncPulledChange], [SyncEntityVersion], String) throws -> Void
    public var handleConflict: @Sendable (OutboxMutation, Int64) throws -> Void
    /// Returns only durable choices that remain semantically different after pull.
    public var reviewConflicts: @Sendable () throws -> [AccountSyncConflictKind]

    public init(
        client: any SyncClient,
        outbox: any SyncOutboxRepository,
        cursor: any SyncCursorStoring,
        versions: (any SyncEntityVersionStoring)? = nil,
        snapshot: @escaping @Sendable () throws -> [OutboxMutation] = { [] },
        assetUploads: @escaping @Sendable (URL) throws -> [SyncAssetUpload] = { _ in [] },
        applyChange: @escaping @Sendable (SyncPulledChange) throws -> Void = { _ in },
        applyPage: (@Sendable ([SyncPulledChange], [SyncEntityVersion], String) throws -> Void)? = nil,
        handleConflict: @escaping @Sendable (OutboxMutation, Int64) throws -> Void = { _, _ in },
        reviewConflicts: @escaping @Sendable () throws -> [AccountSyncConflictKind] = { [] }
    ) {
        self.client = client
        self.outbox = outbox
        self.cursor = cursor
        self.versions = versions
        self.snapshot = snapshot
        self.assetUploads = assetUploads
        self.applyPage = applyPage ?? { changes, pageVersions, nextCursor in
            for change in changes { try applyChange(change) }
            for version in pageVersions { try versions?.saveVersion(version) }
            try cursor.saveCursor(nextCursor)
        }
        self.handleConflict = handleConflict
        self.reviewConflicts = reviewConflicts
    }
}

public enum SyncJSONCoding {
    public static let tombstonePayload = Data("{\"_deleted\":true}".utf8)

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }

    public static func payloadsMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = try? decoder.decode([String: SyncJSONValue].self, from: lhs)
        let right = try? decoder.decode([String: SyncJSONValue].self, from: rhs)
        if let left, let right {
            return left == right
        }
        return lhs == rhs
    }

    public static func data(from payload: [String: SyncJSONValue]) -> Data {
        (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    public static func payloadHash(_ data: Data) -> String {
        // Server manifests hash canonical JSON. Decode and re-encode object payloads so key
        // order and insignificant whitespace do not turn equal records into uploads.
        let bytes: Data
        if let payload = try? decoder.decode([String: SyncJSONValue].self, from: data) {
            bytes = self.data(from: payload)
        } else {
            // Preserve byte-for-byte hashing for malformed/legacy non-JSON payloads.
            bytes = data
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension SyncPulledChange {
    /// Parent upserts precede dependents; vocabulary tombstones follow them so deletion wins.
    public static func applying(_ changes: [SyncPulledChange]) -> [SyncPulledChange] {
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
        var object = (try? JSONDecoder().decode([String: SyncJSONValue].self, from: payload)) ?? [:]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if entityType == .assistantResult,
           case .object(var result)? = object["result"] {
            if case .string(let legacyID)? = result["id"],
               legacyAssistantEntityID(for: legacyID) == entityID.lowercased() {
                // Older sentence results used their content hash locally. The database owns a UUID
                // identity, so only the matching deterministic UUID replaces that redundant wire ID.
                result["id"] = .string(entityID.lowercased())
            }
            // Legacy JSONEncoder rows used seconds from Apple's 2001 reference date, while PostgreSQL
            // requires timestamp text. Normalize only finite numbers so malformed values stay rejectable.
            for key in ["createdAt", "decidedAt"] {
                guard case .number(let seconds)? = result[key], seconds.isFinite else { continue }
                result[key] = .string(formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds)))
            }
            object["result"] = .object(result)
        }
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

    private func legacyAssistantEntityID(for resultID: String) -> String? {
        guard resultID.count == 64, resultID.allSatisfy(\.isHexDigit) else { return nil }
        let digest = SHA256.hash(data: Data("assistant-result:\(resultID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    }
}
