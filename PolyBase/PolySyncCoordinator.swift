//
//  PolySyncCoordinator.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase
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

    /// Offline queue for failed push operations.
    /// Operations are persisted to disk and retried when connectivity returns.
    private lazy var offlineQueue: PolyBaseOfflineQueue = .init()

    /// Whether there are pending offline operations.
    public var hasPendingOfflineOperations: Bool {
        offlineQueue.hasPendingOperations
    }

    /// Number of pending offline operations.
    public var pendingOfflineOperationCount: Int {
        offlineQueue.pendingCount
    }

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

        // 4. Capture parent info and build record BEFORE any async work
        // (SwiftData entities can become stale after async operations)
        let entityID = entity.id
        let tableName = config.tableName
        let parentID = bumpHierarchy ? config.parentRelation?.getParentID(from: entity) : nil
        let parentTable = bumpHierarchy ? config.parentRelation?.parentTableName : nil

        // Build record now (before push) so we can queue it if push fails
        let record: [String: AnyJSON]
        do {
            record = try pushEngine.buildRecord(from: entity, config: config)
        } catch {
            polyError("PolySyncCoordinator: Failed to build record for \(Entity.self) \(entityID): \(error)")
            return
        }

        // 5. Push to Supabase (await to ensure correct state is pushed)
        pushEngine.markAsPushed(entityID, table: tableName)
        do {
            try await pushEngine.pushRawRecord(record, to: tableName)

            // Push parent if hierarchy was bumped
            if let parentID, let parentTable {
                await pushParentHierarchy(
                    parentID: parentID,
                    parentTable: parentTable,
                    context: context,
                )
            }
        } catch {
            polyError("PolySyncCoordinator: Push failed for \(Entity.self) \(entityID), queueing for retry: \(error)")
            queueOperation(table: tableName, action: .update, record: record, entityId: entityID)
        }

        // 6. Post notification
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

        // 5. Capture parent info before async work
        let tableName = config.tableName
        let parentTable = config.parentRelation?.parentTableName

        // 6. Mark all as recently pushed
        for entity in entities {
            pushEngine.markAsPushed(entity.id, table: tableName)
        }

        // 7. Batch push to Supabase (await to ensure correct state is pushed)
        await pushEngine.pushBatch(entities)

        // Push parents
        if let parentTable {
            for parentID in parentIDs {
                await pushParentHierarchy(
                    parentID: parentID,
                    parentTable: parentTable,
                    context: context,
                )
            }
        }

        // 8. Post notification
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

        // 3. Capture values and build record before async work
        let entityID = entity.id
        let tableName = config.tableName
        let parentID = bumpHierarchy ? config.parentRelation?.getParentID(from: entity) : nil
        let parentTable = bumpHierarchy ? config.parentRelation?.parentTableName : nil

        // Build record now (before push) so we can queue it if push fails
        let record: [String: AnyJSON]
        do {
            record = try pushEngine.buildRecord(from: entity, config: config)
        } catch {
            polyError("PolySyncCoordinator: Failed to build record for new \(Entity.self) \(entityID): \(error)")
            return
        }

        // 4. Push to Supabase (await to ensure correct state is pushed)
        pushEngine.markAsPushed(entityID, table: tableName)
        do {
            try await pushEngine.pushRawRecord(record, to: tableName)

            // Push parent if hierarchy was bumped
            if let parentID, let parentTable {
                await pushParentHierarchy(
                    parentID: parentID,
                    parentTable: parentTable,
                    context: context,
                )
            }
        } catch {
            polyError("PolySyncCoordinator: Push failed for new \(Entity.self) \(entityID), queueing for retry: \(error)")
            queueOperation(table: tableName, action: .insert, record: record, entityId: entityID)
        }

        // 5. Post notification
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

        // 2. Capture values IMMEDIATELY after mutation (before save can cause staleness)
        let entityID = entity.id
        let entityVersion = entity.version
        let entityDeleted = entity.deleted
        let tableName = config.tableName
        let parentID = bumpHierarchy ? config.parentRelation?.getParentID(from: entity) : nil
        let parentTable = bumpHierarchy ? config.parentRelation?.parentTableName : nil

        // 3. Bump parent hierarchy if configured
        if bumpHierarchy, let parentRelation = config.parentRelation {
            try bumpParentHierarchy(
                parentID: parentID,
                parentTable: parentRelation.parentTableName,
                context: context,
            )
        }

        // 4. Save locally
        try context.save()

        // 5. Push tombstone to Supabase (use UPDATE, not upsert - row already exists)
        pushEngine.markAsPushed(entityID, table: tableName)
        do {
            try await pushEngine.updateTombstone(
                id: entityID,
                version: entityVersion,
                deleted: entityDeleted,
                tableName: tableName,
            )

            // Push parent if hierarchy was bumped
            if let parentID, let parentTable {
                await pushParentHierarchy(
                    parentID: parentID,
                    parentTable: parentTable,
                    context: context,
                )
            }
        } catch {
            polyError("PolySyncCoordinator: Tombstone push failed for \(Entity.self) \(entityID), queueing for retry: \(error)")

            // Build tombstone record for queueing
            var tombstoneRecord: [String: AnyJSON] = [
                "id": .string(entityID),
                "version": .integer(entityVersion),
                "deleted": .bool(entityDeleted),
                "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
            ]
            if let userID = PolyBaseAuth.shared.userID {
                tombstoneRecord["user_id"] = .string(userID.uuidString)
            }
            queueOperation(table: tableName, action: .delete, record: tombstoneRecord, entityId: entityID)
        }

        // 6. Post notification
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

        // 2. Capture tombstone data IMMEDIATELY after mutation (before save can cause staleness)
        let tableName = config.tableName
        let parentTable = config.parentRelation?.parentTableName
        let tombstones: [(id: String, version: Int, deleted: Bool)] = entities.map { entity in
            (id: entity.id, version: entity.version, deleted: entity.deleted)
        }

        // 3. Collect and bump parent hierarchy
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

        // 4. Save locally
        try context.save()

        // 5. Mark all as recently pushed
        for tombstone in tombstones {
            pushEngine.markAsPushed(tombstone.id, table: tableName)
        }

        // 6. Batch update tombstones (use UPDATE, not upsert)
        _ = await pushEngine.updateTombstones(tableName: tableName, tombstones: tombstones)

        // Push parents
        if let parentTable {
            for parentID in parentIDs {
                await pushParentHierarchy(
                    parentID: parentID,
                    parentTable: parentTable,
                    context: context,
                )
            }
        }

        // 7. Post notification
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

    /// Process all queued offline operations.
    ///
    /// Call this when the app launches, when network connectivity returns,
    /// or at any time you want to retry failed operations.
    ///
    /// - Returns: The number of operations successfully processed.
    @discardableResult
    public func processOfflineQueue() async -> Int {
        guard offlineQueue.hasPendingOperations else { return 0 }

        polyInfo("PolySyncCoordinator: Processing \(offlineQueue.pendingCount) offline operations")

        return await offlineQueue.processQueue { [weak self] operation in
            guard let self else { return }

            switch operation.action {
            case .insert, .update:
                // Decode the record and push
                guard let payload = operation.payload else {
                    throw CoordinatorError.pushFailed(NSError(domain: "PolyBase", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "No payload for \(operation.action)",
                    ]))
                }

                let record = try JSONDecoder().decode([String: AnyJSON].self, from: payload)
                try await pushEngine.pushRawRecord(record, to: operation.table)

            case .delete:
                // Decode tombstone record and push as update
                guard let payload = operation.payload else {
                    throw CoordinatorError.pushFailed(NSError(domain: "PolyBase", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "No payload for delete",
                    ]))
                }

                let record = try JSONDecoder().decode([String: AnyJSON].self, from: payload)

                // Extract version from record
                let version = record["version"]?.integerValue ?? 1
                let deleted = record["deleted"]?.boolValue ?? true

                try await pushEngine.updateTombstone(
                    id: operation.entityId,
                    version: version,
                    deleted: deleted,
                    tableName: operation.table,
                )
            }

            polyDebug("PolySyncCoordinator: Processed queued \(operation.action.rawValue) for \(operation.table)/\(operation.entityId)")
        }
    }

    /// Clear all pending offline operations.
    ///
    /// Use with caution - this discards all queued operations without retrying them.
    public func clearOfflineQueue() {
        offlineQueue.clearQueue()
        polyInfo("PolySyncCoordinator: Offline queue cleared")
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

    // MARK: - Offline Queue

    /// Queue a failed push operation for later retry.
    private func queueOperation(
        table: String,
        action: PolyBaseOfflineOperation.Action,
        record: [String: AnyJSON],
        entityId: String,
    ) {
        // Encode the record as JSON data
        guard let payload = try? JSONEncoder().encode(record) else {
            polyError("PolySyncCoordinator: Failed to encode record for offline queue")
            return
        }

        offlineQueue.enqueue(
            table: table,
            action: action,
            payload: payload,
            entityId: entityId,
        )

        polyInfo("PolySyncCoordinator: Queued \(action.rawValue) for \(table)/\(entityId)")
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
