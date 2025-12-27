//
//  PolyBaseRealtimeCoordinator.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase

// MARK: - PolyBaseRealtimeCoordinator

/// Coordinates Supabase Realtime subscriptions with echo prevention and debouncing.
///
/// This coordinator combines three key components:
/// - **Realtime subscriptions** to database changes
/// - **Echo tracking** to prevent processing your own changes
/// - **Debounced notifications** to batch rapid changes
///
/// ## Usage
///
/// ### Basic Setup
/// ```swift
/// let coordinator = PolyBaseRealtimeCoordinator()
///
/// // Subscribe to changes
/// try await coordinator.subscribe(to: ["projects", "items"]) {
///     // Called when OTHER devices make changes (after debounce)
///     try await syncData()
/// }
/// ```
///
/// ### Mark Your Own Changes (Echo Prevention)
/// ```swift
/// // Before pushing to Supabase
/// coordinator.markPushed(project.id, table: "projects")
///
/// // Push to Supabase
/// try await client.from("projects").upsert(dto).execute()
///
/// // Realtime event will be ignored (it's your own echo)
/// ```
///
/// ### Complete Example
/// ```swift
/// class SyncManager {
///     let coordinator = PolyBaseRealtimeCoordinator()
///
///     func initialize() async throws {
///         try await coordinator.subscribe(to: ["projects", "items"]) {
///             try await self.syncAll()
///         }
///     }
///
///     func pushProject(_ project: Project) async throws {
///         coordinator.markPushed(project.id, table: "projects")
///         try await client.from("projects").upsert(dto).execute()
///     }
/// }
/// ```
@MainActor
public final class PolyBaseRealtimeCoordinator {
    /// Whether the coordinator is currently subscribed to realtime changes.
    public private(set) var isSubscribed = false

    private let echoTracker: PolyBaseEchoTracker
    private let notifier: PolyBaseDebouncedNotifier
    private var channel: RealtimeChannelV2?
    private var realtimeTask: Task<Void, Never>?
    private let notificationName: Notification.Name

    // MARK: - Status

    /// Number of IDs currently being tracked for echo prevention.
    public var trackedEchoCount: Int {
        self.echoTracker.trackedCount
    }

    /// Whether a notification is currently pending (waiting to fire after debounce).
    public var hasPendingNotification: Bool {
        self.notifier.isPending(self.notificationName)
    }

    // MARK: - Initialization

    /// Create a realtime coordinator.
    ///
    /// - Parameters:
    ///   - echoExpiry: How long to remember pushed IDs for echo prevention. Default is 5 seconds.
    ///   - debounceInterval: How long to wait after the last change before firing. Default is 300ms.
    ///   - notificationName: The notification name to post when changes arrive. Default is `.polyBaseRealtimeDidChange`.
    public init(
        echoExpiry: Duration = PolyBaseEchoTracker.defaultExpiry,
        debounceInterval: Duration = PolyBaseDebouncedNotifier.defaultInterval,
        notificationName: Notification.Name = .polyBaseRealtimeDidChange,
    ) {
        self.echoTracker = PolyBaseEchoTracker(expiryDuration: echoExpiry)
        self.notifier = PolyBaseDebouncedNotifier(debounceInterval: debounceInterval)
        self.notificationName = notificationName
    }

    // MARK: - Subscription

