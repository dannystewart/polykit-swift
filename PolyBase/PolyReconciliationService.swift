//
//  PolyReconciliationService.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase
import SwiftData

// MARK: - ReconcileResult

/// Result of a reconciliation operation.
public struct ReconcileResult: Sendable {
    /// Number of records pulled from remote and merged locally.
    public let pulled: Int

    /// Number of records pushed to remote.
    public let pushed: Int

    /// Number of tombstones adopted locally (remote deleted, local wasn't).
    public let tombstonesAdopted: Int

    /// Number of records skipped (no action needed).
    public let skipped: Int

    /// Errors encountered during reconciliation.
    public let errors: [ReconcileError]

    /// Whether reconciliation completed without errors.
    public var succeeded: Bool { errors.isEmpty }

    /// Total records processed.
    public var total: Int { pulled + pushed + tombstonesAdopted + skipped }
}

// MARK: - ReconcileError

/// Error that occurred during reconciliation.
public struct ReconcileError: Error, Sendable {
    public let entityID: String
    public let action: String
    public let underlyingError: String

    public var localizedDescription: String {
        "Reconcile \(action) failed for \(entityID): \(underlyingError)"
    }
}

// MARK: - ReconcileAction

/// Action to take for a single entity during reconciliation.
private enum ReconcileAction {
    case pull // Remote is newer, fetch full record and merge
    case push // Local is newer, push to remote
    case adoptTombstone // Remote is deleted with >= version, mark local deleted
    case skip // No action needed
    case createLocal // Remote exists, local doesn't, create locally
    case createRemote // Local exists, remote doesn't, push to remote
}

// MARK: - PolyReconciliationService

/// Service for reconciling local and remote data.
///
/// Handles the complete reconciliation flow:
/// 1. Pulls version info from remote (efficient, minimal data)
/// 2. Compares with local entities
/// 3. Applies conflict resolution rules with tombstone stickiness
/// 4. Executes pulls and pushes as needed
///
/// ## Key Rule: Tombstone Stickiness
///
/// If remote is deleted with version >= local version, the deletion is adopted
/// locally. This prevents resurrection of deleted items.
///
/// ## Usage
///
/// ```swift
/// // Reconcile all items
/// let result = await PolyReconciliationService.shared.reconcile(Item.self)
/// print("↓\(result.pulled) ↑\(result.pushed) 🪦\(result.tombstonesAdopted)")
/// ```
@MainActor
public final class PolyReconciliationService {
    // MARK: - Singleton

    public static let shared: PolyReconciliationService = .init()

    // MARK: - Dependencies

    private let registry: PolyBaseRegistry = .shared
    private let pushEngine: PolyPushEngine = .shared
    private weak var modelContext: ModelContext?

    private init() {}

    // MARK: - Initialization

    /// Initialize with the app's model context.
    /// Call this once during app startup (can share context with PolySyncCoordinator).
    public func initialize(with context: ModelContext) {
        guard modelContext == nil else {
            polyDebug("PolyReconciliationService already initialized")
            return
        }
        modelContext = context
        polyInfo("PolyReconciliationService initialized")
    }

    // MARK: - Reconcile

