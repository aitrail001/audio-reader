import Foundation

public struct ProductSyncClient: SyncClient, Sendable {
    private let http: any HTTPPerforming
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(http: any HTTPPerforming, baseURL: URL = ProductAPI.defaultBaseURL) {
        self.http = http
        _ = baseURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public init(baseURL: URL) {
        self.init(http: LiveHTTPClient(baseURL: baseURL), baseURL: baseURL)
    }

    public func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        try await send(
            method: "POST",
            path: "/v1/sync/push",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-Device-Id": deviceID,
                "Idempotency-Key": request.batchId
            ],
            body: request
        )
    }

    public func pull(accessToken: String, deviceID: String, cursor: String, limit: Int) async throws -> SyncPullResponse {
        var components = URLComponents()
        components.path = "/v1/sync/pull"
        components.queryItems = [
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let path = components.string ?? "/v1/sync/pull"
        return try await send(
            method: "GET",
            path: path,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "X-Device-Id": deviceID
            ]
        )
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

public final class FakeSyncClient: SyncClient, @unchecked Sendable {
    public private(set) var pushed: [SyncPushRequest] = []
    public private(set) var pulledCursors: [String] = []
    public var pullChanges: [SyncPulledChange] = []
    public var pullCursor: String = "0"
    public var pullHasMore = false
    private let lock = NSLock()

    public init() {}

    public func push(accessToken: String, deviceID: String, request: SyncPushRequest) async throws -> SyncPushResponse {
        _ = accessToken
        _ = deviceID
        return withLock {
            pushed.append(request)
            let results = request.mutations.map { mutation in
                SyncMutationResult(
                    mutationId: mutation.mutationId,
                    status: "applied",
                    entityRevision: mutation.baseRevision + 1
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
        return withLock {
            pulledCursors.append(cursor)
            return SyncPullResponse(changes: pullChanges, cursor: pullCursor, hasMore: pullHasMore)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