    /// Subscribe to realtime changes on specified tables.
    ///
    /// This method:
    /// 1. Creates a Realtime channel
    /// 2. Subscribes to postgres changes on all specified tables
    /// 3. Automatically filters out your own changes (echoes)
    /// 4. Debounces rapid changes
    /// 5. Calls your handler when changes arrive
    ///
    /// - Parameters:
    ///   - tables: Array of table names to subscribe to (e.g., `["projects", "items"]`)
    ///   - channelName: Optional custom channel name. Default is "polybase-realtime".
    ///   - onChange: Handler called when changes arrive (after echo filtering and debouncing)
    ///
    /// - Throws: If client is not configured or subscription fails
    ///
    /// ## Example
    /// ```swift
    /// try await coordinator.subscribe(to: ["projects", "areas", "items"]) {
    ///     print("Data changed on another device!")
    ///     try await syncData()
    /// }
    /// ```
    public func subscribe(
        to tables: [String],
        channelName: String = "polybase-realtime",
        onChange: @escaping @Sendable () async throws -> Void,
    ) async throws {
        guard !self.isSubscribed else {
            polyWarning("PolyBaseRealtimeCoordinator: Already subscribed")
            return
        }

        let client = try PolyBaseClient.requireClient()

        // Create channel
        let newChannel = client.realtimeV2.channel(channelName)

        // Subscribe to all tables
        let changeStream = newChannel.postgresChange(AnyAction.self, schema: "public")

        self.channel = newChannel

        // Subscribe with error handling
        try await newChannel.subscribeWithError()
        self.isSubscribed = true

        let tableWord = tables.count == 1 ? "table" : "tables"
        polyDebug("PolyBaseRealtimeCoordinator: Subscribed to \(tables.count) \(tableWord)")

        // Set up notification observer
        NotificationCenter.default.addObserver(
            forName: self.notificationName,
            object: nil,
            queue: .main,
        ) { _ in
            Task { @MainActor in
                do {
                    try await onChange()
                } catch {
                    polyError("PolyBaseRealtimeCoordinator: onChange handler failed: \(error)")
                }
            }
        }

        // Listen to the change stream
        self.realtimeTask = Task { @MainActor in
            for await _ in changeStream {
                // Post debounced notification
                // The notification observer above will call onChange()
                self.notifier.post(self.notificationName, object: nil, userInfo: nil)
            }
        }
    }

    /// Unsubscribe from realtime changes.
    ///
    /// Cancels the realtime task and removes the notification observer.
    public func unsubscribe() async {
        self.realtimeTask?.cancel()
        self.realtimeTask = nil

        if let channel {
            await channel.unsubscribe()
        }

        channel = nil
        self.isSubscribed = false

        NotificationCenter.default.removeObserver(
            self,
            name: self.notificationName,
            object: nil,
        )

        polyDebug("PolyBaseRealtimeCoordinator: Unsubscribed")
    }

    // MARK: - Echo Prevention

    /// Mark an ID as pushed to prevent echo processing.
    ///
    /// Call this BEFORE pushing a change to Supabase. When the realtime event
    /// comes back, it will be ignored (it's your own change).
    ///
    /// - Parameters:
    ///   - id: The UUID of the record being pushed
    ///   - table: The table name (e.g., "projects", "items")
    ///
    /// ## Example
    /// ```swift
    /// // Before pushing
    /// coordinator.markPushed(project.id, table: "projects")
    ///
    /// // Push to Supabase
    /// try await client.from("projects").upsert(dto).execute()
    ///
    /// // When realtime event arrives, it will be ignored
    /// ```
    public func markPushed(_ id: UUID, table: String) {
        self.echoTracker.markAsPushed(id, table: table)
    }

    /// Check if an ID was recently pushed (and should be treated as an echo).
    ///
    /// - Parameters:
    ///   - id: The UUID to check
    ///   - table: The table name
    /// - Returns: `true` if this ID was recently pushed and should be ignored
    public func wasPushedRecently(_ id: UUID, table: String) -> Bool {
        self.echoTracker.wasPushedRecently(id, table: table)
    }

    // MARK: - Debouncing Control

    /// Post a notification immediately without debouncing.
    ///
    /// Use this for user-initiated actions that should feel instant.
    public func notifyImmediately() {
        self.notifier.post(self.notificationName, object: nil, userInfo: nil)
    }

    /// Cancel any pending debounced notifications.
    public func cancelPending() {
        self.notifier.cancel(self.notificationName)
    }
}

// MARK: - Default Notification Name

public extension Notification.Name {
    /// Default notification name for PolyBase realtime changes.
    static let polyBaseRealtimeDidChange = Notification.Name("polyBaseRealtimeDidChange")
}
