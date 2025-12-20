//
//  PolyPullEngine.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase
import SwiftData

// MARK: - PolyPullResult

/// Result of a pull/merge operation.
public enum PolyPullResult: Sendable {
    /// Entity was created locally
    case created

    /// Entity was updated locally
    case updated

    /// Remote change was skipped (local version higher or echo)
    case skipped(reason: String)

    /// Remote change was rejected (conflict resolution)
    case rejected(reason: String)

    /// Merge failed with error
    case failed(Error)
}

// MARK: - PolyPullEngine

/// Generic engine for pulling and merging remote changes.
///
/// Uses registered field mappings to apply remote changes,
/// handles decryption for encrypted fields, and applies
/// conflict resolution rules.
///
/// ## Conflict Resolution
///
/// 1. **Higher version wins** - Core rule for all entities
/// 2. **Never overwrite content with empty** - Protects against data loss
/// 3. **Heal deletion drift** - Fixes same-version deletion mismatches
/// 4. **Skip echoes** - Ignores changes we just pushed
///
/// ## Usage
///
/// ```swift
/// let engine = PolyPullEngine(modelContext: context)
///
/// // Merge a remote record
/// let result = await engine.mergeRemote(
///     record: remoteRecord,
///     tableName: "messages",
///     isNew: true
/// )
/// ```
@MainActor
public final class PolyPullEngine {
    private let registry: PolyBaseRegistry = .shared
    private let pushEngine: PolyPushEngine = .shared
    private weak var modelContext: ModelContext?

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Merge Remote Record

    /// Merge a remote record into the local database.
    ///
    /// - Parameters:
    ///   - record: The remote record from Supabase
    ///   - tableName: The table this record came from
    ///   - isNew: Whether this is an INSERT (true) or UPDATE (false) event
    /// - Returns: The result of the merge operation
    public func mergeRemote(
        record: [String: AnyJSON],
        tableName: String,
        isNew _: Bool,
    ) async -> PolyPullResult {
        guard registry.config(forTable: tableName) != nil else {
            return .failed(PolyPullError.tableNotRegistered(tableName))
        }

        guard modelContext != nil else {
            return .failed(PolyPullError.noModelContext)
        }

        guard let remoteID = record["id"]?.stringValue else {
            return .failed(PolyPullError.missingID)
        }

        // Check for echo
        if pushEngine.wasRecentlyPushed(remoteID, table: tableName) {
            return .skipped(reason: "Echo from own push")
        }

        // Note: This method provides infrastructure checks only.
        // Actual merging requires type-specific fetch and is done via mergeInto.
        return .skipped(reason: "Generic merge requires type-specific implementation")
    }

    /// Merge a remote record into an existing entity.
    ///
    /// This is the core merge logic that applies conflict resolution rules.
    ///
    /// - Parameters:
    ///   - record: The remote record
    ///   - local: The existing local entity (or nil for new)
    ///   - config: The entity configuration
    /// - Returns: Whether the merge was applied
    public func mergeInto(
        record: [String: AnyJSON],
        local: (some PolySyncable)?,
        config: AnyEntityConfig,
    ) -> PolyPullResult {
        let remoteID = record["id"]?.stringValue ?? ""
        let remoteVersion = record["version"]?.integerValue ?? 0
        let remoteDeleted = record["deleted"]?.boolValue ?? false

        // Check for echo
        if pushEngine.wasRecentlyPushed(remoteID, table: config.tableName) {
            return .skipped(reason: "Echo from own push")
        }

        if let local {
            // UPDATE: Apply conflict resolution

            // Rule 1: Higher version wins
            if remoteVersion < local.version {
                return .skipped(reason: "Local version \(local.version) > remote \(remoteVersion)")
            }

            // Rule 2: Same version - only heal deletion drift
            if remoteVersion == local.version {
                if remoteDeleted != local.deleted {
                    local.deleted = remoteDeleted
                    return .updated
                }
                return .skipped(reason: "Same version, no changes")
            }

            // Rule 3: Check protected fields (don't overwrite non-empty with empty)
            if config.conflictRules.protectNonEmptyContent {
                for field in config.fields where config.conflictRules.protectedFields.contains(field.columnName) {
                    if
                        let currentValue = field.getStringValue(from: local),
                        !currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        if
                            let newValue = record[field.columnName]?.stringValue,
                            newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            return .rejected(reason: "Refusing to overwrite \(field.columnName) with empty")
                        }
                    }
                }
            }

