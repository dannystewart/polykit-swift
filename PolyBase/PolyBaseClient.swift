//
//  PolyBaseClient.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Auth
import Foundation
import Supabase

// MARK: - PolyBaseClient

/// Manages the Supabase client instance for PolyBase.
///
/// Initialize with your Supabase project URL and anon key:
/// ```swift
/// PolyBaseClient.configure(
///     projectURL: URL(string: "https://your-project.supabase.co")!,
///     anonKey: "your-anon-key"
/// )
///
/// // Then access the client
/// let data = try await PolyBaseClient.shared.client.from("table").select().execute()
/// ```
///
/// You can also load credentials from Info.plist:
/// ```swift
/// PolyBaseClient.configureFromInfoPlist(
///     urlKey: "SUPABASE_URL",
///     anonKeyKey: "SUPABASE_KEY"
/// )
/// ```
public final class PolyBaseClient: @unchecked Sendable {
    /// Shared instance. Access after calling `configure()`.
    /// Configured once at app startup before concurrent access.
    public private(set) nonisolated(unsafe) static var shared: PolyBaseClient?

    /// The underlying Supabase client.
    public let client: SupabaseClient

    /// The project URL this client is connected to.
    public let projectURL: URL

    private init(projectURL: URL, anonKey: String) {
        self.projectURL = projectURL
        client = SupabaseClient(
            supabaseURL: projectURL,
            supabaseKey: anonKey,
            options: .init(
                auth: .init(
                    // Opt-in to new session behavior to silence deprecation warning
                    emitLocalSessionAsInitialSession: true,
                ),
            ),
        )
    }

    // MARK: - Configuration

    /// Configure PolyBase with explicit credentials.
    ///
    /// - Parameters:
    ///   - projectURL: Your Supabase project URL.
    ///   - anonKey: Your Supabase anon/public key.
    @discardableResult
    public static func configure(projectURL: URL, anonKey: String) -> PolyBaseClient {
        let instance = PolyBaseClient(projectURL: projectURL, anonKey: anonKey)
        shared = instance
        polyInfo("PolyBase: Configured with project \(projectURL.host ?? "unknown")")
        return instance
    }

    /// Configure PolyBase by loading credentials from Info.plist.
    ///
    /// - Parameters:
    ///   - urlKey: The Info.plist key for the project URL. Defaults to "SUPABASE_URL".
    ///   - anonKeyKey: The Info.plist key for the anon key. Defaults to "SUPABASE_KEY".
    /// - Throws: `PolyBaseError.missingConfiguration` if keys are not found.
    @discardableResult
    public static func configureFromInfoPlist(
        urlKey: String = "SUPABASE_URL",
        anonKeyKey: String = "SUPABASE_KEY",
    ) throws -> PolyBaseClient {
        guard
            let urlString = Bundle.main.infoDictionary?[urlKey] as? String,
            !urlString.isEmpty,
            let url = URL(string: urlString) else
        {
            throw PolyBaseError.missingConfiguration("\(urlKey) not found or invalid in Info.plist")
        }

        guard
            let anonKey = Bundle.main.infoDictionary?[anonKeyKey] as? String,
            !anonKey.isEmpty else
        {
            throw PolyBaseError.missingConfiguration("\(anonKeyKey) not found in Info.plist")
        }

        return configure(projectURL: url, anonKey: anonKey)
    }

    /// Returns the configured client, or throws if not configured.
    public static func requireClient() throws -> SupabaseClient {
        guard let shared else {
            throw PolyBaseError.notConfigured
        }
        return shared.client
    }
}

// MARK: - PolyBaseError

/// Errors thrown by PolyBase services.
public enum PolyBaseError: LocalizedError {
    case notConfigured
    case missingConfiguration(String)
    case notAuthenticated
    case invalidCredential
    case uploadFailed(String)
    case downloadFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "PolyBase not configured. Call PolyBaseClient.configure() first."
        case let .missingConfiguration(detail):
            "Missing configuration: \(detail)"
        case .notAuthenticated:
            "User is not authenticated"
        case .invalidCredential:
            "Invalid credential received"
        case let .uploadFailed(detail):
            "Upload failed: \(detail)"
        case let .downloadFailed(detail):
            "Download failed: \(detail)"
        case let .encryptionFailed(detail):
            "Encryption failed: \(detail)"
        case let .decryptionFailed(detail):
            "Decryption failed: \(detail)"
        }
    }
}
