import CryptoKit
import Foundation

public struct ProductSyncClient: SyncClient, Sendable {
    private let http: any HTTPPerforming
    private let baseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(http: any HTTPPerforming, baseURL: URL = ProductAPI.defaultBaseURL) {
        self.http = http
        self.baseURL = baseURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public init(baseURL: URL) {
        self.init(http: LiveHTTPClient(baseURL: baseURL), baseURL: baseURL)
    }

    public func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        let data = try encoder.encode(request)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try await send(
            method: "POST",
            path: "/v2/sync/push",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-Device-Id": deviceID,
                "Idempotency-Key": request.batchId,
                // Lets the Worker fingerprint a large transcript without cloning its body.
                "X-Content-SHA256": digest
            ],
            data: data
        )
    }

    public func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        var components = URLComponents()
        components.path = "/v2/sync/pull"
        components.queryItems = [
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let path = components.string ?? "/v2/sync/pull"
        return try await send(
            method: "GET",
            path: path,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-Device-Id": deviceID
            ]
        )
    }

    public func bootstrap(
        accessToken: String,
        deviceID: String,
        cursor: String?,
        offset: Int,
        limit: Int
    ) async throws -> SyncBootstrapResponse {
        var components = URLComponents()
        components.path = "/v2/sync/bootstrap"
        components.queryItems = [
            cursor.map { URLQueryItem(name: "cursor", value: $0) },
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ].compactMap { $0 }
        return try await send(
            method: "GET",
            path: components.string ?? "/v2/sync/bootstrap",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-Device-Id": deviceID
            ]
        )
    }

    /// Transcript bytes use the private asset lifecycle; sync JSON never carries them.
    public func publishAsset(accessToken: String, deviceID: String, asset: SyncAssetUpload) async throws {
        let ticket: AssetUploadTicket = try await send(
            method: "POST",
            path: "/v2/assets/uploads",
            headers: assetHeaders(accessToken: accessToken, deviceID: deviceID, key: UUID().uuidString),
            body: AssetUploadDraft(asset: asset)
        )
        if ticket.ready == true { return }
        let uploadTarget = try transferTarget(ticket.url)
        var uploadHeaders = ticket.headers ?? ["Content-Type": asset.contentType]
        uploadHeaders["Content-Length"] = String(asset.compressedBytes)
        if uploadTarget.authenticated {
            uploadHeaders["Authorization"] = "Bearer \(accessToken)"
        }
        let upload = try await http.upload(
            HTTPRequest(
                method: "PUT",
                path: uploadTarget.path,
                headers: uploadHeaders,
                body: nil
            ),
            fromFile: asset.fileURL
        )
        guard (200..<300).contains(upload.statusCode) else {
            throw mapProblem(status: upload.statusCode, body: upload.body)
        }
        let _: ReadyAsset = try await send(
            method: "POST",
            path: "/v2/assets/uploads/\(ticket.uploadId)/complete",
            headers: assetHeaders(accessToken: accessToken, deviceID: deviceID, key: ticket.uploadId),
            body: EmptyRequest()
        )
    }

    public func discoverAssets(
        accessToken: String,
        deviceID: String,
        kind: SyncAssetKind?,
        bookID: String?,
        chapterID: String?
    ) async throws -> [SyncAssetManifest] {
        var components = URLComponents()
        components.path = "/v2/assets"
        components.queryItems = [
            kind.map { URLQueryItem(name: "kind", value: $0.rawValue) },
            bookID.map { URLQueryItem(name: "bookId", value: $0) },
            chapterID.map { URLQueryItem(name: "chapterId", value: $0) }
        ].compactMap { $0 }
        let response: AssetList = try await send(
            method: "GET",
            path: components.string ?? "/v2/assets",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-Device-Id": deviceID
            ]
        )
        return response.assets
    }

    public func assetManifest(
        accessToken: String,
        deviceID: String,
        assetID: String
    ) async throws -> SyncAssetManifest {
        try await send(
            method: "GET",
            path: "/v2/assets/\(assetID)",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-Device-Id": deviceID
            ]
        )
    }

    /// Downloaded bytes remain invisible to local persistence until size and SHA-256 agree.
    public func downloadAsset(
        accessToken: String,
        deviceID: String,
        assetID: String,
        sha256: String,
        compressedBytes: Int
    ) async throws -> URL {
        let ticket: AssetDownloadTicket = try await send(
            method: "POST",
            path: "/v2/assets/\(assetID)/download",
            headers: assetHeaders(accessToken: accessToken, deviceID: deviceID, key: UUID().uuidString),
            body: EmptyRequest()
        )
        let downloadTarget = try transferTarget(ticket.url)
        let response = try await http.download(
            HTTPRequest(
                method: "GET",
                path: downloadTarget.path,
                headers: downloadTarget.authenticated
                    ? ["Authorization": "Bearer \(accessToken)"]
                    : [:],
                body: nil
            )
        )
        defer {
            if !(200..<300).contains(response.statusCode) {
                try? FileManager.default.removeItem(at: response.fileURL)
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = (try? Self.readBoundedProblemBody(response.fileURL)) ?? Data()
            throw mapProblem(status: response.statusCode, body: body)
        }
        let digest = try SyncAssetFileIO.digest(fileURL: response.fileURL)
        guard digest.byteCount == compressedBytes, digest.sha256 == sha256 else {
            try? FileManager.default.removeItem(at: response.fileURL)
            throw AuthClientError.problem(
                status: 422,
                code: "asset_integrity_failed",
                detail: "Downloaded asset integrity verification failed."
            )
        }
        return response.fileURL
    }

    private static func readBoundedProblemBody(_ fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return try handle.read(upToCount: 65_537) ?? Data()
    }

    private func assetHeaders(accessToken: String, deviceID: String, key: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "X-Device-Id": deviceID,
            "Idempotency-Key": key
        ]
    }

    /// Only the API origin receives the bearer token; external object storage must use its signed URL alone.
    private func transferTarget(_ value: String) throws -> (path: String, authenticated: Bool) {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { throw AuthClientError.invalidResponse }
        let apiScheme = baseURL.scheme?.lowercased()
        let apiHost = baseURL.host?.lowercased()
        let sameOrigin = scheme == apiScheme && host == apiHost && effectivePort(url) == effectivePort(baseURL)
        guard sameOrigin || scheme == "https" else { throw AuthClientError.invalidResponse }
        return (url.absoluteString, sameOrigin)
    }

    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }

    private func send<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        headers: [String: String],
        body: Body
    ) async throws -> Response {
        try await send(method: method, path: path, headers: headers, data: try encoder.encode(body))
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        headers: [String: String],
        data: Data? = nil
    ) async throws -> Response {
        var merged = headers
        merged["Accept"] = "application/json"
        if data != nil {
            merged["Content-Type"] = "application/json"
        }
        let response = try await http.send(HTTPRequest(method: method, path: path, headers: merged, body: data))
        guard (200..<300).contains(response.statusCode) else {
            throw mapProblem(status: response.statusCode, body: response.body)
        }
        do {
            return try decoder.decode(Response.self, from: response.body)
        } catch {
            throw AuthClientError.invalidResponse
        }
    }

    private func mapProblem(status: Int, body: Data) -> AuthClientError {
        let problem = try? decoder.decode(APIProblem.self, from: body)
        let detail = problem?.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? problem?.title
            ?? "Sync request failed (\(status))."
        let code = problem?.code ?? "error"
        if status == 401 {
            return .unauthorized(detail)
        }
        if code == "device_revoked" {
            return .deviceRevoked(detail)
        }
        return .problem(status: status, code: code, detail: detail)
    }
}

