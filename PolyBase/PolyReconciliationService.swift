//
//  PolyReconciliationService.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase
import SwiftData

// MARK: - PolyReconciliationResult

/// Result of a reconciliation operation.
public struct PolyReconciliationResult: Sendable {
    /// Per-table results
    public struct TableResult: Sendable {
        public let tableName: String
        public let remoteOnly: Int
        public let localOnly: Int
        public let remoteNewer: Int
        public let localNewer: Int
        public let deletionDrift: Int

        public var hasIssues: Bool {
            remoteOnly > 0 || localOnly > 0 || remoteNewer > 0 || localNewer > 0 || deletionDrift > 0
        }

        public var summary: String {
            if !hasIssues { return "OK" }
            var parts = [String]()
            if remoteOnly > 0 { parts.append("\(remoteOnly) remote-only") }
            if localOnly > 0 { parts.append("\(localOnly) local-only") }
            if remoteNewer > 0 { parts.append("\(remoteNewer) remote-newer") }
            if localNewer > 0 { parts.append("\(localNewer) local-newer") }
            if deletionDrift > 0 { parts.append("\(deletionDrift) deletion-drift") }
            return parts.joined(separator: ", ")
        }
    }

    /// Results for each table
    public let tableResults: [TableResult]

    /// Total issues across all tables
    public var totalIssues: Int {
        tableResults.reduce(0) { $0 + $1.remoteOnly + $1.localOnly + $1.remoteNewer + $1.localNewer + $1.deletionDrift }
    }

    /// Whether any tables have issues
    public var hasIssues: Bool {
        tableResults.contains { $0.hasIssues }
    }

    /// Human-readable summary
    public var summary: String {
        if !hasIssues { return "All tables in sync" }
        return tableResults
            .filter(\.hasIssues)
            .map { "\($0.tableName): \($0.summary)" }
            .joined(separator: "; ")
    }
}

// MARK: - PolyVersionState

/// Lightweight version state for reconciliation.
public struct PolyVersionState: Sendable, Equatable {
    public let version: Int
    public let deleted: Bool

    public init(version: Int, deleted: Bool) {
        self.version = version
        self.deleted = deleted
    }
}

// MARK: - PolyReconciliationService

/// Performs efficient version-based sync reconciliation.
///
/// Instead of downloading all data, compares version numbers to detect drift:
/// 1. Fetch remote versions (lightweight query)
/// 2. Compare with local versions
/// 3. Identify entities that need syncing
/// 4. Trigger targeted sync for mismatched entities
///
/// ## Usage
///
/// ```swift
/// let service = PolyReconciliationService(modelContext: context)
///
/// // Perform reconciliation
/// let result = await service.reconcile()
/// if result.hasIssues {
///     print("Found \(result.totalIssues) issues: \(result.summary)")
/// }
/// ```
@MainActor
public final class PolyReconciliationService {
    // MARK: - Version Diffing

    private struct VersionDiff {
        var remoteOnly: [String] = []
        var localOnly: [String] = []
        var remoteNewer: [String] = []
        var localNewer: [String] = []
        var deletionDrift: [String] = []

        var hasIssues: Bool {
            !remoteOnly.isEmpty || !localOnly.isEmpty || !remoteNewer.isEmpty || !localNewer.isEmpty || !deletionDrift.isEmpty
        }
    }

    /// Minimum time between automatic reconciliations
    public var minimumInterval: TimeInterval = 30

    /// Whether reconciliation is currently in progress
    public private(set) var isReconciling = false

    /// Last reconciliation time
    public private(set) var lastReconciliationTime: Date?

    /// Delegate for type-specific operations
    public weak var delegate: PolyReconciliationDelegate?

