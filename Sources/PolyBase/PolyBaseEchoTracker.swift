//
//  PolyBaseEchoTracker.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

// MARK: - PolyBaseEchoTracker

/// Tracks recently pushed entity IDs to prevent processing your own changes
/// when they echo back via Supabase Realtime.
///
/// When you push a change to Supabase, the realtime subscription will fire
/// with that same change. Use this tracker to detect and ignore those echoes.
///
/// ## Usage
/// ```swift
/// let tracker = PolyBaseEchoTracker()
///
/// // Before pushing to Supabase
/// tracker.markAsPushed(item.id.uuidString, table: "items")
/// try await supabase.from("items").upsert(item).execute()
///
/// // In your realtime handler
/// func handleChange(table: String, record: [String: AnyJSON]) {
///     let id = record["id"]?.stringValue ?? ""
///     if tracker.wasPushedRecently(id, table: table) {
///         return // Skip - this is our own change
///     }
///     // Process the change...
/// }
/// ```
public final class PolyBaseEchoTracker: @unchecked Sendable {
    /// Default expiry duration for tracked IDs
    public static let defaultExpiry: Duration = .seconds(5)

    private var trackedIds: [String: Date] = [:]
    private let lock: NSLock = .init()
    private let expiryDuration: Duration

    /// Number of currently tracked IDs.
    public var trackedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return trackedIds.count
    }

    /// Create an echo tracker.
    ///
    /// - Parameter expiryDuration: How long to remember pushed IDs.
    ///                             Default is 5 seconds.
    public init(expiryDuration: Duration = defaultExpiry) {
        self.expiryDuration = expiryDuration
    }

    // MARK: - Tracking

    /// Mark an entity as recently pushed.
    ///
    /// Call this BEFORE pushing to Supabase to ensure the ID is tracked
    /// before the realtime echo arrives.
    ///
    /// - Parameters:
    ///   - id: The entity's unique identifier
    ///   - table: The table name (combined with ID for uniqueness across tables)
    public func markAsPushed(_ id: String, table: String? = nil) {
        let key = makeKey(id: id, table: table)

        lock.lock()
        trackedIds[key] = Date()
        lock.unlock()

        // Schedule cleanup
        Task { [weak self] in
            try? await Task.sleep(for: self?.expiryDuration ?? Self.defaultExpiry)
            self?.removeTrackedId(key)
        }
    }

    /// Mark a UUID as recently pushed.
    public func markAsPushed(_ id: UUID, table: String? = nil) {
        markAsPushed(id.uuidString, table: table)
    }

    /// Mark an integer ID as recently pushed.
    public func markAsPushed(_ id: Int, table: String? = nil) {
        markAsPushed(String(id), table: table)
    }

    // MARK: - Checking

    /// Check if an entity was recently pushed (and should be ignored).
    ///
    /// - Parameters:
    ///   - id: The entity's unique identifier
    ///   - table: The table name (must match what was passed to `markAsPushed`)
    /// - Returns: `true` if this ID was recently pushed and should be ignored
    public func wasPushedRecently(_ id: String, table: String? = nil) -> Bool {
        let key = makeKey(id: id, table: table)

        lock.lock()
        defer { lock.unlock() }

        guard let timestamp = trackedIds[key] else { return false }

        // Double-check it hasn't expired (in case cleanup task hasn't run)
        let expirySeconds = Double(expiryDuration.components.seconds)
            + Double(expiryDuration.components.attoseconds) / 1e18
        if Date().timeIntervalSince(timestamp) > expirySeconds {
            trackedIds.removeValue(forKey: key)
            return false
        }

        return true
    }

    /// Check if a UUID was recently pushed.
    public func wasPushedRecently(_ id: UUID, table: String? = nil) -> Bool {
        wasPushedRecently(id.uuidString, table: table)
    }

    /// Check if an integer ID was recently pushed.
    public func wasPushedRecently(_ id: Int, table: String? = nil) -> Bool {
        wasPushedRecently(String(id), table: table)
    }

    // MARK: - Utilities

    /// Clear all tracked IDs.
    public func clear() {
        lock.lock()
        trackedIds.removeAll()
        lock.unlock()
    }

    /// Remove a tracked ID (thread-safe, synchronous).
    private func removeTrackedId(_ key: String) {
        lock.lock()
        trackedIds.removeValue(forKey: key)
        lock.unlock()
    }

    private func makeKey(id: String, table: String?) -> String {
        if let table {
            return "\(table):\(id)"
        }
        return id
    }
}