private struct AssetUploadDraft: Encodable {
    var kind: String
    var contentType: String
    var encoding: String
    var compressedBytes: Int
    var originalBytes: Int
    var sha256: String
    var revisionId: String?
    var bookId: String?
    var chapterId: String?
    var segmentCount: Int?
    var fileName: String

    init(asset: SyncAssetUpload) {
        kind = asset.kind.rawValue
        contentType = asset.contentType
        encoding = asset.encoding
        compressedBytes = asset.compressedBytes
        originalBytes = asset.originalBytes
        sha256 = asset.sha256
        revisionId = asset.kind == .transcriptRevision ? asset.revisionID : nil
        bookId = asset.bookID
        chapterId = asset.chapterID.isEmpty ? nil : asset.chapterID
        segmentCount = asset.kind == .transcriptRevision ? asset.segmentCount : nil
        fileName = asset.fileURL.lastPathComponent
    }
}

private struct AssetUploadTicket: Decodable {
    var uploadId: String
    var url: String
    var ready: Bool?
    var headers: [String: String]?
}

private struct AssetList: Decodable {
    var assets: [SyncAssetManifest]
}

private struct ReadyAsset: Decodable {
    var id: String
    var status: String
}

private struct AssetDownloadTicket: Decodable {
    var url: String
}

