//
//  PolySyncCoordinator.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import SwiftData

// MARK: - PolySyncCoordinator

/// Centralized coordinator for all data mutations with Supabase sync.
///
/// This service guarantees consistent handling of:
/// 1. **Version incrementing** - Automatic version bump for conflict resolution
/// 2. **Local persistence** - SwiftData save
/// 3. **Remote sync** - Supabase push with echo tracking
/// 4. **UI notification** - NotificationCenter posts
/// 5. **Hierarchy bumping** - Child changes bump parent versions
///
/// ## Usage
///
/// ```swift
/// // Initialize once at app startup
/// PolySyncCoordinator.shared.initialize(with: modelContext)
///
/// // Persist changes
/// task.title = "Updated"
/// try await PolySyncCoordinator.shared.persistChange(task)
///
/// // Delete (tombstone pattern)
/// try await PolySyncCoordinator.shared.delete(task)
/// ```
@MainActor
public final class PolySyncCoordinator {
    // MARK: - Errors

    public enum CoordinatorError: LocalizedError {
        case noModelContext
        case entityNotRegistered(String)
        case saveFailed(Error)
        case pushFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .noModelContext:
                "PolySyncCoordinator: No model context available"
            case let .entityNotRegistered(type):
                "PolySyncCoordinator: Entity type '\(type)' not registered"
            case let .saveFailed(error):
                "PolySyncCoordinator: Save failed - \(error.localizedDescription)"
            case let .pushFailed(error):
                "PolySyncCoordinator: Push failed - \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Singleton

    public static let shared: PolySyncCoordinator = .init()

    // MARK: - Dependencies

    private weak var modelContext: ModelContext?
    private let registry: PolyBaseRegistry = .shared
    private let pushEngine: PolyPushEngine = .shared

    private init() {}

    // MARK: - Initialization

    /// Initialize with the app's model context.
    /// Call this once during app startup.
    public func initialize(with context: ModelContext) {
        guard modelContext == nil else {
            polyDebug("PolySyncCoordinator already initialized")
            return
        }
        modelContext = context
        polyInfo("PolySyncCoordinator initialized")
    }

    // MARK: - Persist Change (Update Existing)

