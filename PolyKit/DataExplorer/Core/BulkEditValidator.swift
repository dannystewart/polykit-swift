//
//  BulkEditValidator.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import SwiftData

// MARK: - BulkEditValidator

/// Validates bulk edit operations and generates previews.
@MainActor
public struct BulkEditValidator {
    private let dataSource: PolyDataExplorerDataSource

    // MARK: Initialization

    public init(dataSource: PolyDataExplorerDataSource) {
        self.dataSource = dataSource
    }

    // MARK: Public Methods

    /// Validates an operation and returns a list of validation errors.
    public func validate(_ operation: BulkEditOperation) -> [String] {
        var errors = [String]()

        // Check entity exists
        guard self.dataSource.configuration.entity(withID: operation.entityID) != nil else {
            errors.append("Entity not found")
            return errors
        }

        // Check target field is editable
        if !operation.targetField.isEditable {
            errors.append("\(operation.targetField.label) is not editable")
        }

        // Check target field is not a toggle (text only for now)
        if operation.targetField.isToggle {
            errors.append("\(operation.targetField.label) is a toggle field, not supported for bulk edit")
        }

        // Check where field exists and has text value
        if operation.whereField.isToggle {
            errors.append("Where field cannot be a toggle field")
        }

        // Check values are not empty
        if operation.newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("New value cannot be empty")
        }

        if operation.whereValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Where value cannot be empty")
        }

        return errors
    }

    /// Generates a preview of records that will be affected by the operation.
    ///
    /// - Parameters:
    ///   - operation: The bulk edit operation to preview.
    ///   - limit: Maximum number of records to include in preview (default: 5).
    /// - Returns: A preview object with matching records and their before/after values.
    public func preview(_ operation: BulkEditOperation, limit: Int = 5) -> BulkEditPreview? {
        guard let entity = dataSource.configuration.entity(withID: operation.entityID) else {
            return nil
        }

        // Fetch all records for this entity
        let allRecords = entity.fetchRecords(self.dataSource.modelContext, nil, entity.defaultSortFieldID, true)

        // Filter records where the whereField matches whereValue
        let matchingRecords = allRecords.filter { record in
            let value = operation.whereField.getValue(record)
            return value == operation.whereValue
        }

        // Build preview records (limited)
        let previewLimit = min(limit, matchingRecords.count)
        let hasMore = matchingRecords.count > limit

        let previews: [BulkEditPreviewRecord] = matchingRecords.prefix(previewLimit).map { record in
            let recordID = entity.recordID(record)
            let displayName = self.getRecordDisplayName(record, entity: entity)
            let currentValue = operation.targetField.getValue(record)

            return BulkEditPreviewRecord(
                id: recordID,
                displayName: displayName,
                currentValue: currentValue,
                newValue: operation.newValue,
                record: record,
            )
        }

        return BulkEditPreview(matchingRecords: previews, hasMore: hasMore)
    }

    // MARK: Private Helpers

    /// Gets a friendly display name for a record.
    private func getRecordDisplayName(_ record: AnyObject, entity: AnyPolyDataEntity) -> String {
        // Try to use first column as display name if available
        if entity.columnCount > 0 {
            let firstColumnValue = entity.cellValue(record, 0)
            if !firstColumnValue.isEmpty, firstColumnValue != "—" {
                return firstColumnValue
            }
        }

        // Fall back to record ID
        return entity.recordID(record)
    }
}
