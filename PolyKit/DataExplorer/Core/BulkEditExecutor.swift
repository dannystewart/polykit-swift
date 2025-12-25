//
//  BulkEditExecutor.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import SwiftData

// MARK: - BulkEditExecutor

/// Executes bulk edit operations on records.
@MainActor
public struct BulkEditExecutor {
    private let dataSource: PolyDataExplorerDataSource

    // MARK: Initialization

    public init(dataSource: PolyDataExplorerDataSource) {
        self.dataSource = dataSource
    }

    // MARK: Public Methods

    /// Executes a bulk edit operation on the provided preview records.
    ///
    /// - Parameter preview: The preview containing records to update.
    /// - Parameter operation: The operation to execute.
    /// - Returns: A result indicating success or failure.
    public func execute(preview: BulkEditPreview, operation: BulkEditOperation) async -> BulkEditResult {
        var updatedCount = 0

        do {
            // Update each record
            for previewRecord in preview.matchingRecords {
                let record = previewRecord.record

                // Apply the edit via the field's editAction
                if let editAction = operation.targetField.editAction {
                    editAction(record, operation.newValue)
                } else {
                    return BulkEditResult(updatedCount: 0, error: "Field \(operation.targetField.label) has no edit action")
                }

                // Increment version if requested
                if operation.incrementVersion {
                    self.incrementVersion(record)
                }

                updatedCount += 1
            }

            // Save the context
            try self.dataSource.modelContext.save()

            return BulkEditResult(updatedCount: updatedCount, error: nil)

        } catch {
            return BulkEditResult(
                updatedCount: updatedCount,
                error: "Failed to save changes: \(error.localizedDescription)",
            )
        }
    }

    // MARK: Private Helpers

    /// Increments the version field on a record if it exists.
    private func incrementVersion(_ record: AnyObject) {
        // Use mirror to find version property
        let mirror = Mirror(reflecting: record)

        for child in mirror.children {
            if child.label == "version", let version = child.value as? Int {
                // Set the new version value using KVC
                if let record = record as? NSObject {
                    record.setValue(version + 1, forKey: "version")
                }
                break
            }
        }
    }
}