    /// Persist a change to an entity with full lifecycle handling.
    ///
    /// This method handles the complete persistence lifecycle:
    /// 1. Increments the entity's version
    /// 2. Saves to SwiftData
    /// 3. Pushes to Supabase (with echo tracking)
    /// 4. Bumps parent hierarchy versions (if configured)
    /// 5. Posts UI notification (if configured)
    ///
    /// - Parameters:
    ///   - entity: The entity that was modified
    ///   - bumpVersion: Whether to increment the version (default: true)
    ///   - bumpHierarchy: Whether to bump parent versions (default: true)
    /// - Throws: If save or push fails
    public func persistChange<Entity: PolySyncable>(
        _ entity: Entity,
        bumpVersion: Bool = true,
        bumpHierarchy: Bool = true,
    ) async throws {
        let context = try requireContext()

        guard let config = registry.config(for: Entity.self) else {
            throw CoordinatorError.entityNotRegistered(String(describing: Entity.self))
        }

        // 1. Increment version (entity is a class, so we can mutate directly)
        if bumpVersion {
            entity.version &+= 1
        }

        // 2. Bump hierarchy if configured
        if bumpHierarchy, let parentRelation = config.parentRelation {
            try bumpParentHierarchy(
                parentID: parentRelation.getParentID(from: entity),
                parentTable: parentRelation.parentTableName,
                context: context,
            )
        }

        // 3. Save locally
        try context.save()

        // 4. Push to Supabase with echo tracking
        pushEngine.markAsPushed(entity.id, table: config.tableName)
        Task {
            do {
                try await pushEngine.push(entity)

                // Push parent if hierarchy was bumped
                if bumpHierarchy, let parentRelation = config.parentRelation {
                    await pushParentHierarchy(
                        parentID: parentRelation.getParentID(from: entity),
                        parentTable: parentRelation.parentTableName,
                        context: context,
                    )
                }
            } catch {
                polyError("PolySyncCoordinator: Push failed for \(Entity.self) \(entity.id): \(error)")
            }
        }

        // 5. Post notification
        if let notification = config.notification {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    /// Persist changes to multiple entities in a single batch operation.
    ///
    /// More efficient than calling `persistChange` in a loop.
    public func persistChanges<Entity: PolySyncable>(
        _ entities: [Entity],
        bumpVersion: Bool = true,
        bumpHierarchy: Bool = true,
    ) async throws {
        guard !entities.isEmpty else { return }

        let context = try requireContext()

        guard let config = registry.config(for: Entity.self) else {
            throw CoordinatorError.entityNotRegistered(String(describing: Entity.self))
        }

        // 1. Increment versions (entities are classes, so we can mutate directly)
        if bumpVersion {
            for entity in entities {
                entity.version &+= 1
            }
        }

        // 2. Collect unique parent IDs for hierarchy bumping
        var parentIDs = Set<String>()
        if bumpHierarchy, let parentRelation = config.parentRelation {
            for entity in entities {
                if let parentID = parentRelation.getParentID(from: entity) {
                    parentIDs.insert(parentID)
                }
            }
        }

        // 3. Bump parent hierarchy
        if let parentRelation = config.parentRelation {
            for parentID in parentIDs {
                try bumpParentHierarchy(
                    parentID: parentID,
                    parentTable: parentRelation.parentTableName,
                    context: context,
                )
            }
        }

        // 4. Save locally (single save)
        try context.save()

        // 5. Mark all as recently pushed
        for entity in entities {
            pushEngine.markAsPushed(entity.id, table: config.tableName)
        }

        // 6. Batch push to Supabase
        Task {
            await pushEngine.pushBatch(entities)

            // Push parents
            if let parentRelation = config.parentRelation {
                for parentID in parentIDs {
                    await pushParentHierarchy(
                        parentID: parentID,
                        parentTable: parentRelation.parentTableName,
                        context: context,
                    )
                }
            }
        }

        // 7. Post notification
        if let notification = config.notification {
            NotificationCenter.default.post(name: notification, object: nil)
        }

        polyInfo("PolySyncCoordinator: Batch persisted \(entities.count) \(Entity.self) entities")
    }

    // MARK: - Persist New (Create)

    /// Persist a newly created entity.
    ///
    /// No version increment needed for new entities.
    /// Caller should have already inserted the entity into the context.
    public func persistNew<Entity: PolySyncable>(
        _ entity: Entity,
        bumpHierarchy: Bool = true,
    ) async throws {
        let context = try requireContext()

        guard let config = registry.config(for: Entity.self) else {
            throw CoordinatorError.entityNotRegistered(String(describing: Entity.self))
        }

        // 1. Bump parent hierarchy if configured
        if bumpHierarchy, let parentRelation = config.parentRelation {
            try bumpParentHierarchy(
                parentID: parentRelation.getParentID(from: entity),
                parentTable: parentRelation.parentTableName,
                context: context,
            )
        }

        // 2. Save locally
        try context.save()

        // 3. Push to Supabase with echo tracking
        pushEngine.markAsPushed(entity.id, table: config.tableName)
        Task {
            do {
                try await pushEngine.push(entity)

                // Push parent if hierarchy was bumped
                if bumpHierarchy, let parentRelation = config.parentRelation {
                    await pushParentHierarchy(
                        parentID: parentRelation.getParentID(from: entity),
                        parentTable: parentRelation.parentTableName,
                        context: context,
                    )
                }
            } catch {
                polyError("PolySyncCoordinator: Push failed for new \(Entity.self) \(entity.id): \(error)")
            }
        }

        // 4. Post notification
        if let notification = config.notification {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    // MARK: - Delete (Tombstone Pattern)

    /// Soft-delete an entity using the tombstone pattern.
    ///
    /// Sets `deleted = true`, increments version, saves, and syncs.
    /// The entity remains in the database for sync consistency.
    public func delete<Entity: PolySyncable>(
        _ entity: Entity,
        bumpHierarchy: Bool = true,
    ) async throws {
        let context = try requireContext()

        guard let config = registry.config(for: Entity.self) else {
            throw CoordinatorError.entityNotRegistered(String(describing: Entity.self))
        }

        // 1. Mark as deleted and increment version (entity is a class)
        entity.deleted = true
        entity.version &+= 1

        // 2. Bump parent hierarchy if configured
        if bumpHierarchy, let parentRelation = config.parentRelation {
            try bumpParentHierarchy(
                parentID: parentRelation.getParentID(from: entity),
                parentTable: parentRelation.parentTableName,
                context: context,
            )
        }

        // 3. Save locally
        try context.save()

        // 4. Push tombstone to Supabase
        pushEngine.markAsPushed(entity.id, table: config.tableName)
        Task {
            do {
                try await pushEngine.push(entity)

                // Push parent
                if bumpHierarchy, let parentRelation = config.parentRelation {
                    await pushParentHierarchy(
                        parentID: parentRelation.getParentID(from: entity),
                        parentTable: parentRelation.parentTableName,
                        context: context,
                    )
                }
            } catch {
                polyError("PolySyncCoordinator: Tombstone push failed for \(Entity.self) \(entity.id): \(error)")
            }
        }

        // 5. Post notification
        if let notification = config.notification {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    /// Batch delete multiple entities.
    public func delete<Entity: PolySyncable>(
        _ entities: [Entity],
        bumpHierarchy: Bool = true,
    ) async throws {
        guard !entities.isEmpty else { return }

        let context = try requireContext()

        guard let config = registry.config(for: Entity.self) else {
            throw CoordinatorError.entityNotRegistered(String(describing: Entity.self))
        }

        // 1. Mark all as deleted and increment versions (entities are classes)
        for entity in entities {
            entity.deleted = true
            entity.version &+= 1
        }

        // 2. Collect and bump parent hierarchy
        var parentIDs = Set<String>()
        if bumpHierarchy, let parentRelation = config.parentRelation {
            for entity in entities {
                if let parentID = parentRelation.getParentID(from: entity) {
                    parentIDs.insert(parentID)
                }
            }
            for parentID in parentIDs {
                try bumpParentHierarchy(
                    parentID: parentID,
                    parentTable: parentRelation.parentTableName,
                    context: context,
                )
            }
        }

        // 3. Save locally
        try context.save()

        // 4. Mark all as recently pushed
        for entity in entities {
            pushEngine.markAsPushed(entity.id, table: config.tableName)
        }

        // 5. Batch push tombstones
        Task {
            await pushEngine.pushBatch(entities)

            // Push parents
            if let parentRelation = config.parentRelation {
                for parentID in parentIDs {
                    await pushParentHierarchy(
                        parentID: parentID,
                        parentTable: parentRelation.parentTableName,
                        context: context,
                    )
                }
            }
        }

        // 6. Post notification
        if let notification = config.notification {
            NotificationCenter.default.post(name: notification, object: nil)
        }

        polyInfo("PolySyncCoordinator: Batch deleted \(entities.count) \(Entity.self) entities")
    }

    // MARK: - Save Without Sync

    /// Save changes locally without syncing to Supabase.
    ///
    /// Use for local-only changes or when caller will handle sync manually.
    public func saveLocally<Entity: PolySyncable>(
        _ entity: Entity,
        incrementVersion: Bool = false,
    ) throws {
        let context = try requireContext()

        if incrementVersion {
            entity.version &+= 1
        }

        try context.save()

        // Post notification if configured
        if
            let config = registry.config(for: Entity.self),
            let notification = config.notification
        {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    /// Save the context without any entity-specific handling.
    public func saveContext() throws {
        let context = try requireContext()
        try context.save()
    }

    /// Get the current model context or throw.
    private func requireContext() throws -> ModelContext {
        guard let context = modelContext else {
            throw CoordinatorError.noModelContext
        }
        return context
    }

    // MARK: - Hierarchy Bumping

    /// Bump a parent entity's version.
    ///
    /// This is a generic implementation that requires the parent
    /// to also be a PolySyncable registered entity.
    private func bumpParentHierarchy(
        parentID: String?,
        parentTable: String,
        context _: ModelContext,
    ) throws {
        guard let parentID, !parentID.isEmpty else { return }

        // Verify parent is registered
        guard registry.config(forTable: parentTable) != nil else {
            polyWarning("PolySyncCoordinator: Parent table '\(parentTable)' not registered")
            return
        }

        // The actual fetch and bump needs to be done by the app
        // since we don't know the concrete parent type here.
        // Post a notification that the parent should be bumped.
        NotificationCenter.default.post(
            name: .polyBaseShouldBumpParent,
            object: nil,
            userInfo: [
                "parentID": parentID,
                "parentTable": parentTable,
            ],
        )
    }

    /// Push parent hierarchy after bumping.
    private func pushParentHierarchy(
        parentID _: String?,
        parentTable _: String,
        context _: ModelContext)
        async
    {
        // Similar to above - the app handles the actual push
        // since we don't know the concrete type.
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when a parent entity should be bumped.
    /// Apps should listen for this and perform the actual bump.
    static let polyBaseShouldBumpParent = Notification.Name("polyBaseShouldBumpParent")

    /// Posted when sync completes.
    static let polyBaseSyncDidComplete = Notification.Name("polyBaseSyncDidComplete")

    /// Posted when sync encounters an error.
    static let polyBaseSyncDidFail = Notification.Name("polyBaseSyncDidFail")
}
