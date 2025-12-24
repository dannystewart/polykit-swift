import Foundation
import SwiftData

// MARK: - PolyDataEntity

/// Describes a SwiftData model type for the Data Explorer.
///
/// Entities define how a specific model type is displayed and interacted with,
/// including columns, sort fields, fetch logic, and detail view configuration.
///
/// - Note: Use `eraseToAny()` to store heterogeneous entity types in a configuration.
public struct PolyDataEntity<Model: PersistentModel> {
    /// Unique identifier for this entity.
    public let id: String

    /// Display name shown in the tab/segment.
    public let displayName: String

    /// SF Symbol name for the entity icon.
    public let iconName: String

    /// Column definitions for the table view.
    public let columns: [PolyDataColumn<Model>]

    /// Available sort fields.
    public let sortFields: [PolyDataSortField<Model>]

    /// Default sort field ID.
    public let defaultSortFieldID: String

    /// Fields to show in the detail view.
    public let detailFields: [PolyDataField]

    /// Relationships to show in the detail view.
    public let detailRelationships: [PolyDataRelationship]

    /// Closure to fetch records with optional search text and sort descriptor.
    public let fetch: (ModelContext, String?, SortDescriptor<Model>) -> [Model]

    /// Closure to check if a record matches a search query.
    public let searchMatches: (Model, String) -> Bool

    /// Closure to check if a record matches a filter.
    public let filterMatches: (Model, PolyDataFilter) -> Bool

    /// Closure to delete a record.
    public let delete: @MainActor (Model, ModelContext) async -> Void

    /// Closure to get the record's unique ID as a string.
    public let recordID: (Model) -> String

    /// Closure to get record count (for stats).
    public let count: (ModelContext) -> Int

    // MARK: Initialization

    public init(
        id: String,
        displayName: String,
        iconName: String,
        columns: [PolyDataColumn<Model>],
        sortFields: [PolyDataSortField<Model>],
        defaultSortFieldID: String? = nil,
        detailFields: [PolyDataField] = [],
        detailRelationships: [PolyDataRelationship] = [],
        fetch: @escaping (ModelContext, String?, SortDescriptor<Model>) -> [Model],
        searchMatches: @escaping (Model, String) -> Bool,
        filterMatches: @escaping (Model, PolyDataFilter) -> Bool = { _, _ in true },
        delete: @escaping @MainActor (Model, ModelContext) async -> Void,
        recordID: @escaping (Model) -> String,
        count: @escaping (ModelContext) -> Int
    ) {
        self.id = id
        self.displayName = displayName
        self.iconName = iconName
        self.columns = columns
        self.sortFields = sortFields
        self.defaultSortFieldID = defaultSortFieldID ?? sortFields.first?.id ?? ""
        self.detailFields = detailFields
        self.detailRelationships = detailRelationships
        self.fetch = fetch
        self.searchMatches = searchMatches
        self.filterMatches = filterMatches
        self.delete = delete
        self.recordID = recordID
        self.count = count
    }

    /// Erases the generic type for heterogeneous storage.
    public func eraseToAny() -> AnyPolyDataEntity {
        AnyPolyDataEntity(self)
    }
}