private struct EmptyRequest: Encodable {}

public final class FakeSyncClient: SyncClient, @unchecked Sendable {
    public private(set) var pushed: [SyncPushRequest] = []
    public private(set) var pulledCursors: [String] = []
    public var pullChanges: [SyncPulledChange] = []
    public var pullCursor: String = "0"
    public var pullHasMore = false
    public var pullPages: [SyncPullResponse] = []
    public var failPull = false
    public var bootstrapPages: [SyncBootstrapResponse] = []
    public var pushStatus: String = "applied"
    public var pushStatuses: [String] = []
    public var conflictRevision: Int?
    public var echoPublishedAssets = false
    public private(set) var publishedAssets: [SyncAssetUpload] = []
    public private(set) var manifestLookups: [String] = []
    public private(set) var downloadedAssetIDs: [String] = []
    public private(set) var discoveryQueryCount = 0
    private var publishedAssetBodies: [String: Data] = [:]
    private var publishedAssetFiles: [String: URL] = [:]
    private var assetManifests: [String: SyncAssetManifest] = [:]
    private let lock = NSLock()

    public init() {}

    public func seedAssetBody(
        assetID: String,
        bytes: Data,
        kind: SyncAssetKind = .transcriptRevision
    ) {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        withLock {
            publishedAssetBodies[assetID] = bytes
            assetManifests[assetID] = SyncAssetManifest(
                id: assetID,
                kind: kind,
                contentType: kind == .transcriptRevision ? "application/json" : "application/octet-stream",
                compressedBytes: bytes.count,
                originalBytes: bytes.count,
                sha256: digest,
                encoding: kind == .transcriptRevision ? "identity-json-v1" : "identity",
                revisionId: assetID,
                segmentCount: kind == .transcriptRevision ? 0 : nil
            )
        }
    }

    public func publishAsset(accessToken: String, deviceID: String, asset: SyncAssetUpload) async throws {
        _ = accessToken
        _ = deviceID
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderFakeAsset-\(UUID().uuidString).object")
        try FileManager.default.copyItem(at: asset.fileURL, to: copy)
        withLock {
            publishedAssets.append(asset)
            guard echoPublishedAssets else {
                try? FileManager.default.removeItem(at: copy)
                return
            }
            publishedAssetFiles[asset.revisionID] = copy
            assetManifests[asset.revisionID] = SyncAssetManifest(
                id: asset.revisionID, kind: asset.kind, contentType: asset.contentType,
                compressedBytes: asset.compressedBytes, originalBytes: asset.originalBytes,
                sha256: asset.sha256, encoding: asset.encoding, revisionId: asset.revisionID,
                bookId: asset.bookID, chapterId: asset.chapterID.isEmpty ? nil : asset.chapterID,
                segmentCount: asset.kind == .transcriptRevision ? asset.segmentCount : nil
            )
            pullCursor = String((Int(pullCursor) ?? 0) + 1)
            pullChanges.append(
                SyncPulledChange(
                    sequence: Int(pullCursor) ?? 1,
                    entityType: asset.kind == .transcriptRevision
                        ? OutboxEntityType.transcript.rawValue
                        : OutboxEntityType.asset.rawValue,
                    entityId: asset.revisionID,
                    operation: OutboxOperation.upsert.rawValue,
                    revision: 1,
                    changedAt: "2026-08-31T00:00:00Z",
                    payload: [
                        "assetId": .string(asset.revisionID),
                        "kind": .string(asset.kind.rawValue),
                        "revisionId": .string(asset.revisionID),
                        "chapterId": .string(asset.chapterID),
                        "sha256": .string(asset.sha256),
                        "encoding": .string(asset.encoding),
                        "compressedBytes": .number(Double(asset.compressedBytes)),
                        "originalBytes": .number(Double(asset.originalBytes)),
                        "segmentCount": .number(Double(asset.segmentCount)),
                    ]
                )
            )
        }
    }