    /// Reconcile all entities of a type with Supabase.
    ///
    /// This method:
    /// 1. Pulls all remote versions (id, version, deleted)
    /// 2. Compares with all local entities
    /// 3. Applies conflict resolution rules
    /// 4. Pulls records where remote is newer
    /// 5. Pushes records where local is newer (and remote isn't a sticky tombstone)
    /// 6. Adopts tombstones where remote is deleted with >= version
    ///
    /// - Parameter entityType: The entity type to reconcile
    /// - Returns: Summary of reconciliation actions taken
    public func reconcile<Entity: PolySyncable & PersistentModel>(
        _ entityType: Entity.Type,
    ) async -> ReconcileResult {
        guard let context = modelContext else {
            polyError("PolyReconciliationService: No model context")
            return ReconcileResult(
                pulled: 0,
                pushed: 0,
                tombstonesAdopted: 0,
                skipped: 0,
                errors: [ReconcileError(entityID: "", action: "init", underlyingError: "No model context")],
            )
        }

        guard let config = registry.config(for: entityType) else {
            polyError("PolyReconciliationService: Entity type not registered")
            return ReconcileResult(
                pulled: 0,
                pushed: 0,
                tombstonesAdopted: 0,
                skipped: 0,
                errors: [ReconcileError(
                    entityID: "",
                    action: "init",
                    underlyingError: "Entity type '\(String(describing: entityType))' not registered",
                )],
            )
        }

        let tableName = config.tableName
        var errors = [ReconcileError]()
        var pulled = 0
        var pushed = 0
        var tombstonesAdopted = 0
        var skipped = 0

        // 1. Pull all remote versions
        let remoteVersions: [String: (version: Int, deleted: Bool)]
        do {
            remoteVersions = try await pullVersions(entityType)
        } catch {
            polyError("PolyReconciliationService: Failed to pull versions: \(error)")
            return ReconcileResult(
                pulled: 0,
                pushed: 0,
                tombstonesAdopted: 0,
                skipped: 0,
                errors: [ReconcileError(entityID: "", action: "pullVersions", underlyingError: error.localizedDescription)],
            )
        }

        // 2. Fetch all local entities
        let localEntities: [Entity]
        do {
            let descriptor = FetchDescriptor<Entity>()
            localEntities = try context.fetch(descriptor)
        } catch {
            polyError("PolyReconciliationService: Failed to fetch local entities: \(error)")
            return ReconcileResult(
                pulled: 0,
                pushed: 0,
                tombstonesAdopted: 0,
                skipped: 0,
                errors: [ReconcileError(entityID: "", action: "fetchLocal", underlyingError: error.localizedDescription)],
            )
        }

        // 3. Build action plan
        var toPull = [String]() // IDs to fetch full record and merge
        var toPush = [Entity]() // Entities to push
        var toAdoptTombstone = [(Entity, Int)]() // Entities to mark deleted + version
        var localIDs = Set<String>()

        for entity in localEntities {
            localIDs.insert(entity.id)

            if let remote = remoteVersions[entity.id] {
                let action = determineAction(
                    localVersion: entity.version,
                    localDeleted: entity.deleted,
                    remoteVersion: remote.version,
                    remoteDeleted: remote.deleted,
                )

                switch action {
                case .pull:
                    toPull.append(entity.id)
                case .push:
                    toPush.append(entity)
                case .adoptTombstone:
                    toAdoptTombstone.append((entity, remote.version))
                case .skip:
                    skipped += 1
                case .createLocal, .createRemote:
                    // These shouldn't happen when both exist
                    skipped += 1
                }
            } else {
                // Local exists, remote doesn't → push (unless local is deleted)
                if !entity.deleted {
                    toPush.append(entity)
                } else {
                    skipped += 1
                }
            }
        }

        // Check for remote-only entities (need to create locally)
        for (remoteID, remote) in remoteVersions where !localIDs.contains(remoteID) {
            // Only pull if not deleted (no point creating a deleted entity)
            if !remote.deleted {
                toPull.append(remoteID)
            } else {
                skipped += 1
            }
        }

        // 4. Execute tombstone adoptions (local-only, no network)
        for (entity, remoteVersion) in toAdoptTombstone {
            entity.deleted = true
            entity.version = remoteVersion
            tombstonesAdopted += 1
        }

        if tombstonesAdopted > 0 {
            do {
                try context.save()
                polyInfo("PolyReconciliationService: Adopted \(tombstonesAdopted) tombstones")
            } catch {
                polyError("PolyReconciliationService: Failed to save tombstone adoptions: \(error)")
                errors.append(ReconcileError(
                    entityID: "",
                    action: "saveTombstones",
                    underlyingError: error.localizedDescription,
                ))
            }
        }

        // 5. Execute pulls (fetch full records and merge)
        if !toPull.isEmpty {
            let pullResults = await executePulls(toPull, entityType: entityType, config: config, context: context)
            pulled = pullResults.succeeded
            errors.append(contentsOf: pullResults.errors)
        }

        // 6. Execute pushes
        if !toPush.isEmpty {
            let pushResults = await executePushes(toPush, config: config)
            pushed = pushResults.succeeded
            errors.append(contentsOf: pushResults.errors)
        }

        let result = ReconcileResult(
            pulled: pulled,
            pushed: pushed,
            tombstonesAdopted: tombstonesAdopted,
            skipped: skipped,
            errors: errors,
        )

        polyInfo(
            "PolyReconciliationService: Reconciled \(tableName) - " +
                "↓\(pulled) ↑\(pushed) 🪦\(tombstonesAdopted) ⏭\(skipped)" +
                (errors.isEmpty ? "" : " ⚠️\(errors.count) errors"),
        )

        // Post notification
        if let notification = config.notification {
            NotificationCenter.default.post(name: notification, object: nil)
        }

        return result
    }

