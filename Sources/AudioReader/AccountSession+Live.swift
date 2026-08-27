import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
#if canImport(AudioReaderNetworking)
import AudioReaderNetworking
#endif

extension AccountSession {
    static func live() -> AccountSession {
        AccountSession(
            client: ProductAuthClient(baseURL: ProductAPI.resolvedBaseURL),
            store: KeychainAuthSessionStore(),
            oauth: ASWebOAuthBrowserSession(),
            environment: .current()
        )
    }
}

extension AccountDeviceEnvironment {
    @MainActor
    static func current() -> AccountDeviceEnvironment {
        AccountDeviceEnvironment(
            platform: currentPlatform,
            deviceName: currentDeviceName,
            appVersion: AppVersion.marketing,
            buildNumber: AppVersion.build,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier
        )
    }

    @MainActor
    private static var currentPlatform: ProductDevicePlatform {
#if os(macOS)
        .macos
#elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? .ios : .ipados
#else
        .macos
#endif
    }

    @MainActor
    private static var currentDeviceName: String {
#if os(macOS)
        Host.current().localizedName ?? "Mac"
#else
        UIDevice.current.name
#endif
    }
}

final class ASWebOAuthBrowserSession: NSObject, OAuthBrowserSession, @unchecked Sendable {
    private let lock = NSLock()
    private var safari: ASWebAuthenticationSession?

    @concurrent
    func start(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        if LocalOAuthRedirect.isLocalComplete(authorizationURL) {
            return try await LocalOAuthRedirect.follow(authorizationURL)
        }
        return try await presentSafariSession(authorizationURL: authorizationURL, callbackScheme: callbackScheme)
    }

    @MainActor
    private func presentSafariSession(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let resume = OnceResume(continuation)
            let presenter = WebAuthPresenter()
            let session = WebAuthCallbacks.makeSession(
                url: authorizationURL,
                callbackScheme: callbackScheme,
                presenter: presenter,
                resume: resume,
                onComplete: { [weak self] in
                    self?.lock.lock()
                    self?.safari = nil
                    self?.lock.unlock()
                }
            )
            objc_setAssociatedObject(
                session,
                Unmanaged.passUnretained(session).toOpaque(),
                presenter,
                .OBJC_ASSOCIATION_RETAIN
            )
            lock.lock()
            safari = session
            lock.unlock()
            if !session.start() {
                lock.lock()
                safari = nil
                lock.unlock()
                resume.throwing(AuthClientError.cancelled)
            }
        }
    }
}

private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(macOS)
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
#else
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
#endif
    }
}

enum LocalOAuthRedirect {
    static func isLocalComplete(_ url: URL) -> Bool {
        url.path == "/v1/auth/oauth/local-complete"
    }

    static func follow(_ url: URL) async throws -> URL {
        let catcher = RedirectCatcher()
        let session = URLSession(configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("local-oauth", forHTTPHeaderField: "X-Request-Id")
        do {
            _ = try await session.data(for: request)
        } catch {
            if let location = catcher.location {
                return location
            }
            throw error
        }
        if let location = catcher.location {
            return location
        }
        throw AuthClientError.invalidResponse
    }
}

private final class RedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var location: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let header = response.value(forHTTPHeaderField: "Location"), let url = URL(string: header) {
            store(url)
            return nil
        }
        if let url = request.url, url.scheme == ProductAPI.callbackScheme {
            store(url)
            return nil
        }
        return request
    }

    private func store(_ url: URL) {
        lock.lock()
        stored = url
        lock.unlock()
    }
}

private enum WebAuthCallbacks {
    nonisolated static func makeSession(
        url: URL,
        callbackScheme: String,
        presenter: ASWebAuthenticationPresentationContextProviding,
        resume: OnceResume<URL>,
        onComplete: @escaping @Sendable () -> Void
    ) -> ASWebAuthenticationSession {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
            DispatchQueue.main.async {
                finish(resume: resume, url: callbackURL, error: error)
                onComplete()
            }
        }
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = true
        return session
    }

    nonisolated static func finish(resume: OnceResume<URL>, url: URL?, error: (any Error)?) {
        if let url {
            resume.returning(url)
        } else if let error {
            resume.throwing(error)
        } else {
            resume.throwing(AuthClientError.cancelled)
        }
    }
}

private final class OnceResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func returning(_ value: Value) {
        let pending = take()
        pending?.resume(returning: value)
    }

    func throwing(_ error: Error) {
        let pending = take()
        pending?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
