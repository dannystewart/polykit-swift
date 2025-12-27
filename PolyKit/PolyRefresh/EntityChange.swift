//
//  EntityChange.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

// MARK: - EntityChange

/// Describes a change to entities for UI refresh purposes.
///
/// Provides medium granularity: you know what type of change occurred
/// and which entities were affected, without carrying full entity objects.
public struct EntityChange: Sendable {
    /// The type of change that occurred.
    public enum ChangeType: Sendable {
        case insert
        case update
        case delete
    }

    /// What kind of change occurred.
    public let changeType: ChangeType

    /// IDs of the entities that changed.
    public let entityIDs: Set<String>

    /// Parent entity ID for hierarchical relationships.
    /// - For messages: the conversationID
    /// - For conversations: the personaID
    /// - For tasks: the projectID
    /// - For entities with no parent: nil
    public let parentID: String?

    /// Convenience initializer for single-entity changes.
    public init(changeType: ChangeType, entityID: String, parentID: String? = nil) {
        self.changeType = changeType
        self.entityIDs = [entityID]
        self.parentID = parentID
    }

    /// Initializer for batch changes.
    public init(changeType: ChangeType, entityIDs: Set<String>, parentID: String? = nil) {
        self.changeType = changeType
        self.entityIDs = entityIDs
        self.parentID = parentID
    }
}
