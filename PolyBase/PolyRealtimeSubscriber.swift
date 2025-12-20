//
//  PolyRealtimeSubscriber.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Realtime
import Supabase

// MARK: - PolyRealtimeEvent

/// Represents a real-time change event from Supabase.
public struct PolyRealtimeEvent: Sendable {
    /// The type of change
    public enum ChangeType: String, Sendable {
        case insert = "INSERT"
        case update = "UPDATE"
        case delete = "DELETE"
    }

    /// The table that changed
    public let tableName: String

    /// The type of change
    public let changeType: ChangeType

    /// The record data
    public let record: [String: AnyJSON]

    /// The old record data (for updates/deletes)
    public let oldRecord: [String: AnyJSON]?

    /// Extract the entity ID from the record
    public var entityID: String? {
        record["id"]?.stringValue
    }

    /// Extract the version from the record
    public var version: Int? {
        record["version"]?.integerValue
    }

    /// Extract the deleted flag from the record
    public var isDeleted: Bool {
        record["deleted"]?.boolValue ?? false
    }
}

// MARK: - PolyRealtimeHandler

/// Protocol for handling real-time events.
///
/// Apps implement this to process incoming changes for specific entity types.
public protocol PolyRealtimeHandler: Sendable {
    /// Handle a real-time event for this entity type.
    ///
    /// - Parameters:
    ///   - event: The change event
    /// - Returns: Whether the event was handled successfully
    @MainActor
    func handle(_ event: PolyRealtimeEvent) async -> Bool
}

// MARK: - PolyRealtimeSubscriber

/// Manages real-time subscriptions for all registered entity types.
///
/// Automatically subscribes to changes on all tables registered with
/// `PolyBaseRegistry` and routes events to appropriate handlers.
///
/// ## Usage
///
/// ```swift
/// let subscriber = PolyRealtimeSubscriber()
///
/// // Register a handler for a specific table
/// subscriber.registerHandler(for: "messages") { event in
///     // Handle message changes
///     await mergeMessage(event.record)
///     return true
/// }
///
/// // Start listening
/// await subscriber.startListening()
/// ```
@MainActor
public final class PolyRealtimeSubscriber {
    public static let shared: PolyRealtimeSubscriber = .init()

    /// Whether we're currently subscribed
    public private(set) var isListening = false

    /// The realtime channel
    private var channel: RealtimeChannelV2?

    /// Listening task
    private var listeningTasks: [Task<Void, Never>] = []

    /// Per-table handlers
    private var handlers: [String: any PolyRealtimeHandler] = [:]

    /// Generic handler for all events (called if no specific handler)
    private var genericHandler: (@Sendable (PolyRealtimeEvent) async -> Bool)?

    /// Debounced notifier for batching rapid changes
    private let notifier: PolyBaseDebouncedNotifier = .init()

    /// Echo tracker for filtering own changes
    private let echoTracker: PolyBaseEchoTracker = .init()

    /// Channel name
    private let channelName: String

    public init(channelName: String = "polybase-sync") {
        self.channelName = channelName
    }

    // MARK: - Handler Registration

    /// Register a handler for a specific table.
    public func registerHandler(for tableName: String, handler: any PolyRealtimeHandler) {
        handlers[tableName] = handler
    }

    /// Register a closure handler for a specific table.
    public func registerHandler(
        for tableName: String,
        handler: @escaping @Sendable @MainActor (PolyRealtimeEvent) async -> Bool,
    ) {
        handlers[tableName] = ClosureHandler(handler: handler)
    }

    /// Set a generic handler for all events.
    public func setGenericHandler(
        _ handler: @escaping @Sendable (PolyRealtimeEvent) async -> Bool,
    ) {
        genericHandler = handler
    }

    // MARK: - Subscription Management

    /// Start listening to real-time changes on all registered tables.
    ///
    /// Automatically subscribes to all tables registered with `PolyBaseRegistry`.
    public func startListening() async throws {
        guard !isListening else {
            polyDebug("PolyRealtimeSubscriber: Already listening")
            return
        }

        let client = try PolyBaseClient.requireClient()
        let tables = PolyBaseRegistry.shared.registeredTables

        guard !tables.isEmpty else {
            polyWarning("PolyRealtimeSubscriber: No tables registered")
            return
        }

        polyInfo("PolyRealtimeSubscriber: Starting subscriptions for \(tables.count) tables")

        let newChannel = client.realtimeV2.channel(channelName)

        // Subscribe to all registered tables
        for table in tables {
            let stream = newChannel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: table,
            )

            let task = Task { @MainActor [weak self] in
                for await action in stream {
                    await self?.handleAction(action, tableName: table)
                }
            }
            listeningTasks.append(task)
        }

