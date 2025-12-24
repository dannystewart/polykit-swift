//
//  AnyPolyDataEntity.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import SwiftData

// MARK: - AnyPolyDataEntity

/// Type-erased wrapper for `PolyDataEntity` to allow heterogeneous storage.
///
/// This wrapper captures all the entity's operations as closures that work
/// with `AnyObject`, enabling storage of different entity types in a single array.
public struct AnyPolyDataEntity {
    /// Unique identifier for this entity.
    public let id: String

    /// Display name shown in the tab/segment.
    public let displayName: String

    /// SF Symbol name for the entity icon.
    public let iconName: String

    // MARK: Column Information

    /// Number of columns.
    public let columnCount: Int

    /// Get column ID at index.
    public let columnID: (Int) -> String

    /// Get column title at index.
    public let columnTitle: (Int) -> String

    /// Get column width at index.
    public let columnWidth: (Int) -> CGFloat

    /// Get column min width at index.
    public let columnMinWidth: (Int) -> CGFloat

    /// Get column max width at index.
    public let columnMaxWidth: (Int) -> CGFloat

    /// Check if column at index is sortable.
    public let columnIsSortable: (Int) -> Bool

    // MARK: Sort Fields

    /// Number of sort fields.
    public let sortFieldCount: Int

    /// Get sort field ID at index.
    public let sortFieldID: (Int) -> String

    /// Get sort field display name at index.
    public let sortFieldDisplayName: (Int) -> String

    /// Get default ascending for sort field at index.
    public let sortFieldDefaultAscending: (Int) -> Bool

    /// Default sort field ID.
    public let defaultSortFieldID: String

    // MARK: Detail View

    /// Fields for the detail view.
    public let detailFields: [PolyDataField]

    /// Relationships for the detail view.
    public let detailRelationships: [PolyDataRelationship]

    // MARK: Data Operations

    /// Fetch records with optional search text and sort configuration.
    /// Parameters: (context, searchText, sortFieldID, ascending) -> [AnyObject]
    public let fetchRecords: (ModelContext, String?, String, Bool) -> [AnyObject]

    /// Get the cell value for a record at a column index.
    public let cellValue: (AnyObject, Int) -> String

    /// Get the cell text color for a record at a column index.
    public let cellColor: (AnyObject, Int, PolyDataIntegrityReport?) -> PolyColor?

    /// Get the cell badge for a record at a column index (iOS).
    public let cellBadge: (AnyObject, Int, PolyDataIntegrityReport?) -> PolyDataBadge?

    /// Check if a record matches a filter.
    public let recordMatchesFilter: (AnyObject, PolyDataFilter) -> Bool

    /// Delete a record.
    public let deleteRecord: @MainActor (AnyObject, ModelContext) async -> Void

    /// Get the record's unique ID as a string.
    public let recordID: (AnyObject) -> String

    /// Get the total count of records.
    public let recordCount: (ModelContext) -> Int

    // MARK: Initialization

    /// Creates a type-erased wrapper from a typed entity.
    public init<Model: PersistentModel>(_ entity: PolyDataEntity<Model>) {
        id = entity.id
        displayName = entity.displayName
        iconName = entity.iconName

        // Column info
        columnCount = entity.columns.count
        columnID = { entity.columns[$0].id }
        columnTitle = { entity.columns[$0].title }
        columnWidth = { entity.columns[$0].width }
        columnMinWidth = { entity.columns[$0].minWidth }
        columnMaxWidth = { entity.columns[$0].maxWidth }
        columnIsSortable = { entity.columns[$0].isSortable }

        // Sort fields
        sortFieldCount = entity.sortFields.count
        sortFieldID = { entity.sortFields[$0].id }
        sortFieldDisplayName = { entity.sortFields[$0].displayName }
        sortFieldDefaultAscending = { entity.sortFields[$0].defaultAscending }
        defaultSortFieldID = entity.defaultSortFieldID

        // Detail view
        detailFields = entity.detailFields
        detailRelationships = entity.detailRelationships

        // Capture sort field makers for later use
        let sortFieldMakers = entity.sortFields.map { field in
            (id: field.id, maker: field.makeSortDescriptor)
        }

        // Capture closures to avoid capturing the whole entity
        let fetchFn = entity.fetch
        let searchMatchesFn = entity.searchMatches
        let columns = entity.columns

        // Fetch records
        fetchRecords = { context, searchText, sortFieldID, ascending in
            // Find the sort descriptor maker
            let order: SortOrder = ascending ? .forward : .reverse
            let sortDescriptor: SortDescriptor<Model> = if let maker = sortFieldMakers.first(where: { $0.id == sortFieldID })?.maker {
                maker(order)
            } else if let firstMaker = sortFieldMakers.first?.maker {
                firstMaker(order)
            } else {
                // Fallback: no sorting
                SortDescriptor(\Model.persistentModelID.storeIdentifier, order: order)
            }

            var records = fetchFn(context, searchText, sortDescriptor)

            // Apply search filter if provided
            if let searchText, !searchText.isEmpty {
                records = records.filter { searchMatchesFn($0, searchText) }
            }

            return records.map { $0 as AnyObject }
        }

        // Cell value extraction
        cellValue = { record, columnIndex in
            guard
                let model = record as? Model,
                columnIndex < columns.count else { return "" }
            return columns[columnIndex].getValue(model)
        }

        // Cell color extraction
        cellColor = { record, columnIndex, report in
            guard
                let model = record as? Model,
                columnIndex < columns.count else { return nil }
            return columns[columnIndex].getTextColor?(model, report)
        }

        // Cell badge extraction
        cellBadge = { record, columnIndex, report in
            guard
                let model = record as? Model,
                columnIndex < columns.count else { return nil }
            return columns[columnIndex].getBadge?(model, report)
        }

        // Filter matching
        let filterMatchesFn = entity.filterMatches
        recordMatchesFilter = { record, filter in
            guard let model = record as? Model else { return false }
            return filterMatchesFn(model, filter)
        }

        // Delete record - capture only the delete closure to avoid data races
        let deleteFn = entity.delete
        deleteRecord = { record, context in
            guard let model = record as? Model else { return }
            await deleteFn(model, context)
        }

        // Record ID
        let recordIDFn = entity.recordID
        recordID = { record in
            guard let model = record as? Model else { return "" }
            return recordIDFn(model)
        }

        // Record count
        let countFn = entity.count
        recordCount = { context in
            countFn(context)
        }
    }
}

// MARK: Identifiable

extension AnyPolyDataEntity: Identifiable {}