    private let registry: PolyBaseRegistry = .shared
    private let pullEngine: PolyPullEngine
    private weak var modelContext: ModelContext?

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
        pullEngine = PolyPullEngine(modelContext: modelContext)
    }

    // MARK: - Reconciliation

    /// Perform a full reconciliation across all registered tables.
    ///
    /// - Parameter force: If true, skip the minimum interval check
    /// - Returns: Reconciliation result with per-table status
    public func reconcile(force: Bool = false) async -> PolyReconciliationResult {
        guard !isReconciling else {
            polyDebug("PolyReconciliation: Already in progress, skipping")
            return PolyReconciliationResult(tableResults: [])
        }

        if
            !force,
            let lastTime = lastReconciliationTime,
            Date().timeIntervalSince(lastTime) < minimumInterval
        {
            polyDebug("PolyReconciliation: Too recent, skipping")
            return PolyReconciliationResult(tableResults: [])
        }

        isReconciling = true
        defer { isReconciling = false }

        polyInfo("PolyReconciliation: Starting reconciliation...")
        let startTime = Date()

        var tableResults = [PolyReconciliationResult.TableResult]()

        // Reconcile each registered table
        for tableName in registry.registeredTables {
            guard let config = registry.config(forTable: tableName) else { continue }

            do {
                let result = try await reconcileTable(tableName: tableName, config: config)
                tableResults.append(result)
            } catch {
                polyError("PolyReconciliation: Failed for \(tableName): \(error)")
                tableResults.append(PolyReconciliationResult.TableResult(
                    tableName: tableName,
                    remoteOnly: 0,
                    localOnly: 0,
                    remoteNewer: 0,
                    localNewer: 0,
                    deletionDrift: 0,
                ))
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let result = PolyReconciliationResult(tableResults: tableResults)

        lastReconciliationTime = Date()

        polyInfo("PolyReconciliation: Completed in \(String(format: "%.2f", elapsed))s - \(result.summary)")

        return result
    }

    /// Reconcile a single table.
    private func reconcileTable(
        tableName: String,
        config: AnyEntityConfig,
    ) async throws -> PolyReconciliationResult.TableResult {
        // 1. Fetch remote versions
        let remoteVersions = try await fetchRemoteVersions(tableName: tableName, config: config)

        // 2. Get local versions from delegate
        guard let localVersions = await delegate?.getLocalVersions(for: tableName) else {
            polyWarning("PolyReconciliation: No delegate to get local versions for \(tableName)")
            return PolyReconciliationResult.TableResult(
                tableName: tableName,
                remoteOnly: 0,
                localOnly: 0,
                remoteNewer: 0,
                localNewer: 0,
                deletionDrift: 0,
            )
        }

        // 3. Compare versions
        let diff = diffVersions(remote: remoteVersions, local: localVersions)

        // 4. Sync mismatched entities
        if diff.hasIssues {
            await syncMismatched(
                tableName: tableName,
                config: config,
                remoteVersions: remoteVersions,
                localVersions: localVersions,
                diff: diff,
            )
        }

        return PolyReconciliationResult.TableResult(
            tableName: tableName,
            remoteOnly: diff.remoteOnly.count,
            localOnly: diff.localOnly.count,
            remoteNewer: diff.remoteNewer.count,
            localNewer: diff.localNewer.count,
            deletionDrift: diff.deletionDrift.count,
        )
    }

    /// Fetch version numbers from remote.
    private func fetchRemoteVersions(
        tableName: String,
        config: AnyEntityConfig,
    ) async throws -> [String: PolyVersionState] {
        let client = try PolyBaseClient.requireClient()

        var query = client.from(tableName).select("id,version,deleted")

        if config.includeUserID, let userID = PolyBaseAuth.shared.userID {
            query = query.eq(config.userIDColumn, value: userID.uuidString)
        }

        let response: [AnyJSON] = try await query.execute().value

        var versions = [String: PolyVersionState]()
        for json in response {
            if
                case let .object(dict) = json,
                let id = dict["id"]?.stringValue,
                let version = dict["version"]?.integerValue
            {
                let deleted = dict["deleted"]?.boolValue ?? false
                versions[id] = PolyVersionState(version: version, deleted: deleted)
            }
        }

        return versions
    }

    private func diffVersions(
        remote: [String: PolyVersionState],
        local: [String: PolyVersionState],
    ) -> VersionDiff {
        var diff = VersionDiff()

        // Check remote against local
        for (id, remoteState) in remote {
            if let localState = local[id] {
                if remoteState.version > localState.version {
                    diff.remoteNewer.append(id)
                } else if localState.version > remoteState.version {
                    diff.localNewer.append(id)
                } else if remoteState.deleted != localState.deleted {
                    diff.deletionDrift.append(id)
                }
            } else {
                // Remote exists, local doesn't
                // Skip remote tombstones we never had
                if !remoteState.deleted {
                    diff.remoteOnly.append(id)
                }
            }
        }

        // Check for local-only
        for id in local.keys where remote[id] == nil {
            diff.localOnly.append(id)
        }

        return diff
    }

    // MARK: - Sync Mismatched

    private func syncMismatched(
        tableName: String,
        config _: AnyEntityConfig,
        remoteVersions: [String: PolyVersionState],
        localVersions _: [String: PolyVersionState],
        diff: VersionDiff)
        async
    {
        // Remote newer: Pull from remote
        if !diff.remoteNewer.isEmpty || !diff.remoteOnly.isEmpty {
            let idsToPull = diff.remoteNewer + diff.remoteOnly
            await delegate?.pullEntities(ids: idsToPull, tableName: tableName)
        }

        // Local newer: Push to remote
        if !diff.localNewer.isEmpty || !diff.localOnly.isEmpty {
            let idsToPush = diff.localNewer + diff.localOnly
            await delegate?.pushEntities(ids: idsToPush, tableName: tableName)
        }

        // Deletion drift: Use remote as source of truth
        if !diff.deletionDrift.isEmpty {
            await delegate?.healDeletionDrift(ids: diff.deletionDrift, tableName: tableName, remoteStates: remoteVersions)
        }
    }
}

// MARK: - PolyReconciliationDelegate

/// Delegate for type-specific reconciliation operations.
///
/// Apps implement this to provide local version information and
/// handle sync operations for their specific entity types.
@MainActor
public protocol PolyReconciliationDelegate: AnyObject {
    /// Get local version states for a table.
    func getLocalVersions(for tableName: String) async -> [String: PolyVersionState]?

    /// Pull specific entities from remote.
    func pullEntities(ids: [String], tableName: String) async

    /// Push specific entities to remote.
    func pushEntities(ids: [String], tableName: String) async

    /// Heal deletion drift for specific entities.
    func healDeletionDrift(ids: [String], tableName: String, remoteStates: [String: PolyVersionState]) async
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when reconciliation starts.
    static let polyBaseReconciliationDidStart = Notification.Name("polyBaseReconciliationDidStart")

    /// Posted when reconciliation completes.
    static let polyBaseReconciliationDidComplete = Notification.Name("polyBaseReconciliationDidComplete")
}
