import Foundation
import os

enum ProductHTTP {
    static let requestIDHeader = "X-Request-Id"
    static let log = Logger(subsystem: "com.johnsonzhang.AudioReader", category: "product-http")

    static func makeRequestID() -> String {
        UUID().uuidString.lowercased()
    }

    static func headersByAddingRequestID(_ headers: [String: String]) -> (headers: [String: String], requestID: String) {
        var merged = headers
        let requestID = merged[requestIDHeader]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (requestID?.isEmpty == false) ? requestID! : makeRequestID()
        merged[requestIDHeader] = resolved
        return (merged, resolved)
    }
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct HTTPFileResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var fileURL: URL

    public init(statusCode: Int, headers: [String: String] = [:], fileURL: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.fileURL = fileURL
    }
}

public protocol HTTPPerforming: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func upload(_ request: HTTPRequest, fromFile fileURL: URL) async throws -> HTTPResponse
    func download(_ request: HTTPRequest) async throws -> HTTPFileResponse
}

public struct LiveHTTPClient: HTTPPerforming, Sendable {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.path, relativeTo: baseURL)?.absoluteURL else {
            throw AuthClientError.invalidResponse
        }
        let prepared = ProductHTTP.headersByAddingRequestID(request.headers)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in prepared.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AuthClientError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        let path = url.path
        ProductHTTP.log.info(
            "http_complete message=product_http_complete method=\(request.method, privacy: .public) path=\(path, privacy: .public) status=\(http.statusCode, privacy: .public) requestId=\(prepared.requestID, privacy: .public)"
        )
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    /// Asset uploads are delegated to URLSession's file API so neither proxy nor signed PUT paths
    /// assign a whole immutable object to `httpBody`.
    public func upload(_ request: HTTPRequest, fromFile fileURL: URL) async throws -> HTTPResponse {
        let urlRequest = try preparedURLRequest(request)
        let (data, response) = try await session.upload(for: urlRequest, fromFile: fileURL)
        if let http = response as? HTTPURLResponse { logCompletion(request, urlRequest, http) }
        return try makeResponse(status: response, body: data)
    }

    /// URLSession owns the transfer buffer; the returned file is moved before the task temp expires.
    public func download(_ request: HTTPRequest) async throws -> HTTPFileResponse {
        let urlRequest = try preparedURLRequest(request)
        let (temporary, response) = try await session.download(for: urlRequest)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderHTTP-\(UUID().uuidString).download")
        try FileManager.default.moveItem(at: temporary, to: destination)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: destination)
            throw AuthClientError.invalidResponse
        }
        logCompletion(request, urlRequest, http)
        return HTTPFileResponse(
            statusCode: http.statusCode,
            headers: Self.responseHeaders(http),
            fileURL: destination
        )
    }

    private func preparedURLRequest(_ request: HTTPRequest) throws -> URLRequest {
        guard let url = URL(string: request.path, relativeTo: baseURL)?.absoluteURL else {
            throw AuthClientError.invalidResponse
        }
        let prepared = ProductHTTP.headersByAddingRequestID(request.headers)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in prepared.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        return urlRequest
    }

    private func makeResponse(status response: URLResponse, body: Data) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else { throw AuthClientError.invalidResponse }
        return HTTPResponse(statusCode: http.statusCode, headers: Self.responseHeaders(http), body: body)
    }

    private static func responseHeaders(_ http: HTTPURLResponse) -> [String: String] {
        Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
            guard let key = key as? String, let value = value as? String else { return nil }
            return (key, value)
        })
    }

    private func logCompletion(_ request: HTTPRequest, _ prepared: URLRequest, _ response: HTTPURLResponse) {
        let requestID = prepared.value(forHTTPHeaderField: ProductHTTP.requestIDHeader) ?? "missing"
        ProductHTTP.log.info(
            "http_complete message=product_http_complete method=\(request.method, privacy: .public) path=\(response.url?.path ?? request.path, privacy: .public) status=\(response.statusCode, privacy: .public) requestId=\(requestID, privacy: .public)"
        )
    }
}

public final class StubHTTPClient: HTTPPerforming, @unchecked Sendable {
    public private(set) var requests: [HTTPRequest] = []
    public private(set) var uploadedFiles: [URL] = []
    private var queued: [HTTPResponse] = []
    private let lock = NSLock()

    public init() {}

    public func enqueue(status: Int, json: String) {
        enqueue(status: status, body: Data(json.utf8))
    }

    public func enqueue(status: Int, body: Data, headers: [String: String] = [:]) {
        withLock {
            queued.append(HTTPResponse(statusCode: status, headers: headers, body: body))
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = dequeue(request)
        guard let response else { throw AuthClientError.invalidResponse }
        return response
    }

    public func upload(_ request: HTTPRequest, fromFile fileURL: URL) async throws -> HTTPResponse {
        withLock { uploadedFiles.append(fileURL) }
        guard let response = dequeue(request) else { throw AuthClientError.invalidResponse }
        return response
    }

    public func download(_ request: HTTPRequest) async throws -> HTTPFileResponse {
        guard let response = dequeue(request) else { throw AuthClientError.invalidResponse }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioReaderStubHTTP-\(UUID().uuidString).download")
        try response.body.write(to: url)
        return HTTPFileResponse(statusCode: response.statusCode, headers: response.headers, fileURL: url)
    }

    private func dequeue(_ request: HTTPRequest) -> HTTPResponse? {
        withLock {
            requests.append(request)
            return queued.isEmpty ? nil : queued.removeFirst()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