    // MARK: - Action Determination

    /// Determine what action to take for an entity.
    ///
    /// Key rules:
    /// 1. Tombstone stickiness: if remote is deleted with version >= local, adopt it
    /// 2. Higher version wins (when not a sticky tombstone)
    /// 3. Same version, same state → skip
    private func determineAction(
        localVersion: Int,
        localDeleted: Bool,
        remoteVersion: Int,
        remoteDeleted: Bool,
    ) -> ReconcileAction {
        // Rule 1: Tombstone stickiness
        // If remote is deleted with version >= local, and local isn't deleted, adopt the tombstone
        if remoteDeleted, remoteVersion >= localVersion, !localDeleted {
            return .adoptTombstone
        }

        // Rule 2: If local is deleted and remote isn't, and local version > remote, push the deletion
        if localDeleted, !remoteDeleted, localVersion > remoteVersion {
            return .push
        }

        // Rule 3: Higher version wins
        if remoteVersion > localVersion {
            return .pull
        }

        if localVersion > remoteVersion {
            // Only push if remote isn't a tombstone (already handled above, but be safe)
            if !remoteDeleted {
                return .push
            }
            // Local is newer but remote is a tombstone with lower version
            // This is the "intentional undelete" case - allow the push
            return .push
        }

        // Rule 4: Same version
        if remoteVersion == localVersion {
            // If deleted states differ, prefer the deleted state (tombstone wins ties)
            if remoteDeleted != localDeleted {
                if remoteDeleted {
                    return .adoptTombstone
                }
                // Local is deleted, remote isn't - push the deletion
                return .push
            }
            // Same version, same state
            return .skip
        }

        return .skip
    }

    // MARK: - Pull Execution

    /// Pull version info for all entities of a type.
    private func pullVersions(
        _ entityType: (some PolySyncable).Type,
    ) async throws -> [String: (version: Int, deleted: Bool)] {
        guard let config = registry.config(for: entityType) else {
            throw ReconcileServiceError.entityNotRegistered
        }

        let client = try PolyBaseClient.requireClient()

        var query = client.from(config.tableName).select("id,version,deleted")

        if config.includeUserID, let userID = PolyBaseAuth.shared.userID {
            query = query.eq(config.userIDColumn, value: userID.uuidString)
        }

        let response: [AnyJSON] = try await query.execute().value

        var versions = [String: (version: Int, deleted: Bool)]()
        for json in response {
            if
                case let .object(dict) = json,
                let id = dict["id"]?.stringValue,
                let version = dict["version"]?.integerValue
            {
                let deleted = dict["deleted"]?.boolValue ?? false
                versions[id] = (version, deleted)
            }
        }

        return versions
    }