            // Rule 4: Custom validator
            if let validator = config.conflictRules.customValidator {
                if !validator(local, record) {
                    return .rejected(reason: "Custom validator rejected change")
                }
            }

            // Apply update (local is a class, so we can mutate directly)
            applyFields(from: record, to: local, config: config)
            local.version = remoteVersion
            local.deleted = remoteDeleted

            return .updated

        } else {
            // INSERT: This requires creating a new entity
            // The caller must handle entity creation since we don't know the concrete type
            return .skipped(reason: "New entity requires type-specific creation")
        }
    }

    // MARK: - Bulk Pull

    /// Pull all entities of a type from Supabase.
    ///
    /// Useful for initial sync or full reconciliation.
    ///
    /// - Parameters:
    ///   - entityType: The entity type to pull
    ///   - filter: Optional filter predicate
    /// - Returns: Array of remote records
    public func pullAll<Entity: PolySyncable>(
        _ entityType: Entity.Type,
        filter: ((PostgrestFilterBuilder) -> PostgrestFilterBuilder)? = nil,
    ) async throws -> [[String: AnyJSON]] {
        guard let config = registry.config(for: entityType) else {
            throw PolyPullError.entityNotRegistered(String(describing: entityType))
        }

        let client = try PolyBaseClient.requireClient()

        var query = client.from(config.tableName).select()

        // Apply user filter for RLS
        if config.includeUserID, let userID = PolyBaseAuth.shared.userID {
            query = query.eq(config.userIDColumn, value: userID.uuidString)
        }

        // Apply custom filter
        if let filter {
            query = filter(query)
        }

        let response: [AnyJSON] = try await query.execute().value

        // Convert to record dictionaries
        let records: [[String: AnyJSON]] = response.compactMap { json in
            if case let .object(dict) = json {
                return dict
            }
            return nil
        }

        polyInfo("PolyPullEngine: Pulled \(records.count) \(Entity.self) records")
        return records
    }

    /// Pull version numbers for all entities of a type.
    ///
    /// Efficient query for reconciliation - only fetches id, version, deleted.
    public func pullVersions(
        _ entityType: (some PolySyncable).Type,
    ) async throws -> [String: (version: Int, deleted: Bool)] {
        guard let config = registry.config(for: entityType) else {
            throw PolyPullError.entityNotRegistered(String(describing: entityType))
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

    /// Apply field values from a remote record to a local entity.
    private func applyFields(
        from record: [String: AnyJSON],
        to entity: Any,
        config: AnyEntityConfig,
    ) {
        for field in config.fields {
            guard let value = record[field.columnName] else { continue }

            // Handle decryption
            if field.encrypted, let stringValue = value.stringValue {
                if
                    let userID = PolyBaseAuth.shared.userID,
                    let decrypted = PolyBaseEncryption.shared?.decrypt(stringValue, forUserID: userID)
                {
                    field.setStringValue(on: entity, value: decrypted)
                    continue
                }
            }

            // Apply value directly
            _ = field.setValue(on: entity, value: value)
        }
    }
}

// MARK: - PolyPullError

/// Errors from pull operations.
public enum PolyPullError: LocalizedError {
    case tableNotRegistered(String)
    case entityNotRegistered(String)
    case noModelContext
    case missingID
    case fetchFailed(String)
    case mergeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .tableNotRegistered(table):
            "Table '\(table)' is not registered with PolyBaseRegistry"
        case let .entityNotRegistered(type):
            "Entity type '\(type)' is not registered with PolyBaseRegistry"
        case .noModelContext:
            "No ModelContext available for pull operation"
        case .missingID:
            "Remote record is missing 'id' field"
        case let .fetchFailed(reason):
            "Fetch from Supabase failed: \(reason)"
        case let .mergeFailed(reason):
            "Merge failed: \(reason)"
        }
    }
}
