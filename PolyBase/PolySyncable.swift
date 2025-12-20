//
//  PolySyncable.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import SwiftData

// MARK: - PolySyncable

/// Protocol for entities that can be synchronized with Supabase.
///
/// All syncable entities must have these fields for consistent conflict resolution:
/// - `id`: Unique identifier (typically a ULID or UUID string)
/// - `version`: Incremented on each change for conflict resolution (higher wins)
/// - `deleted`: Soft delete flag for the tombstone pattern
///
/// ## Usage
///
/// ```swift
/// @Model
/// final class Task: PolySyncable {
///     var id: String = ""
///     var version: Int = 0
///     var deleted: Bool = false
///
///     var title: String = ""
///     var completed: Bool = false
/// }
/// ```
///
/// ## Conflict Resolution
///
/// The sync engine uses version-based conflict resolution:
/// 1. Higher version always wins
/// 2. On version tie, remote wins (prevents data loss)
/// 3. Deletion drift is healed at same version
///
/// ## Tombstone Pattern
///
/// Entities are never hard-deleted. Instead:
/// 1. `deleted` is set to `true`
/// 2. `version` is incremented
/// 3. Entity is pushed to Supabase
/// 4. Entity remains in local database for sync consistency
///
/// This ensures deletions propagate correctly across devices.
public protocol PolySyncable: PersistentModel {
    /// Unique identifier for this entity.
    /// Typically a ULID or UUID string.
    var id: String { get }

    /// Version number for conflict resolution.
    /// Incremented on each change. Higher version wins during sync.
    var version: Int { get set }

    /// Soft delete flag.
    /// When true, entity is treated as deleted but kept for sync.
    var deleted: Bool { get set }
}

// MARK: - PolySyncable Convenience

public extension PolySyncable {
    /// Whether this entity is active (not deleted).
    var isActive: Bool { !deleted }

    /// Increment the version number.
    /// Uses wrapping addition to handle overflow gracefully.
    func bumpVersion() {
        version &+= 1
    }

    /// Mark this entity as deleted (tombstone pattern).
    /// Also increments the version to ensure the deletion syncs.
    func markDeleted() {
        deleted = true
        version &+= 1
    }
}

// MARK: - PolySyncState

/// Represents the sync state of an entity.
public enum PolySyncState: String, Sendable {
    /// Entity is synced with remote
    case synced

    /// Entity has local changes not yet pushed
    case pendingPush

    /// Entity has remote changes not yet merged
    case pendingPull

    /// Entity has conflicts that need resolution
    case conflict
}

// MARK: - PolySyncMetadata

/// Metadata tracked for sync operations.
///
/// This can be used by apps that need to track additional sync state
/// beyond what's in the entity itself.
public struct PolySyncMetadata: Sendable {
    /// When this entity was last synced
    public var lastSyncTime: Date?

    /// Current sync state
    public var syncState: PolySyncState

    /// Error message if sync failed
    public var lastError: String?

    public init(
        lastSyncTime: Date? = nil,
        syncState: PolySyncState = .synced,
        lastError: String? = nil,
    ) {
        self.lastSyncTime = lastSyncTime
        self.syncState = syncState
        self.lastError = lastError
    }
}
