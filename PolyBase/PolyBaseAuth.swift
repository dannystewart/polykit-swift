//
//  PolyBaseAuth.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Auth
import AuthenticationServices
import Foundation
import Supabase

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// MARK: - PolyBaseAuth

/// Handles Sign in with Apple authentication with Supabase.
///
/// Usage:
/// ```swift
/// // Sign in
/// let session = try await PolyBaseAuth.shared.signInWithApple()
///
/// // Check status
/// if PolyBaseAuth.shared.isSignedIn {
///     print("User ID: \(PolyBaseAuth.shared.userID!)")
/// }
///
/// // Sign out
/// try await PolyBaseAuth.shared.signOut()
/// ```
///
/// Listen for auth state changes:
/// ```swift
/// NotificationCenter.default.addObserver(
///     forName: .polyBaseAuthStateDidChange,
///     object: nil,
///     queue: .main
/// ) { _ in
///     // Handle auth state change
/// }
/// ```
@MainActor
public final class PolyBaseAuth: NSObject {
    /// Shared instance.
    public static let shared: PolyBaseAuth = .init()

    private var authContinuation: CheckedContinuation<ASAuthorization, Error>?

    /// Current authenticated user, if any.
    public var currentUser: Auth.User? {
        try? PolyBaseClient.requireClient().auth.currentUser
    }

    /// Whether the user is currently signed in.
    public var isSignedIn: Bool {
        currentUser != nil
    }

    /// The current user's UUID (for including in database records).
    public var userID: UUID? {
        currentUser?.id
    }

    override private init() {
        super.init()
    }

    // MARK: - Sign In with Apple

    /// Initiates Sign in with Apple flow and authenticates with Supabase.
    ///
    /// - Returns: The authenticated Supabase session.
    /// - Throws: `PolyBaseError.notConfigured` if client not configured,
    ///           `PolyBaseError.invalidCredential` if Apple credential is invalid.
    @discardableResult
    public func signInWithApple() async throws -> Session {
        let client = try PolyBaseClient.requireClient()

        // Request Apple credential
        let authorization = try await requestAppleAuthorization()

        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let identityTokenData = credential.identityToken,
            let identityToken = String(data: identityTokenData, encoding: .utf8) else
        {
            throw PolyBaseError.invalidCredential
        }

        polyInfo("PolyBase: Got Apple credential, signing in with Supabase...")

        // Sign in with Supabase using the Apple identity token
        let session = try await client.auth.signInWithIdToken(
            credentials: .init(
                provider: .apple,
                idToken: identityToken,
            ),
        )

        polyInfo("PolyBase: Signed in! User ID: \(session.user.id)")

        // Save user's name if provided (Apple only provides this on first sign-in)
        if let fullName = credential.fullName {
            let givenName = fullName.givenName ?? ""
            let familyName = fullName.familyName ?? ""
            if !givenName.isEmpty || !familyName.isEmpty {
                _ = try? await client.auth.update(user: UserAttributes(
                    data: [
                        "full_name": .string("\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)),
                        "given_name": .string(givenName),
                        "family_name": .string(familyName),
                    ],
                ))
                polyDebug("PolyBase: Saved user name: \(givenName) \(familyName)")
            }
        }

        // Post notification for UI updates
        NotificationCenter.default.post(name: .polyBaseAuthStateDidChange, object: nil)

        return session
    }

    /// Sign out the current user.
    public func signOut() async throws {
        let client = try PolyBaseClient.requireClient()
        try await client.auth.signOut()
        polyInfo("PolyBase: Signed out")
        NotificationCenter.default.post(name: .polyBaseAuthStateDidChange, object: nil)
    }

    /// Restore session on app launch (checks for existing session).
    ///
    /// Call this early in your app lifecycle to restore any existing session.
    public func restoreSession() async {
        do {
            let client = try PolyBaseClient.requireClient()
            let session = try await client.auth.session
            polyInfo("PolyBase: Restored session for user: \(session.user.id)")
        } catch {
            polyDebug("PolyBase: No existing session to restore")
        }
    }

    // MARK: - Apple Authorization

    private func requestAppleAuthorization() async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.authContinuation = continuation

            // Dispatch to main to avoid QoS priority inversion
            DispatchQueue.main.async {
                let provider = ASAuthorizationAppleIDProvider()
                let request = provider.createRequest()
                request.requestedScopes = [.email, .fullName]

                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        }
    }
}

// MARK: ASAuthorizationControllerDelegate

extension PolyBaseAuth: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization,
    ) {
        authContinuation?.resume(returning: authorization)
        authContinuation = nil
    }

    public func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithError error: Error,
    ) {
        authContinuation?.resume(throwing: error)
        authContinuation = nil
    }
}

// MARK: ASAuthorizationControllerPresentationContextProviding

extension PolyBaseAuth: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(macOS)
            return NSApplication.shared.keyWindow ?? NSWindow()
        #else
            // Find the first available window scene and its key window
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                    return keyWindow
                }
                // No key window, but scene exists - return first window
                if let firstWindow = windowScene.windows.first {
                    return firstWindow
                }
                return UIWindow(windowScene: windowScene)
            }
            // Should never reach here if app is running
            fatalError("No window scene available for Sign in with Apple")
        #endif
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when PolyBase auth state changes (sign in, sign out).
    static let polyBaseAuthStateDidChange = Notification.Name("polyBaseAuthStateDidChange")
}