        // Subscribe to the channel
        try await newChannel.subscribeWithError()

        channel = newChannel
        isListening = true

        polyInfo("PolyRealtimeSubscriber: Now listening to \(tables.count) tables")
    }

    /// Start listening to specific tables only.
    public func startListening(to tables: [String]) async throws {
        guard !isListening else {
            polyDebug("PolyRealtimeSubscriber: Already listening")
            return
        }

        let client = try PolyBaseClient.requireClient()

        guard !tables.isEmpty else {
            polyWarning("PolyRealtimeSubscriber: No tables specified")
            return
        }

        polyInfo("PolyRealtimeSubscriber: Starting subscriptions for \(tables.count) tables")

        let newChannel = client.realtimeV2.channel(channelName)

        for table in tables {
            let stream = newChannel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: table,
            )

            let task = Task { @MainActor [weak self] in
                for await action in stream {
                    await self?.handleAction(action, tableName: table)
                }
            }
            listeningTasks.append(task)
        }

        try await newChannel.subscribeWithError()

        channel = newChannel
        isListening = true

        polyInfo("PolyRealtimeSubscriber: Now listening to \(tables.count) tables")
    }

    /// Stop listening to real-time changes.
    public func stopListening() async {
        for task in listeningTasks {
            task.cancel()
        }
        listeningTasks.removeAll()

        if let channel {
            await channel.unsubscribe()
        }
        channel = nil
        isListening = false

        polyInfo("PolyRealtimeSubscriber: Stopped listening")
    }

    // MARK: - Echo Tracking

    /// Mark an entity as recently pushed (for echo prevention).
    public func markAsPushed(_ id: String, table: String) {
        echoTracker.markAsPushed(id, table: table)
    }

    /// Check if an entity was recently pushed.
    public func wasPushedRecently(_ id: String, table: String) -> Bool {
        echoTracker.wasPushedRecently(id, table: table)
    }

    // MARK: - Event Handling

    /// Handle a raw action from Supabase realtime.
    private func handleAction(_ action: AnyAction, tableName: String) async {
        let event = switch action {
        case let .insert(insertAction):
            PolyRealtimeEvent(
                tableName: tableName,
                changeType: .insert,
                record: insertAction.record,
                oldRecord: nil,
            )

        case let .update(updateAction):
            PolyRealtimeEvent(
                tableName: tableName,
                changeType: .update,
                record: updateAction.record,
                oldRecord: updateAction.oldRecord,
            )

        case let .delete(deleteAction):
            PolyRealtimeEvent(
                tableName: tableName,
                changeType: .delete,
                record: deleteAction.oldRecord,
                oldRecord: nil,
            )
        }

        // Check for echo
        if let entityID = event.entityID {
            if echoTracker.wasPushedRecently(entityID, table: tableName) {
                polyDebug("PolyRealtimeSubscriber: Skipping echo for \(tableName)/\(entityID)")
                return
            }
        }

        polyDebug("PolyRealtimeSubscriber: \(event.changeType.rawValue) on \(tableName) id=\(event.entityID ?? "?")")

        // Try table-specific handler first
        if let handler = handlers[tableName] {
            _ = await handler.handle(event)
            return
        }

        // Fall back to generic handler
        if let genericHandler {
            _ = await genericHandler(event)
            return
        }

        // No handler - post notification
        postChangeNotification(for: tableName)
    }

    /// Post a debounced change notification.
    private func postChangeNotification(for tableName: String) {
        // Check if there's a registered notification for this table
        if
            let config = PolyBaseRegistry.shared.config(forTable: tableName),
            let notification = config.notification
        {
            notifier.post(notification, object: nil, userInfo: nil)
        } else {
            // Post generic notification
            notifier.post(.polyBaseRealtimeDidChange, object: nil, userInfo: ["table": tableName])
        }
    }
}

// MARK: - ClosureHandler

/// Internal handler that wraps a closure.
private struct ClosureHandler: PolyRealtimeHandler {
    let handler: @Sendable @MainActor (PolyRealtimeEvent) async -> Bool

    @MainActor
    func handle(_ event: PolyRealtimeEvent) async -> Bool {
        await handler(event)
    }
}