    public func downloadAsset(
        accessToken: String,
        deviceID: String,
        assetID: String,
        sha256: String,
        compressedBytes: Int
    ) async throws -> URL {
        _ = accessToken
        _ = deviceID
        let source = try withLock { () throws -> URL in
            downloadedAssetIDs.append(assetID)
            if let file = publishedAssetFiles[assetID] { return file }
            guard let bytes = publishedAssetBodies[assetID] else {
                throw AuthClientError.problem(status: 404, code: "asset_missing", detail: "Asset is missing.")
            }
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard bytes.count == compressedBytes, actual == sha256 else {
                throw AuthClientError.problem(
                    status: 422,
                    code: "asset_integrity_failed",
                    detail: "Downloaded asset integrity verification failed."
                )
            }
            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioReaderFakeSeed-\(UUID().uuidString).object")
            try bytes.write(to: source)
            return source
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderFakeDownload-\(UUID().uuidString).object")
        try FileManager.default.copyItem(at: source, to: destination)
        let digest = try SyncAssetFileIO.digest(fileURL: destination)
        guard digest.byteCount == compressedBytes, digest.sha256 == sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw AuthClientError.problem(
                status: 422,
                code: "asset_integrity_failed",
                detail: "Downloaded asset integrity verification failed."
            )
        }
        return destination
    }

    public func assetManifest(
        accessToken: String,
        deviceID: String,
        assetID: String
    ) async throws -> SyncAssetManifest {
        _ = accessToken
        _ = deviceID
        return try withLock {
            manifestLookups.append(assetID)
            guard let manifest = assetManifests[assetID] else {
                throw AuthClientError.problem(status: 404, code: "asset_missing", detail: "Asset is missing.")
            }
            return manifest
        }
    }

    public func discoverAssets(
        accessToken: String,
        deviceID: String,
        kind: SyncAssetKind?,
        bookID: String?,
        chapterID: String?
    ) async throws -> [SyncAssetManifest] {
        _ = accessToken; _ = deviceID; _ = bookID; _ = chapterID
        return withLock {
            discoveryQueryCount += 1
            let explicit = assetManifests.values.filter { kind == nil || $0.kind == kind }
            if !explicit.isEmpty { return Array(explicit.prefix(500)) }
            guard let kind else { return [] }
            return publishedAssetBodies.map { id, bytes in
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let segmentCount: Int? = kind == .transcriptRevision
                    ? ((try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["segments"] as? [Any])?.count
                    : nil
                return SyncAssetManifest(
                    id: id, kind: kind,
                    contentType: kind == .transcriptRevision ? "application/json" : "application/octet-stream",
                    compressedBytes: bytes.count, originalBytes: bytes.count, sha256: digest,
                    encoding: kind == .transcriptRevision ? "identity-json-v1" : "identity",
                    revisionId: id, segmentCount: segmentCount
                )
            }
        }
    }

    public func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        _ = accessToken
        _ = deviceID
        return withLock {
            pushed.append(request)
            let status = pushStatuses.isEmpty ? pushStatus : pushStatuses.removeFirst()
            let results = request.mutations.map { mutation in
                let revision: Int
                if status == "conflict" {
                    revision = conflictRevision ?? max(mutation.baseRevision, 1)
                } else {
                    revision = mutation.baseRevision + 1
                }
                return SyncMutationResult(
                    mutationId: mutation.mutationId,
                    status: status,
                    entityRevision: revision
                )
            }
            let cursor = String((Int(pullCursor) ?? 0) + results.count)
            pullCursor = cursor
            return SyncPushResponse(batchId: request.batchId, results: results, cursor: cursor)
        }
    }

    public func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        _ = accessToken
        _ = deviceID
        _ = limit
        return try withLock {
            pulledCursors.append(cursor)
            if failPull {
                throw AuthClientError.problem(
                    status: 503,
                    code: "sync_unavailable",
                    detail: "The sync service is unavailable."
                )
            }
            if !pullPages.isEmpty {
                return pullPages.removeFirst()
            }
            let changes = echoPublishedAssets
                ? pullChanges.filter { $0.sequence > (Int(cursor) ?? 0) }
                : pullChanges
            return SyncPullResponse(changes: changes, cursor: pullCursor, hasMore: pullHasMore)
        }
    }

    public func bootstrap(
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
        return withLock {
            if !bootstrapPages.isEmpty { return bootstrapPages.removeFirst() }
            return SyncBootstrapResponse(entities: [], cursor: "0", nextOffset: 0, hasMore: false)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
