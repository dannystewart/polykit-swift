//
//  PolyConflictResolution.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

// MARK: - VersionState

/// Version state for reconciliation comparisons.
///
/// Represents the sync-relevant state of an entity: its version number and deletion status.
/// Used by reconciliation logic to compare local and remote states.
public struct VersionState: Sendable, Equatable, Hashable {
    /// The entity's version number.
    public let version: Int

    /// Whether the entity is marked as deleted (tombstone).
    public let deleted: Bool

    public init(version: Int, deleted: Bool) {
        self.version = version
        self.deleted = deleted
    }
}

// MARK: - ReconcileAction

/// Action to take for a single entity during reconciliation.
public enum ReconcileAction: Sendable {
    /// Remote is newer, fetch full record and merge locally.
    case pull

    /// Local is newer, push to remote.
    case push

    /// Remote is deleted with sufficient version, mark local as deleted.
    case adoptTombstone

    /// No action needed (versions match, same state).
    case skip

    /// Remote exists but local doesn't, create locally.
    case createLocal

    /// Local exists but remote doesn't, create remotely.
    case createRemote
}

// MARK: - Constants

/// Server-enforced safety threshold for undeletes.
///
/// The database allows `deleted=true -> deleted=false` only when the incoming version is at least
/// `old.version + Δ`. This prevents accidental resurrection while preserving a manual escape hatch.
public let defaultUndeleteVersionDelta: Int = 1000

// MARK: - Conflict Resolution

/// Determine what reconciliation action to take for a single entity.
///
/// This is the core conflict resolution logic for sync. It implements a deterministic set of rules
/// that ensure consistency across devices while preventing accidental data resurrection.
///
/// ## Key Rules
///
/// 1. **Tombstone Always Wins**: If remote is deleted and local isn't, adopt the tombstone.
///    This prevents accidental resurrection of deleted items via sync. Deletion is an explicit
///    user action that should never be overridden by sync.
///
/// 2. **Undelete Escape Hatch**: To intentionally undelete, local version must be at least
///    `remoteVersion + undeleteVersionDelta` (default 1000). This allows manual recovery
///    while preventing accidental resurrection.
///
/// 3. **Local Deletion Propagates**: If local is deleted but remote isn't, push the deletion.
///    This ensures deletions sync in both directions.
///
/// 4. **Higher Version Wins**: For non-deleted entities, higher version takes precedence.
///    This is the standard optimistic concurrency control rule.
///
/// 5. **Same Version = Skip**: If versions match and deletion state matches, no action needed.
///
/// - Parameters:
///   - localVersion: The local entity's version (-1 if entity doesn't exist locally)
///   - localDeleted: Whether the local entity is marked as deleted
///   - remoteVersion: The remote entity's version (-1 if entity doesn't exist remotely)
///   - remoteDeleted: Whether the remote entity is marked as deleted
///   - undeleteVersionDelta: Version jump required to intentionally undelete (default 1000)
/// - Returns: The action to take for this entity
public func determineReconcileAction(
    localVersion: Int,
    localDeleted: Bool,
    remoteVersion: Int,
    remoteDeleted: Bool,
    undeleteVersionDelta: Int = defaultUndeleteVersionDelta
) -> ReconcileAction {
    // Rule 1: Tombstone always wins (unless undelete escape hatch)
    // If remote is deleted and local isn't, adopt the tombstone regardless of version.
    // Deletion is an explicit user action — never resurrect via sync.
    if remoteDeleted, !localDeleted {
        // Allow intentional undelete only if local version is high enough
        if localVersion >= remoteVersion + undeleteVersionDelta {
            return .push
        }
        return .adoptTombstone
    }

    // Rule 2: Local deletion propagates to remote
    // If local is deleted but remote isn't, push the deletion
    if localDeleted, !remoteDeleted {
        return .push
    }

    // At this point, both have the same deleted state

    // Rule 3: Higher version wins
    if remoteVersion > localVersion {
        return .pull
    }
    if localVersion > remoteVersion {
        return .push
    }

    // Rule 4: Same version, same state -> skip
    return .skip
}

/// Convenience for when entity doesn't exist on one side.
///
/// This is a specialized version of `determineReconcileAction` for the case where one side
/// is completely missing (not just deleted). Use this when you've already determined that
/// an entity exists only on one side.
///
/// - Parameters:
///   - localExists: Whether the entity exists locally
///   - remoteExists: Whether the entity exists remotely
///   - localDeleted: If local exists, whether it's deleted
///   - remoteDeleted: If remote exists, whether it's deleted
/// - Returns: `.createLocal`, `.createRemote`, or `.skip`
public func determineCreateAction(
    localExists: Bool,
    remoteExists: Bool,
    localDeleted: Bool = false,
    remoteDeleted: Bool = false
) -> ReconcileAction {
    if remoteExists, !localExists {
        // Remote exists, local doesn't -> pull (create locally)
        // But skip if it's a tombstone (don't create deleted entities)
        return remoteDeleted ? .skip : .createLocal
    }

    if localExists, !remoteExists {
        // Local exists, remote doesn't -> push (create remotely)
        // But skip if it's a local tombstone (nothing to push)
        return localDeleted ? .skip : .createRemote
    }

    return .skip
}
