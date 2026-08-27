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

final class ASWebOAuthBrowserSession: NSObject, OAuthBrowserSession, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?

    func start(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let resume = OnceResume(continuation)
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] url, error in
                // SafariLaunchAgent replies on an XPC queue. Resume on the main
                // actor so Swift 6 isolation does not trap.
                DispatchQueue.main.async {
                    self?.session = nil
                    if let url {
                        resume.returning(url)
                    } else if let error {
                        resume.throwing(error)
                    } else {
                        resume.throwing(AuthClientError.cancelled)
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                self.session = nil
                resume.throwing(AuthClientError.cancelled)
            }
        }
    }

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
