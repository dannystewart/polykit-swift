//
//  LogRemoteConfig.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

// MARK: - LogRemoteConfig

/// Configuration for remote log streaming via Supabase.
///
/// Stores Supabase credentials for the PolyApps project which receives logs
/// from all apps using PolyLog with remote logging enabled.
///
/// ## Configuration
///
/// Create a `LogRemoteConfig.plist` file in your app bundle or use programmatic configuration:
///
/// ```swift
/// // Option 1: Load from plist
/// LogRemoteConfig.load()  // Looks for LogRemoteConfig.plist
///
/// // Option 2: Configure programmatically
/// LogRemoteConfig.configure(
///     supabaseURL: URL(string: "https://xxx.supabase.co")!,
///     supabaseKey: "your-anon-key"
/// )
/// ```
///
/// The plist should contain:
/// - `SupabaseURL`: String URL of your Supabase project
/// - `SupabaseKey`: String anon key for the project
public struct LogRemoteConfig: Sendable {
    // MARK: - Shared Configuration

    /// The shared configuration instance, set via `configure()` or `load()`.
    /// Protected by `lock` for thread-safe access.
    private nonisolated(unsafe) static var _shared: LogRemoteConfig?
    private static let lock: NSLock = .init()

    /// The current shared configuration, if set.
    public static var shared: LogRemoteConfig? {
        lock.lock()
        defer { lock.unlock() }
        return _shared
    }

    /// The Supabase project URL.
    public let supabaseURL: URL

    /// The Supabase anon key.
    public let supabaseKey: String

    /// The table name for logs (defaults to "logs").
    public let tableName: String

    /// Creates a new configuration.
    ///
    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL
    ///   - supabaseKey: The Supabase anon key
    ///   - tableName: The table name for logs (defaults to "logs")
    public init(
        supabaseURL: URL,
        supabaseKey: String,
        tableName: String = "polylogs",
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        self.tableName = tableName
    }

    /// Configure remote logging with explicit values.
    ///
    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL
    ///   - supabaseKey: The Supabase anon key
    ///   - tableName: The table name for logs (defaults to "logs")
    public static func configure(
        supabaseURL: URL,
        supabaseKey: String,
        tableName: String = "polylogs",
    ) {
        lock.lock()
        defer { lock.unlock() }
        _shared = LogRemoteConfig(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            tableName: tableName,
        )
    }

    /// Load configuration from a plist file.
    ///
    /// Looks for `LogRemoteConfig.plist` in the main bundle.
    /// The plist should contain `SupabaseURL` and `SupabaseKey` string entries.
    ///
    /// - Parameter fileName: The plist file name (without extension). Defaults to "LogRemoteConfig".
    /// - Returns: Whether configuration was loaded successfully.
    @discardableResult
    public static func load(from fileName: String = "LogRemoteConfig") -> Bool {
        guard
            let url = Bundle.main.url(forResource: fileName, withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let urlString = plist["SupabaseURL"] as? String,
            let supabaseURL = URL(string: urlString),
            let supabaseKey = plist["SupabaseKey"] as? String else
        {
            return false
        }

        let tableName = plist["TableName"] as? String ?? "polylogs"

        lock.lock()
        defer { lock.unlock() }
        _shared = LogRemoteConfig(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            tableName: tableName,
        )
        return true
    }

    /// Clear the shared configuration.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _shared = nil
    }
}