    /// Execute pulls for a list of entity IDs.
    private func executePulls<Entity: PolySyncable & PersistentModel>(
        _ ids: [String],
        entityType _: Entity.Type,
        config: AnyEntityConfig,
        context: ModelContext,
    ) async -> (succeeded: Int, errors: [ReconcileError]) {
        guard !ids.isEmpty else { return (0, []) }

        var succeeded = 0
        var errors = [ReconcileError]()

        // Fetch full records in batches
        let batchSize = 100
        for batchStart in stride(from: 0, to: ids.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, ids.count)
            let batchIDs = Array(ids[batchStart ..< batchEnd])

            do {
                let client = try PolyBaseClient.requireClient()

                var query = client.from(config.tableName).select()

                if config.includeUserID, let userID = PolyBaseAuth.shared.userID {
                    query = query.eq(config.userIDColumn, value: userID.uuidString)
                }

                query = query.in("id", values: batchIDs)

                let response: [AnyJSON] = try await query.execute().value

                // Process each record
                for json in response {
                    guard case let .object(record) = json else { continue }
                    guard let id = record["id"]?.stringValue else { continue }

                    do {
                        // Try to find existing entity
                        let descriptor = FetchDescriptor<Entity>(
                            predicate: #Predicate { $0.id == id })
                        let existing = try context.fetch(descriptor).first

                        if let existing {
                            // Update existing
                            let pullEngine = PolyPullEngine(modelContext: context)
                            let result = pullEngine.mergeInto(record: record, local: existing, config: config)
                            if result.wasModified {
                                succeeded += 1
                            }
                        } else {
                            // Create new - requires entity-specific creation
                            // Post notification for app to handle
                            NotificationCenter.default.post(
                                name: .polyBaseNeedsEntityCreation,
                                object: nil,
                                userInfo: [
                                    "tableName": config.tableName,
                                    "record": record,
                                ],
                            )
                            succeeded += 1
                        }
                    } catch {
                        errors.append(ReconcileError(
                            entityID: id,
                            action: "merge",
                            underlyingError: error.localizedDescription,
                        ))
                    }
                }

                try context.save()

            } catch {
                for id in batchIDs {
                    errors.append(ReconcileError(
                        entityID: id,
                        action: "pull",
                        underlyingError: error.localizedDescription,
                    ))
                }
            }
        }

        return (succeeded, errors)
    }

    // MARK: - Push Execution

    /// Execute pushes for a list of entities.
    private func executePushes(
        _ entities: [some PolySyncable],
        config: AnyEntityConfig,
    ) async -> (succeeded: Int, errors: [ReconcileError]) {
        guard !entities.isEmpty else { return (0, []) }

        var succeeded = 0
        var errors = [ReconcileError]()

        // Mark all as recently pushed
        for entity in entities {
            pushEngine.markAsPushed(entity.id, table: config.tableName)
        }

        // Push in batches
        let batchSize = 100
        for batchStart in stride(from: 0, to: entities.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, entities.count)
            let batch = Array(entities[batchStart ..< batchEnd])

            do {
                // Build records
                var records = [[String: AnyJSON]]()
                for entity in batch {
                    let record = try pushEngine.buildRecord(from: entity, config: config)
                    records.append(record)
                }

                // Push batch
                let client = try PolyBaseClient.requireClient()
                try await client
                    .from(config.tableName)
                    .upsert(records, onConflict: "id")
                    .execute()

                succeeded += batch.count

            } catch {
                // If batch fails, try individual pushes
                for entity in batch {
                    do {
                        let record = try pushEngine.buildRecord(from: entity, config: config)
                        let client = try PolyBaseClient.requireClient()
                        try await client
                            .from(config.tableName)
                            .upsert(record, onConflict: "id")
                            .execute()
                        succeeded += 1
                    } catch {
                        errors.append(ReconcileError(
                            entityID: entity.id,
                            action: "push",
                            underlyingError: error.localizedDescription,
                        ))
                    }
                }
            }
        }

        return (succeeded, errors)
    }
}

// MARK: - ReconcileServiceError

private enum ReconcileServiceError: LocalizedError {
    case entityNotRegistered
    case noModelContext

    var errorDescription: String? {
        switch self {
        case .entityNotRegistered:
            "Entity type not registered with PolyBaseRegistry"
        case .noModelContext:
            "No ModelContext available"
        }
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when reconciliation needs to create a new entity.
    /// Apps should listen for this and create the entity from the provided record.
    ///
    /// UserInfo contains:
    /// - "tableName": String
    /// - "record": [String: AnyJSON]
    static let polyBaseNeedsEntityCreation = Notification.Name("polyBaseNeedsEntityCreation")
}
