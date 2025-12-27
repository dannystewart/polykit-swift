//
//  PolyRefreshCoordinator.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Observation

// MARK: - PolyRefreshCoordinator

/// Centralized coordinator for UI refresh signals across any entity types.
///
/// A universal solution to the UI refresh problem: when data changes,
/// UI components need to know. PolyRefresh provides typed, observable signals
/// for any entity types you register, with optional hierarchical bubbling.
///
/// ## Setup
///
/// Register your entity types at app startup:
/// ```swift
/// PolyRefreshCoordinator.shared.register("Persona")
/// PolyRefreshCoordinator.shared.register("Conversation", parent: "Persona")
/// PolyRefreshCoordinator.shared.register("Message", parent: "Conversation")
/// ```
///
/// ## Notifying of Changes
///
/// From your data coordinator or sync services:
/// ```swift
/// PolyRefreshCoordinator.shared.notify(
///     "Message",
///     change: EntityChange(changeType: .insert, entityID: messageID, parentID: conversationID)
/// )
/// ```
///
/// Changes automatically bubble up the hierarchy (Message → Conversation → Persona).
///
/// ## Observing Changes
///
/// In view controllers:
/// ```swift
/// private func observeRefreshSignals() {
///     withObservationTracking {
///         _ = PolyRefreshCoordinator.shared.signal(for: "Conversation")
///     } onChange: { [weak self] in
///         Task { @MainActor in
///             self?.handleConversationsChanged()
///             self?.observeRefreshSignals()
///         }
///     }
/// }
/// ```
@Observable
@MainActor
public final class PolyRefreshCoordinator {
    // MARK: - Singleton

    public static let shared: PolyRefreshCoordinator = .init()

    // MARK: - Storage

    /// Dynamic signals for registered entity types.
    /// Key is entity type (e.g., "Message", "Conversation")
    /// Value is the signal counter that increments on change.
    private var signals: [String: Int] = [:]

    /// Last change details for each entity type.
    private var lastChanges: [String: EntityChange] = [:]

    /// Hierarchical relationships: child entity type → parent entity type.
    /// Example: "Message" → "Conversation", "Conversation" → "Persona"
    private var hierarchy: [String: String] = [:]

    /// Registered entity types for validation.
    private var registeredTypes: Set<String> = []

    private init() {}

    // MARK: - Registration

    /// Register an entity type for refresh coordination.
    ///
    /// Call this at app startup for each entity type you want to track.
    /// Optionally specify a parent for hierarchical bubbling.
    ///
    /// - Parameters:
    ///   - entityType: The entity type name (e.g., "Message", "Conversation").
    ///   - parent: Optional parent entity type for hierarchical bubbling.
    ///
    /// - Note: If a parent is specified, changes to this entity will also
    ///   trigger the parent's signal, creating cascading updates.
    public func register(_ entityType: String, parent: String? = nil) {
        self.registeredTypes.insert(entityType)
        self.signals[entityType] = 0

        if let parent {
            self.hierarchy[entityType] = parent
        }

        #if DEBUG
            print("PolyRefresh: Registered '\(entityType)'" + (parent != nil ? " with parent '\(parent!)'" : ""))
        #endif
    }

    // MARK: - Signals

    /// Get the current signal value for an entity type.
    ///
    /// Use this inside `withObservationTracking` to observe changes:
    /// ```swift
    /// withObservationTracking {
    ///     _ = PolyRefreshCoordinator.shared.signal(for: "Message")
    /// } onChange: {
    ///     handleMessageChanged()
    /// }
    /// ```
    ///
    /// - Parameter entityType: The entity type to observe.
    /// - Returns: The current signal value (increments on each change).
    public func signal(for entityType: String) -> Int {
        self.signals[entityType] ?? 0
    }

    /// Get the most recent change details for an entity type.
    ///
    /// Returns nil if no changes have occurred since registration.
    ///
    /// - Parameter entityType: The entity type to query.
    /// - Returns: The most recent EntityChange, or nil if none.
    public func lastChange(for entityType: String) -> EntityChange? {
        self.lastChanges[entityType]
    }

    // MARK: - Notify Methods

    /// Notify that entities of a given type have changed.
    ///
    /// This increments the signal for the entity type, triggering observers.
    /// If the entity type has a parent in the hierarchy, the change bubbles up.
    ///
    /// - Parameters:
    ///   - entityType: The entity type that changed (e.g., "Message").
    ///   - change: Details about what changed.
    public func notify(_ entityType: String, change: EntityChange) {
        #if DEBUG
            if !self.registeredTypes.contains(entityType) {
                print("⚠️ PolyRefresh: Warning - notifying unregistered entity type '\(entityType)'")
            }
        #endif

        // Store change details
        self.lastChanges[entityType] = change

        // Increment signal (triggers observers)
        self.signals[entityType, default: 0] &+= 1

        #if DEBUG
            print("PolyRefresh: '\(entityType)' changed (\(change.changeType), \(change.entityIDs.count) entities)")
        #endif

        // Bubble up hierarchy
        self.bubbleUpHierarchy(from: entityType, sourceChange: change)
    }

    /// Notify that entities changed without specific details.
    ///
    /// Use when you don't have specific change information (e.g., after bulk sync).
    ///
    /// - Parameter entityType: The entity type that changed.
    public func notify(_ entityType: String) {
        self.notify(entityType, change: EntityChange(changeType: .update, entityIDs: []))
    }

    /// Notify that all registered entity types should refresh.
    ///
    /// Use sparingly - this triggers all signals. Appropriate after sign-in,
    /// full resync, or cache invalidation.
    public func notifyAll() {
        for entityType in self.registeredTypes {
            self.signals[entityType, default: 0] &+= 1
        }

        #if DEBUG
            print("PolyRefresh: All entity types signaled for refresh")
        #endif
    }

    // MARK: - Inspection

    /// Get all registered entity types.
    ///
    /// Useful for debugging or building dynamic UIs.
    ///
    /// - Returns: Set of all registered entity type names.
    public func registeredEntityTypes() -> Set<String> {
        self.registeredTypes
    }

    /// Get the parent entity type for a given entity type, if any.
    ///
    /// - Parameter entityType: The entity type to query.
    /// - Returns: The parent entity type, or nil if none.
    public func parent(of entityType: String) -> String? {
        self.hierarchy[entityType]
    }

    // MARK: - Hierarchical Bubbling

    /// Bubble changes up the hierarchy.
    ///
    /// When a child entity changes, parent entities need to know (e.g., when a message
    /// changes, the conversation's metadata like lastMessageTime needs updating).
    ///
    /// - Parameters:
    ///   - entityType: The entity type that changed.
    ///   - sourceChange: The original change that triggered bubbling.
    private func bubbleUpHierarchy(from entityType: String, sourceChange: EntityChange) {
        guard let parentType = hierarchy[entityType] else { return }

        // Create parent change using the child's parentID (if available)
        // For example: Message change with conversationID becomes Conversation update
        let parentChange = EntityChange(
            changeType: .update,
            entityID: sourceChange.parentID ?? "",
            parentID: nil,
        )

        self.lastChanges[parentType] = parentChange
        self.signals[parentType, default: 0] &+= 1

        #if DEBUG
            print("PolyRefresh: Bubbled '\(entityType)' change to parent '\(parentType)'")
        #endif

        // Continue bubbling up (e.g., Conversation → Persona)
        self.bubbleUpHierarchy(from: parentType, sourceChange: parentChange)
    }
}
