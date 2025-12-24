//
//  PolyBaseOfflineQueue.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

// MARK: - PolyBaseOfflineOperation

/// A pending database operation to be synced when connectivity returns.
///
/// Operations are persisted to disk and automatically deduplicated
/// (newer operations for the same entity replace older ones).
public struct PolyBaseOfflineOperation: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case insert
        case update
        case delete
    }

    /// The Supabase table name (e.g., "items", "projects")
    public let table: String

    /// The type of operation
    public let action: Action

    /// JSON-encoded payload for insert/update operations
    public let payload: Data?

    /// The entity's unique identifier (for deduplication)
    public let entityId: String

    /// When this operation was queued
    public let queuedAt: Date

    public init(
        table: String,
        action: Action,
        payload: Data?,
        entityId: String,
        queuedAt: Date = Date(),
    ) {
        self.table = table
        self.action = action
        self.payload = payload
        self.entityId = entityId
        self.queuedAt = queuedAt
    }
}

// MARK: - PolyBaseOfflineQueue

/// Manages a queue of pending Supabase operations for offline support.
///
/// Operations are persisted to disk and processed when connectivity returns.
/// Uses automatic deduplication: newer operations for the same entity replace older ones.
///
/// ## Usage
/// ```swift
/// let queue = PolyBaseOfflineQueue(appName: "MyApp")
///
/// // Enqueue a failed operation
/// queue.enqueue(
///     table: "items",
///     action: .update,
///     payload: try JSONEncoder().encode(itemDTO),
///     entityId: item.id.uuidString
/// )
///
/// // Process queue when back online
/// await queue.processQueue { operation in
///     // Execute the operation against Supabase
///     switch operation.action {
///     case .insert:
///         try await supabase.from(operation.table).insert(operation.payload!).execute()
///     case .update:
///         try await supabase.from(operation.table).update(operation.payload!).execute()
///     case .delete:
///         try await supabase.from(operation.table).delete().eq("id", value: operation.entityId).execute()
///     }
/// }
/// ```
public final class PolyBaseOfflineQueue: @unchecked Sendable {
    private struct OperationKey: Hashable, Sendable {
        let table: String
        let entityId: String
    }

    private var operations: [PolyBaseOfflineOperation] = []
    private let fileURL: URL
    private let lock: NSLock = .init()

    /// Whether the queue has pending operations.
    public var hasPendingOperations: Bool {
        self.lock.lock()
        defer { lock.unlock() }
        return !self.operations.isEmpty
    }

    /// Number of pending operations.
    public var pendingCount: Int {
        self.lock.lock()
        defer { lock.unlock() }
        return self.operations.count
    }

    /// Create an offline queue for your app.
    ///
    /// - Parameter appName: Your app's name (used for the storage directory).
    ///                      Defaults to the bundle identifier or "PolyBase".
    public init(appName: String? = nil) {
        let name = appName ?? Bundle.main.bundleIdentifier ?? "PolyBase"

        // Store in app's Application Support directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
        ).first!
        let appDir = appSupport.appendingPathComponent(name, isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        self.fileURL = appDir.appendingPathComponent("offline_queue.json")

        // Load existing queue
        self.loadQueue()

        polyInfo("PolyBase: Offline queue initialized with \(self.operations.count) pending operations")
    }

    // MARK: - Enqueue Operations

    /// Add an operation to the queue.
    ///
    /// If an operation for the same entity already exists, it will be replaced
    /// (deduplication ensures only the latest operation is kept).
    ///
    /// - Parameters:
    ///   - table: The Supabase table name
    ///   - action: The operation type (.insert, .update, .delete)
    ///   - payload: JSON-encoded DTO for insert/update (nil for delete)
    ///   - entityId: The entity's unique identifier (UUID string or similar)
    public func enqueue(
        table: String,
        action: PolyBaseOfflineOperation.Action,
        payload: Data? = nil,
        entityId: String,
    ) {
        self.lock.lock()
        defer { lock.unlock() }

        // Remove any existing operation for this entity in this table
        self.operations.removeAll { $0.table == table && $0.entityId == entityId }

        // Add the new operation
        let operation = PolyBaseOfflineOperation(
            table: table,
            action: action,
            payload: payload,
            entityId: entityId,
        )
        self.operations.append(operation)

        self.saveQueue()
        polyInfo("PolyBase: Queued \(action.rawValue) for \(table)/\(entityId), queue size: \(self.operations.count)")
    }

    /// Convenience: Enqueue an insert operation with an Encodable payload.
    public func enqueueInsert(
        table: String,
        payload: some Encodable,
        entityId: String,
    ) {
        guard let data = try? JSONEncoder().encode(payload) else {
            polyError("PolyBase: Failed to encode payload for insert")
            return
        }
        self.enqueue(table: table, action: .insert, payload: data, entityId: entityId)
    }

