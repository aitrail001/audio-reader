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

    private static var currentPlatform: ProductDevicePlatform {
#if os(macOS)
        .macos
#elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? .ios : .ipados
#else
        .macos
#endif
    }

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
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] url, error in
                self?.session = nil
                if let url {
                    continuation.resume(returning: url)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: AuthClientError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: AuthClientError.cancelled)
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
