//
//  PolyPushEngine.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase

// MARK: - PolyPushEngine

/// Generic engine for pushing entities to Supabase.
///
/// Uses registered field mappings to build Supabase records,
/// handles encryption for marked fields, and manages batch operations.
///
/// ## Usage
///
/// ```swift
/// let engine = PolyPushEngine.shared
///
/// // Push a single entity
/// try await engine.push(message)
///
/// // Push multiple entities in batch
/// let count = await engine.pushBatch(messages, batchSize: 100)
/// ```
@MainActor
public final class PolyPushEngine {
    public static let shared: PolyPushEngine = .init()

    private let registry: PolyBaseRegistry = .shared
    /// Echo tracker used for realtime echo prevention.
    ///
    /// This is deliberately `nonisolated` so echo checks can be performed from
    /// background sync executors without hopping to `MainActor`.
    ///
    /// `PolyBaseEchoTracker` is internally thread-safe (lock-protected).
    private nonisolated static let echoTracker: PolyBaseEchoTracker = .init()

    private init() {}

    // MARK: - Single Entity Push

    /// Push a single entity to Supabase.
    ///
    /// - Parameter entity: The entity to push
    /// - Throws: If push fails or entity type is not registered
    public func push<Entity: PolySyncable>(_ entity: Entity) async throws {
        guard let config = registry.config(for: Entity.self) else {
            throw PolyPushError.entityNotRegistered(String(describing: Entity.self))
        }

        let record = try buildRecord(from: entity, config: config)

        let client = try PolyBaseClient.requireClient()
        try await client
            .from(config.tableName)
            .upsert(record, onConflict: "id")
            .execute()

        polyDebug("PolyPushEngine: Pushed \(Entity.self) \(entity.id)")
    }

    /// Push a single entity and mark it as recently pushed for echo prevention.
    ///
    /// Call this when you want to prevent the realtime subscription
    /// from processing this entity's echo.
    public func pushWithEchoTracking<Entity: PolySyncable>(_ entity: Entity) async throws {
        guard let config = registry.config(for: Entity.self) else {
            throw PolyPushError.entityNotRegistered(String(describing: Entity.self))
        }

        // Mark BEFORE push to prevent race conditions
        Self.markAsPushed(entity.id, table: config.tableName)

        try await push(entity)
    }

    // MARK: - Batch Push

    /// Push multiple entities in batches.
    ///
    /// - Parameters:
    ///   - entities: The entities to push
    ///   - batchSize: Maximum entities per batch (default: 100)
    /// - Returns: Number of successfully pushed entities
    @discardableResult
    public func pushBatch<Entity: PolySyncable>(
        _ entities: [Entity],
        batchSize: Int = 100,
    ) async -> Int {
        guard !entities.isEmpty else { return 0 }

        guard let config = registry.config(for: Entity.self) else {
            polyError("PolyPushEngine: Entity type \(Entity.self) not registered")
            return 0
        }

        var successCount = 0
        let client: SupabaseClient
        do {
            client = try PolyBaseClient.requireClient()
        } catch {
            polyError("PolyPushEngine: Client not configured: \(error)")
            return 0
        }

        // Process in batches
        for batchStart in stride(from: 0, to: entities.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, entities.count)
            let batch = Array(entities[batchStart ..< batchEnd])

            do {
                let records = try batch.map { try buildRecord(from: $0, config: config) }
                try await client
                    .from(config.tableName)
                    .upsert(records, onConflict: "id")
                    .execute()
                successCount += batch.count
            } catch {
                polyError("PolyPushEngine: Batch push failed: \(error)")
                // Continue with remaining batches
            }
        }