    /// Convenience: Enqueue an update operation with an Encodable payload.
    public func enqueueUpdate(
        table: String,
        payload: some Encodable,
        entityId: String,
    ) {
        guard let data = try? JSONEncoder().encode(payload) else {
            polyError("PolyBase: Failed to encode payload for update")
            return
        }
        self.enqueue(table: table, action: .update, payload: data, entityId: entityId)
    }

    /// Convenience: Enqueue a delete operation.
    public func enqueueDelete(table: String, entityId: String) {
        self.enqueue(table: table, action: .delete, payload: nil, entityId: entityId)
    }

    // MARK: - Process Queue

    /// Process all queued operations.
    ///
    /// - Parameter executor: A closure that executes each operation against Supabase.
    ///                       Should throw if the operation fails (will be re-queued).
    /// - Returns: The number of operations successfully processed.
    @discardableResult
    public func processQueue(
        executor: @Sendable (PolyBaseOfflineOperation) async throws -> Void,
    ) async -> Int {
        let operationsToProcess = self.getOperationsSnapshot()

        guard !operationsToProcess.isEmpty else { return 0 }

        polyInfo("PolyBase: Processing \(operationsToProcess.count) pending operations")

        var failedOperations = [PolyBaseOfflineOperation]()
        var successCount = 0

        for operation in operationsToProcess {
            do {
                try await executor(operation)
                successCount += 1
            } catch {
                polyWarning("PolyBase: Operation failed, will retry later: \(error.localizedDescription)")
                failedOperations.append(operation)
            }
        }

        // IMPORTANT:
        // Do not overwrite the entire queue with only `failedOperations`.
        //
        // While we're processing, new operations can be enqueued (e.g. user edits while a replay is running).
        // If we blindly replace the queue, we'd drop those new operations. Instead, we:
        // - Remove only the snapshot operations we actually processed (matched by key + queuedAt)
        // - Re-add failures *only if* they weren't superseded by a newer enqueue for the same entity
        self.finalizeQueueAfterProcessing(snapshot: operationsToProcess, failed: failedOperations)

        if failedOperations.isEmpty {
            polyInfo("PolyBase: All \(successCount) operations processed successfully")
        } else {
            polyInfo("PolyBase: Processed \(successCount) operations, \(failedOperations.count) still pending")
        }

        return successCount
    }

    /// Clear all pending operations (use with caution).
    public func clearQueue() {
        self.lock.lock()
        defer { lock.unlock() }
        self.operations.removeAll()
        self.saveQueue()
        polyInfo("PolyBase: Queue cleared")
    }

    /// Get a snapshot of current operations (thread-safe, synchronous).
    private func getOperationsSnapshot() -> [PolyBaseOfflineOperation] {
        self.lock.lock()
        defer { lock.unlock() }
        return self.operations
    }

    /// Update the queue after processing a snapshot, without dropping concurrent enqueues.
    ///
    /// This removes processed operations from the queue **only if** they still match the snapshot’s
    /// `queuedAt` (i.e. haven't been replaced by a newer operation), then re-adds failures unless
    /// they were superseded by a newer enqueue.
    private func finalizeQueueAfterProcessing(
        snapshot: [PolyBaseOfflineOperation],
        failed: [PolyBaseOfflineOperation],
    ) {
        self.lock.lock()
        defer { lock.unlock() }

        let snapshotQueuedAtByKey: [OperationKey: Date] = Dictionary(
            uniqueKeysWithValues: snapshot.map { op in
                (OperationKey(table: op.table, entityId: op.entityId), op.queuedAt)
            })

        // Preserve any operations that were enqueued while processing was in-flight.
        var retained = [PolyBaseOfflineOperation]()
        retained.reserveCapacity(self.operations.count)

        for op in self.operations {
            let key = OperationKey(table: op.table, entityId: op.entityId)
            if let snapshotQueuedAt = snapshotQueuedAtByKey[key], snapshotQueuedAt == op.queuedAt {
                // This exact operation was part of the snapshot and is now processed (success or failure).
                // Drop it and re-add failures later if still relevant.
                continue
            }
            retained.append(op)
        }

        var retainedKeys = Set(retained.map { OperationKey(table: $0.table, entityId: $0.entityId) })

        for op in failed {
            let key = OperationKey(table: op.table, entityId: op.entityId)

            // If a newer operation for this entity was enqueued during processing, keep the newer one.
            guard !retainedKeys.contains(key) else { continue }

            retained.append(op)
            retainedKeys.insert(key)
        }

        self.operations = retained
        self.saveQueue()
    }

    // MARK: - Persistence

    private func loadQueue() {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            self.operations = try JSONDecoder().decode([PolyBaseOfflineOperation].self, from: data)
        } catch {
            polyWarning("PolyBase: Failed to load offline queue: \(error.localizedDescription)")
            self.operations = []
        }
    }

    private func saveQueue() {
        do {
            let data = try JSONEncoder().encode(self.operations)
            try data.write(to: self.fileURL, options: .atomic)
        } catch {
            polyError("PolyBase: Failed to save offline queue: \(error.localizedDescription)")
        }
    }
}
