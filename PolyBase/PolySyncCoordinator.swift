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

    /// Handle a push error, distinguishing between retryable and permanent failures.
    ///
    /// - Version regression: Don't queue, post notification to trigger reconcile
    /// - Invalid undelete: Don't queue, post notification to trigger reconcile
    /// - Same-version: Ignore (benign duplicate)
    /// - Other errors: Queue for retry (transient failure)
    private struct PushErrorContext {
        let error: Error
        let entityType: String
        let entityId: String
        let tableName: String
        let record: [String: AnyJSON]
        let action: PolyBaseOfflineOperation.Action
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
        self.offlineQueue.hasPendingOperations
    }

    /// Number of pending offline operations.
    public var pendingOfflineOperationCount: Int {
        self.offlineQueue.pendingCount
    }

    private init() {}

    /// Check if an error is permanent (should not be retried).
    ///
    /// Permanent errors include:
    /// - Version regression (local version < remote)
    /// - Immutable field violations (e.g., created_at)
    /// - Same-version mutations (already at that version)
    /// - Invalid undelete attempts (requires version >= old + 1000)
    private nonisolated static func isPermanentOfflineQueueError(_ error: Error) -> Bool {
        let errorString = String(describing: error)
        return errorString.contains("version regression") ||
            errorString.contains("is immutable") ||
            errorString.contains("same-version mutation") ||
            errorString.contains("undelete requires version")
    }

    // MARK: - Initialization

    /// Initialize with the app's model context.
    /// Call this once during app startup.
    public func initialize(with context: ModelContext) {
        guard self.modelContext == nil else {
            polyDebug("PolySyncCoordinator already initialized")
            return
        }
        self.modelContext = context
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
            try self.bumpParentHierarchy(
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
            record = try self.pushEngine.buildRecord(from: entity, config: config)
        } catch {
            polyError("PolySyncCoordinator: Failed to build record for \(Entity.self) \(entityID): \(error)")
            return
        }

        // 5. Push to Supabase (non-blocking with offline queue backup)
        // We spawn a Task to avoid blocking the main thread on network I/O.
        // The offline queue handles retry if the push fails.
        self.pushEngine.markAsPushed(entityID, table: tableName)
        let entityType = String(describing: Entity.self)
        Task { [weak self, pushEngine] in
            guard let self else { return }
            do {
                try await pushEngine.pushRawRecord(record, to: tableName)

                // Push parent if hierarchy was bumped
                if let parentID, let parentTable {
                    await self.pushParentHierarchy(
                        parentID: parentID,
                        parentTable: parentTable,
                        context: context,
                    )
                }
            } catch {
                self.handlePushError(PushErrorContext(
                    error: error,
                    entityType: entityType,
                    entityId: entityID,
                    tableName: tableName,
                    record: record,
                    action: .update,
                ))
            }
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
                try self.bumpParentHierarchy(
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
            self.pushEngine.markAsPushed(entity.id, table: tableName)
        }

        // 7. Batch push to Supabase (non-blocking)
        let capturedParentIDs = parentIDs
        Task { [weak self, pushEngine] in
            guard let self else { return }
            await pushEngine.pushBatch(entities)

            // Push parents
            if let parentTable {
                for parentID in capturedParentIDs {
                    await self.pushParentHierarchy(
                        parentID: parentID,
                        parentTable: parentTable,
                        context: context,
                    )
                }
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
            try self.bumpParentHierarchy(
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
            record = try self.pushEngine.buildRecord(from: entity, config: config)
        } catch {
            polyError("PolySyncCoordinator: Failed to build record for new \(Entity.self) \(entityID): \(error)")
            return
        }

        // 4. Push to Supabase (non-blocking with offline queue backup)
        self.pushEngine.markAsPushed(entityID, table: tableName)
        let entityType = String(describing: Entity.self)
        Task { [weak self, pushEngine] in
            guard let self else { return }
            do {
                try await pushEngine.pushRawRecord(record, to: tableName)

                // Push parent if hierarchy was bumped
                if let parentID, let parentTable {
                    await self.pushParentHierarchy(
                        parentID: parentID,
                        parentTable: parentTable,
                        context: context,
                    )
                }
            } catch {
                self.handlePushError(PushErrorContext(
                    error: error,
                    entityType: entityType,
                    entityId: entityID,
                    tableName: tableName,
                    record: record,
                    action: .insert,
                ))
            }
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
            try self.bumpParentHierarchy(
                parentID: parentID,
                parentTable: parentRelation.parentTableName,
                context: context,
            )
        }

        // 4. Save locally
        try context.save()

        // 5. Push tombstone to Supabase (non-blocking, use UPDATE not upsert)
        self.pushEngine.markAsPushed(entityID, table: tableName)
        let entityType = String(describing: Entity.self)
        Task { [weak self, pushEngine] in
            guard let self else { return }
            do {
                try await pushEngine.updateTombstone(
                    id: entityID,
                    version: entityVersion,
                    deleted: entityDeleted,
                    tableName: tableName,
                )

                // Push parent if hierarchy was bumped
                if let parentID, let parentTable {
                    await self.pushParentHierarchy(
                        parentID: parentID,
                        parentTable: parentTable,
                        context: context,
                    )
                }
            } catch {
                // Build tombstone record for potential queueing
                var tombstoneRecord: [String: AnyJSON] = [
                    "id": .string(entityID),
                    "version": .integer(entityVersion),
                    "deleted": .bool(entityDeleted),
                    "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
                ]
                if let userID = PolyBaseAuth.shared.userID {
                    tombstoneRecord["user_id"] = .string(userID.uuidString)
                }

                self.handlePushError(PushErrorContext(
                    error: error,
                    entityType: entityType,
                    entityId: entityID,
                    tableName: tableName,
                    record: tombstoneRecord,
                    action: .delete,
                ))
            }
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
        let tombstones: [TombstoneRecord] = entities.map { entity in
            TombstoneRecord(id: entity.id, version: entity.version, deleted: entity.deleted)
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
                try self.bumpParentHierarchy(
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
            self.pushEngine.markAsPushed(tombstone.id, table: tableName)
        }

        // 6. Batch update tombstones (non-blocking, use UPDATE not upsert)
        let capturedParentIDs = parentIDs
        Task { [weak self, pushEngine] in
            guard let self else { return }
            _ = await pushEngine.updateTombstones(tableName: tableName, tombstones: tombstones)

            // Push parents
            if let parentTable {
                for parentID in capturedParentIDs {
                    await self.pushParentHierarchy(
                        parentID: parentID,
                        parentTable: parentTable,
                        context: context,
                    )
                }
            }
        }

        // 7. Post notification
        if let notification = config.notification {
            NotificationCenter.default.post(name: notification, object: nil)
        }

        polyInfo("PolySyncCoordinator: Batch deleted \(entities.count) \(Entity.self) entities")
    }

    // MARK: - Undelete

    /// Explicitly undelete an entity using the +1000 version rule.
    ///
    /// This is the **only** way to resurrect a deleted entity. Normal sync operations
    /// enforce "tombstone always wins" — a deleted entity stays deleted regardless of
    /// version. The +1000 version jump signals intentional undelete and is honored
    /// by both the sync engine and database guards.
    ///
    /// Use this for explicit "restore" or "undo delete" features in your app.
    ///
    /// - Parameter entity: The deleted entity to restore
    /// - Throws: If the entity isn't registered or save/push fails
    public func undelete<Entity: PolySyncable>(_ entity: Entity) async throws {
        let context = try requireContext()

        guard let config = registry.config(for: Entity.self) else {
            throw CoordinatorError.entityNotRegistered(String(describing: Entity.self))
        }

        guard entity.deleted else {
            polyWarning("PolySyncCoordinator: Entity \(entity.id) is not deleted, nothing to undelete")
            return
        }

        // The +1000 version jump signals intentional undelete
        entity.deleted = false
        entity.version += 1000

        // Capture values before async work
        let entityID = entity.id
        let tableName = config.tableName

        // Build record before push
        let record: [String: AnyJSON]
        do {
            record = try self.pushEngine.buildRecord(from: entity, config: config)
        } catch {
            polyError("PolySyncCoordinator: Failed to build record for undelete \(Entity.self) \(entityID): \(error)")
            return
        }

        // Save locally
        try context.save()

        // Push to Supabase (non-blocking)
        self.pushEngine.markAsPushed(entityID, table: tableName)
        let entityType = String(describing: Entity.self)
        Task { [weak self, pushEngine] in
            guard let self else { return }
            do {
                try await pushEngine.pushRawRecord(record, to: tableName)
            } catch {
                self.handlePushError(PushErrorContext(
                    error: error,
                    entityType: entityType,
                    entityId: entityID,
                    tableName: tableName,
                    record: record,
                    action: .update,
                ))
            }
        }

        // Post notification
        if let notification = config.notification {
            NotificationCenter.default.post(name: notification, object: nil)
        }

        polyInfo("PolySyncCoordinator: Undeleted \(Entity.self) \(entityID) with +1000 version jump")
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
    /// Operations that fail with permanent errors (version regression, immutable field)
    /// are dropped rather than re-queued, since retrying them will never succeed.
    ///
    /// - Returns: The number of operations successfully processed.
    @discardableResult
    public func processOfflineQueue() async -> Int {
        guard self.offlineQueue.hasPendingOperations else { return 0 }

        polyInfo("PolySyncCoordinator: Processing \(self.offlineQueue.pendingCount) offline operations")

        // Run offline queue replay off MainActor so large queues and disk I/O don't hitch the UI.
        // SwiftData persistence stays on MainActor; this is push-only replay of already-built records.
        let queue = self.offlineQueue

        return await Task.detached(priority: .utility) {
            await queue.processQueue { operation in
                do {
                    switch operation.action {
                    case .insert, .update:
                        // Decode the record and push
                        guard let payload = operation.payload else {
                            throw CoordinatorError.pushFailed(NSError(domain: "PolyBase", code: -1, userInfo: [
                                NSLocalizedDescriptionKey: "No payload for \(operation.action)",
                            ]))
                        }

                        let record = try JSONDecoder().decode([String: AnyJSON].self, from: payload)

                        let client = try PolyBaseClient.requireClient()
                        try await client
                            .from(operation.table)
                            .upsert(record, onConflict: "id")
                            .execute()

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

                        var update = [String: AnyJSON]()
                        update["version"] = .integer(version)
                        update["deleted"] = .bool(deleted)
                        update["updated_at"] = .string(ISO8601DateFormatter().string(from: Date()))

                        let client = try PolyBaseClient.requireClient()
                        try await client
                            .from(operation.table)
                            .update(update)
                            .eq("id", value: operation.entityId)
                            .execute()
                    }

                    polyDebug(
                        "PolySyncCoordinator: Processed queued \(operation.action.rawValue) for \(operation.table)/\(operation.entityId)",
                    )
                } catch {
                    // Check if this is a permanent error that should NOT be retried.
                    if Self.isPermanentOfflineQueueError(error) {
                        polyWarning(
                            "PolySyncCoordinator: Dropping queued operation for \(operation.table)/\(operation.entityId) - " +
                                "permanent error: \(error.localizedDescription)",
                        )
                        // Don't throw — treating as “processed” removes it from the queue.
                        return
                    }

                    // Transient error — throw to keep it in the queue.
                    throw error
                }
            }
        }.value
    }

    /// Clear all pending offline operations.
    ///
    /// Use with caution - this discards all queued operations without retrying them.
    public func clearOfflineQueue() {
        self.offlineQueue.clearQueue()
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
        guard self.registry.config(forTable: parentTable) != nil else {
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

        self.offlineQueue.enqueue(
            table: table,
            action: action,
            payload: payload,
            entityId: entityId,
        )

        polyInfo("PolySyncCoordinator: Queued \(action.rawValue) for \(table)/\(entityId)")
    }

    // MARK: - Error Classification

    /// Check if an error is a version regression (local version < remote version).
    ///
    /// Version regression errors are permanent failures — retrying won't help.
    /// The local entity is stale and needs to pull the remote state.
    private func isVersionRegressionError(_ error: Error) -> Bool {
        let errorString = String(describing: error)
        return errorString.contains("version regression")
    }

    /// Check if an error is a same-version mutation (benign duplicate).
    ///
    /// This happens when we try to push an entity that's already at the same version
    /// remotely — usually caused by concurrent push tasks. Treat as a no-op.
    private func isSameVersionMutationError(_ error: Error) -> Bool {
        let errorString = String(describing: error)
        return errorString.contains("same-version mutation is not allowed")
    }

    /// Check if an error is an invalid undelete attempt (permanent failure).
    ///
    /// The database requires undeletes to bump version by at least 1000.
    /// This prevents accidental resurrection. The local entity needs reconciliation.
    private func isInvalidUndeleteError(_ error: Error) -> Bool {
        let errorString = String(describing: error)
        return errorString.contains("undelete requires version")
    }

    private func handlePushError(_ context: PushErrorContext) {
        if self.isVersionRegressionError(context.error) {
            // Permanent failure: local is stale, needs reconciliation
            polyWarning(
                "PolySyncCoordinator: Version regression for \(context.entityType) \(context.entityId) - " +
                    "local is stale, will sync at next reconciliation",
            )
            // Post notification so app can trigger reconciliation if desired
            NotificationCenter.default.post(
                name: .polyBaseVersionRegressionDetected,
                object: nil,
                userInfo: [
                    "entityType": context.entityType,
                    "entityId": context.entityId,
                    "tableName": context.tableName,
                ],
            )
            // Do NOT queue — retrying will never succeed
            return
        }

        if self.isInvalidUndeleteError(context.error) {
            // Permanent failure: trying to undelete without proper version bump
            polyWarning(
                "PolySyncCoordinator: Invalid undelete attempt for \(context.entityType) \(context.entityId) - " +
                    "remote is deleted, local needs to adopt tombstone",
            )
            // Post notification so app can trigger reconciliation
            NotificationCenter.default.post(
                name: .polyBaseVersionRegressionDetected, // Reuse same notification
                object: nil,
                userInfo: [
                    "entityType": context.entityType,
                    "entityId": context.entityId,
                    "tableName": context.tableName,
                ],
            )
            // Do NOT queue — retrying will never succeed
            return
        }

        if self.isSameVersionMutationError(context.error) {
            // Benign duplicate — the push already happened, ignore
            polyDebug("PolySyncCoordinator: Same-version mutation for \(context.entityType) \(context.entityId) - ignoring")
            return
        }

        // Transient failure — queue for retry
        polyError("PolySyncCoordinator: Push failed for \(context.entityType) \(context.entityId), queueing for retry: \(context.error)")
        self.queueOperation(table: context.tableName, action: context.action, record: context.record, entityId: context.entityId)
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

    /// Posted when a version regression is detected during push.
    ///
    /// This means the local entity is stale (behind remote). The push was rejected
    /// and NOT queued for retry. Apps should trigger reconciliation to sync the
    /// latest remote state.
    ///
    /// UserInfo contains:
    /// - "entityType": String — the entity type name
    /// - "entityId": String — the entity ID
    /// - "tableName": String — the Supabase table name
    static let polyBaseVersionRegressionDetected = Notification.Name("polyBaseVersionRegressionDetected")
}