        polyInfo("PolyPushEngine: Pushed \(successCount)/\(entities.count) \(Entity.self) entities")
        return successCount
    }

    /// Push multiple entities with echo tracking.
    @discardableResult
    public func pushBatchWithEchoTracking<Entity: PolySyncable>(
        _ entities: [Entity],
        batchSize: Int = 100,
    ) async -> Int {
        guard let config = registry.config(for: Entity.self) else {
            polyError("PolyPushEngine: Entity type \(Entity.self) not registered")
            return 0
        }

        // Mark all BEFORE push
        for entity in entities {
            Self.markAsPushed(entity.id, table: config.tableName)
        }

        return await pushBatch(entities, batchSize: batchSize)
    }

    // MARK: - Tombstone Push

    /// Update an existing record to mark it as deleted (tombstone).
    ///
    /// Uses UPDATE instead of UPSERT because:
    /// 1. The row already exists (we're soft-deleting)
    /// 2. We only need to update version, deleted, and updated_at
    /// 3. UPSERT would require all NOT NULL columns
    ///
    /// This is nonisolated to allow network I/O off the main actor.
    public nonisolated func updateTombstone(
        id: String,
        version: Int,
        deleted: Bool,
        tableName: String,
    ) async throws {
        var record = [String: AnyJSON]()
        record["version"] = .integer(version)
        record["deleted"] = .bool(deleted)
        record["updated_at"] = .string(ISO8601DateFormatter().string(from: Date()))

        polyDebug("PolyPushEngine: Updating tombstone for \(tableName)/\(id) - version=\(version), deleted=\(deleted)")

        let client = try PolyBaseClient.requireClient()
        try await client
            .from(tableName)
            .update(record)
            .eq("id", value: id)
            .execute()

        polyDebug("PolyPushEngine: Updated tombstone for \(tableName)/\(id)")
    }

    /// Batch update existing records to mark them as deleted (tombstones).
    ///
    /// Uses individual UPDATE calls since Supabase doesn't support batch updates.
    /// This is nonisolated to allow network I/O off the main actor.
    @discardableResult
    public nonisolated func updateTombstones(
        tableName: String,
        tombstones: [(id: String, version: Int, deleted: Bool)],
    ) async -> Int {
        guard !tombstones.isEmpty else { return 0 }

        var successCount = 0
        for tombstone in tombstones {
            do {
                try await updateTombstone(
                    id: tombstone.id,
                    version: tombstone.version,
                    deleted: tombstone.deleted,
                    tableName: tableName,
                )
                successCount += 1

                // Yield periodically to prevent blocking
                if successCount % 10 == 0 {
                    await Task.yield()
                }
            } catch {
                polyError("PolyPushEngine: Failed to update tombstone \(tableName)/\(tombstone.id): \(error)")
            }
        }

        polyInfo("PolyPushEngine: Updated \(successCount)/\(tombstones.count) tombstones in \(tableName)")
        return successCount
    }

    /// Push multiple pre-built records to Supabase in a single batch.
    ///
    /// This is nonisolated to allow network I/O off the main actor.
    /// Records should be built on MainActor before calling this.
    public nonisolated func pushRawRecords(
        _ records: [[String: AnyJSON]],
        to tableName: String,
    ) async throws {
        guard !records.isEmpty else { return }

        let client = try PolyBaseClient.requireClient()
        try await client
            .from(tableName)
            .upsert(records, onConflict: "id")
            .execute()
    }

    /// Push a tombstone with captured values using UPSERT (for new records or full replacement).
    ///
    /// Note: This requires all NOT NULL columns to be included.
    /// For soft-deleting existing records, use updateTombstone instead.
    public func pushTombstone(
        id: String,
        version: Int,
        deleted: Bool,
        tableName: String,
    ) async throws {
        var record = [String: AnyJSON]()
        record["id"] = .string(id)
        record["version"] = .integer(version)
        record["deleted"] = .bool(deleted)
        record["updated_at"] = .string(ISO8601DateFormatter().string(from: Date()))

        if let userID = PolyBaseAuth.shared.userID {
            record["user_id"] = .string(userID.uuidString)
        }

        polyDebug("PolyPushEngine: Pushing tombstone for \(tableName)/\(id) - version=\(version), deleted=\(deleted)")

        let client = try PolyBaseClient.requireClient()
        try await client
            .from(tableName)
            .upsert(record, onConflict: "id")
            .execute()

        polyDebug("PolyPushEngine: Pushed tombstone for \(tableName)/\(id)")
    }

    /// Push a tombstone (deleted entity) to Supabase with additional fields.
    ///
    /// This is used when you've captured entity data before deletion
    /// to avoid race conditions with SwiftData.
    public func pushTombstoneWithFields(
        tableName: String,
        id: String,
        fields: [String: AnyJSON],
    ) async throws {
        var record = fields
        record["id"] = .string(id)
        record["deleted"] = .bool(true)
        record["updated_at"] = .string(ISO8601DateFormatter().string(from: Date()))

        if let userID = PolyBaseAuth.shared.userID {
            record["user_id"] = .string(userID.uuidString)
        }

        let client = try PolyBaseClient.requireClient()
        try await client
            .from(tableName)
            .upsert(record, onConflict: "id")
            .execute()

        polyDebug("PolyPushEngine: Pushed tombstone for \(tableName)/\(id)")
    }

    /// Push multiple tombstones in batch.
    @discardableResult
    public func pushTombstones(
        tableName: String,
        tombstones: [[String: AnyJSON]],
        batchSize: Int = 100,
    ) async -> Int {
        guard !tombstones.isEmpty else { return 0 }

        var successCount = 0
        let client: SupabaseClient
        do {
            client = try PolyBaseClient.requireClient()
        } catch {
            polyError("PolyPushEngine: Client not configured: \(error)")
            return 0
        }

        let userID = PolyBaseAuth.shared.userID

        // Process in batches
        for batchStart in stride(from: 0, to: tombstones.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, tombstones.count)
            let batch = Array(tombstones[batchStart ..< batchEnd])

            do {
                let records: [[String: AnyJSON]] = batch.map { tombstone in
                    var record = tombstone
                    record["deleted"] = .bool(true)
                    record["updated_at"] = .string(ISO8601DateFormatter().string(from: Date()))
                    if let userID {
                        record["user_id"] = .string(userID.uuidString)
                    }
                    return record
                }
                try await client
                    .from(tableName)
                    .upsert(records, onConflict: "id")
                    .execute()
                successCount += batch.count
            } catch {
                polyError("PolyPushEngine: Tombstone batch push failed: \(error)")
            }
        }

        polyInfo("PolyPushEngine: Pushed \(successCount)/\(tombstones.count) tombstones to \(tableName)")
        return successCount
    }

    // MARK: - Raw Record Push (for offline queue replay)

    /// Push a pre-built record dictionary to Supabase.
    ///
    /// Used by the offline queue to replay failed operations.
    /// The record should already contain all necessary fields including id, version, etc.
    ///
    /// - Parameters:
    ///   - record: The record dictionary (as built by buildRecord)
    ///   - tableName: The target table
    /// Push a pre-built record to Supabase.
    ///
    /// This is nonisolated to allow network I/O off the main actor.
    /// The record should be built on MainActor before calling this.
    public nonisolated func pushRawRecord(_ record: [String: AnyJSON], to tableName: String) async throws {
        let client = try PolyBaseClient.requireClient()
        try await client
            .from(tableName)
            .upsert(record, onConflict: "id")
            .execute()
    }

    // MARK: - Echo Tracking

    /// Check if an entity was recently pushed (for echo prevention).
    public func wasRecentlyPushed(_ id: String, table: String) -> Bool {
        Self.wasRecentlyPushed(id, table: table)
    }

    /// Mark an entity as recently pushed.
    public func markAsPushed(_ id: String, table: String) {
        Self.markAsPushed(id, table: table)
    }

    /// Check if an entity was recently pushed (for echo prevention).
    ///
    /// This is `nonisolated` to avoid accidental `MainActor` hops inside merge loops.
    public nonisolated static func wasRecentlyPushed(_ id: String, table: String) -> Bool {
        echoTracker.wasPushedRecently(id, table: table)
    }

    /// Mark an entity as recently pushed.
    ///
    /// This is `nonisolated` so callers can mark echoes without requiring `MainActor`.
    public nonisolated static func markAsPushed(_ id: String, table: String) {
        echoTracker.markAsPushed(id, table: table)
    }

    // MARK: - Record Building

    /// Build a Supabase record from an entity using registered mappings.
    ///
    /// Public so that callers (like PolySyncCoordinator) can build the record
    /// before attempting to push, enabling offline queue capture on failure.
    public func buildRecord(
        from entity: some PolySyncable,
        config: AnyEntityConfig,
    ) throws -> [String: AnyJSON] {
        var record = [String: AnyJSON]()

        // Add ID
        record["id"] = .string(entity.id)

        // Add mapped fields
        for field in config.fields {
            guard var value = field.getValue(from: entity) else { continue }

            // Handle encryption for marked fields
            if field.encrypted, let stringValue = field.getStringValue(from: entity) {
                if let userID = PolyBaseAuth.shared.userID {
                    if let encryption = PolyBaseEncryption.shared {
                        if let encrypted = encryption.encrypt(stringValue, forUserID: userID) {
                            value = .string(encrypted)
                        } else {
                            polyWarning("PolyPushEngine: Encryption failed for field '\(field.columnName)' on \(config.tableName)/\(entity.id) - using unencrypted value")
                        }
                    } else {
                        polyWarning("PolyPushEngine: Encryption not configured but field '\(field.columnName)' requires encryption - pushing unencrypted")
                    }
                } else {
                    polyWarning("PolyPushEngine: No user ID available for encryption of '\(field.columnName)' - pushing unencrypted")
                }
            }

            record[field.columnName] = value
        }

        // Add standard sync fields
        record["version"] = .integer(entity.version)
        record["deleted"] = .bool(entity.deleted)
        record["updated_at"] = .string(ISO8601DateFormatter().string(from: Date()))

        // Debug logging for sync issues
        polyDebug("PolyPushEngine: Building record for \(config.tableName)/\(entity.id) - version=\(entity.version), deleted=\(entity.deleted)")

        // Add user_id if configured
        if config.includeUserID, let userID = PolyBaseAuth.shared.userID {
            record[config.userIDColumn] = .string(userID.uuidString)
        }

        return record
    }
}

// MARK: - PolyPushError

/// Errors from push operations.
public enum PolyPushError: LocalizedError {
    case entityNotRegistered(String)
    case buildRecordFailed(String)
    case pushFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .entityNotRegistered(type):
            "Entity type '\(type)' is not registered with PolyBaseRegistry"
        case let .buildRecordFailed(reason):
            "Failed to build Supabase record: \(reason)"
        case let .pushFailed(reason):
            "Push to Supabase failed: \(reason)"
        }
    }
}
