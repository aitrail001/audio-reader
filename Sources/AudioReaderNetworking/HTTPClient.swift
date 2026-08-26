import Foundation

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

public protocol HTTPPerforming: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
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
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
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
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

public final class StubHTTPClient: HTTPPerforming, @unchecked Sendable {
    public private(set) var requests: [HTTPRequest] = []
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
