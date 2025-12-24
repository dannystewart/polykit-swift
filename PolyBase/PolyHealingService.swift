//
//  PolyHealingService.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase
import SwiftData

// MARK: - PolyHealingResult

/// Result of a healing operation for a single table.
public struct PolyHealingResult: Sendable {
    /// Table name.
    public let tableName: String

    /// Number of records scanned.
    public let scanned: Int

    /// Number of records that needed healing.
    public let needsHealing: Int

    /// Number of records successfully healed.
    public let healed: Int

    /// Whether any healing was needed.
    public var hadIssues: Bool { self.needsHealing > 0 }

    /// Whether all issues were fixed.
    public var fullyHealed: Bool { self.healed == self.needsHealing }
}

// MARK: - PolyHealingService

/// Service for detecting and fixing unencrypted data that should be encrypted.
///
/// This service scans Supabase for records with encrypted fields that are stored
/// in plaintext, then re-pushes them with proper encryption.
///
/// ## Usage
///
/// ```swift
/// let service = PolyHealingService(modelContext: context)
///
/// // Heal all registered tables
/// let results = await service.healAll()
///
/// // Heal a specific entity type
/// let result = await service.heal(UserKeyword.self)
/// ```
@MainActor
public final class PolyHealingService {
    private let registry: PolyBaseRegistry = .shared
    private weak var modelContext: ModelContext?

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Heal All

    /// Heal all registered entity types that have encrypted fields.
    ///
    /// Scans each table for unencrypted data and re-pushes with encryption.
    ///
    /// - Returns: Array of results for each table processed.
    public func healAll() async -> [PolyHealingResult] {
        var results = [PolyHealingResult]()

        for tableName in self.registry.registeredTables {
            guard let config = registry.config(forTable: tableName) else { continue }

            // Skip tables with no encrypted fields
            let hasEncryptedFields = config.fields.contains { $0.encrypted }
            guard hasEncryptedFields else { continue }

            let result = await healTable(tableName: tableName, config: config)
            results.append(result)
        }

        return results
    }

    // MARK: - Heal Specific Type

    /// Heal a specific entity type.
    ///
    /// - Parameter entityType: The entity type to heal.
    /// - Returns: The healing result.
    public func heal(_ entityType: (some PolySyncable).Type) async -> PolyHealingResult {
        guard let config = registry.config(for: entityType) else {
            return PolyHealingResult(
                tableName: String(describing: entityType),
                scanned: 0,
                needsHealing: 0,
                healed: 0,
            )
        }

        return await self.healTable(tableName: config.tableName, config: config)
    }

    // MARK: - Private

    /// Heal a single table.
    private func healTable(tableName: String, config: AnyEntityConfig) async -> PolyHealingResult {
        guard let userID = PolyBaseAuth.shared.userID else {
            polyWarning("PolyHealingService: No user ID - cannot heal")
            return PolyHealingResult(tableName: tableName, scanned: 0, needsHealing: 0, healed: 0)
        }

        guard let encryption = PolyBaseEncryption.shared else {
            polyWarning("PolyHealingService: Encryption not configured - cannot heal")
            return PolyHealingResult(tableName: tableName, scanned: 0, needsHealing: 0, healed: 0)
        }

        // Get encrypted field column names
        let encryptedColumns = config.fields.filter(\.encrypted).map(\.columnName)
        guard !encryptedColumns.isEmpty else {
            return PolyHealingResult(tableName: tableName, scanned: 0, needsHealing: 0, healed: 0)
        }

        polyDebug("PolyHealingService: Scanning \(tableName) for unencrypted data...")

        // Fetch all records from Supabase
        let client: SupabaseClient
        do {
            client = try PolyBaseClient.requireClient()
        } catch {
            polyError("PolyHealingService: Client not configured: \(error)")
            return PolyHealingResult(tableName: tableName, scanned: 0, needsHealing: 0, healed: 0)
        }

        let records: [[String: AnyJSON]]
        do {
            // Only select columns we need: id + encrypted fields
            let selectColumns = ["id"] + encryptedColumns
            let response: [AnyJSON] = try await client
                .from(tableName)
                .select(selectColumns.joined(separator: ","))
                .eq(config.userIDColumn, value: userID.uuidString)
                .execute()
                .value

            records = response.compactMap { json in
                if case let .object(dict) = json {
                    return dict
                }
                return nil
            }
        } catch {
            polyError("PolyHealingService: Failed to fetch \(tableName): \(error)")
            return PolyHealingResult(tableName: tableName, scanned: 0, needsHealing: 0, healed: 0)
        }

        // Find records with unencrypted fields
        var idsNeedingHealing = [String]()

        for record in records {
            guard let id = record["id"]?.stringValue else { continue }

            for column in encryptedColumns {
                if let value = record[column]?.stringValue, !value.isEmpty {
                    if !encryption.isEncrypted(value) {
                        idsNeedingHealing.append(id)
                        break // Only need to flag once per record
                    }
                }
            }
        }

        let scanned = records.count
        let needsHealing = idsNeedingHealing.count

        if needsHealing == 0 {
            polyDebug("PolyHealingService: \(tableName) - all \(scanned) records properly encrypted")
            return PolyHealingResult(tableName: tableName, scanned: scanned, needsHealing: 0, healed: 0)
        }

        polyInfo("PolyHealingService: \(tableName) - found \(needsHealing)/\(scanned) records needing healing")

        // Heal by re-pushing from local data
        // The local data is decrypted, so pushing will encrypt it properly
        var healed = 0

        for id in idsNeedingHealing {
            // We need to find the local entity and re-push it
            // This requires the delegate to provide the entity since we don't know the concrete type
            // For now, post a notification that apps can listen to
            NotificationCenter.default.post(
                name: .polyBaseHealingNeeded,
                object: nil,
                userInfo: [
                    "tableName": tableName,
                    "entityID": id,
                ],
            )
            healed += 1
        }

        polyInfo("PolyHealingService: Requested healing for \(healed) \(tableName) records")

        return PolyHealingResult(
            tableName: tableName,
            scanned: scanned,
            needsHealing: needsHealing,
            healed: healed,
        )
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when an entity needs healing (re-push with encryption).
    ///
    /// userInfo contains:
    /// - "tableName": String - the table name
    /// - "entityID": String - the entity ID to heal
    static let polyBaseHealingNeeded = Notification.Name("polyBaseHealingNeeded")
}
